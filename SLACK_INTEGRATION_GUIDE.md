# Slack Integration Guide

**Date:** 2025-01-XX  
**Status:** Ready for Implementation

---

## Overview

This guide explains how to integrate Slack into the Tomo data model using the existing normalized schema. The integration leverages the `dev.services` and `dev.user_integrations` tables, which already support multi-workspace installations per user.

---

## Architecture

### Where Slack Lives in the Schema

Slack is integrated using the existing normalized structure:

1. **`dev.services`** - Contains the Slack service definition:
   ```sql
   ('slack', 'Slack', 'messaging', 'slack', true, '{"icon": "slack", "color": "#4A154B"}')
   ```

2. **`dev.user_integrations`** - Stores TWO types of Slack integrations:
   
   **Type 1: Workspace Installation** (stores bot token)
   - `service_id = 'slack'`
   - `external_user_id = team_id` (e.g., `T02Q7P07G91`)
   - `external_username = team_name` (e.g., `JIA Nomads`)
   - `access_token = bot token` (e.g., `xoxb-...`)
   - `credentials` JSON holds `app_id`, `bot_user_id`, `installing_user_id`, etc.
   - `user_id` = whoever installed it (or system user)
   
   **Type 2: User Mapping** (maps Slack user → Tomo user)
   - `service_id = 'slack'`
   - `external_user_id = slack_user_id` (e.g., `U07U3MJ9SQY`)
   - `user_id = tomo_user_id` (the Tomo user this Slack user corresponds to)
   - `metadata->>'workspace_team_id'` = which workspace this user is in
   - No `access_token` needed (workspace row has it)

**Key Design:** 
- One workspace row per workspace (for bot token)
- One user row per Slack user who wants to use the bot (for routing DMs)
- The unique constraint `(user_id, service_id, external_user_id)` allows this

---

## Integration Flow

### 1. OAuth Installation (n8n `/slack-oauth` workflow)

When a user installs your Slack app, you'll receive an OAuth response like:

```json
{
  "ok": true,
  "app_id": "A09U4GD1064",
  "authed_user": { "id": "U07U3MJ9SQY" },
  "access_token": "xoxb-...",
  "bot_user_id": "U09U4508SFK",
  "team": { "id": "T02Q7P07G91", "name": "JIA Nomads" },
  ...
}
```

**Map it to the database:**

```sql
SELECT dev.link_slack_to_user(
  p_user_id          := :tomo_user_id,        -- Your internal Tomo user ID (from session/JWT)
  p_team_id          := :team_id,              -- team.id from OAuth response
  p_access_token     := :access_token,          -- access_token (bot token)
  p_app_id           := :app_id,                -- app_id
  p_team_name        := :team_name,             -- team.name
  p_bot_user_id      := :bot_user_id,           -- bot_user_id
  p_installing_user_id := :authed_user_id       -- authed_user.id
);
```

