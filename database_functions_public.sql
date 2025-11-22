-- ============================================================================
-- DATABASE HELPER FUNCTIONS FOR NORMALIZED USER INTEGRATIONS SCHEMA
-- ============================================================================
-- Description: Utility functions to simplify working with the new
--              users/services/user_integrations schema
--
-- Author: Data Engineering Team
-- Date: 2025-10-13
-- ============================================================================

-- ============================================================================
-- FUNCTION 1: Get User with All Integrations (Full Details)
-- ============================================================================

-- Returns user profile with nested integrations array as JSON
-- Includes ALL integration details including sensitive tokens
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

COMMENT ON FUNCTION public.get_user_with_integrations IS 
'Returns user profile with complete integration details as JSON object. WARNING: Contains sensitive tokens!';

-- ============================================================================
-- FUNCTION 2: Get Valid Token (Generic)
-- ============================================================================

-- Returns token information with expiration status for any service
-- Returns NULL if integration doesn't exist
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
    
    -- Check if token is expired
    -- Logic matches the JavaScript isTokenExpired function:
    -- 1. No token or no expiration date → expired
    -- 2. Expiration date in the past → expired
    -- 3. Otherwise → not expired
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

COMMENT ON FUNCTION public.get_valid_token IS 
'Returns token details with expiration status for a specific service. Returns NULL if integration not found.';

-- ============================================================================
-- FUNCTION 3: Service-Specific Token Functions
-- ============================================================================

-- Get Gmail token
CREATE OR REPLACE FUNCTION public.get_gmail_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'gmail');
$$;

COMMENT ON FUNCTION public.get_gmail_token IS 
'Returns Gmail token details with expiration status for user. Convenience wrapper for get_valid_token.';

-- Get Google Calendar token
CREATE OR REPLACE FUNCTION public.get_calendar_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'google_calendar');
$$;

COMMENT ON FUNCTION public.get_calendar_token IS 
'Returns Google Calendar token details with expiration status for user. Convenience wrapper for get_valid_token.';

-- Get Telegram token/credentials
CREATE OR REPLACE FUNCTION public.get_telegram_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'telegram');
$$;

COMMENT ON FUNCTION public.get_telegram_token IS 
'Returns Telegram credentials with status for user. Convenience wrapper for get_valid_token.';

-- Get Signal token/credentials
CREATE OR REPLACE FUNCTION public.get_signal_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT public.get_valid_token(p_user_id, 'signal');
$$;

COMMENT ON FUNCTION public.get_signal_token IS 
'Returns Signal credentials with status for user. Convenience wrapper for get_valid_token.';

-- ============================================================================
-- FUNCTION 4: Additional Helper Functions
-- ============================================================================

-- Get list of active service IDs for a user (lightweight)
CREATE OR REPLACE FUNCTION public.get_user_services(p_user_id text)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    SELECT array_agg(service_id)
    FROM public.user_integrations
    WHERE user_id = p_user_id
      AND is_active = true;
$$;

COMMENT ON FUNCTION public.get_user_services IS 
'Returns array of service IDs that user has active integrations for.';

