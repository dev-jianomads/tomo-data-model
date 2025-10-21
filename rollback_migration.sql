-- ============================================================================
-- ROLLBACK SCRIPT: Revert Users Table Normalization
-- ============================================================================
-- Description: Reverts the migration_normalize_users.sql changes
--              Restores original users table with all integration columns
--
-- ⚠️ WARNING: This will DELETE the new normalized schema!
-- Only run this if the migration failed or needs to be reverted.
--
-- Prerequisites:
-- - users_old table must exist
-- - Backup database before running (just in case)
--
-- Author: Data Engineering Team
-- Date: 2025-10-13
-- ============================================================================

BEGIN;

-- ============================================================================
-- STEP 1: PRE-ROLLBACK CHECKS
-- ============================================================================

DO $$
BEGIN
    -- Verify users_old exists
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'users_old') THEN
        RAISE EXCEPTION 'dev.users_old table not found. Cannot rollback without backup table!';
    END IF;
    
    -- Verify new users table exists (sanity check)
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'users') THEN
        RAISE EXCEPTION 'dev.users table not found. Nothing to rollback?';
    END IF;
    
    RAISE NOTICE 'Pre-rollback checks passed. Starting rollback...';
END $$;

-- ============================================================================
-- STEP 2: DROP FOREIGN KEY CONSTRAINTS POINTING TO NEW USERS TABLE
-- ============================================================================

DO $$
DECLARE
    fk_record RECORD;
BEGIN
    RAISE NOTICE 'Dropping foreign key constraints pointing to dev.users...';
    
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
            AND ccu.table_schema = 'dev'
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

-- ============================================================================
-- STEP 3: DROP NEW TABLES
-- ============================================================================

-- Drop helper functions first
DROP FUNCTION IF EXISTS dev.update_calendar_token(text, text, integer, text);
DROP FUNCTION IF EXISTS dev.update_gmail_token(text, text, integer, text);
DROP FUNCTION IF EXISTS dev.update_service_token(text, text, text, integer, text);
DROP FUNCTION IF EXISTS dev.has_valid_token(text, text);
DROP FUNCTION IF EXISTS dev.get_signal_token(text);
DROP FUNCTION IF EXISTS dev.get_telegram_token(text);
DROP FUNCTION IF EXISTS dev.get_calendar_token(text);
DROP FUNCTION IF EXISTS dev.get_gmail_token(text);
DROP FUNCTION IF EXISTS dev.get_valid_token(text, text);
DROP FUNCTION IF EXISTS dev.get_user_with_integrations(text);
DROP FUNCTION IF EXISTS dev.user_has_service(text, text);
DROP FUNCTION IF EXISTS dev.get_telegram_id(text);
DROP FUNCTION IF EXISTS dev.get_user_integrations(text);

RAISE NOTICE 'Dropped all helper functions';

-- Drop new users table
DROP TABLE IF EXISTS dev.users CASCADE;
RAISE NOTICE 'Dropped new dev.users table';

-- Drop user_integrations table
DROP TABLE IF EXISTS dev.user_integrations CASCADE;
RAISE NOTICE 'Dropped dev.user_integrations table';

-- Drop services table
DROP TABLE IF EXISTS dev.services CASCADE;
RAISE NOTICE 'Dropped dev.services table';

-- ============================================================================
-- STEP 4: RESTORE OLD USERS TABLE
-- ============================================================================

ALTER TABLE dev.users_old RENAME TO users;
RAISE NOTICE 'Restored: users_old → users';

-- ============================================================================
-- STEP 5: RECREATE FOREIGN KEY CONSTRAINTS
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE 'Recreating foreign key constraints pointing to dev.users...';
    
    -- digests.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'digests') THEN
        ALTER TABLE dev.digests 
            ADD CONSTRAINT digests_user_id_fkey 
            FOREIGN KEY (user_id) REFERENCES dev.users(id);
        RAISE NOTICE '  Created FK: digests.user_id → users.id';
    END IF;

    -- emails.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'emails') THEN
        ALTER TABLE dev.emails 
            ADD CONSTRAINT emails_user_id_fkey 
            FOREIGN KEY (user_id) REFERENCES dev.users(id);
        RAISE NOTICE '  Created FK: emails.user_id → users.id';
    END IF;

    -- preferences.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'preferences') THEN
        ALTER TABLE dev.preferences 
            ADD CONSTRAINT preferences_user_id_fkey 
            FOREIGN KEY (user_id) REFERENCES dev.users(id);
        RAISE NOTICE '  Created FK: preferences.user_id → users.id';
    END IF;

    -- user_logs.user_id → users.id
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'user_logs') THEN
        ALTER TABLE dev.user_logs 
            ADD CONSTRAINT user_logs_user_id_fkey 
            FOREIGN KEY (user_id) REFERENCES dev.users(id);
        RAISE NOTICE '  Created FK: user_logs.user_id → users.id';
    END IF;
    
    RAISE NOTICE 'Recreated all foreign key constraints';
END $$;

-- ============================================================================
-- STEP 6: VERIFY ROLLBACK
-- ============================================================================

DO $$
DECLARE
    users_count int;
    has_old_columns boolean;
BEGIN
    -- Check row count
    SELECT count(*) INTO users_count FROM dev.users;
    RAISE NOTICE 'Restored users table has % rows', users_count;
    
    -- Verify old columns exist
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'dev' 
          AND table_name = 'users' 
          AND column_name = 'access_token'
    ) INTO has_old_columns;
    
    IF has_old_columns THEN
        RAISE NOTICE 'Verified: Original columns restored (access_token exists)';
    ELSE
        RAISE WARNING 'Warning: Original columns not found!';
    END IF;
    
    -- Check that new tables are gone
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'user_integrations') THEN
        RAISE WARNING 'Warning: user_integrations table still exists!';
    ELSE
        RAISE NOTICE 'Verified: user_integrations table removed';
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dev' AND table_name = 'services') THEN
        RAISE WARNING 'Warning: services table still exists!';
    ELSE
        RAISE NOTICE 'Verified: services table removed';
    END IF;
END $$;

-- ============================================================================
-- STEP 7: FINAL SUMMARY
-- ============================================================================

DO $$
DECLARE
    users_count int;
BEGIN
    SELECT count(*) INTO users_count FROM dev.users;
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'ROLLBACK SUMMARY';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Original users table restored';
    RAISE NOTICE 'Total users: %', users_count;
    RAISE NOTICE 'New tables removed:';
    RAISE NOTICE '  - user_integrations';
    RAISE NOTICE '  - services';
    RAISE NOTICE 'Helper functions removed';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Rollback completed successfully!';
    RAISE NOTICE '========================================';
END $$;

-- ============================================================================
-- COMMIT ROLLBACK TRANSACTION
-- ============================================================================

COMMIT;

-- ============================================================================
-- POST-ROLLBACK NOTES
-- ============================================================================

-- 1. Restart application - it should work with original schema
-- 2. Verify application functionality
-- 3. Monitor logs for errors
-- 4. Investigate why migration needed to be rolled back
-- 5. Fix issues before attempting migration again

-- VERIFICATION QUERY:
-- SELECT column_name FROM information_schema.columns 
-- WHERE table_schema = 'dev' AND table_name = 'users'
-- ORDER BY ordinal_position;
-- Should show: access_token, telegram_id, signal_source_uuid, etc.

