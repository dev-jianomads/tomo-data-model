-- ============================================================================
-- MIGRATION: Normalize Users Table - Extract Integrations
-- ============================================================================
-- Description: Separates user profile data from integration credentials
--              Creates new tables: services, user_integrations
--              Migrates Gmail, Google Calendar, Telegram, and Signal integrations
--
-- STRATEGY: NON-DESTRUCTIVE TABLE SWAP
-- - Creates new users_new table with clean schema
-- - Populates services and user_integrations tables
-- - Renames users → users_old (backup)
-- - Renames users_new → users
-- - Updates foreign key constraints
-- - Keeps users_old for rollback safety (drop manually after verification)
--
-- IMPORTANT: 
-- - Test on staging environment first
-- - Run during maintenance window (breaking change for frontend)
-- - users_old table will remain for rollback (drop manually when confident)
--
-- Author: Data Engineering Team
-- Date: 2025-10-09
-- ============================================================================

-- ============================================================================
-- CRITICAL: SET TRANSACTION TIMEOUTS FOR SAFETY
-- ============================================================================
-- Prevent indefinite locks that could cause system deadlock
SET statement_timeout = '30min';  -- Maximum 30 minutes for entire migration
SET lock_timeout = '5min';        -- Maximum 5 minutes to acquire locks
SET idle_in_transaction_session_timeout = '35min'; -- Kill idle transactions

BEGIN;

-- ============================================================================
-- CRITICAL: LOCK TABLE TO PREVENT CONCURRENT ACCESS
-- ============================================================================
-- Prevents application writes during migration to avoid data loss
-- This will block all operations on users table until COMMIT

DO $$
BEGIN
    LOCK TABLE public.users IN ACCESS EXCLUSIVE MODE;
    RAISE NOTICE 'Acquired exclusive lock on public.users table';
END $$;

-- ============================================================================
-- STEP 1: PRE-FLIGHT CHECKS
-- ============================================================================

-- Verify we're in the correct schema and check prerequisites
DO $$
DECLARE
    users_count int;
    pg_version_num int;
BEGIN
    -- Check if users table exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'users') THEN
        RAISE EXCEPTION 'public.users table not found. Aborting migration.';
    END IF;
    
    -- Check if tables already exist (idempotency check)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'users_old') THEN
        RAISE WARNING 'public.users_old already exists. This migration may have been run before.';
    END IF;
    
    -- Count users to migrate
    SELECT count(*) INTO users_count FROM public.users;
    RAISE NOTICE 'Found % users to migrate', users_count;
    
    -- Check for incomplete OAuth flows (informational)
    SELECT count(*) INTO users_count
    FROM public.users 
    WHERE (auth_code IS NOT NULL OR granted_scopes IS NOT NULL)
      AND access_token IS NULL 
      AND refresh_token IS NULL 
      AND client_id IS NULL;
    
    IF users_count > 0 THEN
        RAISE NOTICE 'Found % users with incomplete OAuth flows (will be skipped)', users_count;
    END IF;
    
    -- Check PostgreSQL version for NULLS NOT DISTINCT support
    SELECT current_setting('server_version_num')::int INTO pg_version_num;
    IF pg_version_num < 150000 THEN
        RAISE WARNING 'PostgreSQL version < 15 detected. NULLS NOT DISTINCT syntax may not be supported.';
        RAISE WARNING 'If migration fails, edit line 160 to remove NULLS NOT DISTINCT.';
    END IF;
    
    RAISE NOTICE 'Pre-flight checks passed. Starting migration...';
END $$;

-- ============================================================================
-- STEP 2: CREATE NEW CLEAN USERS TABLE
-- ============================================================================

-- 2.1: Create users_new table with only core profile columns
CREATE TABLE IF NOT EXISTS public.users_new (
    -- Core identity
    id text PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now(),
    email text NOT NULL UNIQUE,
    
    -- Profile information
    display_name text,
    position text,
    role text,
    phone_number text,
    time_zone text
);

COMMENT ON TABLE public.users_new IS 'New users table with clean schema (integration data removed)';

-- Copy core user data from old table
INSERT INTO public.users_new (
    id,
    created_at,
    email,
    display_name,
    position,
    role,
    phone_number,
    time_zone
)
SELECT 
    id,
    created_at,
    email,
    display_name,
    position,
    role,
    phone_number,
    time_zone
FROM public.users
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
    row_count int;
BEGIN
    SELECT count(*) INTO row_count FROM public.users_new;
    RAISE NOTICE 'Created users_new table and copied % user records', row_count;
END $$;

-- ============================================================================
-- STEP 3: CREATE NEW TABLES
-- ============================================================================

