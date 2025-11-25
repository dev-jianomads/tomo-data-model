-- ============================================================================
-- SLACK INTEGRATION FUNCTIONS
-- ============================================================================
-- Design: Only workspace rows exist (no separate user mapping rows)
-- - external_user_id = team_id (always)
-- - credentials->>'slack_user_id' = Slack user ID
-- - One row per workspace installation
-- ============================================================================

-- ============================================================================
-- LINKING FUNCTIONS
-- ============================================================================

-- Link Slack workspace to user (after OAuth installation)
-- Creates a workspace row with external_user_id = team_id
CREATE OR REPLACE FUNCTION public.link_slack_to_user(
    p_user_id text,
    p_team_id text,
    p_access_token text,
    p_app_id text DEFAULT NULL,
    p_team_name text DEFAULT NULL,
    p_bot_user_id text DEFAULT NULL,
    p_installing_user_id text DEFAULT NULL,
    p_display_label text DEFAULT NULL,
    p_metadata jsonb DEFAULT NULL,
    p_credentials jsonb DEFAULT NULL
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
    SELECT EXISTS(SELECT 1 FROM public.services WHERE id = 'slack' AND is_active = true) INTO v_service_exists;
    IF NOT v_service_exists THEN
        RAISE EXCEPTION 'Slack service does not exist or is inactive';
    END IF;
    
    -- Insert the workspace integration
    INSERT INTO public.user_integrations (
        user_id,
        service_id,
        external_user_id,  -- team_id
        external_username,  -- team_name
        display_label,
        access_token,      -- bot token
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
        'slack',
        p_team_id,  -- external_user_id = team_id
        p_team_name,
        COALESCE(p_display_label, p_team_name, 'Slack Workspace'),
        p_access_token,
        NULL,  -- refresh_token (Slack tokens don't expire)
        now() + interval '10 years',  -- Set far future so get_valid_token works correctly
        now() + interval '10 years',
        NULL,  -- client_id
        NULL,  -- client_secret
        NULL,  -- auth_code
        NULL,  -- granted_scopes
        COALESCE(p_credentials, jsonb_build_object(
            'app_id', p_app_id,
            'bot_user_id', p_bot_user_id,
            'slack_user_id', p_installing_user_id
        )),
        COALESCE(p_metadata, jsonb_build_object(
            'app_id', p_app_id,
            'team_id', p_team_id,
            'team_name', p_team_name
        )),
        true
    )
    RETURNING id INTO v_integration_id;
    
    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'integration_id', v_integration_id,
        'user_id', p_user_id,
        'service_id', 'slack',
        'external_user_id', p_team_id,
        'created_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.link_slack_to_user IS 
'Links Slack workspace to user. Uses team_id as external_user_id to allow multiple workspace installations per user. Sets token_expiration_date to 10 years in the future so get_valid_token() works correctly (Slack tokens don''t expire).';

-- Link Slack workspace and auto-create Tomo user if needed (for OAuth installation)
-- Use this when the installing user might not be a Tomo user yet
CREATE OR REPLACE FUNCTION public.link_slack_workspace_or_create_user(
    p_installing_slack_user_id text,
    p_installing_slack_email text,
    p_team_id text,
    p_access_token text,
    p_installing_slack_name text DEFAULT NULL,
    p_installing_slack_username text DEFAULT NULL,
    p_app_id text DEFAULT NULL,
    p_team_name text DEFAULT NULL,
    p_bot_user_id text DEFAULT NULL,
    p_display_label text DEFAULT NULL,
    p_metadata jsonb DEFAULT NULL,
    p_credentials jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_tomo_user_id text;
    v_user_created boolean := false;
    v_workspace_result jsonb;
BEGIN
    -- Try to find existing Tomo user by email first
    SELECT id INTO v_tomo_user_id
    FROM public.users
    WHERE email = p_installing_slack_email
    LIMIT 1;
    
    -- If no user found, create new Tomo user
    IF v_tomo_user_id IS NULL THEN
        v_tomo_user_id := gen_random_uuid()::text;
        v_user_created := true;
        
        INSERT INTO public.users (id, email, display_name, created_at)
        VALUES (
            v_tomo_user_id,
            COALESCE(p_installing_slack_email, p_installing_slack_user_id || '@slack.local'),
            COALESCE(p_installing_slack_name, p_installing_slack_username, 'Slack User'),
            now()
        );
    END IF;
    
    -- Link workspace to Tomo user
    v_workspace_result := public.link_slack_to_user(
        v_tomo_user_id,
        p_team_id,
        p_access_token,
        p_app_id,
        p_team_name,
        p_bot_user_id,
        p_installing_slack_user_id,
        p_display_label,
        p_metadata,
        p_credentials
    );
    
    -- Return combined result
    RETURN jsonb_build_object(
        'success', true,
        'tomo_user_id', v_tomo_user_id,
        'user_created', v_user_created,
        'workspace', v_workspace_result
    );
END;
$$;

COMMENT ON FUNCTION public.link_slack_workspace_or_create_user IS 
'Links Slack workspace to Tomo user, creating the user if they don''t exist. Use this during OAuth installation when the installing user might not be a Tomo user yet.';

-- Update workspace row to link a different Slack user to the same Tomo user
-- Use this when a different Slack user in the same workspace wants to use the bot
CREATE OR REPLACE FUNCTION public.update_slack_workspace_user(
    p_workspace_team_id text,
    p_slack_user_id text,
    p_tomo_user_id text
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_updated_count int;
BEGIN
    -- Update the workspace row to point to the new user and update slack_user_id
    UPDATE public.user_integrations
    SET 
        user_id = p_tomo_user_id,
        credentials = COALESCE(credentials, '{}'::jsonb) || jsonb_build_object('slack_user_id', p_slack_user_id),
        updated_at = now()
    WHERE service_id = 'slack'
      AND external_user_id = p_workspace_team_id
      AND is_active = true;
    
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    
    IF v_updated_count = 0 THEN
        RAISE EXCEPTION 'Workspace with team_id % not found', p_workspace_team_id;
    END IF;
    
    RETURN jsonb_build_object(
        'success', true,
        'user_id', p_tomo_user_id,
        'slack_user_id', p_slack_user_id,
        'workspace_team_id', p_workspace_team_id,
        'updated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.update_slack_workspace_user IS 
'Updates workspace row to link a different Slack user to a Tomo user. Use this when a different Slack user in the same workspace wants to use the bot.';

-- ============================================================================
-- QUERY FUNCTIONS
-- ============================================================================

-- Get all Slack workspaces for a user
CREATE OR REPLACE FUNCTION public.get_user_slack_workspaces(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_agg(
        jsonb_build_object(
            'integration_id', ui.id,
            'team_id', ui.external_user_id,
            'team_name', ui.external_username,
            'app_id', ui.credentials->>'app_id',
            'display_label', ui.display_label,
            'is_active', ui.is_active,
            'bot_user_id', ui.credentials->>'bot_user_id',
            'slack_user_id', ui.credentials->>'slack_user_id',
            'metadata', ui.metadata,
            'created_at', ui.created_at,
            'updated_at', ui.updated_at
        )
        ORDER BY ui.created_at DESC
    )
    FROM public.user_integrations ui
    WHERE ui.user_id = p_user_id
      AND ui.service_id = 'slack'
      AND ui.is_active = true;
$$;

COMMENT ON FUNCTION public.get_user_slack_workspaces IS 
'Returns all Slack workspace installations for a user as JSONB array.';

-- Get Slack workspace by app_id and team_id
CREATE OR REPLACE FUNCTION public.get_slack_workspace(
    p_user_id text,
    p_app_id text,
    p_team_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'integration_id', ui.id,
        'team_id', ui.external_user_id,
        'team_name', ui.external_username,
        'app_id', ui.credentials->>'app_id',
        'display_label', ui.display_label,
        'is_active', ui.is_active,
        'bot_user_id', ui.credentials->>'bot_user_id',
        'slack_user_id', ui.credentials->>'slack_user_id',
        'access_token', ui.access_token,
        'metadata', ui.metadata,
        'created_at', ui.created_at,
        'updated_at', ui.updated_at
    )
    FROM public.user_integrations ui
    WHERE ui.user_id = p_user_id
      AND ui.service_id = 'slack'
      AND ui.credentials->>'app_id' = p_app_id
      AND (p_team_id IS NULL OR ui.external_user_id = p_team_id)
      AND ui.is_active = true
    ORDER BY ui.created_at DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_slack_workspace IS 
'Returns a specific Slack workspace installation by app_id (and optionally team_id). Useful for filtering by app when user has multiple Slack apps.';

-- Get Slack integration by team_id (for event routing)
CREATE OR REPLACE FUNCTION public.get_slack_integration_by_team(p_team_id text)
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
        'access_token', ui.access_token,
        'bot_user_id', ui.credentials->>'bot_user_id',
        'app_id', ui.credentials->>'app_id',
        'slack_user_id', ui.credentials->>'slack_user_id',
        'team_id', ui.external_user_id,
        'team_name', ui.external_username
    )
    FROM public.user_integrations ui
    WHERE ui.service_id = 'slack'
      AND ui.external_user_id = p_team_id
      AND ui.is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_slack_integration_by_team IS 
'Finds Slack integration by team_id. Returns user_id, access_token, bot_user_id, and other workspace details. Use this for event routing when you receive a team_id from Slack.';

-- Get Tomo user ID for a Slack user in a specific workspace (for event routing)
-- This is the recommended function for event routing when you have both slack_user_id and team_id
CREATE OR REPLACE FUNCTION public.get_user_by_slack_user_and_workspace(
    p_slack_user_id text,
    p_workspace_team_id text
)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'tomo_user_id', ui.user_id,
        'slack_user_id', ui.credentials->>'slack_user_id',
        'workspace_team_id', ui.external_user_id,
        'integration_id', ui.id
    )
    FROM public.user_integrations ui
    WHERE ui.service_id = 'slack'
      AND ui.external_user_id = p_workspace_team_id
      AND ui.credentials->>'slack_user_id' = p_slack_user_id
      AND ui.is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_user_by_slack_user_and_workspace IS 
'Finds Tomo user ID for a Slack user in a specific workspace. Use this in event routing when you receive a DM from a Slack user and need workspace-specific routing. Returns NULL if not linked.';

-- Get Slack user by Slack user ID (simple lookup, returns first match if multiple workspaces)
CREATE OR REPLACE FUNCTION public.get_slack_user(p_slack_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'integration_id', ui.id,
        'user_id', ui.user_id,
        'service_id', ui.service_id,
        'is_active', ui.is_active,
        'slack_user_id', ui.credentials->>'slack_user_id',
        'external_user_id', ui.external_user_id,
        'external_username', ui.external_username,
        'display_label', ui.display_label,
        'workspace_team_id', ui.external_user_id,
        'created_at', ui.created_at,
        'updated_at', ui.updated_at
    )
    FROM public.user_integrations ui
    WHERE ui.service_id = 'slack'
      AND ui.credentials->>'slack_user_id' = p_slack_user_id
      AND ui.is_active = true
    ORDER BY ui.created_at ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_slack_user IS 
'Finds user by Slack user ID. Returns user integration details for Slack service. Returns first match if user is linked in multiple workspaces. For workspace-specific lookups, use get_user_by_slack_user_and_workspace() instead.';

-- Get user ID by Slack user ID (simple text return)
-- NOTE: If Slack user is in multiple workspaces, returns first match.
-- For workspace-specific lookups, use get_user_by_slack_user_and_workspace() instead.
CREATE OR REPLACE FUNCTION public.get_user_id_by_slack_user_id(p_slack_user_id text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT user_id 
    FROM public.user_integrations 
    WHERE service_id = 'slack' 
      AND credentials->>'slack_user_id' = p_slack_user_id
      AND is_active = true
    ORDER BY created_at ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_user_id_by_slack_user_id IS 
'Returns Tomo user ID for a Slack user ID. Returns first match if user is linked in multiple workspaces. For workspace-specific lookups (recommended), use get_user_by_slack_user_and_workspace(slack_user_id, team_id) instead.';

-- Get all workspaces for a Slack user (returns all rows where this Slack user is linked)
CREATE OR REPLACE FUNCTION public.get_slack_user_workspaces(p_slack_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_agg(
        jsonb_build_object(
            'integration_id', ui.id,
            'user_id', ui.user_id,
            'workspace_team_id', ui.external_user_id,
            'workspace_name', ui.external_username,
            'app_id', ui.credentials->>'app_id',
            'bot_user_id', ui.credentials->>'bot_user_id',
            'is_active', ui.is_active,
            'created_at', ui.created_at,
            'updated_at', ui.updated_at
        )
        ORDER BY ui.created_at ASC
    )
    FROM public.user_integrations ui
    WHERE ui.service_id = 'slack'
      AND ui.credentials->>'slack_user_id' = p_slack_user_id
      AND ui.is_active = true;
$$;

COMMENT ON FUNCTION public.get_slack_user_workspaces IS 
'Returns all workspaces where a Slack user is linked. Useful when a Slack user belongs to multiple workspaces. Returns JSONB array of workspace objects.';

-- ============================================================================
-- TOKEN FUNCTIONS
-- ============================================================================

-- Get Slack token/credentials (for first workspace - use get_slack_token_by_team for specific workspace)
CREATE OR REPLACE FUNCTION public.get_slack_token(p_user_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'token', ui.access_token,
        'refresh_token', ui.refresh_token,
        'is_expired', COALESCE(ui.token_expiration_date < now(), false),
        'expires_at', ui.token_expiration_date,
        'refresh_expired', COALESCE(ui.refresh_expired, false),
        'bot_user_id', ui.credentials->>'bot_user_id',
        'app_id', ui.credentials->>'app_id',
        'team_id', ui.external_user_id
    )
    FROM public.user_integrations ui
    WHERE ui.user_id = p_user_id
      AND ui.service_id = 'slack'
      AND ui.is_active = true
    ORDER BY ui.created_at ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_slack_token IS 
'Returns Slack token details with expiration status for user. Returns first workspace if user has multiple. Use get_slack_token_by_team() for specific workspace.';

-- Get Slack token for a specific workspace by team_id
CREATE OR REPLACE FUNCTION public.get_slack_token_by_team(p_user_id text, p_team_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'token', ui.access_token,
        'refresh_token', ui.refresh_token,
        'is_expired', COALESCE(ui.token_expiration_date < now(), false),
        'expires_at', ui.token_expiration_date,
        'refresh_expired', COALESCE(ui.refresh_expired, false),
        'bot_user_id', ui.credentials->>'bot_user_id',
        'app_id', ui.credentials->>'app_id',
        'team_id', ui.external_user_id
    )
    FROM public.user_integrations ui
    WHERE ui.user_id = p_user_id
      AND ui.service_id = 'slack'
      AND ui.external_user_id = p_team_id
      AND ui.is_active = true
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_slack_token_by_team IS 
'Returns Slack token details for a specific workspace (team_id). Includes bot_user_id and app_id. Use this for event routing when you know the team_id.';

-- ============================================================================
-- UNLINKING FUNCTIONS
-- ============================================================================

-- Deactivate Slack workspace integration for user
CREATE OR REPLACE FUNCTION public.unlink_slack_from_user(p_user_id text, p_team_id text DEFAULT NULL)
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
      AND service_id = 'slack'
      AND (p_team_id IS NULL OR external_user_id = p_team_id)
      AND is_active = true
    RETURNING id INTO v_integration_id;
    
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    
    -- Raise error if integration doesn't exist
    IF v_updated_count = 0 THEN
        RAISE EXCEPTION 'Active Slack integration not found for user_id=% and team_id=%', p_user_id, COALESCE(p_team_id, 'ANY');
    END IF;
    
    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'integration_id', v_integration_id,
        'user_id', p_user_id,
        'service_id', 'slack',
        'team_id', p_team_id,
        'deactivated_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.unlink_slack_from_user IS 
'Deactivates Slack workspace integration for user. Specify team_id to unlink a specific workspace. If team_id is NULL, unlinks all Slack workspaces for the user.';

-- ============================================================================
-- AUTO-CREATE FUNCTIONS
-- ============================================================================

-- Auto-create Tomo user and link Slack user (for unknown Slack users)
CREATE OR REPLACE FUNCTION public.auto_create_tomo_user_from_slack(
    p_slack_user_id text,
    p_workspace_team_id text,
    p_slack_email text,
    p_slack_name text DEFAULT NULL,
    p_slack_username text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_tomo_user_id text;
    v_workspace_row RECORD;
BEGIN
    -- Generate new Tomo user ID
    v_tomo_user_id := gen_random_uuid()::text;
    
    -- Create Tomo user
    INSERT INTO public.users (id, email, display_name, created_at)
    VALUES (
        v_tomo_user_id,
        COALESCE(p_slack_email, p_slack_user_id || '@slack.local'),
        COALESCE(p_slack_name, p_slack_username, 'Slack User'),
        now()
    );
    
    -- Find the workspace row for this team_id
    SELECT * INTO v_workspace_row
    FROM public.user_integrations
    WHERE service_id = 'slack'
      AND external_user_id = p_workspace_team_id
      AND is_active = true
    LIMIT 1;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Workspace with team_id % not found', p_workspace_team_id;
    END IF;
    
    -- Update the workspace row to point to the new user and store slack_user_id
    UPDATE public.user_integrations
    SET 
        user_id = v_tomo_user_id,
        credentials = COALESCE(credentials, '{}'::jsonb) || jsonb_build_object('slack_user_id', p_slack_user_id),
        updated_at = now()
    WHERE id = v_workspace_row.id;
    
    -- Return both user and integration info
    RETURN jsonb_build_object(
        'success', true,
        'tomo_user_id', v_tomo_user_id,
        'email', COALESCE(p_slack_email, p_slack_user_id || '@slack.local'),
        'display_name', COALESCE(p_slack_name, p_slack_username, 'Slack User'),
        'workspace_team_id', p_workspace_team_id,
        'slack_user_id', p_slack_user_id,
        'created_at', now()
    );
END;
$$;

COMMENT ON FUNCTION public.auto_create_tomo_user_from_slack IS 
'Auto-creates a Tomo user from Slack user info and links them to an existing workspace. Use this when an unknown Slack user DMs the bot. Returns new user_id and integration details.';

-- ============================================================================
-- MESSAGE FUNCTIONS
-- ============================================================================

-- Get last N Slack messages for a user
-- Similar to get_user_telegram_messages, but adapted for Slack's structure
-- For Slack: external_user_id = team_id, slack_user_id is in credentials->>'slack_user_id'
-- NOTE: p_user_id is the internal Tomo user_id, NOT the Slack user_id
CREATE OR REPLACE FUNCTION public.get_user_slack_messages(
    p_user_id text,
    p_limit int DEFAULT 8,
    p_direction text DEFAULT 'inbound',
    p_team_id text DEFAULT NULL
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
            'sender_id', sender_id,
            'team_id', team_id
        )
    )
    FROM (
        SELECT 
            sm.id,
            sm.text,
            coalesce(sm.slack_message_ts_utc, sm.created_at) as ts,
            sm.direction,
            sm.sender_id,
            ui.external_user_id as team_id
        FROM public.slack_messages sm
        JOIN public.user_integrations ui ON 
            ui.credentials->>'slack_user_id' = sm.sender_id
        WHERE ui.user_id = p_user_id
          AND ui.service_id = 'slack'
          AND ui.is_active = true
          AND sm.direction = p_direction
          AND sm.text IS NOT NULL
          AND (p_team_id IS NULL OR ui.external_user_id = p_team_id)
        ORDER BY coalesce(sm.slack_message_ts_utc, sm.created_at) DESC
        LIMIT p_limit
    ) sub;
$$;

COMMENT ON FUNCTION public.get_user_slack_messages IS 
'Returns last N Slack messages for a user as JSONB array. p_user_id is the internal Tomo user_id (not Slack user_id). Defaults to 8 inbound messages. Optionally filter by team_id for workspace-specific messages.';

-- Alternative function returning table format (for easier joins)
-- NOTE: p_user_id is the internal Tomo user_id, NOT the Slack user_id
CREATE OR REPLACE FUNCTION public.get_user_slack_messages_table(
    p_user_id text,
    p_limit int DEFAULT 8,
    p_direction text DEFAULT 'inbound',
    p_team_id text DEFAULT NULL
)
RETURNS TABLE (
    id bigint,
    text text,
    ts timestamp with time zone,
    direction text,
    sender_id text,
    team_id text
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        sm.id,
        sm.text,
        coalesce(sm.slack_message_ts_utc, sm.created_at) as ts,
        sm.direction,
        sm.sender_id,
        ui.external_user_id as team_id
    FROM public.slack_messages sm
    JOIN public.user_integrations ui ON 
        ui.credentials->>'slack_user_id' = sm.sender_id
    WHERE ui.user_id = p_user_id
      AND ui.service_id = 'slack'
      AND ui.is_active = true
      AND sm.direction = p_direction
      AND sm.text IS NOT NULL
      AND (p_team_id IS NULL OR ui.external_user_id = p_team_id)
    ORDER BY coalesce(sm.slack_message_ts_utc, sm.created_at) DESC
    LIMIT p_limit;
$$;

COMMENT ON FUNCTION public.get_user_slack_messages_table IS 
'Returns last N Slack messages for a user as table. p_user_id is the internal Tomo user_id (not Slack user_id). Defaults to 8 inbound messages. Use this for JOINs or when you need individual columns. Optionally filter by team_id for workspace-specific messages.';