-- Check if user has valid (non-expired) token for a service
CREATE OR REPLACE FUNCTION public.has_valid_token(p_user_id text, p_service_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_token_info jsonb;
BEGIN
    v_token_info := public.get_valid_token(p_user_id, p_service_id);
    
    -- If no integration, return false
    IF v_token_info IS NULL THEN
        RETURN false;
    END IF;
    
    -- Check if token exists and is not expired
    RETURN (
        v_token_info->>'token' IS NOT NULL 
        AND (v_token_info->>'is_expired')::boolean = false
    );
END;
$$;

COMMENT ON FUNCTION public.has_valid_token IS 
'Returns true if user has an active, non-expired token for the specified service.';

-- Get integration by external user ID (for reverse lookups)
CREATE OR REPLACE FUNCTION public.get_integration_by_external_id(p_service_id text, p_external_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'integration_id', ui.id,
        'user_id', ui.user_id,
        'service_id', ui.service_id,
        'is_active', ui.is_active,
        'external_user_id', ui.external_user_id,
        'external_username', ui.external_username
    )
    FROM public.user_integrations ui
    WHERE ui.service_id = p_service_id
      AND ui.external_user_id = p_external_user_id
      AND ui.is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_integration_by_external_id IS 
'Finds user integration by service and external user ID (e.g., telegram_id). Useful for message routing.';

-- Get WhatsApp user by WhatsApp ID
CREATE OR REPLACE FUNCTION public.get_whatsapp_user(p_whatsapp_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'integration_id', ui.id,
        'user_id', ui.user_id,
        'service_id', ui.service_id,
        'is_active', ui.is_active,
        'external_user_id', ui.external_user_id,
        'external_username', ui.external_username,
        'display_label', ui.display_label,
        'created_at', ui.created_at,
        'updated_at', ui.updated_at
    )
    FROM public.user_integrations ui
    WHERE ui.service_id = 'whatsapp'
      AND ui.external_user_id = p_whatsapp_id
      AND ui.is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_whatsapp_user IS 
'Finds user by WhatsApp ID. Returns user integration details for WhatsApp service.';

-- ============================================================================
-- FUNCTION 5: Service Linking Functions (CREATE Operations)
-- ============================================================================

-- Generic function to link any service to a user
CREATE OR REPLACE FUNCTION public.link_service_to_user(
    p_user_id text,
    p_service_id text,
    p_external_user_id text DEFAULT NULL,
    p_external_username text DEFAULT NULL,
    p_display_label text DEFAULT NULL,
    p_access_token text DEFAULT NULL,
    p_refresh_token text DEFAULT NULL,
    p_token_expiration_date timestamptz DEFAULT NULL,
    p_client_id text DEFAULT NULL,
    p_client_secret text DEFAULT NULL,
    p_auth_code text DEFAULT NULL,
    p_granted_scopes jsonb DEFAULT NULL,
    p_credentials jsonb DEFAULT NULL,
    p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_integration_id uuid;
    v_service_exists boolean;
    v_user_exists boolean;
BEGIN
    -- Validate that user exists
    SELECT EXISTS(SELECT 1 FROM public.users WHERE id = p_user_id) INTO v_user_exists;
    IF NOT v_user_exists THEN
        RAISE EXCEPTION 'User with id=% does not exist', p_user_id;
    END IF;
    
    -- Validate that service exists
    SELECT EXISTS(SELECT 1 FROM public.services WHERE id = p_service_id AND is_active = true) INTO v_service_exists;
    IF NOT v_service_exists THEN
        RAISE EXCEPTION 'Service with id=% does not exist or is inactive', p_service_id;
    END IF;
    
    -- Insert the integration
    INSERT INTO public.user_integrations (
        user_id,
        service_id,
        external_user_id,
        external_username,
        display_label,
        access_token,
        refresh_token,
        token_expiration_date,
        token_expires_at,
        client_id,
        client_secret,
        auth_code,
        granted_scopes,
        credentials,
        metadata,
        is_active
    ) VALUES (
        p_user_id,
        p_service_id,
        p_external_user_id,
        p_external_username,
        p_display_label,
        p_access_token,
        p_refresh_token,
        p_token_expiration_date,
        p_token_expiration_date, -- Set both fields for compatibility
        p_client_id,
        p_client_secret,
        p_auth_code,
        p_granted_scopes,
        COALESCE(p_credentials, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb),
        true
    )
    RETURNING id INTO v_integration_id;
    
    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'integration_id', v_integration_id,
        'user_id', p_user_id,
        'service_id', p_service_id,
        'external_user_id', p_external_user_id,
        'created_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.link_service_to_user IS 
'Links any service to a user with optional credentials. Validates user and service existence.';

-- Convenience wrapper for Gmail integration
CREATE OR REPLACE FUNCTION public.link_gmail_to_user(
    p_user_id text,
    p_access_token text,
    p_refresh_token text DEFAULT NULL,
    p_token_expiration_date timestamptz DEFAULT NULL,
    p_client_id text DEFAULT NULL,
    p_client_secret text DEFAULT NULL,
    p_auth_code text DEFAULT NULL,
    p_granted_scopes jsonb DEFAULT NULL,
    p_external_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.link_service_to_user(
        p_user_id,
        'gmail',
        COALESCE(p_external_user_id, (SELECT email FROM public.users WHERE id = p_user_id)),
        NULL, -- external_username
        'Gmail Integration',
        p_access_token,
        p_refresh_token,
        p_token_expiration_date,
        p_client_id,
        p_client_secret,
        p_auth_code,
        p_granted_scopes,
        NULL, -- credentials
        NULL  -- metadata
    );
$$;

COMMENT ON FUNCTION public.link_gmail_to_user IS 
'Links Gmail service to user with OAuth credentials. Uses email as external_user_id if not provided.';

-- Convenience wrapper for Google Calendar integration
CREATE OR REPLACE FUNCTION public.link_calendar_to_user(
    p_user_id text,
    p_access_token text,
    p_refresh_token text DEFAULT NULL,
    p_token_expiration_date timestamptz DEFAULT NULL,
    p_client_id text DEFAULT NULL,
    p_client_secret text DEFAULT NULL,
    p_auth_code text DEFAULT NULL,
    p_granted_scopes jsonb DEFAULT NULL,
    p_external_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.link_service_to_user(
        p_user_id,
        'google_calendar',
        COALESCE(p_external_user_id, (SELECT email FROM public.users WHERE id = p_user_id)),
        NULL, -- external_username
        'Google Calendar Integration',
        p_access_token,
        p_refresh_token,
        p_token_expiration_date,
        p_client_id,
        p_client_secret,
        p_auth_code,
        p_granted_scopes,
        NULL, -- credentials
        NULL  -- metadata
    );
$$;

COMMENT ON FUNCTION public.link_calendar_to_user IS 
'Links Google Calendar service to user with OAuth credentials. Uses email as external_user_id if not provided.';

-- Convenience wrapper for Telegram integration
CREATE OR REPLACE FUNCTION public.link_telegram_to_user(
    p_user_id text,
    p_telegram_id text,
    p_telegram_username text DEFAULT NULL,
    p_display_label text DEFAULT NULL,
    p_credentials jsonb DEFAULT NULL,
    p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.link_service_to_user(
        p_user_id,
        'telegram',
        p_telegram_id,
        p_telegram_username,
        COALESCE(p_display_label, 'Telegram Integration'),
        NULL, -- access_token
        NULL, -- refresh_token
        NULL, -- token_expiration_date
        NULL, -- client_id
        NULL, -- client_secret
        NULL, -- auth_code
        NULL, -- granted_scopes
        p_credentials,
        p_metadata
    );
$$;

COMMENT ON FUNCTION public.link_telegram_to_user IS 
'Links Telegram service to user with telegram_id and optional credentials/metadata.';

-- Convenience wrapper for Signal integration
CREATE OR REPLACE FUNCTION public.link_signal_to_user(
    p_user_id text,
    p_signal_uuid text,
    p_display_label text DEFAULT NULL,
    p_credentials jsonb DEFAULT NULL,
    p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.link_service_to_user(
        p_user_id,
        'signal',
        p_signal_uuid,
        NULL, -- external_username
        COALESCE(p_display_label, 'Signal Integration'),
        NULL, -- access_token
        NULL, -- refresh_token
        NULL, -- token_expiration_date
        NULL, -- client_id
        NULL, -- client_secret
        NULL, -- auth_code
        NULL, -- granted_scopes
        p_credentials,
        p_metadata
    );
$$;

COMMENT ON FUNCTION public.link_signal_to_user IS 
'Links Signal service to user with signal_uuid and optional credentials/metadata.';

-- Convenience wrapper for WhatsApp integration
CREATE OR REPLACE FUNCTION public.link_whatsapp_to_user(
    p_user_id text,
    p_whatsapp_id text,
    p_whatsapp_username text DEFAULT NULL,
    p_display_label text DEFAULT NULL,
    p_credentials jsonb DEFAULT NULL,
    p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.link_service_to_user(
        p_user_id,
        'whatsapp',
        p_whatsapp_id,
        p_whatsapp_username,
        COALESCE(p_display_label, 'WhatsApp Integration'),
        NULL, -- access_token
        NULL, -- refresh_token
        NULL, -- token_expiration_date
        NULL, -- client_id
        NULL, -- client_secret
        NULL, -- auth_code
        NULL, -- granted_scopes
        p_credentials,
        p_metadata
    );
$$;

COMMENT ON FUNCTION public.link_whatsapp_to_user IS 
'Links WhatsApp service to user with whatsapp_id and optional credentials/metadata.';

-- ============================================================================
-- FUNCTION 6: Service Unlinking Functions (DEACTIVATE Operations)
-- ============================================================================

-- Generic function to unlink/deactivate any service from a user
CREATE OR REPLACE FUNCTION public.unlink_service_from_user(
    p_user_id text,
    p_service_id text,
    p_external_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_updated_count int;
    v_integration_id uuid;
BEGIN
    -- Deactivate the integration (soft delete)
    UPDATE public.user_integrations
    SET 
        is_active = false,
        updated_at = now()
    WHERE user_id = p_user_id
      AND service_id = p_service_id
      AND (p_external_user_id IS NULL OR external_user_id = p_external_user_id)
      AND is_active = true
    RETURNING id INTO v_integration_id;
    
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    
    -- Raise error if integration doesn't exist
    IF v_updated_count = 0 THEN
        RAISE EXCEPTION 'Active integration not found for user_id=% and service_id=%', p_user_id, p_service_id;
    END IF;
    
    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'integration_id', v_integration_id,
        'user_id', p_user_id,
        'service_id', p_service_id,
        'external_user_id', p_external_user_id,
        'deactivated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.unlink_service_from_user IS 
'Deactivates (soft deletes) a service integration for a user. Raises error if integration not found.';

-- Convenience wrapper for Gmail
CREATE OR REPLACE FUNCTION public.unlink_gmail_from_user(p_user_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.unlink_service_from_user(p_user_id, 'gmail');
$$;

COMMENT ON FUNCTION public.unlink_gmail_from_user IS 
'Deactivates Gmail integration for user. Wrapper for unlink_service_from_user.';

-- Convenience wrapper for Calendar
CREATE OR REPLACE FUNCTION public.unlink_calendar_from_user(p_user_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.unlink_service_from_user(p_user_id, 'google_calendar');
$$;

COMMENT ON FUNCTION public.unlink_calendar_from_user IS 
'Deactivates Google Calendar integration for user. Wrapper for unlink_service_from_user.';

-- Convenience wrapper for Telegram
CREATE OR REPLACE FUNCTION public.unlink_telegram_from_user(p_user_id text, p_telegram_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.unlink_service_from_user(p_user_id, 'telegram', p_telegram_id);
$$;

COMMENT ON FUNCTION public.unlink_telegram_from_user IS 
'Deactivates Telegram integration for user. Optionally specify telegram_id for multiple integrations.';

-- Convenience wrapper for Signal
CREATE OR REPLACE FUNCTION public.unlink_signal_from_user(p_user_id text, p_signal_uuid text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.unlink_service_from_user(p_user_id, 'signal', p_signal_uuid);
$$;

COMMENT ON FUNCTION public.unlink_signal_from_user IS 
'Deactivates Signal integration for user. Optionally specify signal_uuid for multiple integrations.';

-- Convenience wrapper for WhatsApp
CREATE OR REPLACE FUNCTION public.unlink_whatsapp_from_user(p_user_id text, p_whatsapp_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.unlink_service_from_user(p_user_id, 'whatsapp', p_whatsapp_id);
$$;

COMMENT ON FUNCTION public.unlink_whatsapp_from_user IS 
'Deactivates WhatsApp integration for user. Optionally specify whatsapp_id for multiple integrations.';

-- ============================================================================
-- FUNCTION 7: Token Update Functions
-- ============================================================================

-- Update token for Gmail or Calendar (generic for Google services)
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
        refresh_token = COALESCE(p_refresh_token, refresh_token), -- Update only if provided
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
    
    -- Return success response with new expiration
    RETURN jsonb_build_object(
        'success', true,
        'user_id', p_user_id,
        'service_id', p_service_id,
        'expires_at', v_new_expiry,
        'updated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.update_service_token IS 
'Updates access token and computes expiration date. Optionally updates refresh_token. Raises error if integration does not exist.';

-- Convenience wrapper for Gmail token updates
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

COMMENT ON FUNCTION public.update_gmail_token IS 
'Updates Gmail token with automatic expiration calculation. Default 3600 seconds (1 hour).';

-- Convenience wrapper for Calendar token updates
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

COMMENT ON FUNCTION public.update_calendar_token IS 
'Updates Calendar token with automatic expiration calculation. Default 3600 seconds (1 hour).';

-- Expire refresh token for a service
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
    -- Update the integration
    UPDATE public.user_integrations
    SET 
        refresh_expired = true,
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
        'refresh_expired', true,
        'updated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.expire_refresh_token IS 
'Marks refresh token as expired for a service. Raises error if integration not found.';

-- Convenience wrapper for Gmail
CREATE OR REPLACE FUNCTION public.expire_gmail_refresh_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.expire_refresh_token(p_user_id, 'gmail');
$$;

COMMENT ON FUNCTION public.expire_gmail_refresh_token IS 
'Marks Gmail refresh token as expired. Wrapper for expire_refresh_token.';

-- Convenience wrapper for Calendar
CREATE OR REPLACE FUNCTION public.expire_calendar_refresh_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
    SELECT public.expire_refresh_token(p_user_id, 'google_calendar');
$$;

COMMENT ON FUNCTION public.expire_calendar_refresh_token IS 
'Marks Calendar refresh token as expired. Wrapper for expire_refresh_token.';

-- ============================================================================
-- FUNCTION 8: Bulk Operations and Advanced Utilities
-- ============================================================================

-- Function to reactivate a previously deactivated integration
CREATE OR REPLACE FUNCTION public.reactivate_service_integration(
    p_user_id text,
    p_service_id text,
    p_external_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_updated_count int;
    v_integration_id uuid;
BEGIN
    -- Reactivate the integration
    UPDATE public.user_integrations
    SET 
        is_active = true,
        updated_at = now()
    WHERE user_id = p_user_id
      AND service_id = p_service_id
      AND (p_external_user_id IS NULL OR external_user_id = p_external_user_id)
      AND is_active = false
    RETURNING id INTO v_integration_id;
    
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    
    -- Raise error if integration doesn't exist
    IF v_updated_count = 0 THEN
        RAISE EXCEPTION 'Inactive integration not found for user_id=% and service_id=%', p_user_id, p_service_id;
    END IF;
    
    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'integration_id', v_integration_id,
        'user_id', p_user_id,
        'service_id', p_service_id,
        'external_user_id', p_external_user_id,
        'reactivated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.reactivate_service_integration IS 
'Reactivates a previously deactivated service integration for a user.';

-- Function to completely remove (hard delete) an integration
CREATE OR REPLACE FUNCTION public.remove_service_integration(
    p_user_id text,
    p_service_id text,
    p_external_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted_count int;
    v_integration_id uuid;
BEGIN
    -- Get the integration ID before deletion
    SELECT id INTO v_integration_id
    FROM public.user_integrations
    WHERE user_id = p_user_id
      AND service_id = p_service_id
      AND (p_external_user_id IS NULL OR external_user_id = p_external_user_id);
    
    -- Hard delete the integration
    DELETE FROM public.user_integrations
    WHERE user_id = p_user_id
      AND service_id = p_service_id
      AND (p_external_user_id IS NULL OR external_user_id = p_external_user_id);
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    -- Raise error if integration doesn't exist
    IF v_deleted_count = 0 THEN
        RAISE EXCEPTION 'Integration not found for user_id=% and service_id=%', p_user_id, p_service_id;
    END IF;
    
    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'integration_id', v_integration_id,
        'user_id', p_user_id,
        'service_id', p_service_id,
        'external_user_id', p_external_user_id,
        'removed_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.remove_service_integration IS 
'Completely removes (hard deletes) a service integration for a user. Use with caution!';

-- Function to bulk link multiple services to a user
CREATE OR REPLACE FUNCTION public.bulk_link_services_to_user(
    p_user_id text,
    p_services jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_service jsonb;
    v_results jsonb := '[]'::jsonb;
    v_result jsonb;
    v_error_count int := 0;
    v_success_count int := 0;
BEGIN
    -- Validate that user exists
    IF NOT EXISTS(SELECT 1 FROM public.users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User with id=% does not exist', p_user_id;
    END IF;
    
    -- Process each service
    FOR v_service IN SELECT * FROM jsonb_array_elements(p_services)
    LOOP
        BEGIN
            v_result := public.link_service_to_user(
                p_user_id,
                v_service->>'service_id',
                v_service->>'external_user_id',
                v_service->>'external_username',
                v_service->>'display_label',
                v_service->>'access_token',
                v_service->>'refresh_token',
                (v_service->>'token_expiration_date')::timestamptz,
                v_service->>'client_id',
                v_service->>'client_secret',
                v_service->>'auth_code',
                v_service->'granted_scopes',
                v_service->'credentials',
                v_service->'metadata'
            );
            
            v_results := v_results || jsonb_build_object(
                'service_id', v_service->>'service_id',
                'success', true,
                'result', v_result
            );
            v_success_count := v_success_count + 1;
            
        EXCEPTION WHEN OTHERS THEN
            v_results := v_results || jsonb_build_object(
                'service_id', v_service->>'service_id',
                'success', false,
                'error', SQLERRM
            );
            v_error_count := v_error_count + 1;
        END;
    END LOOP;
    
    -- Return summary
    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'total_services', jsonb_array_length(p_services),
        'successful', v_success_count,
        'failed', v_error_count,
        'results', v_results
    );
END;
$$;

COMMENT ON FUNCTION public.bulk_link_services_to_user IS 
'Bulk links multiple services to a user. Input: JSON array of service objects. Returns summary with individual results.';

-- Function to get integration statistics for a user
CREATE OR REPLACE FUNCTION public.get_user_integration_stats(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'user_id', p_user_id,
        'total_integrations', (
            SELECT count(*) FROM public.user_integrations WHERE user_id = p_user_id
        ),
        'active_integrations', (
            SELECT count(*) FROM public.user_integrations WHERE user_id = p_user_id AND is_active = true
        ),
        'inactive_integrations', (
            SELECT count(*) FROM public.user_integrations WHERE user_id = p_user_id AND is_active = false
        ),
        'services_by_type', (
            SELECT jsonb_object_agg(sub.type, sub.service_count)
            FROM (
                SELECT s.type, count(*) as service_count
                FROM public.user_integrations ui
                JOIN public.services s ON ui.service_id = s.id
                WHERE ui.user_id = p_user_id AND ui.is_active = true
                GROUP BY s.type
            ) sub
        ),
        'services_with_tokens', (
            SELECT count(*) FROM public.user_integrations 
            WHERE user_id = p_user_id 
              AND is_active = true 
              AND access_token IS NOT NULL
        ),
        'expired_tokens', (
            SELECT count(*) FROM public.user_integrations 
            WHERE user_id = p_user_id 
              AND is_active = true 
              AND access_token IS NOT NULL
              AND token_expiration_date IS NOT NULL
              AND token_expiration_date < now()
        )
    );
$$;

COMMENT ON FUNCTION public.get_user_integration_stats IS 
'Returns comprehensive statistics about a user''s integrations including counts by type and token status.';

-- Function to find users with incomplete integrations (missing tokens, etc.)
CREATE OR REPLACE FUNCTION public.find_incomplete_integrations(
    p_service_id text DEFAULT NULL
)
RETURNS TABLE (
    user_id text,
    email text,
    service_id text,
    service_name text,
    integration_id uuid,
    issues jsonb
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        u.id,
        u.email,
        ui.service_id,
        s.name,
        ui.id,
        jsonb_build_object(
            'missing_access_token', ui.access_token IS NULL,
            'missing_refresh_token', ui.refresh_token IS NULL,
            'missing_client_credentials', ui.client_id IS NULL OR ui.client_secret IS NULL,
            'missing_external_id', ui.external_user_id IS NULL,
            'token_expired', ui.token_expiration_date IS NOT NULL AND ui.token_expiration_date < now(),
            'refresh_expired', COALESCE(ui.refresh_expired, false)
        ) as issues
    FROM public.user_integrations ui
    JOIN public.users u ON ui.user_id = u.id
    JOIN public.services s ON ui.service_id = s.id
    WHERE ui.is_active = true
      AND (p_service_id IS NULL OR ui.service_id = p_service_id)
      AND (
          ui.access_token IS NULL 
          OR ui.refresh_token IS NULL 
          OR (ui.client_id IS NULL OR ui.client_secret IS NULL)
          OR ui.external_user_id IS NULL
          OR (ui.token_expiration_date IS NOT NULL AND ui.token_expiration_date < now())
          OR COALESCE(ui.refresh_expired, false) = true
      )
    ORDER BY u.email, s.name;
$$;

COMMENT ON FUNCTION public.find_incomplete_integrations IS 
'Finds users with incomplete or problematic integrations. Optionally filter by service_id.';

-- Function to cleanup orphaned integrations (users that no longer exist)
CREATE OR REPLACE FUNCTION public.cleanup_orphaned_integrations()
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted_count int;
BEGIN
    -- Delete integrations for non-existent users
    DELETE FROM public.user_integrations
    WHERE user_id NOT IN (SELECT id FROM public.users);
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', true,
        'orphaned_integrations_removed', v_deleted_count,
        'cleaned_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.cleanup_orphaned_integrations IS 
'Removes integrations for users that no longer exist. Use with caution!';

-- ============================================================================
-- EXAMPLE USAGE
-- ============================================================================

-- Example 1: Get user with all integrations
-- SELECT public.get_user_with_integrations('user_123');

-- Example 2: Get Calendar token (N8N workflow replacement)
-- SELECT public.get_calendar_token('user_123');
-- Returns: {"token": "...", "refresh_token": "...", "is_expired": false, "expires_at": "..."}

-- Example 3: Check if user has valid Gmail token
-- SELECT public.has_valid_token('user_123', 'gmail');

-- Example 4: Get all service IDs for user
-- SELECT public.get_user_services('user_123');

-- Example 5: Find user by telegram ID
-- SELECT public.get_integration_by_external_id('telegram', 'telegram_456');

-- Example 5b: Find user by WhatsApp ID
-- SELECT public.get_whatsapp_user('whatsapp_789');

-- Example 6: Update Gmail token (N8N after OAuth refresh)
-- SELECT public.update_gmail_token('user_123', 'ya29.new_token_here', 3600);
-- Returns: {"success": true, "expires_at": "2025-10-13T11:00:00+00", ...}

-- Example 7: Update Calendar token with new refresh token
-- SELECT public.update_calendar_token('user_123', 'ya29.new_token', 3600, '1//0g_new_refresh');

-- Example 8: Generic token update for any service
-- SELECT public.update_service_token('user_123', 'gmail', 'ya29.token', 7200);

-- Example 9: Link Gmail to user (OAuth flow completion)
-- SELECT public.link_gmail_to_user('user_123', 'ya29.access_token', '1//refresh_token', '2025-10-13T12:00:00Z', 'client_id', 'client_secret');

-- Example 10: Link Telegram to user
-- SELECT public.link_telegram_to_user('user_123', 'telegram_456', '@username', 'My Telegram');

-- Example 11: Link WhatsApp to user
-- SELECT public.link_whatsapp_to_user('user_123', 'whatsapp_789', '@whatsapp_user', 'WhatsApp Business');

-- Example 12: Link Signal to user
-- SELECT public.link_signal_to_user('user_123', 'signal_uuid_abc', 'Signal Integration');

-- Example 13: Unlink Gmail from user
-- SELECT public.unlink_gmail_from_user('user_123');

-- Example 14: Unlink Telegram from user (with specific telegram_id)
-- SELECT public.unlink_telegram_from_user('user_123', 'telegram_456');

-- Example 15: Bulk link multiple services
-- SELECT public.bulk_link_services_to_user('user_123', '[
--   {"service_id": "gmail", "access_token": "ya29.token", "external_user_id": "user@example.com"},
--   {"service_id": "telegram", "external_user_id": "telegram_456", "external_username": "@user"},
--   {"service_id": "whatsapp", "external_user_id": "whatsapp_789"}
-- ]'::jsonb);

-- Example 16: Get user integration statistics
-- SELECT public.get_user_integration_stats('user_123');

-- Example 17: Find incomplete integrations
-- SELECT * FROM public.find_incomplete_integrations('gmail');

-- Example 18: Reactivate a deactivated integration
-- SELECT public.reactivate_service_integration('user_123', 'telegram', 'telegram_456');

-- Example 19: Remove integration completely (hard delete)
-- SELECT public.remove_service_integration('user_123', 'telegram', 'telegram_456');

-- Example 20: Cleanup orphaned integrations
-- SELECT public.cleanup_orphaned_integrations();

-- ============================================================================
-- FUNCTION 9: MISSING FUNCTIONS FROM MIGRATION SCRIPT
-- ============================================================================
-- These functions were in the migration script but missing from this file
-- Adding them for complete backwards compatibility

-- Get user integrations as table (backwards compatibility)
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

COMMENT ON FUNCTION public.get_user_integrations IS 'Returns all integrations for a given user (table format)';

-- Get telegram ID for user (backwards compatibility)
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

-- Check if user has specific service (backwards compatibility)
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

-- Get user ID by external integration ID (generic)
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

-- Get full user by external integration ID (generic)
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
-- FUNCTION 10: TELEGRAM SIGNUP TOKEN LINKING (BULLETPROOF)
-- ============================================================================

-- Bulletproof function to link Telegram by signup token
-- Handles all edge cases for JSONB operations and data validation
CREATE OR REPLACE FUNCTION public.link_telegram_by_signup_token(
    p_telegram_id text,
    p_signup_token text,
    p_telegram_username text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id text;
    v_integration_id uuid;
    v_existing_telegram_id text;
    v_signup_token_from_db text;
    v_credentials_jsonb jsonb;
    v_result jsonb;
    v_error_details text;
BEGIN
    -- ============================================================================
    -- STEP 1: INPUT VALIDATION
    -- ============================================================================
    
    -- Validate required parameters
    IF p_telegram_id IS NULL OR trim(p_telegram_id) = '' THEN
        RAISE EXCEPTION 'telegram_id cannot be NULL or empty';
    END IF;
    
    IF p_signup_token IS NULL OR trim(p_signup_token) = '' THEN
        RAISE EXCEPTION 'signup_token cannot be NULL or empty';
    END IF;
    
    -- Normalize inputs (trim whitespace)
    p_telegram_id := trim(p_telegram_id);
    p_signup_token := trim(p_signup_token);
    
    -- Validate telegram_id format (should be numeric)
    IF NOT p_telegram_id ~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'Invalid telegram_id format: % (must be numeric)', p_telegram_id;
    END IF;
    
    -- Validate signup_token format (should be alphanumeric with possible dashes/underscores)
    IF NOT p_signup_token ~ '^[a-zA-Z0-9_-]+$' THEN
        RAISE EXCEPTION 'Invalid signup_token format: % (must be alphanumeric with dashes/underscores only)', p_signup_token;
    END IF;
    
    -- ============================================================================
    -- STEP 2: CHECK FOR EXISTING TELEGRAM INTEGRATION
    -- ============================================================================
    
    -- Check if telegram_id is already linked to another user
    SELECT ui.user_id INTO v_existing_telegram_id
    FROM public.user_integrations ui
    WHERE ui.service_id = 'telegram'
      AND ui.external_user_id = p_telegram_id
      AND ui.is_active = true
    LIMIT 1;
    
    IF v_existing_telegram_id IS NOT NULL THEN
        RAISE EXCEPTION 'Telegram ID % is already linked to user %', p_telegram_id, v_existing_telegram_id;
    END IF;
    
    -- ============================================================================
    -- STEP 3: FIND USER BY SIGNUP TOKEN (ROBUST JSONB HANDLING)
    -- ============================================================================
    
    BEGIN
        -- Get the integration with signup token
        SELECT 
            ui.user_id,
            ui.id,
            ui.credentials,
            ui.external_user_id
        INTO 
            v_user_id,
            v_integration_id,
            v_credentials_jsonb,
            v_existing_telegram_id
        FROM public.user_integrations ui
        WHERE ui.service_id = 'telegram'
          AND ui.is_active = true
          AND ui.credentials IS NOT NULL
          AND jsonb_typeof(ui.credentials) = 'object'
          AND ui.credentials ? 'signup_token'
          AND ui.credentials->>'signup_token' = p_signup_token
        LIMIT 1;
        
        -- Handle case where no integration found
        IF NOT FOUND THEN
            RAISE EXCEPTION 'No active Telegram integration found with signup_token: %', p_signup_token;
        END IF;
        
        -- Handle case where user already has telegram_id linked
        IF v_existing_telegram_id IS NOT NULL THEN
            RAISE EXCEPTION 'User % already has Telegram ID % linked. Cannot link new ID %', 
                v_user_id, v_existing_telegram_id, p_telegram_id;
        END IF;
        
        -- Validate that credentials contains valid signup_token
        v_signup_token_from_db := v_credentials_jsonb->>'signup_token';
        IF v_signup_token_from_db IS NULL OR v_signup_token_from_db != p_signup_token THEN
            RAISE EXCEPTION 'Signup token mismatch: expected %, found %', p_signup_token, v_signup_token_from_db;
        END IF;
        
    EXCEPTION WHEN OTHERS THEN
        -- Enhanced error reporting for JSONB issues
        v_error_details := SQLERRM;
        IF v_error_details LIKE '%malformed%' OR v_error_details LIKE '%invalid%' THEN
            RAISE EXCEPTION 'Invalid JSONB data in credentials column for signup_token %. Error: %', p_signup_token, v_error_details;
        ELSE
            RAISE;
        END IF;
    END;
    
    -- ============================================================================
    -- STEP 4: VALIDATE USER EXISTS
    -- ============================================================================
    
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'User % not found in users table', v_user_id;
    END IF;
    
    -- ============================================================================
    -- STEP 5: UPDATE INTEGRATION WITH TELEGRAM ID
    -- ============================================================================
    
    BEGIN
        -- Update the integration with the telegram_id and clean up signup_token
        UPDATE public.user_integrations
        SET 
            external_user_id = p_telegram_id,
            external_username = p_telegram_username,
            credentials = credentials - 'signup_token', -- Remove signup_token from credentials
            updated_at = now()
        WHERE id = v_integration_id
          AND user_id = v_user_id
          AND service_id = 'telegram'
          AND is_active = true;
        
        -- Verify update succeeded
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Failed to update Telegram integration for user %', v_user_id;
        END IF;
        
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Failed to update Telegram integration: %', SQLERRM;
    END;
    
    -- ============================================================================
    -- STEP 6: RETURN SUCCESS RESPONSE
    -- ============================================================================
    
    v_result := jsonb_build_object(
        'success', true,
        'user_id', v_user_id,
        'integration_id', v_integration_id,
        'telegram_id', p_telegram_id,
        'telegram_username', p_telegram_username,
        'linked_at', now(),
        'signup_token_consumed', true
    );
    
    RETURN v_result;
    
EXCEPTION WHEN OTHERS THEN
    -- Comprehensive error handling
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE,
        'telegram_id', p_telegram_id,
        'signup_token', p_signup_token,
        'failed_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.link_telegram_by_signup_token IS 
'Bulletproof function to link Telegram ID to user via signup token. Handles all JSONB edge cases, validates inputs, prevents duplicates, and cleans up signup tokens.';

-- ============================================================================
-- FUNCTION 11: TELEGRAM SIGNUP TOKEN VALIDATION (HELPER)
-- ============================================================================

-- Helper function to validate signup token without linking
CREATE OR REPLACE FUNCTION public.validate_telegram_signup_token(p_signup_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_user_id text;
    v_integration_id uuid;
    v_credentials_jsonb jsonb;
    v_existing_telegram_id text;
    v_signup_token_from_db text;
BEGIN
    -- Input validation
    IF p_signup_token IS NULL OR trim(p_signup_token) = '' THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'signup_token cannot be NULL or empty'
        );
    END IF;
    
    p_signup_token := trim(p_signup_token);
    
    IF NOT p_signup_token ~ '^[a-zA-Z0-9_-]+$' THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'Invalid signup_token format (must be alphanumeric with dashes/underscores only)'
        );
    END IF;
    
    BEGIN
        -- Find integration with signup token
        SELECT 
            ui.user_id,
            ui.id,
            ui.credentials,
            ui.external_user_id
        INTO 
            v_user_id,
            v_integration_id,
            v_credentials_jsonb,
            v_existing_telegram_id
        FROM public.user_integrations ui
        WHERE ui.service_id = 'telegram'
          AND ui.is_active = true
          AND ui.credentials IS NOT NULL
          AND jsonb_typeof(ui.credentials) = 'object'
          AND ui.credentials ? 'signup_token'
          AND ui.credentials->>'signup_token' = p_signup_token
        LIMIT 1;
        
        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'valid', false,
                'error', 'No active Telegram integration found with this signup_token'
            );
        END IF;
        
        -- Check if already linked
        IF v_existing_telegram_id IS NOT NULL THEN
            RETURN jsonb_build_object(
                'valid', false,
                'error', 'User already has Telegram ID linked',
                'user_id', v_user_id,
                'existing_telegram_id', v_existing_telegram_id
            );
        END IF;
        
        -- Validate credentials
        v_signup_token_from_db := v_credentials_jsonb->>'signup_token';
        IF v_signup_token_from_db IS NULL OR v_signup_token_from_db != p_signup_token THEN
            RETURN jsonb_build_object(
                'valid', false,
                'error', 'Signup token mismatch in database'
            );
        END IF;
        
        -- Success
        RETURN jsonb_build_object(
            'valid', true,
            'user_id', v_user_id,
            'integration_id', v_integration_id,
            'ready_for_linking', true
        );
        
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'Database error: ' || SQLERRM
        );
    END;
END;
$$;

COMMENT ON FUNCTION public.validate_telegram_signup_token IS 
'Validates a Telegram signup token without performing any modifications. Safe for testing and validation.';

-- ============================================================================
-- FUNCTION 12: TELEGRAM SIGNUP TOKEN CLEANUP (MAINTENANCE)
-- ============================================================================

-- Function to clean up expired or invalid signup tokens
CREATE OR REPLACE FUNCTION public.cleanup_expired_telegram_signup_tokens()
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_cleaned_count int := 0;
    v_integration RECORD;
BEGIN
    -- Find integrations with signup tokens that are older than 24 hours
    -- and haven't been linked yet
    FOR v_integration IN 
        SELECT id, user_id, credentials
        FROM public.user_integrations
        WHERE service_id = 'telegram'
          AND is_active = true
          AND external_user_id IS NULL
          AND credentials IS NOT NULL
          AND jsonb_typeof(credentials) = 'object'
          AND credentials ? 'signup_token'
          AND created_at < now() - interval '24 hours'
    LOOP
        BEGIN
            -- Remove signup_token from credentials
            UPDATE public.user_integrations
            SET 
                credentials = credentials - 'signup_token',
                updated_at = now()
            WHERE id = v_integration.id;
            
            v_cleaned_count := v_cleaned_count + 1;
            
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue with other records
            RAISE WARNING 'Failed to cleanup signup token for integration %: %', 
                v_integration.id, SQLERRM;
        END;
    END LOOP;
    
    RETURN jsonb_build_object(
        'success', true,
        'cleaned_tokens', v_cleaned_count,
        'cleaned_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.cleanup_expired_telegram_signup_tokens IS 
'Cleans up expired Telegram signup tokens (older than 24 hours) that were never used for linking.';

-- ============================================================================
-- MIGRATION COMPATIBILITY
-- ============================================================================
-- These functions can be run independently or included in the migration script
-- To apply: psql -d your_database -f database_functions.sql