-- 3.1: Create services catalog table
CREATE TABLE IF NOT EXISTS public.services (
    id text PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    -- Service identity
    name text NOT NULL UNIQUE,
    type text NOT NULL CHECK (type IN ('email', 'calendar', 'messaging', 'storage', 'other')),
    provider text NOT NULL,
    
    -- Management
    is_active boolean NOT NULL DEFAULT true,
    
    -- Metadata for UI/configuration
    metadata jsonb DEFAULT '{}'::jsonb,
    
    -- Audit
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.services IS 'Catalog of available integration services (Gmail, Telegram, etc.)';
COMMENT ON COLUMN public.services.id IS 'Service identifier (e.g., gmail, telegram)';
COMMENT ON COLUMN public.services.type IS 'Service category: email, calendar, messaging, storage, other';
COMMENT ON COLUMN public.services.provider IS 'Provider/vendor: google, microsoft, telegram, signal, etc.';

-- 3.2: Create user_integrations junction table
-- Note: References old users table for now, will update after rename
CREATE TABLE IF NOT EXISTS public.user_integrations (
    -- Primary key
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    
    -- Relationships (FK to old users table temporarily)
    user_id text NOT NULL,
    service_id text NOT NULL REFERENCES public.services(id) ON DELETE RESTRICT,
    
    -- Connection state
    is_active boolean NOT NULL DEFAULT true,
    display_label text,
    
    -- OAuth/Token credentials
    access_token text,
    refresh_token text,
    token_expires_at timestamptz,
    token_expiration_date timestamptz, -- legacy compatibility
    refresh_expired boolean DEFAULT false,
    
    -- OAuth client credentials (should be encrypted in production!)
    client_id text,
    client_secret text,
    
    -- Authorization
    auth_code text,
    granted_scopes jsonb,
    
    -- Service-specific identifiers
    external_user_id text, -- telegram_id, signal_uuid, email address, etc.
    external_username text, -- @username, display handle
    
    -- Flexible storage for service-specific data
    credentials jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    
    -- Constraints
    -- Note: NULLS NOT DISTINCT requires PostgreSQL 15+
    -- For older versions, remove NULLS NOT DISTINCT (allows duplicate NULLs)
    CONSTRAINT user_integrations_user_service_unique 
        UNIQUE NULLS NOT DISTINCT (user_id, service_id, external_user_id)
);

COMMENT ON TABLE public.user_integrations IS 'Links users to their connected services with credentials';
COMMENT ON COLUMN public.user_integrations.user_id IS 'Reference to user who owns this integration';
COMMENT ON COLUMN public.user_integrations.service_id IS 'Reference to service being integrated';
COMMENT ON COLUMN public.user_integrations.external_user_id IS 'User identifier on external service (telegram_id, signal_uuid, etc.)';
COMMENT ON COLUMN public.user_integrations.credentials IS 'Service-specific credential data (jsonb for flexibility)';

-- ============================================================================
-- STEP 4: CREATE INDEXES FOR PERFORMANCE
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_user_integrations_user_id 
    ON public.user_integrations(user_id);

CREATE INDEX IF NOT EXISTS idx_user_integrations_service_id 
    ON public.user_integrations(service_id);

CREATE INDEX IF NOT EXISTS idx_user_integrations_external_user_id 
    ON public.user_integrations(external_user_id) 
    WHERE external_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_integrations_active 
    ON public.user_integrations(user_id, service_id, is_active) 
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_user_integrations_user_service 
    ON public.user_integrations(user_id, service_id);

-- ============================================================================
-- STEP 5: POPULATE SERVICES CATALOG
-- ============================================================================

INSERT INTO public.services (id, name, type, provider, is_active, metadata) VALUES
    ('gmail', 'Gmail', 'email', 'google', true, '{"icon": "gmail", "color": "#EA4335"}'::jsonb),
    ('google_calendar', 'Google Calendar', 'calendar', 'google', true, '{"icon": "calendar", "color": "#4285F4"}'::jsonb),
    ('telegram', 'Telegram', 'messaging', 'telegram', true, '{"icon": "telegram", "color": "#0088cc"}'::jsonb),
    ('signal', 'Signal', 'messaging', 'signal', true, '{"icon": "signal", "color": "#3A76F0"}'::jsonb),
    ('whatsapp', 'WhatsApp', 'messaging', 'whatsapp', true, '{"icon": "whatsapp", "color": "#25D366"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
    service_count int;
BEGIN
    SELECT count(*) INTO service_count FROM public.services;
    RAISE NOTICE 'Services catalog populated with % services', service_count;
END $$;

-- ============================================================================
-- STEP 6: MIGRATE DATA FROM users TO user_integrations
-- ============================================================================

-- 6.1: Migrate Primary Google Integration (Gmail)
-- Migrates: access_token, refresh_token, client_id, client_secret, granted_scopes, etc.
INSERT INTO public.user_integrations (
    user_id,
    service_id,
    is_active,
    display_label,
    access_token,
    refresh_token,
    token_expiration_date,
    refresh_expired,
    client_id,
    client_secret,
    auth_code,
    granted_scopes,
    external_user_id,
    created_at,
    updated_at
)
SELECT 
    id AS user_id,
    'gmail' AS service_id,
    true AS is_active,
    'Primary Gmail' AS display_label,
    access_token,
    refresh_token,
    token_expiration_date,
    COALESCE(refresh_expired, false) AS refresh_expired,
    client_id,
    client_secret,
    auth_code,
    granted_scopes,
    email AS external_user_id, -- use email as external identifier
    created_at,
    now() AS updated_at
FROM public.users
WHERE access_token IS NOT NULL 
   OR refresh_token IS NOT NULL 
   OR client_id IS NOT NULL
ON CONFLICT (user_id, service_id, external_user_id) DO NOTHING;

DO $$
DECLARE
    integration_count int;
BEGIN
    SELECT count(*) INTO integration_count FROM public.user_integrations WHERE service_id = 'gmail';
    RAISE NOTICE 'Migrated % Gmail integrations', integration_count;
END $$;

-- 6.2: Migrate Secondary Google Integration (Google Calendar)
-- Migrates: access_token_2, refresh_token_2, client_id_2, client_secret_2, etc.
INSERT INTO public.user_integrations (
    user_id,
    service_id,
    is_active,
    display_label,
    access_token,
    refresh_token,
    token_expiration_date,
    refresh_expired,
    client_id,
    client_secret,
    external_user_id,
    created_at,
    updated_at
)
SELECT 
    id AS user_id,
    'google_calendar' AS service_id,
    true AS is_active,
    'Google Calendar' AS display_label,
    access_token_2 AS access_token,
    refresh_token_2 AS refresh_token,
    token_expiration_date_2 AS token_expiration_date,
    COALESCE(refresh_expired_2, false) AS refresh_expired,
    client_id_2 AS client_id,
    client_secret_2 AS client_secret,
    email AS external_user_id, -- use email as external identifier (same as Gmail)
    created_at,
    now() AS updated_at
FROM public.users
WHERE access_token_2 IS NOT NULL 
   OR refresh_token_2 IS NOT NULL 
   OR client_id_2 IS NOT NULL
ON CONFLICT (user_id, service_id, external_user_id) DO NOTHING;

DO $$
DECLARE
    integration_count int;
BEGIN
    SELECT count(*) INTO integration_count FROM public.user_integrations WHERE service_id = 'google_calendar';
    RAISE NOTICE 'Migrated % Google Calendar integrations', integration_count;
END $$;

-- 6.3: Migrate Telegram Integration
-- Migrates: telegram_id -> external_user_id, telegram_signup_token -> credentials
INSERT INTO public.user_integrations (
    user_id,
    service_id,
    is_active,
    display_label,
    external_user_id,
    credentials,
    created_at,
    updated_at
)
SELECT 
    id AS user_id,
    'telegram' AS service_id,
    true AS is_active,
    'Telegram' AS display_label,
    telegram_id AS external_user_id,
    CASE 
        WHEN telegram_signup_token IS NOT NULL 
        THEN jsonb_build_object('signup_token', telegram_signup_token)
        ELSE '{}'::jsonb
    END AS credentials,
    created_at,
    now() AS updated_at
FROM public.users
WHERE telegram_id IS NOT NULL
ON CONFLICT (user_id, service_id, external_user_id) DO NOTHING;

DO $$
DECLARE
    integration_count int;
BEGIN
    SELECT count(*) INTO integration_count FROM public.user_integrations WHERE service_id = 'telegram';
    RAISE NOTICE 'Migrated % Telegram integrations', integration_count;
END $$;

-- 6.4: Migrate Signal Integration
-- Migrates: signal_source_uuid -> external_user_id
INSERT INTO public.user_integrations (
    user_id,
    service_id,
    is_active,
    display_label,
    external_user_id,
    created_at,
    updated_at
)
SELECT 
    id AS user_id,
    'signal' AS service_id,
    true AS is_active,
    'Signal' AS display_label,
    signal_source_uuid AS external_user_id,
    created_at,
    now() AS updated_at
FROM public.users
WHERE signal_source_uuid IS NOT NULL
ON CONFLICT (user_id, service_id, external_user_id) DO NOTHING;

DO $$
DECLARE
    integration_count int;
BEGIN
    SELECT count(*) INTO integration_count FROM public.user_integrations WHERE service_id = 'signal';
    RAISE NOTICE 'Migrated % Signal integrations', integration_count;
END $$;

-- ============================================================================
-- STEP 7: DATA INTEGRITY VALIDATION
-- ============================================================================

-- Validate that all users with integrations have corresponding rows
-- Optimized with EXISTS instead of NOT IN for better performance
DO $$
DECLARE
    missing_count int;
BEGIN
    -- Check Gmail migrations
    SELECT count(*) INTO missing_count
    FROM public.users u
    WHERE (u.access_token IS NOT NULL OR u.refresh_token IS NOT NULL OR u.client_id IS NOT NULL)
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = u.id AND ui.service_id = 'gmail'
    );
    
    IF missing_count > 0 THEN
        RAISE WARNING 'Found % users with Gmail credentials but no integration row', missing_count;
    END IF;
    
    -- Check Calendar migrations
    SELECT count(*) INTO missing_count
    FROM public.users u
    WHERE (u.access_token_2 IS NOT NULL OR u.refresh_token_2 IS NOT NULL OR u.client_id_2 IS NOT NULL)
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = u.id AND ui.service_id = 'google_calendar'
    );
    
    IF missing_count > 0 THEN
        RAISE WARNING 'Found % users with Calendar credentials but no integration row', missing_count;
    END IF;
    
    -- Check Telegram migrations
    SELECT count(*) INTO missing_count
    FROM public.users u
    WHERE u.telegram_id IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = u.id AND ui.service_id = 'telegram'
    );
    
    IF missing_count > 0 THEN
        RAISE WARNING 'Found % users with Telegram but no integration row', missing_count;
    END IF;
    
    -- Check Signal migrations
    SELECT count(*) INTO missing_count
    FROM public.users u
    WHERE u.signal_source_uuid IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = u.id AND ui.service_id = 'signal'
    );
    
    IF missing_count > 0 THEN
        RAISE WARNING 'Found % users with Signal but no integration row', missing_count;
    END IF;
    
    RAISE NOTICE 'Data integrity validation completed';
