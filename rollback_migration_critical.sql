-- ============================================================================
-- CRITICAL ROLLBACK SCRIPT - USERS TABLE MIGRATION
-- ============================================================================
-- Description: Emergency rollback procedure for users table normalization migration
--              Use ONLY if migration fails or data corruption is detected
--
-- WARNING: This script will COMPLETELY REVERSE the migration
--          Execute ONLY in emergency situations
--
-- Author: Data Engineering Team
-- Date: 2025-10-09
-- Criticality: EMERGENCY USE ONLY
-- ============================================================================

-- ============================================================================
-- CRITICAL: PRE-ROLLBACK VALIDATION
-- ============================================================================
-- Verify we're in the correct environment and have necessary permissions

DO $$
DECLARE
    users_old_exists boolean;
    users_exists boolean;
    user_integrations_exists boolean;
    services_exists boolean;
BEGIN
    -- Check if rollback is possible
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'users_old'
    ) INTO users_old_exists;
    
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'users'
    ) INTO users_exists;
    
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'user_integrations'
    ) INTO user_integrations_exists;
    
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'services'
    ) INTO services_exists;
    
    -- Validate rollback prerequisites
    IF NOT users_old_exists THEN
        RAISE EXCEPTION 'CRITICAL: users_old table not found! Cannot rollback - backup table missing!';
    END IF;
    
    IF NOT users_exists THEN
        RAISE EXCEPTION 'CRITICAL: users table not found! Database may be in inconsistent state!';
    END IF;
    
    IF NOT user_integrations_exists THEN
        RAISE WARNING 'user_integrations table not found - migration may not have completed';
    END IF;
    
    IF NOT services_exists THEN
        RAISE WARNING 'services table not found - migration may not have completed';
    END IF;
    
    RAISE NOTICE 'Rollback validation passed - proceeding with emergency rollback';
END $$;

-- ============================================================================
-- CRITICAL: SET TRANSACTION TIMEOUTS FOR SAFETY
-- ============================================================================
SET statement_timeout = '15min';  -- Maximum 15 minutes for rollback
SET lock_timeout = '2min';        -- Maximum 2 minutes to acquire locks
SET idle_in_transaction_session_timeout = '20min';

BEGIN;

-- ============================================================================
-- STEP 1: ACQUIRE EXCLUSIVE LOCKS
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE 'Acquiring exclusive locks for rollback...';
    LOCK TABLE public.users IN ACCESS EXCLUSIVE MODE;
    LOCK TABLE public.users_old IN ACCESS EXCLUSIVE MODE;
    RAISE NOTICE 'Exclusive locks acquired';
END $$;

-- ============================================================================
-- STEP 2: DROP NEW TABLES (CASCADE to handle dependencies)
-- ============================================================================

DO $$
DECLARE
    table_dropped boolean := false;
BEGIN
    RAISE NOTICE 'Dropping new tables...';
    
    -- Drop user_integrations table
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user_integrations') THEN
        DROP TABLE public.user_integrations CASCADE;
        RAISE NOTICE 'Dropped user_integrations table';
        table_dropped := true;
    END IF;
    
    -- Drop services table
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'services') THEN
        DROP TABLE public.services CASCADE;
        RAISE NOTICE 'Dropped services table';
        table_dropped := true;
    END IF;
    
    IF NOT table_dropped THEN
        RAISE WARNING 'No new tables found to drop - migration may not have completed';
    END IF;
END $$;

-- ============================================================================
-- STEP 3: RESTORE ORIGINAL USERS TABLE
-- ============================================================================

DO $$
DECLARE
    old_count int;
    new_count int;
BEGIN
    RAISE NOTICE 'Restoring original users table...';
    
    -- Count records before swap
    SELECT count(*) INTO old_count FROM public.users_old;
    SELECT count(*) INTO new_count FROM public.users;
    
    RAISE NOTICE 'Record counts: users_old=%, users=%', old_count, new_count;
    
    -- Drop current users table
    DROP TABLE public.users CASCADE;
    RAISE NOTICE 'Dropped current users table';
    
    -- Restore original table
    ALTER TABLE public.users_old RENAME TO users;
    RAISE NOTICE 'Restored original users table';
    
    -- Verify restoration
    SELECT count(*) INTO new_count FROM public.users;
    IF new_count != old_count THEN
        RAISE EXCEPTION 'CRITICAL: Record count mismatch after restoration! Expected: %, Got: %', old_count, new_count;
    END IF;
    
    RAISE NOTICE 'Users table restoration verified: % records', new_count;
END $$;

-- ============================================================================
-- STEP 4: RECREATE ORIGINAL FOREIGN KEY CONSTRAINTS
-- ============================================================================

DO $$
DECLARE
    fk_error_count int := 0;
    fk_error_details text := '';
BEGIN
    RAISE NOTICE 'Recreating original foreign key constraints...';
    
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
        END IF;
    END IF;
    
    -- Report FK recreation results
    IF fk_error_count > 0 THEN
        RAISE WARNING 'Some foreign key constraints failed to recreate: %', fk_error_details;
    ELSE
        RAISE NOTICE 'All foreign key constraints recreated successfully';
    END IF;
END $$;

-- ============================================================================
-- STEP 5: FINAL VALIDATION
-- ============================================================================

DO $$
DECLARE
    users_count int;
    digests_count int;
    emails_count int;
    preferences_count int;
    user_logs_count int;
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE 'ROLLBACK VALIDATION';
    RAISE NOTICE '========================================';
    
    -- Count users
    SELECT count(*) INTO users_count FROM public.users;
    RAISE NOTICE 'Users table restored: % records', users_count;
    
    -- Verify dependent tables can access users
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'digests') THEN
        SELECT count(*) INTO digests_count FROM public.digests WHERE user_id IN (SELECT id FROM public.users LIMIT 1);
        RAISE NOTICE 'Digests table accessible: % records', digests_count;
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'emails') THEN
        SELECT count(*) INTO emails_count FROM public.emails WHERE user_id IN (SELECT id FROM public.users LIMIT 1);
        RAISE NOTICE 'Emails table accessible: % records', emails_count;
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'preferences') THEN
        SELECT count(*) INTO preferences_count FROM public.preferences WHERE user_id IN (SELECT id FROM public.users LIMIT 1);
        RAISE NOTICE 'Preferences table accessible: % records', preferences_count;
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user_logs') THEN
        SELECT count(*) INTO user_logs_count FROM public.user_logs WHERE user_id IN (SELECT id FROM public.users LIMIT 1);
        RAISE NOTICE 'User_logs table accessible: % records', user_logs_count;
    END IF;
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'ROLLBACK COMPLETED SUCCESSFULLY';
    RAISE NOTICE '========================================';
END $$;

-- ============================================================================
-- COMMIT ROLLBACK TRANSACTION
-- ============================================================================

COMMIT;

-- ============================================================================
-- POST-ROLLBACK ACTIONS
-- ============================================================================

-- CRITICAL: Execute these steps immediately after rollback:
-- 1. Verify all applications can connect to database
-- 2. Test critical user operations (login, profile access)
-- 3. Monitor application logs for 2 hours
-- 4. Run VACUUM ANALYZE on users table
-- 5. Check for any orphaned records in dependent tables
-- 6. Document the rollback incident
-- 7. Schedule investigation of migration failure

RAISE NOTICE 'EMERGENCY ROLLBACK COMPLETED - Database restored to pre-migration state';
RAISE NOTICE 'Next steps: Verify applications, monitor logs, investigate failure cause';
