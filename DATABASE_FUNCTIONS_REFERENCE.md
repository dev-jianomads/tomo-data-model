# Database Functions Quick Reference

**Last Updated:** 2025-10-13  
**Schema:** `dev`  
**Total Functions:** 25+ (including new service linking functions)

---

## 📋 Overview

This document provides a quick reference for all database helper functions created for the normalized users/integrations schema. **NEW:** Comprehensive service linking/unlinking functions for all supported services (Gmail, Calendar, Telegram, Signal, WhatsApp).

---

## 🔧 Basic Functions

### `get_user_integrations(user_id)`
Returns basic integration info for a user (no sensitive data).

**Usage:**
```sql
SELECT * FROM dev.get_user_integrations('user_123');
```

**Returns:** Table with columns:
- `integration_id` (uuid)
- `service_name` (text)
- `service_type` (text)
- `is_active` (boolean)
- `external_user_id` (text)

---

### `get_telegram_id(user_id)`
Backward compatibility helper to get telegram_id.

**Usage:**
```sql
SELECT dev.get_telegram_id('user_123');
-- Returns: 'telegram_456' or NULL
```

---

### `user_has_service(user_id, service_id)`
Check if user has an active integration for a service.

**Usage:**
```sql
SELECT dev.user_has_service('user_123', 'gmail');
-- Returns: true or false
```

---

## 🔐 Token Management Functions

### `get_user_with_integrations(user_id)`
**⚠️ WARNING: Returns ALL data including sensitive tokens!**

Returns complete user profile with nested integrations as JSON.

**Usage:**
```sql
SELECT dev.get_user_with_integrations('user_123');
```

**Returns:** JSON object with user profile + integrations array containing:
- All OAuth tokens (access_token, refresh_token)
- Client credentials (client_id, client_secret)
- Expiration dates
- Granted scopes
- All metadata

**Use case:** Full data export, admin dashboards, comprehensive user views

---

### `get_valid_token(user_id, service_id)`
**Generic token getter with expiration check.**

**Usage:**
```sql
SELECT dev.get_valid_token('user_123', 'gmail');
SELECT dev.get_valid_token('user_123', 'google_calendar');
```

**Returns:** JSON object:
```json
{
  "token": "ya29.a0...",
  "refresh_token": "1//0g...",
  "is_expired": false,
  "expires_at": "2025-10-14T10:00:00+00",
  "refresh_expired": false,
  "client_id": "123456.apps.googleusercontent.com",
  "client_secret": "GOCSPX-...",
  "granted_scopes": ["https://www.googleapis.com/auth/gmail.readonly"]
}
```

Returns `NULL` if integration doesn't exist.

**Expiration Logic:**
- Token is expired if: `access_token` is NULL OR `token_expiration_date` is NULL OR `token_expiration_date < now()`
- Matches the original JavaScript `isTokenExpired()` logic

---

### Service-Specific Token Functions

Convenience wrappers for `get_valid_token()`.

#### `get_gmail_token(user_id)`
```sql
SELECT dev.get_gmail_token('user_123');
```

#### `get_calendar_token(user_id)`
```sql
SELECT dev.get_calendar_token('user_123');
```
**Use case:** Replaces old N8N workflow queries for Calendar integration.

#### `get_telegram_token(user_id)`
```sql
SELECT dev.get_telegram_token('user_123');
```

#### `get_signal_token(user_id)`
```sql
SELECT dev.get_signal_token('user_123');
```

All return the same JSON format as `get_valid_token()`.

---

### `has_valid_token(user_id, service_id)`
Boolean check for valid (non-expired) token.

**Usage:**
```sql
SELECT dev.has_valid_token('user_123', 'gmail');
-- Returns: true or false
```

Returns `true` only if:
1. Integration exists
2. Integration is active
3. Token exists
4. Token is not expired

---

## 🔗 Service Linking Functions (NEW)

### `link_service_to_user(user_id, service_id, ...)`
**Generic function to link any service to a user with full validation.**