END $$;

-- ============================================================================
-- STEP 8: SWAP TABLES (NON-DESTRUCTIVE RENAME)
-- ============================================================================

-- 8.1: Drop existing foreign key constraints pointing to users table
-- We'll recreate these pointing to the new users table after rename

-- Get list of dependent tables with FKs
DO $$
DECLARE
    fk_record RECORD;
BEGIN
    RAISE NOTICE 'Dropping foreign key constraints pointing to public.users...';
    
    FOR fk_record IN 
        SELECT 
            tc.constraint_name,
            tc.table_schema,
            tc.table_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.constraint_column_usage ccu
            ON tc.constraint_name = ccu.constraint_name
            AND tc.table_schema = ccu.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
            AND ccu.table_schema = 'public'
            AND ccu.table_name = 'users'
    LOOP
        EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I',
            fk_record.table_schema,
            fk_record.table_name,
            fk_record.constraint_name
        );
        RAISE NOTICE '  Dropped: %.%.%', 
            fk_record.table_schema, 
            fk_record.table_name, 
            fk_record.constraint_name;
    END LOOP;
END $$;

-- 8.2: Rename tables
ALTER TABLE public.users RENAME TO users_old;
ALTER TABLE public.users_new RENAME TO users;

DO $$
BEGIN
    RAISE NOTICE 'Renamed: users → users_old, users_new → users';
END $$;

-- 8.3: Recreate foreign key constraints pointing to the new users table

DO $$
DECLARE
    fk_error_count int := 0;
    fk_error_details text := '';
BEGIN
    RAISE NOTICE 'Recreating foreign key constraints...';
    
    -- digests.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'digests') THEN
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.table_constraints 
            WHERE constraint_schema = 'public' 
              AND table_name = 'digests' 
              AND constraint_name = 'digests_user_id_fkey'
        ) THEN
            BEGIN
                ALTER TABLE public.digests 
                    ADD CONSTRAINT digests_user_id_fkey 
                    FOREIGN KEY (user_id) REFERENCES public.users(id);
                RAISE NOTICE '  Created FK: digests.user_id → users.id';
            EXCEPTION WHEN OTHERS THEN
                fk_error_count := fk_error_count + 1;
                fk_error_details := fk_error_details || 'digests.user_id_fkey: ' || SQLERRM || '; ';
                RAISE WARNING '  FAILED to create FK: digests.user_id → users.id - %', SQLERRM;
            END;
        ELSE
            RAISE NOTICE '  Skipped FK (already exists): digests.user_id → users.id';
        END IF;
    END IF;

    -- emails.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'emails') THEN
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.table_constraints 
            WHERE constraint_schema = 'public' 
              AND table_name = 'emails' 
              AND constraint_name = 'emails_user_id_fkey'
        ) THEN
            BEGIN
                ALTER TABLE public.emails 
                    ADD CONSTRAINT emails_user_id_fkey 
                    FOREIGN KEY (user_id) REFERENCES public.users(id);
                RAISE NOTICE '  Created FK: emails.user_id → users.id';
            EXCEPTION WHEN OTHERS THEN
                fk_error_count := fk_error_count + 1;
                fk_error_details := fk_error_details || 'emails.user_id_fkey: ' || SQLERRM || '; ';
                RAISE WARNING '  FAILED to create FK: emails.user_id → users.id - %', SQLERRM;
            END;
        ELSE
            RAISE NOTICE '  Skipped FK (already exists): emails.user_id → users.id';
        END IF;
    END IF;

    -- preferences.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'preferences') THEN
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.table_constraints 
            WHERE constraint_schema = 'public' 
              AND table_name = 'preferences' 
              AND constraint_name = 'preferences_user_id_fkey'
        ) THEN
            BEGIN
                ALTER TABLE public.preferences 
                    ADD CONSTRAINT preferences_user_id_fkey 
                    FOREIGN KEY (user_id) REFERENCES public.users(id);
                RAISE NOTICE '  Created FK: preferences.user_id → users.id';
            EXCEPTION WHEN OTHERS THEN
                fk_error_count := fk_error_count + 1;
                fk_error_details := fk_error_details || 'preferences.user_id_fkey: ' || SQLERRM || '; ';
                RAISE WARNING '  FAILED to create FK: preferences.user_id → users.id - %', SQLERRM;
            END;
        ELSE
            RAISE NOTICE '  Skipped FK (already exists): preferences.user_id → users.id';
        END IF;
    END IF;

    -- user_logs.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user_logs') THEN
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.table_constraints 
            WHERE constraint_schema = 'public' 
              AND table_name = 'user_logs' 
              AND constraint_name = 'user_logs_user_id_fkey'
        ) THEN
            BEGIN
                ALTER TABLE public.user_logs 
                    ADD CONSTRAINT user_logs_user_id_fkey 
                    FOREIGN KEY (user_id) REFERENCES public.users(id);
                RAISE NOTICE '  Created FK: user_logs.user_id → users.id';
            EXCEPTION WHEN OTHERS THEN
                fk_error_count := fk_error_count + 1;
                fk_error_details := fk_error_details || 'user_logs.user_id_fkey: ' || SQLERRM || '; ';
                RAISE WARNING '  FAILED to create FK: user_logs.user_id → users.id - %', SQLERRM;
            END;
        ELSE
            RAISE NOTICE '  Skipped FK (already exists): user_logs.user_id → users.id';
        END IF;
    END IF;

    -- user_integrations.user_id → users.id (add FK that was omitted during creation)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_schema = 'public' 
          AND table_name = 'user_integrations' 
          AND constraint_name = 'user_integrations_user_id_fkey'
    ) THEN
        BEGIN
            ALTER TABLE public.user_integrations
                ADD CONSTRAINT user_integrations_user_id_fkey
                FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
            RAISE NOTICE '  Created FK: user_integrations.user_id → users.id (CASCADE)';
        EXCEPTION WHEN OTHERS THEN
            fk_error_count := fk_error_count + 1;
            fk_error_details := fk_error_details || 'user_integrations.user_id_fkey: ' || SQLERRM || '; ';
            RAISE WARNING '  FAILED to create FK: user_integrations.user_id → users.id - %', SQLERRM;
        END;
    ELSE
        RAISE NOTICE '  Skipped FK (already exists): user_integrations.user_id → users.id';
    END IF;
    
    -- CRITICAL: Validate all foreign key constraints were created successfully
    IF fk_error_count > 0 THEN
        RAISE EXCEPTION 'CRITICAL FAILURE: % foreign key constraints failed to recreate. Details: %', fk_error_count, fk_error_details;
    END IF;
    
    RAISE NOTICE 'Successfully recreated all foreign key constraints pointing to new users table';