**Field Mapping:**
- `p_user_id` → **Your internal Tomo user ID** (from your auth/session/JWT, NOT the Slack user ID)
  - Example: `"user_abc123"` or `"550e8400-e29b-41d4-a716-446655440000"` (your system's user ID)
  - **NOT** `"U07U3MJ9SQY"` (that's the Slack user ID, which goes in `p_installing_user_id`)
- `p_team_id` → `team.id` (e.g., `"T02Q7P07G91"`)
- `p_access_token` → `access_token` (bot token, e.g., `"xoxb-1234..."`)
- `p_app_id` → `app_id` (e.g., `"A09U4GD1064"`)
- `p_team_name` → `team.name` (e.g., `"JIA Nomads"`)
- `p_bot_user_id` → `bot_user_id` (e.g., `"U09U4508SFK"`)
- `p_installing_user_id` → `authed_user.id` (e.g., `"U07U3MJ9SQY"` - the Slack user who installed the app)
- `p_display_label` → Optional (e.g., `"JIA Nomads (Slack)"` or null)

**Why do you need `user_id`?**

The `user_id` is the Tomo user who installed the workspace. This is used as:
- **Fallback routing:** If a Slack user DMs but doesn't exist in your system, route to this user
- **Workspace owner:** Track who installed it
- **Settings page:** Show "Your Workspaces" in Tomo dashboard

**How to get it:**
- If OAuth initiated from Tomo: Use the logged-in Tomo user
- If OAuth from Slack App Directory: Use `authed_user.email` to find/create Tomo user, or use a system user as fallback

---

### ⚠️ How to Get the Tomo User ID During Slack OAuth (If You Need It)

**The Problem:** Unlike Gmail/Calendar (where user is already logged into Tomo), Slack OAuth can be initiated from Slack's side, so you don't automatically have the Tomo user context.

**Solutions (pick one):**

#### Option 1: OAuth State Parameter (Recommended)
Include the Tomo user ID in the OAuth `state` parameter. Slack will return it in the callback.

**Flow:**
1. User clicks "Connect Slack" in Tomo dashboard (user is logged in)
2. Tomo redirects to Slack OAuth with `state` containing Tomo user ID:
   ```
   https://slack.com/oauth/v2/authorize?
     client_id=YOUR_CLIENT_ID&
     scope=chat:write,commands&
     state=ENCODED_TOMO_USER_ID_OR_JWT
   ```
3. Slack redirects back to your callback with `state` parameter
4. Decode `state` to get Tomo user ID
5. Call `link_slack_to_user()` with the decoded user ID

**Security:** Encrypt/sign the state parameter (use JWT or signed token) to prevent tampering.

#### Option 2: Redirect from Tomo Dashboard (Simplest)
Require users to initiate OAuth from within Tomo (like Gmail/Calendar).

**Flow:**
1. User must be logged into Tomo
2. User clicks "Connect Slack Workspace" in Tomo settings
3. Tomo redirects to Slack OAuth (user context is in session)
4. Slack redirects back to Tomo callback
5. Tomo callback has user from session → call `link_slack_to_user()`

**Limitation:** Users can't install from Slack's App Directory directly.

#### Option 3: Post-Installation Linking
Store pending installations, then link when user logs into Tomo.

**Flow:**
1. Slack OAuth completes, but no Tomo user ID available
2. Store installation in temporary table with `team_id`, `access_token`, etc.
3. When user logs into Tomo, check for pending installations
4. Match by email (if Slack OAuth provides `authed_user.email`) or prompt user to claim
5. Link installation to Tomo user

**Database helper needed:**
```sql
-- Store pending installation
INSERT INTO dev.pending_slack_installations (team_id, access_token, ...);

-- Link when user logs in
SELECT dev.link_slack_to_user(
  p_user_id := :tomo_user_id,
  ... -- from pending installation
);
```

#### Option 4: Email Matching (If Available)
If Slack OAuth provides `authed_user.email`, match it to Tomo user email.

**Flow:**
1. Slack OAuth completes
2. Extract `authed_user.email` from OAuth response
3. Look up Tomo user by email:
   ```sql
   SELECT id FROM dev.users WHERE email = :slack_user_email;
   ```
4. If found, link installation
5. If not found, use Option 3 (pending installation)

**Note:** Slack OAuth may not always provide email (depends on scopes and user permissions).

---

**Recommendation:** Use **Option 1 (OAuth State)** or **Option 2 (Redirect from Tomo)** for the cleanest flow. Option 3 is good for allowing Slack App Directory installations.

---

### 2. Event Routing (n8n `/slack-events` workflow)

**When ANY user in the workspace DMs the bot:**

1. Extract `team_id` and `user` (Slack user ID) from event
2. Get bot token (to reply):
```sql
SELECT access_token 
FROM dev.user_integrations 
WHERE service_id = 'slack' AND external_user_id = :team_id;
```

3. **Check if this Slack user exists in our system:**
```sql
SELECT dev.get_tomo_user_by_slack_user(:slack_user_id, :team_id);
```

**What happens next depends on the result:**

#### Case A: User EXISTS (found in database)
- Route DM to that Tomo user
- Done

#### Case B: User DOES NOT EXIST (not found)
**Auto-create Tomo user:**

1. Get Slack user info via Slack API:
```javascript
// In n8n: Call Slack API users.info
const slackUser = await slack.users.info({ user: slack_user_id });
const email = slackUser.user.profile.email;
const name = slackUser.user.real_name || slackUser.user.name;
const username = slackUser.user.name;
```

2. Auto-create Tomo user and link:
```sql
SELECT dev.auto_create_tomo_user_from_slack(
  p_slack_user_id := :slack_user_id,
  p_workspace_team_id := :team_id,
  p_slack_email := :slack_email,        -- from Slack API
  p_slack_name := :slack_name,           -- from Slack API
  p_slack_username := :slack_username    -- from Slack API
);
-- Returns: {"success": true, "tomo_user_id": "...", "email": "...", ...}
```

3. Route DM to the new Tomo user

**Note:** If Slack doesn't provide email, the function uses `slack_user_id@slack.local` as placeholder.

---

### 3. UI Management (Settings, Disconnect, etc.)

#### List All Workspaces for a User

```sql
SELECT dev.get_user_slack_workspaces(:user_id);
```

Returns a JSONB array of workspaces with `team_id`, `team_name`, `bot_user_id`, etc.

**Example Response:**
```json
[
  {
    "integration_id": "uuid-here",
    "team_id": "T02Q7P07G91",
    "team_name": "JIA Nomads",
    "app_id": "A09U4GD1064",
    "display_label": "JIA Nomads",
    "is_active": true,
    "bot_user_id": "U09U4508SFK",
    "installing_user_id": "U07U3MJ9SQY",
    "created_at": "2025-01-XX...",
    "updated_at": "2025-01-XX..."
  }
]
```

#### Disconnect a Workspace

```sql
SELECT dev.unlink_slack_from_user(:user_id, :team_id);
```

Soft-deactivates the integration (sets `is_active = false`).

**Note:** If `team_id` is NULL, it will unlink all Slack workspaces for the user.

---

## Token Expiry Handling

### The Issue

The generic `get_valid_token()` function treats NULL expiration as expired:

```sql
v_is_expired := (
    v_integration.access_token IS NULL 
    OR v_integration.token_expiration_date IS NULL 
    OR v_integration.token_expiration_date < now()
);
```

Since Slack bot tokens don't expire, we initially passed `token_expiration_date = NULL`, which would cause `get_valid_token()` to incorrectly report tokens as expired.

### The Solution

The `link_slack_to_user()` function now sets `token_expiration_date` to a far future date (10 years):

```sql
now() + interval '10 years'  -- token_expiration_date
```

This allows `get_valid_token()` and `has_valid_token()` to work correctly for Slack while maintaining compatibility with the generic token helpers.

**Alternative Approach (if needed):**

If you prefer to never call `get_valid_token()` for Slack, you can read `access_token` directly from `user_integrations`:

```sql
SELECT access_token, credentials
FROM dev.user_integrations
WHERE user_id = :user_id
  AND service_id = 'slack'
  AND external_user_id = :team_id
  AND is_active = true;
```

---

## Database Functions Reference

### Linking Functions

#### `dev.link_slack_to_user(...)`
Links a Slack workspace to a user after OAuth installation.

**Parameters:**
- `p_user_id` (required) - Tomo user ID
- `p_team_id` (required) - Slack workspace team ID
- `p_access_token` (required) - Bot token (xoxb-...)
- `p_app_id` (optional) - Slack app ID
- `p_team_name` (optional) - Workspace name
- `p_bot_user_id` (optional) - Bot user ID
- `p_installing_user_id` (optional) - User who installed the app
- `p_display_label` (optional) - Display name for UI
- `p_metadata` (optional) - Additional metadata JSONB
- `p_credentials` (optional) - Additional credentials JSONB

**Returns:** JSONB with `success`, `integration_id`, `user_id`, `external_user_id`, `created_at`

---

### Query Functions

#### `dev.get_user_slack_workspaces(p_user_id)`
Returns all Slack workspace installations for a user.

**Returns:** JSONB array of workspace objects

#### `dev.get_slack_workspace(p_user_id, p_app_id, p_team_id)`
Returns a specific Slack workspace by app_id (and optionally team_id).

**Use case:** Filter by app when user has multiple Slack apps.

#### `dev.get_slack_token(p_user_id)`
Returns Slack token details for a user (first workspace if multiple).

**Returns:** JSONB with token, expiration status, etc.

**Note:** If user has multiple workspaces, use `get_slack_token_by_team()` for specific workspace.

#### `dev.get_slack_token_by_team(p_user_id, p_team_id)`
Returns Slack token details for a specific workspace.

**Returns:** JSONB with token, `bot_user_id`, `app_id`, `team_id`, expiration status, etc.

**Use case:** Event routing when you know both user_id and team_id.

#### `dev.get_slack_integration_by_team(p_team_id)`
Finds Slack integration by team_id only (no user_id needed).

**Returns:** JSONB with `user_id`, `access_token`, `bot_user_id`, `app_id`, `team_id`, etc.

**Use case:** Event routing - find which user owns a workspace when you only have team_id from Slack event.

#### `dev.get_integration_by_external_id('slack', p_team_id)`
Generic function to find integration by service and external ID (team_id).

**Use case:** Event routing - alternative to `get_slack_integration_by_team()`.

---

### Unlinking Functions

#### `dev.unlink_slack_from_user(p_user_id, p_team_id)`
Deactivates a Slack workspace integration (soft delete).

**Parameters:**
- `p_user_id` (required) - Tomo user ID
- `p_team_id` (optional) - Specific workspace to unlink (NULL = all workspaces)

**Returns:** JSONB with `success`, `integration_id`, `deactivated_at`

---

## Example Usage

### Complete OAuth Flow (n8n)

```sql
-- After exchanging OAuth code for tokens
SELECT dev.link_slack_to_user(
  p_user_id          := $1,  -- from session/JWT
  p_team_id          := $2,  -- from OAuth response.team.id
  p_access_token     := $3,  -- from OAuth response.access_token
  p_app_id           := $4,  -- from OAuth response.app_id
  p_team_name        := $5,  -- from OAuth response.team.name
  p_bot_user_id      := $6,  -- from OAuth response.bot_user_id
  p_installing_user_id := $7 -- from OAuth response.authed_user.id
);
```

### Complete Event Routing Flow (n8n)

**When a DM arrives:**

```sql
-- 1. Get bot token for workspace
SELECT access_token 
FROM dev.user_integrations 
WHERE service_id = 'slack' AND external_user_id = :team_id;

-- 2. Check if Slack user exists
SELECT dev.get_tomo_user_by_slack_user(:slack_user_id, :team_id);

-- 3a. If user EXISTS: Route DM to that tomo_user_id
-- 3b. If user DOES NOT EXIST: Auto-create
--    (Get Slack user info via API first, then:)
SELECT dev.auto_create_tomo_user_from_slack(
  :slack_user_id,
  :team_id,
  :slack_email,
  :slack_name,
  :slack_username
);
-- Then route DM to the new tomo_user_id
```

### Settings Page (Frontend)

```sql
-- List all connected workspaces
SELECT dev.get_user_slack_workspaces(:user_id);

-- Disconnect a specific workspace
SELECT dev.unlink_slack_from_user(:user_id, :team_id);
```

---

## Multi-Workspace Support

The schema supports multiple Slack workspace installations per user out of the box:

- Unique constraint: `(user_id, service_id, external_user_id)`
- Each workspace gets its own row in `user_integrations`
- `external_user_id = team_id` ensures uniqueness per workspace
- Users can connect multiple workspaces (e.g., personal + company)

**Example:**
```
User "alice" can have:
- Workspace "JIA Nomads" (team_id: T02Q7P07G91)
- Workspace "Personal Slack" (team_id: T09XYZ12345)
```

Both stored as separate rows with the same `user_id` but different `external_user_id`.

---

## Implementation Checklist

### Backend (n8n Workflows)

- [ ] **OAuth Installation Flow** (`/slack-oauth`)
  - [ ] Exchange OAuth code for tokens
  - [ ] Extract `tomo_user_id` from session/JWT
  - [ ] Call `dev.link_slack_to_user(...)` with OAuth response data
  - [ ] Handle errors (duplicate installation, invalid tokens, etc.)

- [ ] **Event Routing** (`/slack-events`)
  - [ ] Extract `team_id` from Slack event payload
  - [ ] Query `dev.user_integrations` to find owning user
  - [ ] Use `access_token` for Slack API calls
  - [ ] Use `bot_user_id` to filter bot's own messages
  - [ ] Route events to Tomo brain with user context

- [ ] **Token Management**
  - [ ] Use `access_token` directly from `user_integrations` (recommended)
  - [ ] OR use `dev.get_valid_token()` (works correctly with 10-year expiration)

### Frontend (Tomo Dashboard)

- [ ] **Settings Page** (`/settings/integrations/slack`)
  - [ ] Display list of connected workspaces using `dev.get_user_slack_workspaces()`
  - [ ] Show workspace name, team_id, installation date
  - [ ] "Disconnect" button calls `dev.unlink_slack_from_user()`
  - [ ] "Connect Workspace" button redirects to OAuth flow

- [ ] **OAuth Callback**
  - [ ] Handle OAuth redirect
  - [ ] Show success/error messages
  - [ ] Refresh workspace list after successful installation

---

## Error Handling

### Common Scenarios

1. **Duplicate Installation**
   - Constraint violation: `(user_id, service_id, external_user_id)` already exists
   - **Solution:** Check if integration exists before linking, or handle gracefully

2. **Invalid Team ID**
   - No integration found for `team_id`
   - **Solution:** Return 404 or prompt user to reinstall

3. **Deactivated Integration**
   - Integration exists but `is_active = false`
   - **Solution:** Check `is_active` flag in queries

4. **Missing Tokens**
   - `access_token` is NULL
   - **Solution:** Prompt user to reinstall workspace

---

## Security Considerations

1. **Token Storage**
   - `access_token` stored in plain text (should be encrypted in production)
   - Consider using PostgreSQL encryption or application-level encryption

2. **Token Access**
   - Only expose tokens to authorized users
   - Use `is_active` flag to prevent use of deactivated integrations

3. **OAuth Flow**
   - Validate OAuth state parameter
   - Verify token authenticity with Slack API
   - Store `installing_user_id` for audit trail

---

## Testing

### Manual Testing

1. **Install Workspace**
   ```sql
   SELECT dev.link_slack_to_user(
     'test_user_123',
     'T02Q7P07G91',
     'xoxb-test-token',
     'A09U4GD1064',
     'Test Workspace',
     'U09U4508SFK',
     'U07U3MJ9SQY'
   );
   ```

2. **List Workspaces**
   ```sql
   SELECT dev.get_user_slack_workspaces('test_user_123');
   ```

3. **Find by Team ID**
   ```sql
   SELECT dev.get_integration_by_external_id('slack', 'T02Q7P07G91');
   ```

4. **Disconnect**
   ```sql
   SELECT dev.unlink_slack_from_user('test_user_123', 'T02Q7P07G91');
   ```

---

## Summary

The Slack integration is **80% complete** with the existing schema and functions. You just need to:

1. **Call `dev.link_slack_to_user()`** from your n8n OAuth workflow
2. **Query by `team_id`** in your n8n event routing workflow
3. **Use helper functions** for UI/settings management

No additional tables or schema changes needed. The existing `services + user_integrations` design is the right abstraction.

---

**Questions?** Refer to `database_functions.sql` for full function definitions and examples.