**Usage:**
```sql
SELECT dev.link_service_to_user(
  'user_123',
  'gmail',
  'user@example.com',  -- external_user_id
  NULL,                -- external_username
  'Primary Gmail',     -- display_label
  'ya29.access_token', -- access_token
  '1//refresh_token',  -- refresh_token
  '2025-10-13T12:00:00Z', -- token_expiration_date
  'client_id',         -- client_id
  'client_secret',     -- client_secret
  NULL,                -- auth_code
  '["scope1","scope2"]'::jsonb, -- granted_scopes
  '{"key":"value"}'::jsonb,     -- credentials
  '{"meta":"data"}'::jsonb      -- metadata
);
```

**Returns:** JSON object with success status and integration details.

**Validation:**
- ✅ Checks user exists
- ✅ Checks service exists and is active
- ✅ Prevents duplicate integrations

---

### Service-Specific Link Functions

#### `link_gmail_to_user(user_id, access_token, refresh_token?, ...)`
```sql
SELECT dev.link_gmail_to_user('user_123', 'ya29.token', '1//refresh');
```

#### `link_calendar_to_user(user_id, access_token, refresh_token?, ...)`
```sql
SELECT dev.link_calendar_to_user('user_123', 'ya29.token', '1//refresh');
```

#### `link_telegram_to_user(user_id, telegram_id, username?, label?, ...)`
```sql
SELECT dev.link_telegram_to_user('user_123', 'telegram_456', '@username', 'My Telegram');
```

#### `link_signal_to_user(user_id, signal_uuid, label?, ...)`
```sql
SELECT dev.link_signal_to_user('user_123', 'signal_uuid_abc', 'Signal Integration');
```

#### `link_whatsapp_to_user(user_id, whatsapp_id, username?, label?, ...)`
```sql
SELECT dev.link_whatsapp_to_user('user_123', 'whatsapp_789', '@whatsapp_user', 'WhatsApp Business');
```

---

## 🔌 Service Unlinking Functions (NEW)

### `unlink_service_from_user(user_id, service_id, external_user_id?)`
**Soft deletes (deactivates) a service integration.**

**Usage:**
```sql
SELECT dev.unlink_service_from_user('user_123', 'gmail');
SELECT dev.unlink_service_from_user('user_123', 'telegram', 'telegram_456');
```

### Service-Specific Unlink Functions

#### `unlink_gmail_from_user(user_id)`
```sql
SELECT dev.unlink_gmail_from_user('user_123');
```

#### `unlink_calendar_from_user(user_id)`
```sql
SELECT dev.unlink_calendar_from_user('user_123');
```

#### `unlink_telegram_from_user(user_id, telegram_id?)`
```sql
SELECT dev.unlink_telegram_from_user('user_123', 'telegram_456');
```

#### `unlink_signal_from_user(user_id, signal_uuid?)`
```sql
SELECT dev.unlink_signal_from_user('user_123', 'signal_uuid_abc');
```

#### `unlink_whatsapp_from_user(user_id, whatsapp_id?)`
```sql
SELECT dev.unlink_whatsapp_from_user('user_123', 'whatsapp_789');
```

---

## 🔄 Advanced Management Functions (NEW)

### `bulk_link_services_to_user(user_id, services_json)`
**Bulk link multiple services to a user via JSON array.**

**Usage:**
```sql
SELECT dev.bulk_link_services_to_user('user_123', '[
  {
    "service_id": "gmail",
    "access_token": "ya29.token",
    "external_user_id": "user@example.com"
  },
  {
    "service_id": "telegram", 
    "external_user_id": "telegram_456",
    "external_username": "@user"
  },
  {
    "service_id": "whatsapp",
    "external_user_id": "whatsapp_789"
  }
]'::jsonb);
```

**Returns:** Summary with individual results for each service.

### `get_user_integration_stats(user_id)`
**Returns comprehensive statistics about a user's integrations.**

**Usage:**
```sql
SELECT dev.get_user_integration_stats('user_123');
```

**Returns JSON:**
```json
{
  "user_id": "user_123",
  "total_integrations": 4,
  "active_integrations": 3,
  "inactive_integrations": 1,
  "services_by_type": {
    "email": 1,
    "calendar": 1,
    "messaging": 2
  },
  "services_with_tokens": 2,
  "expired_tokens": 0
}
```