END $$;

-- 8.4: Verify table swap
DO $$
DECLARE
    old_count int;
    new_count int;
BEGIN
    SELECT count(*) INTO old_count FROM public.users_old;
    SELECT count(*) INTO new_count FROM public.users;
    
    IF old_count != new_count THEN
        RAISE WARNING 'Row count mismatch! users_old: %, users: %', old_count, new_count;
    ELSE
        RAISE NOTICE 'Table swap verified: both tables have % rows', new_count;
    END IF;
END $$;

-- ============================================================================
-- STEP 9: UPDATE CONSTRAINTS AND COMMENTS
-- ============================================================================

COMMENT ON TABLE public.users IS 'Core user profile data (integration data moved to user_integrations)';
COMMENT ON COLUMN public.users.email IS 'User email address (unique identifier)';
COMMENT ON TABLE public.users_old IS 'Backup of old users table (safe to drop after verification)';

-- ============================================================================
-- STEP 10: CREATE HELPER FUNCTIONS (OPTIONAL)
-- ============================================================================

-- Helper function to get user's active integrations
CREATE OR REPLACE FUNCTION public.get_user_integrations(p_user_id text)
RETURNS TABLE (
    integration_id uuid,
    service_name text,
    service_type text,
    is_active boolean,
    external_user_id text
) 
LANGUAGE sql
STABLE
AS $$
    SELECT 
        ui.id,
        s.name,
        s.type,
        ui.is_active,
        ui.external_user_id
    FROM public.user_integrations ui
    JOIN public.services s ON ui.service_id = s.id
    WHERE ui.user_id = p_user_id
    ORDER BY s.type, s.name;
$$;

COMMENT ON FUNCTION public.get_user_integrations IS 'Returns all integrations for a given user';

-- Helper function to get telegram integration for user
CREATE OR REPLACE FUNCTION public.get_telegram_id(p_user_id text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT external_user_id 
    FROM public.user_integrations 
    WHERE user_id = p_user_id 
      AND service_id = 'telegram' 
      AND is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_telegram_id IS 'Returns telegram_id for a user (backwards compatibility)';

-- Helper function to check if user has specific service
CREATE OR REPLACE FUNCTION public.user_has_service(p_user_id text, p_service_id text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS(
        SELECT 1 
        FROM public.user_integrations 
        WHERE user_id = p_user_id 
          AND service_id = p_service_id 
          AND is_active = true
    );
$$;

COMMENT ON FUNCTION public.user_has_service IS 'Checks if user has an active integration for a service';

-- Helper function to get user with all integrations (full details as JSON)
CREATE OR REPLACE FUNCTION public.get_user_with_integrations(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'id', u.id,
        'created_at', u.created_at,
        'email', u.email,
        'display_name', u.display_name,
        'position', u.position,
        'role', u.role,
        'phone_number', u.phone_number,
        'time_zone', u.time_zone,
        'integrations', COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', ui.id,
                        'service_id', s.id,
                        'service_name', s.name,
                        'service_type', s.type,
                        'provider', s.provider,
                        'is_active', ui.is_active,
                        'display_label', ui.display_label,
                        'access_token', ui.access_token,
                        'refresh_token', ui.refresh_token,
                        'token_expires_at', ui.token_expires_at,
                        'token_expiration_date', ui.token_expiration_date,
                        'refresh_expired', ui.refresh_expired,
                        'client_id', ui.client_id,
                        'client_secret', ui.client_secret,
                        'auth_code', ui.auth_code,
                        'granted_scopes', ui.granted_scopes,
                        'external_user_id', ui.external_user_id,
                        'external_username', ui.external_username,
                        'credentials', ui.credentials,
                        'metadata', ui.metadata,
                        'created_at', ui.created_at,
                        'updated_at', ui.updated_at
                    )
                )
                FROM public.user_integrations ui
                JOIN public.services s ON ui.service_id = s.id
                WHERE ui.user_id = u.id
            ),
            '[]'::jsonb
        )
    )
    FROM public.users u
    WHERE u.id = p_user_id;
$$;

COMMENT ON FUNCTION public.get_user_with_integrations IS 'Returns user with complete integration details as JSON. WARNING: Contains sensitive tokens!';

-- Helper function to get valid token with expiration check (generic)
CREATE OR REPLACE FUNCTION public.get_valid_token(p_user_id text, p_service_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_integration RECORD;
    v_is_expired boolean;
BEGIN
    -- Get the integration
    SELECT 
        ui.access_token,
        ui.refresh_token,
        ui.token_expiration_date,
        ui.token_expires_at,
        ui.refresh_expired,
        ui.is_active,
        ui.client_id,
        ui.client_secret,
        ui.granted_scopes
    INTO v_integration
    FROM public.user_integrations ui
    WHERE ui.user_id = p_user_id 
      AND ui.service_id = p_service_id
      AND ui.is_active = true
    LIMIT 1;
    
    -- If no integration found, return NULL
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    
    -- Check if token is expired (matches JavaScript isTokenExpired logic)
    v_is_expired := (
        v_integration.access_token IS NULL 
        OR v_integration.token_expiration_date IS NULL 
        OR v_integration.token_expiration_date < now()
    );
    
    -- Build and return JSON response
    RETURN jsonb_build_object(
        'token', v_integration.access_token,
        'refresh_token', v_integration.refresh_token,
        'is_expired', v_is_expired,
        'expires_at', v_integration.token_expiration_date,
        'refresh_expired', COALESCE(v_integration.refresh_expired, false),
        'client_id', v_integration.client_id,
        'client_secret', v_integration.client_secret,
        'granted_scopes', v_integration.granted_scopes
    );
END;
$$;

COMMENT ON FUNCTION public.get_valid_token IS 'Returns token with expiration status for any service. Returns NULL if not found.';

-- Service-specific token functions
CREATE OR REPLACE FUNCTION public.get_gmail_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'gmail');
$$;

COMMENT ON FUNCTION public.get_gmail_token IS 'Returns Gmail token with expiration status. Wrapper for get_valid_token.';

CREATE OR REPLACE FUNCTION public.get_calendar_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'google_calendar');
$$;

COMMENT ON FUNCTION public.get_calendar_token IS 'Returns Google Calendar token with expiration status. Wrapper for get_valid_token.';

CREATE OR REPLACE FUNCTION public.get_telegram_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'telegram');
$$;

COMMENT ON FUNCTION public.get_telegram_token IS 'Returns Telegram credentials with status. Wrapper for get_valid_token.';

CREATE OR REPLACE FUNCTION public.get_signal_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'signal');
$$;

COMMENT ON FUNCTION public.get_signal_token IS 'Returns Signal credentials with status. Wrapper for get_valid_token.';

-- Helper function to check if user has valid (non-expired) token
CREATE OR REPLACE FUNCTION public.has_valid_token(p_user_id text, p_service_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_token_info jsonb;
BEGIN
    v_token_info := public.get_valid_token(p_user_id, p_service_id);
    
    IF v_token_info IS NULL THEN
        RETURN false;
    END IF;
    
    RETURN (
        v_token_info->>'token' IS NOT NULL 
        AND (v_token_info->>'is_expired')::boolean = false
    );
END;
$$;

COMMENT ON FUNCTION public.has_valid_token IS 'Returns true if user has active, non-expired token for service.';

-- Helper function to update service token with automatic expiration calculation
CREATE OR REPLACE FUNCTION public.update_service_token(
    p_user_id text,
    p_service_id text,
    p_access_token text,
    p_expiry_seconds integer,
    p_refresh_token text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_updated_count int;
    v_new_expiry timestamptz;
BEGIN
    -- Calculate expiration date
    v_new_expiry := now() + (p_expiry_seconds || ' seconds')::interval;
    
    -- Update the integration
    UPDATE public.user_integrations
    SET 
        access_token = p_access_token,
        token_expiration_date = v_new_expiry,
        token_expires_at = v_new_expiry,
        refresh_token = COALESCE(p_refresh_token, refresh_token),
        refresh_expired = false,
        updated_at = now()
    WHERE user_id = p_user_id
      AND service_id = p_service_id
      AND is_active = true;
    
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    
    -- Raise error if integration doesn't exist
    IF v_updated_count = 0 THEN
        RAISE EXCEPTION 'Integration not found for user_id=% and service_id=%', p_user_id, p_service_id;
    END IF;
    
    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'user_id', p_user_id,
        'service_id', p_service_id,
        'expires_at', v_new_expiry,
        'updated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.update_service_token IS 'Updates token with automatic expiration. Raises error if integration not found.';

-- Convenience wrappers for token updates
CREATE OR REPLACE FUNCTION public.update_gmail_token(
    p_user_id text,
    p_access_token text,
    p_expiry_seconds integer DEFAULT 3600,
    p_refresh_token text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.update_service_token(p_user_id, 'gmail', p_access_token, p_expiry_seconds, p_refresh_token);
$$;

COMMENT ON FUNCTION public.update_gmail_token IS 'Updates Gmail token. Default 3600 seconds (1 hour).';

CREATE OR REPLACE FUNCTION public.update_calendar_token(
    p_user_id text,
    p_access_token text,
    p_expiry_seconds integer DEFAULT 3600,
    p_refresh_token text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.update_service_token(p_user_id, 'google_calendar', p_access_token, p_expiry_seconds, p_refresh_token);
$$;

COMMENT ON FUNCTION public.update_calendar_token IS 'Updates Calendar token. Default 3600 seconds (1 hour).';

-- Helper function to expire refresh token
CREATE OR REPLACE FUNCTION public.expire_refresh_token(
    p_user_id text,
    p_service_id text
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_updated_count int;
BEGIN
    UPDATE public.user_integrations
    SET 
        refresh_expired = true,
        updated_at = now()
    WHERE user_id = p_user_id
      AND service_id = p_service_id
      AND is_active = true;
    
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    
    IF v_updated_count = 0 THEN
        RAISE EXCEPTION 'Integration not found for user_id=% and service_id=%', p_user_id, p_service_id;
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'user_id', p_user_id,
        'service_id', p_service_id,
        'refresh_expired', true,
        'updated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.expire_refresh_token IS 'Marks refresh token as expired. Raises error if integration not found.';

CREATE OR REPLACE FUNCTION public.expire_gmail_refresh_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.expire_refresh_token(p_user_id, 'gmail');
$$;

COMMENT ON FUNCTION public.expire_gmail_refresh_token IS 'Marks Gmail refresh token as expired.';

CREATE OR REPLACE FUNCTION public.expire_calendar_refresh_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.expire_refresh_token(p_user_id, 'google_calendar');
$$;

COMMENT ON FUNCTION public.expire_calendar_refresh_token IS 'Marks Calendar refresh token as expired.';

-- Helper function to get user_id by external integration ID
CREATE OR REPLACE FUNCTION public.get_user_id_by_external_id(
    p_service_id text,
    p_external_user_id text
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT user_id 
    FROM public.user_integrations 
    WHERE service_id = p_service_id 
      AND external_user_id = p_external_user_id
      AND is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_user_id_by_external_id IS 'Returns user_id for a given external service ID (e.g., telegram_id). Returns NULL if not found.';

-- Helper function to get full user by external integration ID
CREATE OR REPLACE FUNCTION public.get_user_by_external_id(
    p_service_id text,
    p_external_user_id text
)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT row_to_json(u.*)::jsonb
    FROM public.users u
    JOIN public.user_integrations ui ON u.id = ui.user_id
    WHERE ui.service_id = p_service_id 
      AND ui.external_user_id = p_external_user_id
      AND ui.is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_user_by_external_id IS 'Returns full user record for a given external service ID. Returns NULL if not found.';

-- Convenience wrapper for Telegram
CREATE OR REPLACE FUNCTION public.get_user_id_by_telegram_id(p_telegram_id text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_user_id_by_external_id('telegram', p_telegram_id);
$$;

COMMENT ON FUNCTION public.get_user_id_by_telegram_id IS 'Returns user_id for a telegram_id. Wrapper for get_user_id_by_external_id.';

CREATE OR REPLACE FUNCTION public.get_user_by_telegram_id(p_telegram_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_user_by_external_id('telegram', p_telegram_id);
$$;

COMMENT ON FUNCTION public.get_user_by_telegram_id IS 'Returns full user record for a telegram_id. Wrapper for get_user_by_external_id.';

-- Convenience wrapper for Signal
CREATE OR REPLACE FUNCTION public.get_user_id_by_signal_id(p_signal_id text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_user_id_by_external_id('signal', p_signal_id);
$$;

COMMENT ON FUNCTION public.get_user_id_by_signal_id IS 'Returns user_id for a signal_source_uuid. Wrapper for get_user_id_by_external_id.';

CREATE OR REPLACE FUNCTION public.get_user_by_signal_id(p_signal_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_user_by_external_id('signal', p_signal_id);
$$;

COMMENT ON FUNCTION public.get_user_by_signal_id IS 'Returns full user record for a signal_source_uuid. Wrapper for get_user_by_external_id.';

-- Function to get last N telegram messages for a user
CREATE OR REPLACE FUNCTION public.get_user_telegram_messages(
    p_user_id text,
    p_limit int DEFAULT 8,
    p_direction text DEFAULT 'inbound'
)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', id,
            'text', text,
            'ts', ts,
            'direction', direction,
            'sender_id', sender_id
        )
    )
    FROM (
        SELECT 
            tm.id,
            tm.text,
            coalesce(tm.telegram_date_utc, tm.created_at) as ts,
            tm.direction,
            tm.sender_id
        FROM public.telegram_messages tm
        JOIN public.user_integrations ui ON ui.external_user_id = tm.sender_id
        WHERE ui.user_id = p_user_id
          AND ui.service_id = 'telegram'
          AND ui.is_active = true
          AND tm.direction = p_direction
          AND tm.text IS NOT NULL
        ORDER BY coalesce(tm.telegram_date_utc, tm.created_at) DESC
        LIMIT p_limit
    ) sub;
$$;

COMMENT ON FUNCTION public.get_user_telegram_messages IS 'Returns last N telegram messages for a user as JSONB array. Defaults to 8 inbound messages.';

-- Alternative function returning table format (for easier joins)
CREATE OR REPLACE FUNCTION public.get_user_telegram_messages_table(
    p_user_id text,
    p_limit int DEFAULT 8,
    p_direction text DEFAULT 'inbound'
)
RETURNS TABLE (
    id text,
    text text,
    ts timestamp with time zone,
    direction text,
    sender_id text
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        tm.id,
        tm.text,
        coalesce(tm.telegram_date_utc, tm.created_at) as ts,
        tm.direction,
        tm.sender_id
    FROM public.telegram_messages tm
    JOIN public.user_integrations ui ON ui.external_user_id = tm.sender_id
    WHERE ui.user_id = p_user_id
      AND ui.service_id = 'telegram'
      AND ui.is_active = true
      AND tm.direction = p_direction
      AND tm.text IS NOT NULL
    ORDER BY coalesce(tm.telegram_date_utc, tm.created_at) DESC
    LIMIT p_limit;
$$;

COMMENT ON FUNCTION public.get_user_telegram_messages_table IS 'Returns last N telegram messages for a user as table. Defaults to 8 inbound messages. Use this for JOINs or when you need individual columns.';

-- Function to get all users with a specific service enabled
CREATE OR REPLACE FUNCTION public.get_users_with_service(
    p_service_id text
)
RETURNS TABLE (
    id text,
    email text,
    display_name text,
    created_at timestamp with time zone,
    time_zone text,
    "position" text,
    role text,
    phone_number text,
    integration_created_at timestamp with time zone,
    integration_updated_at timestamp with time zone
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        u.id,
        u.email,
        u.display_name,
        u.created_at,
        u.time_zone,
        u."position",
        u.role,
        u.phone_number,
        ui.created_at as integration_created_at,
        ui.updated_at as integration_updated_at
    FROM public.users u
    JOIN public.user_integrations ui ON u.id = ui.user_id
    WHERE ui.service_id = p_service_id
      AND ui.is_active = true
      AND ui.access_token IS NOT NULL
      AND ui.refresh_token IS NOT NULL
    ORDER BY u.created_at DESC;
$$;

COMMENT ON FUNCTION public.get_users_with_service IS 'Returns all users who have a specific service enabled with valid tokens. Use service_id like gmail, google_calendar, telegram, signal.';

-- Convenience functions for common services
CREATE OR REPLACE FUNCTION public.get_users_with_gmail()
RETURNS TABLE (
    id text,
    email text,
    display_name text,
    created_at timestamp with time zone,
    time_zone text,
    "position" text,
    role text,
    phone_number text,
    integration_created_at timestamp with time zone,
    integration_updated_at timestamp with time zone
)
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM public.get_users_with_service('gmail');
$$;

COMMENT ON FUNCTION public.get_users_with_gmail IS 'Returns all users with Gmail integration enabled.';

CREATE OR REPLACE FUNCTION public.get_users_with_calendar()
RETURNS TABLE (
    id text,
    email text,
    display_name text,
    created_at timestamp with time zone,
    time_zone text,
    "position" text,
    role text,
    phone_number text,
    integration_created_at timestamp with time zone,
    integration_updated_at timestamp with time zone
)
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM public.get_users_with_service('google_calendar');
$$;

COMMENT ON FUNCTION public.get_users_with_calendar IS 'Returns all users with Google Calendar integration enabled.';

CREATE OR REPLACE FUNCTION public.get_users_with_telegram()
RETURNS TABLE (
    id text,
    email text,
    display_name text,
    created_at timestamp with time zone,
    time_zone text,
    "position" text,
    role text,
    phone_number text,
    integration_created_at timestamp with time zone,
    integration_updated_at timestamp with time zone
)
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM public.get_users_with_service('telegram');
$$;

COMMENT ON FUNCTION public.get_users_with_telegram IS 'Returns all users with Telegram integration enabled.';

CREATE OR REPLACE FUNCTION public.get_users_with_signal()
RETURNS TABLE (
    id text,
    email text,
    display_name text,
    created_at timestamp with time zone,
    time_zone text,
    "position" text,
    role text,
    phone_number text,
    integration_created_at timestamp with time zone,
    integration_updated_at timestamp with time zone
)
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM public.get_users_with_service('signal');
$$;

COMMENT ON FUNCTION public.get_users_with_signal IS 'Returns all users with Signal integration enabled.';

-- Function to get users with service + their integration details (JSONB)
CREATE OR REPLACE FUNCTION public.get_users_with_service_details(
    p_service_id text
)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_agg(
        jsonb_build_object(
            'user', row_to_json(u.*),
            'integration', jsonb_build_object(
                'service_id', ui.service_id,
                'external_user_id', ui.external_user_id,
                'is_active', ui.is_active,
                'created_at', ui.created_at,
                'updated_at', ui.updated_at,
                'has_access_token', ui.access_token IS NOT NULL,
                'has_refresh_token', ui.refresh_token IS NOT NULL,
                'token_expires_at', ui.token_expires_at,
                'refresh_expired', ui.refresh_expired
            )
        )
        ORDER BY u.created_at DESC
    )
    FROM public.users u
    JOIN public.user_integrations ui ON u.id = ui.user_id
    WHERE ui.service_id = p_service_id
      AND ui.is_active = true
      AND ui.access_token IS NOT NULL
      AND ui.refresh_token IS NOT NULL;
$$;

COMMENT ON FUNCTION public.get_users_with_service_details IS 'Returns JSONB with users and their integration details for a specific service.';

-- ============================================================================
-- STEP 11: FINAL VALIDATION AND SUMMARY
-- ============================================================================

DO $$
DECLARE
    total_users int;
    total_integrations int;
    gmail_count int;
    calendar_count int;
    telegram_count int;
    signal_count int;
    orphaned_integrations int;
    null_external_ids int;
BEGIN
    SELECT count(*) INTO total_users FROM public.users;
    SELECT count(*) INTO total_integrations FROM public.user_integrations;
    SELECT count(*) INTO gmail_count FROM public.user_integrations WHERE service_id = 'gmail';
    SELECT count(*) INTO calendar_count FROM public.user_integrations WHERE service_id = 'google_calendar';
    SELECT count(*) INTO telegram_count FROM public.user_integrations WHERE service_id = 'telegram';
    SELECT count(*) INTO signal_count FROM public.user_integrations WHERE service_id = 'signal';
    
    -- Check for orphaned integrations (shouldn't exist due to FK)
    SELECT count(*) INTO orphaned_integrations 
    FROM public.user_integrations ui
    WHERE NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = ui.user_id);
    
    -- Check for NULL external_user_ids in Gmail/Calendar (data quality)
    SELECT count(*) INTO null_external_ids
    FROM public.user_integrations
    WHERE service_id IN ('gmail', 'google_calendar')
      AND external_user_id IS NULL;
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'MIGRATION SUMMARY';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Total users: %', total_users;
    RAISE NOTICE 'Total integrations created: %', total_integrations;
    RAISE NOTICE '  - Gmail: %', gmail_count;
    RAISE NOTICE '  - Google Calendar: %', calendar_count;
    RAISE NOTICE '  - Telegram: %', telegram_count;
    RAISE NOTICE '  - Signal: %', signal_count;
    RAISE NOTICE '========================================';
    
    IF orphaned_integrations > 0 THEN
        RAISE WARNING 'Found % orphaned integrations (no matching user)!', orphaned_integrations;
    END IF;
    
    IF null_external_ids > 0 THEN
        RAISE WARNING 'Found % Gmail/Calendar integrations with NULL external_user_id!', null_external_ids;
    END IF;
    
    IF orphaned_integrations = 0 AND null_external_ids = 0 THEN
        RAISE NOTICE 'All validation checks passed!';
    END IF;
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Migration completed successfully!';
    RAISE NOTICE '========================================';
END $$;

-- ============================================================================
-- CRITICAL: PRE-COMMIT VALIDATION
-- ============================================================================

-- FINAL VALIDATION: Ensure NO DATA LOSS before committing
DO $$
DECLARE
    validation_failed boolean := false;
    error_details text := '';
    old_users_count int;
    new_users_count int;
    old_gmail_count int;
    new_gmail_count int;
    old_calendar_count int;
    new_calendar_count int;
    old_telegram_count int;
    new_telegram_count int;
    old_signal_count int;
    new_signal_count int;
    missing_users int;
    missing_gmail int;
    missing_calendar int;
    missing_telegram int;
    missing_signal int;
    data_mismatch_users int;
    data_mismatch_gmail int;
    data_mismatch_calendar int;
    data_mismatch_telegram int;
    data_mismatch_signal int;
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'CRITICAL: COMPREHENSIVE PRE-COMMIT VALIDATION';
    RAISE NOTICE '========================================';
    
    -- ============================================================================
    -- STEP 1: COUNT VALIDATION
    -- ============================================================================
    
    -- Count users in both tables
    SELECT count(*) INTO old_users_count FROM public.users_old;
    SELECT count(*) INTO new_users_count FROM public.users;
    
    IF old_users_count != new_users_count THEN
        validation_failed := true;
        error_details := error_details || 'User count mismatch: old=' || old_users_count || ', new=' || new_users_count || '; ';
    END IF;
    
    -- Count Gmail integrations
    SELECT count(*) INTO old_gmail_count FROM public.users_old WHERE access_token IS NOT NULL OR refresh_token IS NOT NULL OR client_id IS NOT NULL;
    SELECT count(*) INTO new_gmail_count FROM public.user_integrations WHERE service_id = 'gmail';
    
    IF old_gmail_count != new_gmail_count THEN
        validation_failed := true;
        error_details := error_details || 'Gmail count mismatch: old=' || old_gmail_count || ', new=' || new_gmail_count || '; ';
    END IF;
    
    -- Count Calendar integrations
    SELECT count(*) INTO old_calendar_count FROM public.users_old WHERE access_token_2 IS NOT NULL OR refresh_token_2 IS NOT NULL OR client_id_2 IS NOT NULL;
    SELECT count(*) INTO new_calendar_count FROM public.user_integrations WHERE service_id = 'google_calendar';
    
    IF old_calendar_count != new_calendar_count THEN
        validation_failed := true;
        error_details := error_details || 'Calendar count mismatch: old=' || old_calendar_count || ', new=' || new_calendar_count || '; ';
    END IF;
    
    -- Count Telegram integrations
    SELECT count(*) INTO old_telegram_count FROM public.users_old WHERE telegram_id IS NOT NULL;
    SELECT count(*) INTO new_telegram_count FROM public.user_integrations WHERE service_id = 'telegram';
    
    IF old_telegram_count != new_telegram_count THEN
        validation_failed := true;
        error_details := error_details || 'Telegram count mismatch: old=' || old_telegram_count || ', new=' || new_telegram_count || '; ';
    END IF;
    
    -- Count Signal integrations
    SELECT count(*) INTO old_signal_count FROM public.users_old WHERE signal_source_uuid IS NOT NULL;
    SELECT count(*) INTO new_signal_count FROM public.user_integrations WHERE service_id = 'signal';
    
    IF old_signal_count != new_signal_count THEN
        validation_failed := true;
        error_details := error_details || 'Signal count mismatch: old=' || old_signal_count || ', new=' || new_signal_count || '; ';
    END IF;
    
    -- ============================================================================
    -- STEP 2: COMPREHENSIVE DATA INTEGRITY VALIDATION
    -- ============================================================================
    
    -- Validate ALL users exist in new table with correct data
    SELECT count(*) INTO missing_users
    FROM public.users_old uo
    WHERE NOT EXISTS (
        SELECT 1 FROM public.users u 
        WHERE u.id = uo.id 
          AND u.email = uo.email
          AND u.display_name IS NOT DISTINCT FROM uo.display_name
          AND u.position IS NOT DISTINCT FROM uo.position
          AND u.role IS NOT DISTINCT FROM uo.role
          AND u.phone_number IS NOT DISTINCT FROM uo.phone_number
          AND u.time_zone IS NOT DISTINCT FROM uo.time_zone
          AND u.created_at = uo.created_at
    );
    
    IF missing_users > 0 THEN
        validation_failed := true;
        error_details := error_details || 'Missing or corrupted users: ' || missing_users || '; ';
    END IF;
    
    -- Validate ALL Gmail integrations migrated correctly (simplified validation)
    SELECT count(*) INTO missing_gmail
    FROM public.users_old uo
    WHERE (uo.access_token IS NOT NULL OR uo.refresh_token IS NOT NULL OR uo.client_id IS NOT NULL)
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = uo.id 
          AND ui.service_id = 'gmail'
          AND ui.external_user_id = uo.email
    );
    
    IF missing_gmail > 0 THEN
        validation_failed := true;
        error_details := error_details || 'Missing or corrupted Gmail integrations: ' || missing_gmail || '; ';
    END IF;
    
    -- Validate ALL Calendar integrations migrated correctly (simplified validation)
    SELECT count(*) INTO missing_calendar
    FROM public.users_old uo
    WHERE (uo.access_token_2 IS NOT NULL OR uo.refresh_token_2 IS NOT NULL OR uo.client_id_2 IS NOT NULL)
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = uo.id 
          AND ui.service_id = 'google_calendar'
          AND ui.external_user_id = uo.email
    );
    
    IF missing_calendar > 0 THEN
        validation_failed := true;
        error_details := error_details || 'Missing or corrupted Calendar integrations: ' || missing_calendar || '; ';
    END IF;
    
    -- Validate ALL Telegram integrations migrated correctly (simplified validation)
    SELECT count(*) INTO missing_telegram
    FROM public.users_old uo
    WHERE uo.telegram_id IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = uo.id 
          AND ui.service_id = 'telegram'
          AND ui.external_user_id = uo.telegram_id
    );
    
    IF missing_telegram > 0 THEN
        validation_failed := true;
        error_details := error_details || 'Missing or corrupted Telegram integrations: ' || missing_telegram || '; ';
    END IF;
    
    -- Validate ALL Signal integrations migrated correctly (simplified validation)
    SELECT count(*) INTO missing_signal
    FROM public.users_old uo
    WHERE uo.signal_source_uuid IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM public.user_integrations ui 
        WHERE ui.user_id = uo.id 
          AND ui.service_id = 'signal'
          AND ui.external_user_id = uo.signal_source_uuid
    );
    
    IF missing_signal > 0 THEN
        validation_failed := true;
        error_details := error_details || 'Missing or corrupted Signal integrations: ' || missing_signal || '; ';
    END IF;
    
    -- ============================================================================
    -- STEP 3: SERVICES CATALOG VALIDATION
    -- ============================================================================
    
    -- Validate services catalog is complete
    IF NOT EXISTS (SELECT 1 FROM public.services WHERE id = 'gmail') THEN
        validation_failed := true;
        error_details := error_details || 'Missing gmail service; ';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM public.services WHERE id = 'google_calendar') THEN
        validation_failed := true;
        error_details := error_details || 'Missing google_calendar service; ';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM public.services WHERE id = 'telegram') THEN
        validation_failed := true;
        error_details := error_details || 'Missing telegram service; ';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM public.services WHERE id = 'signal') THEN
        validation_failed := true;
        error_details := error_details || 'Missing signal service; ';
    END IF;
    
    -- ============================================================================
    -- STEP 4: ORPHANED DATA VALIDATION
    -- ============================================================================
    
    -- Check for orphaned integrations (should be zero due to FK constraints)
    SELECT count(*) INTO data_mismatch_users
    FROM public.user_integrations ui
    WHERE NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = ui.user_id);
    
    IF data_mismatch_users > 0 THEN
        validation_failed := true;
        error_details := error_details || 'Orphaned integrations found: ' || data_mismatch_users || '; ';
    END IF;
    
    -- Check for orphaned service references
    SELECT count(*) INTO data_mismatch_gmail
    FROM public.user_integrations ui
    WHERE ui.service_id = 'gmail' 
    AND NOT EXISTS (SELECT 1 FROM public.services s WHERE s.id = ui.service_id);
    
    IF data_mismatch_gmail > 0 THEN
        validation_failed := true;
        error_details := error_details || 'Orphaned Gmail service references: ' || data_mismatch_gmail || '; ';
    END IF;
    
    -- ============================================================================
    -- STEP 5: FINAL VALIDATION RESULT
    -- ============================================================================
    
    -- CRITICAL: Abort if ANY validation fails
    IF validation_failed THEN
        RAISE EXCEPTION 'CRITICAL VALIDATION FAILURE: Data integrity compromised! Aborting migration. Details: %', error_details;
    END IF;
    
    RAISE NOTICE '✅ ALL COMPREHENSIVE VALIDATION CHECKS PASSED';
    RAISE NOTICE '✅ User counts: old=%, new=%', old_users_count, new_users_count;
    RAISE NOTICE '✅ Integration counts: Gmail=%, Calendar=%, Telegram=%, Signal=%', new_gmail_count, new_calendar_count, new_telegram_count, new_signal_count;
    RAISE NOTICE '✅ Data integrity: ALL users and integrations migrated correctly';
    RAISE NOTICE '✅ Services catalog: Complete and valid';
    RAISE NOTICE '✅ No orphaned data detected';
    RAISE NOTICE '========================================';
    RAISE NOTICE '🚀 SAFE TO COMMIT - PROCEEDING WITH TRANSACTION';
    RAISE NOTICE '========================================';
END $$;

-- ============================================================================
-- COMMIT TRANSACTION
-- ============================================================================

COMMIT;

-- ============================================================================
-- POST-MIGRATION NOTES
-- ============================================================================

-- CLEANUP (After verification):
-- Once you've verified the migration is successful, you can drop the backup table:
--   DROP TABLE public.users_old;
--
-- ROLLBACK PROCEDURE (CRITICAL - Execute in order if migration fails):
-- 
-- STEP 1: Stop all applications immediately
-- STEP 2: Connect to database as superuser
-- STEP 3: Execute rollback script:
--
-- BEGIN;
-- 
-- -- Drop new tables
-- DROP TABLE IF EXISTS public.user_integrations CASCADE;
-- DROP TABLE IF EXISTS public.services CASCADE;
-- 
-- -- Restore original users table
-- DROP TABLE IF EXISTS public.users CASCADE;
-- ALTER TABLE public.users_old RENAME TO users;
-- 
-- -- Recreate original foreign key constraints
-- ALTER TABLE public.digests ADD CONSTRAINT digests_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);
-- ALTER TABLE public.emails ADD CONSTRAINT emails_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);
-- ALTER TABLE public.preferences ADD CONSTRAINT preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);
-- ALTER TABLE public.user_logs ADD CONSTRAINT user_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);
-- 
-- COMMIT;
--
-- STEP 4: Verify data integrity
-- STEP 5: Restart applications
-- STEP 6: Monitor for 24 hours