### `find_incomplete_integrations(service_id?)`
**Finds users with incomplete or problematic integrations.**

**Usage:**
```sql
SELECT * FROM dev.find_incomplete_integrations('gmail');
SELECT * FROM dev.find_incomplete_integrations(); -- All services
```

### `reactivate_service_integration(user_id, service_id, external_user_id?)`
**Reactivates a previously deactivated integration.**

**Usage:**
```sql
SELECT dev.reactivate_service_integration('user_123', 'telegram', 'telegram_456');
```

### `remove_service_integration(user_id, service_id, external_user_id?)`
**Completely removes (hard deletes) an integration. Use with caution!**

**Usage:**
```sql
SELECT dev.remove_service_integration('user_123', 'telegram', 'telegram_456');
```

### `cleanup_orphaned_integrations()`
**Removes integrations for users that no longer exist.**

**Usage:**
```sql
SELECT dev.cleanup_orphaned_integrations();
```

---

## 🔄 Token Update Functions

### `update_service_token(user_id, service_id, access_token, expiry_seconds, refresh_token?)`
**Generic token updater with automatic expiration calculation.**

**Usage:**
```sql
-- Update token with 1 hour expiration
SELECT dev.update_service_token('user_123', 'gmail', 'ya29.new_token', 3600);

-- Update token with 2 hours expiration and new refresh token
SELECT dev.update_service_token('user_123', 'google_calendar', 'ya29.new_token', 7200, '1//0g_refresh');
```

**Parameters:**
- `user_id` (text) - User ID
- `service_id` (text) - Service ID ('gmail', 'google_calendar', etc.)
- `access_token` (text) - New access token
- `expiry_seconds` (integer) - Token lifetime in seconds
- `refresh_token` (text, optional) - New refresh token (if NULL, keeps existing)

**Returns:** JSON object:
```json
{
  "success": true,
  "user_id": "user_123",
  "service_id": "gmail",
  "expires_at": "2025-10-13T11:00:00+00",
  "updated_at": "2025-10-13T10:00:00+00"
}
```

**Behavior:**
- Automatically calculates `token_expiration_date` as `now() + expiry_seconds`
- Updates both `token_expiration_date` and `token_expires_at` fields
- Sets `refresh_expired` to FALSE
- Updates `updated_at` timestamp
- Only updates `refresh_token` if provided (otherwise keeps existing)
- **Raises error** if integration doesn't exist

---

### Service-Specific Update Functions

#### `update_gmail_token(user_id, access_token, expiry_seconds?, refresh_token?)`
```sql
-- Simple update (defaults to 1 hour)
SELECT dev.update_gmail_token('user_123', 'ya29.new_token');

-- Custom expiration
SELECT dev.update_gmail_token('user_123', 'ya29.new_token', 7200);

-- With new refresh token
SELECT dev.update_gmail_token('user_123', 'ya29.new_token', 3600, '1//0g_refresh');
```

**Default expiry:** 3600 seconds (1 hour)

#### `update_calendar_token(user_id, access_token, expiry_seconds?, refresh_token?)`
```sql
SELECT dev.update_calendar_token('user_123', 'ya29.new_token', 3600);
```

**Default expiry:** 3600 seconds (1 hour)

---

## 🎯 Common Use Cases

### N8N Workflow: Get Calendar Token

**Before (Old Schema):**
```sql
SELECT * 
FROM "dev"."users"
WHERE id = '{{ $json.user_id }}'
  AND (refresh_expired_2 = FALSE OR refresh_expired_2 IS NULL)
LIMIT 1;
```
Then JavaScript to check expiration.

**After (New Schema):**
```sql
SELECT dev.get_calendar_token('{{ $json.user_id }}') as token_info;
```

**N8N JavaScript:**
```javascript
const tokenInfo = $json.token_info;

if (!tokenInfo || tokenInfo.is_expired) {
  return { needsRefresh: true };
}

return {
  token: tokenInfo.token,
  refreshToken: tokenInfo.refresh_token,
  needsRefresh: false
};
```

---

### Backend: Check User Has Gmail Before Fetching Emails

```javascript
const hasGmail = await db.query(
  'SELECT dev.has_valid_token($1, $2)',
  [userId, 'gmail']
);

if (!hasGmail.rows[0].has_valid_token) {
  throw new Error('User does not have Gmail connected');
}
```

---

### Admin Dashboard: Show All User Integrations

```javascript
const userData = await db.query(
  'SELECT dev.get_user_with_integrations($1)',
  [userId]
);

const user = userData.rows[0].get_user_with_integrations;

// user.integrations is an array of all integrations
user.integrations.forEach(integration => {
  console.log(`${integration.service_name}: ${integration.is_active ? 'Active' : 'Inactive'}`);
});
```

---

### N8N Workflow: Update Token After OAuth Refresh

**Scenario:** OAuth token expired, need to refresh and save new token.

**N8N Flow:**
1. Detect expired token
2. Call OAuth refresh endpoint
3. Save new token to database

**SQL Query:**
```sql
SELECT dev.update_calendar_token(
  '{{ $json.user_id }}',
  '{{ $json.new_access_token }}',
  {{ $json.expires_in }},
  '{{ $json.new_refresh_token }}'
) as result;
```

**Example with Google OAuth Response:**
```javascript
// Google returns: { access_token, expires_in, refresh_token }
const oauthResponse = $json;

// Call update function
const result = await db.query(
  'SELECT dev.update_calendar_token($1, $2, $3, $4)',
  [userId, oauthResponse.access_token, oauthResponse.expires_in, oauthResponse.refresh_token]
);

// result: {"success": true, "expires_at": "2025-10-13T11:00:00+00"}
```

---

### API Endpoint: Get User's Active Services

```javascript
const services = await db.query(
  'SELECT * FROM dev.get_user_integrations($1)',
  [userId]
);

return {
  userId,
  services: services.rows.map(s => ({
    name: s.service_name,
    type: s.service_type,
    active: s.is_active
  }))
};
```

---

### OAuth Flow: Link New Service After Authorization

```javascript
// After successful OAuth flow
const oauthResult = await googleOAuth.exchangeCode(code);

await db.query(
  'SELECT dev.link_gmail_to_user($1, $2, $3, $4, $5, $6)',
  [
    userId,
    oauthResult.access_token,
    oauthResult.refresh_token,
    oauthResult.expires_at,
    oauthResult.client_id,
    oauthResult.client_secret
  ]
);

// Returns: {"success": true, "integration_id": "uuid", ...}
```

---

### Bulk Service Connection (Multi-Service OAuth)

```javascript
// User connects multiple Google services at once
const servicesToLink = [
  {
    service_id: 'gmail',
    access_token: gmailToken,
    external_user_id: userEmail
  },
  {
    service_id: 'google_calendar', 
    access_token: calendarToken,
    external_user_id: userEmail
  }
];

const result = await db.query(
  'SELECT dev.bulk_link_services_to_user($1, $2)',
  [userId, JSON.stringify(servicesToLink)]
);

// Returns summary with individual results
console.log(`Linked ${result.successful} services successfully`);
```

---

### Admin Dashboard: Integration Management

```javascript
// Get user integration statistics
const stats = await db.query(
  'SELECT dev.get_user_integration_stats($1)',
  [userId]
);

// Find users with incomplete integrations
const incomplete = await db.query(
  'SELECT * FROM dev.find_incomplete_integrations()'
);

// Reactivate a deactivated integration
await db.query(
  'SELECT dev.reactivate_service_integration($1, $2, $3)',
  [userId, 'telegram', telegramId]
);
```

---

### Service Disconnection Flow

```javascript
// Soft delete (recommended)
await db.query(
  'SELECT dev.unlink_gmail_from_user($1)',
  [userId]
);

// Hard delete (use with caution)
await db.query(
  'SELECT dev.remove_service_integration($1, $2)',
  [userId, 'telegram']
);
```

---

## 📊 Performance Considerations