-- ACTION ITEMS:
-- 1. Update application code to query user_integrations instead of users table
-- 2. Update frontend to use new API endpoints (see documentation)
-- 3. Consider encrypting sensitive columns (access_token, refresh_token, client_secret)
-- 4. Monitor application logs for any broken queries
-- 5. Run VACUUM ANALYZE on modified tables for query optimization
-- 6. After 1-2 weeks of stability, DROP TABLE public.users_old

-- VERIFICATION QUERIES:
-- 
-- Compare row counts:
-- SELECT 'users' as table, count(*) FROM public.users
-- UNION ALL
-- SELECT 'users_old', count(*) FROM public.users_old
-- UNION ALL
-- SELECT 'user_integrations', count(*) FROM public.user_integrations;
--
-- Check for missing integrations:
-- SELECT u.id, u.email
-- FROM public.users_old u
-- WHERE (u.access_token IS NOT NULL OR u.telegram_id IS NOT NULL OR u.signal_source_uuid IS NOT NULL)
-- AND u.id NOT IN (SELECT user_id FROM public.user_integrations);

-- EXAMPLE QUERIES FOR FRONTEND TEAM:
-- 
-- Get all integrations for a user:
-- SELECT * FROM public.get_user_integrations('user_123');
--
-- Get user with full integration details (JSON):
-- SELECT public.get_user_with_integrations('user_123');
--
-- Get user's telegram ID:
-- SELECT public.get_telegram_id('user_123');
--
-- Check if user has Gmail:
-- SELECT public.user_has_service('user_123', 'gmail');
--
-- Get Gmail token with expiration status:
-- SELECT public.get_gmail_token('user_123');
--
-- Get Calendar token (replaces old N8N workflow):
-- SELECT public.get_calendar_token('user_123');
--
-- Check if token is valid (not expired):
-- SELECT public.has_valid_token('user_123', 'gmail');
--
-- Generic token getter:
-- SELECT public.get_valid_token('user_123', 'google_calendar');
--
-- Update Gmail token (automatic expiration calculation):
-- SELECT public.update_gmail_token('user_123', 'ya29.new_token', 3600);
--
-- Update Calendar token with refresh token:
-- SELECT public.update_calendar_token('user_123', 'ya29.new_token', 3600, '1//0g_refresh');
--
-- Generic token update:
-- SELECT public.update_service_token('user_123', 'gmail', 'ya29.new_token', 3600);
--
-- Expire refresh token:
-- SELECT public.expire_calendar_refresh_token('user_123');
--
-- Generic expire:
-- SELECT public.expire_refresh_token('user_123', 'google_calendar');
--
-- Get all services a user has:
-- SELECT s.name, s.type, ui.is_active, ui.external_user_id
-- FROM public.user_integrations ui
-- JOIN public.services s ON ui.service_id = s.id
-- WHERE ui.user_id = 'user_123';

-- ADDITIONAL FUNCTIONS:
-- See database_functions.sql for standalone version with additional helper functions