| Function | Performance | Use Case |
|----------|-------------|----------|
| `get_user_integrations()` | ⚡ Fast | Lightweight list of integrations |
| `get_telegram_id()` | ⚡ Fast | Single column lookup |
| `user_has_service()` | ⚡ Fast | Boolean check with EXISTS |
| `get_valid_token()` | ⚡ Fast | Single row lookup + calculation |
| `has_valid_token()` | ⚡ Fast | Wraps get_valid_token |
| `link_service_to_user()` | ⚡ Fast | Single INSERT with validation |
| `unlink_service_from_user()` | ⚡ Fast | Single UPDATE (soft delete) |
| `bulk_link_services_to_user()` | 🐌 Moderate | Multiple INSERTs, use for batch operations |
| `get_user_integration_stats()` | 🐌 Moderate | Multiple aggregations |
| `find_incomplete_integrations()` | 🐌 Moderate | Complex filtering across users |
| `get_user_with_integrations()` | 🐌 Moderate | Full JSON aggregation, use sparingly |

**Tips:**
- Use `get_user_integrations()` for lists (faster than full JSON)
- Use service-specific functions (`get_gmail_token()`) for readability
- Cache results of `get_user_with_integrations()` if used frequently
- Use `has_valid_token()` for quick checks instead of fetching full token
- Use `bulk_link_services_to_user()` for OAuth flows with multiple services
- Use `find_incomplete_integrations()` for admin dashboards and monitoring

---

## 🔒 Security Notes

1. **Functions that return tokens are SENSITIVE:**
   - `get_user_with_integrations()`
   - `get_valid_token()`
   - All service-specific token functions

2. **Functions that modify data require authorization:**
   - `link_service_to_user()` and all link functions
   - `unlink_service_from_user()` and all unlink functions
   - `bulk_link_services_to_user()`
   - `reactivate_service_integration()`
   - `remove_service_integration()`
   - `cleanup_orphaned_integrations()`

3. **Best Practices:**
   - Only expose token functions to authenticated backend services
   - Never call these directly from frontend
   - Use proper API authentication and authorization
   - Log access to token-returning functions
   - Log all integration creation/deletion operations
   - Consider encryption at rest for `access_token` and `refresh_token` columns
   - Validate user ownership before linking/unlinking services

4. **Public-Safe Functions:**
   - `get_user_integrations()` (no tokens)
   - `user_has_service()` (boolean only)
   - `has_valid_token()` (boolean only)
   - `get_user_integration_stats()` (aggregated data only)
   - `find_incomplete_integrations()` (admin use only)

---

## 🛠️ Maintenance

### Adding New Functions

Add new functions to both:
1. `database_functions.sql` (standalone collection)
2. `migration_normalize_users.sql` Step 10 (for automatic availability after migration)

### Updating Functions

Use `CREATE OR REPLACE FUNCTION` for safe updates in production.

### Removing Functions

```sql
DROP FUNCTION IF EXISTS dev.function_name(parameter_types);
```

---

## 📚 Additional Resources

- **Full Documentation:** `MIGRATION_DOCUMENTATION.md`
- **Standalone Functions File:** `database_functions.sql`
- **Migration Script:** `migration_normalize_users.sql`
- **Audit Report:** `MIGRATION_AUDIT_REPORT.md`

---

## 💡 Tips & Tricks

### Extract JSON Fields in Queries
```sql
-- Get just the token value
SELECT (dev.get_gmail_token('user_123')->>'token') as access_token;

-- Check expiration in WHERE clause
SELECT * FROM users 
WHERE NOT (dev.get_gmail_token(id)->>'is_expired')::boolean;
```

### Use in Joins
```sql
SELECT 
  u.email,
  (dev.get_gmail_token(u.id)->>'is_expired')::boolean as gmail_expired
FROM users u
WHERE dev.has_valid_token(u.id, 'gmail');
```

### Batch Check Multiple Services
```sql
SELECT 
  u.id,
  u.email,
  dev.has_valid_token(u.id, 'gmail') as has_gmail,
  dev.has_valid_token(u.id, 'google_calendar') as has_calendar,
  dev.has_valid_token(u.id, 'telegram') as has_telegram
FROM users u;
```

---

**Questions?** Contact the Data Engineering team.

