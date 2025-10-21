# 🔄 Database Migration: Users Table Normalization

## 📋 Executive Summary

**Migration Date:** TBD  
**Breaking Change:** ✅ YES  
**Downtime Required:** Recommended (5-10 minutes)  
**Rollback Available:** ✅ YES  

### What Changed?

We've normalized the `users` table by extracting integration credentials (Gmail, Google Calendar, Telegram, Signal) into a separate `user_integrations` table with a many-to-many relationship through a `services` catalog.

**Old Schema:**
```
users (one bloated table with all integration fields)
  - access_token, refresh_token, client_id (Gmail)
  - access_token_2, refresh_token_2, client_id_2 (Google Calendar)
  - telegram_id, telegram_signup_token
  - signal_source_uuid
  - ... + 20 other integration columns
```

**New Schema:**
```
users (clean profile only)
  - id, email, display_name, position, role, phone_number, time_zone

services (integration catalog)
  - gmail, google_calendar, telegram, signal, whatsapp

user_integrations (many-to-many junction)
  - Links users to services with credentials
  - Supports unlimited integrations per user
```

---

## 🎯 Why This Matters for Frontend

### What Breaks:

1. **Direct queries to `users` table for integration data** ❌
   ```sql
   -- OLD (BREAKS):
   SELECT access_token FROM users WHERE id = 'user_123';
   SELECT telegram_id FROM users WHERE id = 'user_123';
   ```

2. **Assuming one integration per service** ❌
   - Users can now have multiple Gmail accounts, multiple Telegram accounts, etc.

3. **Hardcoded column names** ❌
   - `users.telegram_id` → Doesn't exist anymore
   - `users.access_token_2` → Doesn't exist anymore

### What Still Works:

1. **Queries for user profile data** ✅
   ```sql
   -- STILL WORKS:
   SELECT id, email, display_name, time_zone FROM users WHERE id = 'user_123';
   ```

2. **Foreign keys from other tables** ✅
   - `emails.user_id` → `users.id` (unchanged)
   - `tasks.user_id` → `users.id` (unchanged)
   - All FK relationships remain intact

---

## 🔧 Required Code Changes

### 1. Getting User Integrations

#### ❌ OLD WAY:
```javascript
// Fetching Gmail token
const user = await db.query(
  'SELECT access_token, refresh_token FROM users WHERE id = $1',
  [userId]
);
const gmailToken = user.access_token;

// Fetching Telegram ID
const telegramId = user.telegram_id;
```

#### ✅ NEW WAY:
```javascript
// Option A: Using helper function
const integrations = await db.query(
  'SELECT * FROM dev.get_user_integrations($1)',
  [userId]
);

// Option B: Direct query
const gmailIntegration = await db.query(`
  SELECT access_token, refresh_token, token_expires_at, granted_scopes
  FROM dev.user_integrations
  WHERE user_id = $1 
    AND service_id = 'gmail' 
    AND is_active = true
  LIMIT 1
`, [userId]);

const telegramIntegration = await db.query(`
  SELECT external_user_id as telegram_id
  FROM dev.user_integrations
  WHERE user_id = $1 
    AND service_id = 'telegram' 
    AND is_active = true
  LIMIT 1
`, [userId]);
```

---

### 2. Checking If User Has a Service

#### ❌ OLD WAY:
```javascript
const hasGmail = user.access_token != null;
const hasTelegram = user.telegram_id != null;
```

#### ✅ NEW WAY:
```javascript
// Option A: Using helper function
const hasGmail = await db.query(
  'SELECT dev.user_has_service($1, $2)',
  [userId, 'gmail']
);

// Option B: Direct query
const hasGmail = await db.query(`
  SELECT EXISTS(
    SELECT 1 FROM dev.user_integrations 
    WHERE user_id = $1 AND service_id = 'gmail' AND is_active = true
  )
`, [userId]);
```

---

### 3. Getting All User's Services

#### ✅ NEW:
```javascript
const services = await db.query(`
  SELECT 
    s.id as service_id,
    s.name as service_name,
    s.type as service_type,
    ui.is_active,
    ui.external_user_id,
    ui.display_label,
    ui.created_at as connected_at
  FROM dev.user_integrations ui
  JOIN dev.services s ON ui.service_id = s.id
  WHERE ui.user_id = $1
  ORDER BY s.type, s.name
`, [userId]);

// Example response:
// [
//   { service_id: 'gmail', service_name: 'Gmail', type: 'email', is_active: true, ... },
//   { service_id: 'google_calendar', service_name: 'Google Calendar', type: 'calendar', ... },
//   { service_id: 'telegram', service_name: 'Telegram', type: 'messaging', ... }
// ]
```

---

### 4. Updating OAuth Tokens

#### ❌ OLD WAY:
```javascript
await db.query(
  'UPDATE users SET access_token = $1, refresh_token = $2 WHERE id = $3',
  [newToken, newRefresh, userId]
);
```

#### ✅ NEW WAY:
```javascript
await db.query(`
  UPDATE dev.user_integrations 
  SET 
    access_token = $1, 
    refresh_token = $2, 
    token_expires_at = $3,
    updated_at = now()
  WHERE user_id = $4 
    AND service_id = $5
`, [newToken, newRefresh, expiresAt, userId, 'gmail']);
```

---

### 5. Adding a New Integration

#### ✅ NEW:
```javascript
// User connects a new Telegram account
await db.query(`
  INSERT INTO dev.user_integrations (
    user_id, 
    service_id, 
    external_user_id, 
    display_label,
    is_active
  ) VALUES ($1, $2, $3, $4, true)
  ON CONFLICT (user_id, service_id, external_user_id) 
  DO UPDATE SET 
    is_active = true,
    updated_at = now()
`, [userId, 'telegram', telegramId, 'Personal Telegram']);
```

---

### 6. Disconnecting an Integration

#### ✅ NEW:
```javascript
// Soft delete (recommended)
await db.query(`
  UPDATE dev.user_integrations 
  SET is_active = false, updated_at = now()
  WHERE user_id = $1 AND service_id = $2
`, [userId, 'telegram']);

// Hard delete (not recommended)
await db.query(`
  DELETE FROM dev.user_integrations 
  WHERE user_id = $1 AND service_id = $2
`, [userId, 'telegram']);
```

---

## 📊 New Database Schema

### `dev.users` (Core Profile)
| Column | Type | Description |
|--------|------|-------------|
| `id` | text | User ID (PK) |
| `created_at` | timestamptz | Account creation |
| `email` | text | Email (unique) |
| `display_name` | text | Display name |
| `position` | text | Job title |
| `role` | text | User role |
| `phone_number` | text | Phone |
| `time_zone` | text | Timezone |

### `dev.services` (Integration Catalog)
| Column | Type | Description |
|--------|------|-------------|
| `id` | text | Service ID (PK) |
| `name` | text | Display name |
| `type` | text | Service type: `email`, `calendar`, `messaging`, `storage` |
| `provider` | text | Provider: `google`, `microsoft`, `telegram`, `signal` |
| `is_active` | boolean | Service availability |
| `metadata` | jsonb | UI metadata (icons, colors, etc.) |

**Available Services:**
- `gmail` - Gmail (email)
- `google_calendar` - Google Calendar (calendar)
- `telegram` - Telegram (messaging)
- `signal` - Signal (messaging)
- `whatsapp` - WhatsApp (messaging) - *future*

### `dev.user_integrations` (Junction Table)
| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Integration ID (PK) |
| `user_id` | text | FK to `users.id` |
| `service_id` | text | FK to `services.id` |
| `is_active` | boolean | Connection status |
| `display_label` | text | User-defined label |
| `access_token` | text | OAuth access token |
| `refresh_token` | text | OAuth refresh token |
| `token_expires_at` | timestamptz | Token expiration |
| `refresh_expired` | boolean | Refresh token expired |
| `client_id` | text | OAuth client ID |
| `client_secret` | text | OAuth client secret |
| `auth_code` | text | Authorization code |
| `granted_scopes` | jsonb | OAuth scopes |
| `external_user_id` | text | Service-specific user ID |
| `external_username` | text | Service-specific username |
| `credentials` | jsonb | Additional credential data |
| `metadata` | jsonb | Additional metadata |
| `created_at` | timestamptz | Connection created |
| `updated_at` | timestamptz | Last updated |

**Unique Constraint:** `(user_id, service_id, external_user_id)`

---

## 🛠️ Helper Functions

The migration creates these helper functions for convenience. **NEW:** Comprehensive service linking/unlinking functions have been added for all services.

### Basic Functions

#### `get_user_integrations(user_id)`
Returns all integrations for a user (basic info).

```sql
SELECT * FROM dev.get_user_integrations('user_123');
```

**Returns:**
| Column | Type | Description |
|--------|------|-------------|
| `integration_id` | uuid | Integration ID |
| `service_name` | text | Service name |
| `service_type` | text | Service type |
| `is_active` | boolean | Active status |
| `external_user_id` | text | External ID |

#### `get_telegram_id(user_id)`
Returns telegram_id for a user (backwards compatibility).

```sql
SELECT dev.get_telegram_id('user_123'); -- Returns telegram_id or NULL
```

#### `user_has_service(user_id, service_id)`
Checks if user has an active integration.

```sql
SELECT dev.user_has_service('user_123', 'gmail'); -- Returns true/false
```

---

### Advanced Functions (Token Management)

#### `get_user_with_integrations(user_id)`
Returns complete user profile with all integration details as JSON object.

**⚠️ WARNING: Contains sensitive tokens!**

```sql
SELECT dev.get_user_with_integrations('user_123');
```

**Returns JSON:**
```json
{
  "id": "user_123",
  "email": "john@example.com",
  "display_name": "John Doe",
  "position": "Engineer",
  "role": "admin",
  "phone_number": "+1234567890",
  "time_zone": "America/New_York",
  "integrations": [
    {
      "id": "uuid-1",
      "service_id": "gmail",
      "service_name": "Gmail",
      "service_type": "email",
      "provider": "google",
      "is_active": true,
      "display_label": "Primary Gmail",
      "access_token": "ya29.a0...",
      "refresh_token": "1//0g...",
      "token_expiration_date": "2025-10-14T10:00:00+00",
      "refresh_expired": false,
      "client_id": "123456.apps.googleusercontent.com",
      "granted_scopes": ["https://www.googleapis.com/auth/gmail.readonly"],
      "external_user_id": "john@example.com"
    },
    {
      "id": "uuid-2",
      "service_id": "telegram",
      "service_name": "Telegram",
      "service_type": "messaging",
      "provider": "telegram",
      "is_active": true,
      "external_user_id": "telegram_456"
    }
  ]
}
```

#### `get_valid_token(user_id, service_id)`
Generic function to get token with expiration status for any service.

```sql
SELECT dev.get_valid_token('user_123', 'gmail');
SELECT dev.get_valid_token('user_123', 'google_calendar');
```

**Returns JSON:**
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

**Returns NULL if integration doesn't exist.**

#### Service-Specific Token Functions

Convenience wrappers for common services:

```sql
-- Get Gmail token
SELECT dev.get_gmail_token('user_123');

-- Get Google Calendar token (replaces old N8N query)
SELECT dev.get_calendar_token('user_123');

-- Get Telegram credentials
SELECT dev.get_telegram_token('user_123');

-- Get Signal credentials
SELECT dev.get_signal_token('user_123');
```

All return the same JSON format as `get_valid_token`.

#### `has_valid_token(user_id, service_id)`
Checks if user has a valid (non-expired) token for a service.

```sql
SELECT dev.has_valid_token('user_123', 'gmail'); -- Returns true/false
SELECT dev.has_valid_token('user_123', 'google_calendar'); -- Returns true/false
```

Returns `true` only if:
- Integration exists and is active
- Token exists
- Token is not expired

---

### Service Linking Functions (NEW)

#### `link_service_to_user(user_id, service_id, ...)`
Generic function to link any service to a user with full validation.

```sql
SELECT dev.link_service_to_user('user_123', 'gmail', 'user@example.com', NULL, 'Primary Gmail', 'ya29.token', '1//refresh');
```

#### Service-Specific Link Functions
```sql
-- Link Gmail with OAuth credentials
SELECT dev.link_gmail_to_user('user_123', 'ya29.token', '1//refresh');

-- Link Telegram with external ID
SELECT dev.link_telegram_to_user('user_123', 'telegram_456', '@username', 'My Telegram');

-- Link WhatsApp
SELECT dev.link_whatsapp_to_user('user_123', 'whatsapp_789', '@whatsapp_user', 'WhatsApp Business');

-- Link Signal
SELECT dev.link_signal_to_user('user_123', 'signal_uuid_abc', 'Signal Integration');
```

#### `unlink_service_from_user(user_id, service_id, external_user_id?)`
Soft deletes (deactivates) a service integration.

```sql
SELECT dev.unlink_gmail_from_user('user_123');
SELECT dev.unlink_telegram_from_user('user_123', 'telegram_456');
```

#### `bulk_link_services_to_user(user_id, services_json)`
Bulk link multiple services to a user via JSON array.

```sql
SELECT dev.bulk_link_services_to_user('user_123', '[
  {"service_id": "gmail", "access_token": "ya29.token"},
  {"service_id": "telegram", "external_user_id": "telegram_456"}
]'::jsonb);
```

#### `get_user_integration_stats(user_id)`
Returns comprehensive statistics about a user's integrations.

```sql
SELECT dev.get_user_integration_stats('user_123');
```

#### `find_incomplete_integrations(service_id?)`
Finds users with incomplete or problematic integrations.

```sql
SELECT * FROM dev.find_incomplete_integrations('gmail');
```

---

### N8N Workflow Migration Example

#### Old N8N Query (Before Migration):
```sql
SELECT * 
FROM "dev"."users"
WHERE id = '{{ $json.user_id }}'
  AND (refresh_expired_2 = FALSE OR refresh_expired_2 IS NULL)
LIMIT 1;
```

Then JavaScript code to check expiration:
```javascript
function isTokenExpired(user) {
  const { access_token_2: token, token_expiration_date_2: exp } = user;
  if (!token || !exp) return true;
  const iso = exp.replace(' ', 'T');
  const expiresAt = new Date(iso);
  if (isNaN(expiresAt.getTime())) return true;
  return expiresAt.getTime() < Date.now();
}
```

#### New N8N Query (After Migration):
```sql
SELECT dev.get_calendar_token('{{ $json.user_id }}') as token_info;
```

**That's it!** The function returns:
```json
{
  "token": "ya29.a0...",
  "refresh_token": "1//0g...",
  "is_expired": false,
  "expires_at": "2025-10-14T10:00:00+00",
  "refresh_expired": false
}
```

Check expiration in N8N:
```javascript
// Access the result
const tokenInfo = $json.token_info;

// Check if valid
if (!tokenInfo || tokenInfo.is_expired) {
  // Token is expired or doesn't exist
  return { needsRefresh: true };
}

// Use the token
return {
  token: tokenInfo.token,
  needsRefresh: false
};
```

**Benefits:**
- ✅ No complex JavaScript expiration logic
- ✅ Single database query
- ✅ Consistent with server-side timezone handling
- ✅ Easier to debug and maintain

---

## 🔍 Common Query Patterns

### Get Gmail Access Token
```sql
SELECT access_token, refresh_token, token_expires_at
FROM dev.user_integrations
WHERE user_id = 'user_123' 
  AND service_id = 'gmail' 
  AND is_active = true
LIMIT 1;
```

### Get Telegram ID (Backward Compatible)
```sql
-- Option 1: Using helper
SELECT dev.get_telegram_id('user_123');

-- Option 2: Direct query
SELECT external_user_id
FROM dev.user_integrations
WHERE user_id = 'user_123' 
  AND service_id = 'telegram' 
  AND is_active = true
LIMIT 1;
```

### Get All Active Services for User
```sql
SELECT 
  s.id,
  s.name,
  s.type,
  s.provider,
  ui.external_user_id,
  ui.display_label
FROM dev.user_integrations ui
JOIN dev.services s ON ui.service_id = s.id
WHERE ui.user_id = 'user_123' 
  AND ui.is_active = true;
```

### Check Multiple Services at Once
```sql
SELECT 
  service_id,
  is_active
FROM dev.user_integrations
WHERE user_id = 'user_123'
  AND service_id IN ('gmail', 'telegram', 'signal');
```

### Update Token and Expiration
```sql
UPDATE dev.user_integrations
SET 
  access_token = 'new_token',
  refresh_token = 'new_refresh',
  token_expires_at = now() + interval '1 hour',
  updated_at = now()
WHERE user_id = 'user_123' 
  AND service_id = 'gmail';
```

### Query Telegram Messages for a User

#### ❌ OLD WAY:
```sql
-- Get messages sent by a user
SELECT tm.*
FROM telegram_messages tm
JOIN users u ON tm.sender_id = u.telegram_id
WHERE u.id = 'user_123';

-- Get messages received by a user
SELECT tm.*
FROM telegram_messages tm
JOIN users u ON tm.recipient_id = u.telegram_id
WHERE u.id = 'user_123';
```

#### ✅ NEW WAY:
```sql
-- Get messages sent by a user
SELECT tm.*
FROM telegram_messages tm
JOIN user_integrations ui 
  ON tm.sender_id = ui.external_user_id
WHERE ui.user_id = 'user_123' 
  AND ui.service_id = 'telegram'
  AND ui.is_active = true;

-- Get messages received by a user
SELECT tm.*
FROM telegram_messages tm
JOIN user_integrations ui 
  ON tm.recipient_id = ui.external_user_id
WHERE ui.user_id = 'user_123' 
  AND ui.service_id = 'telegram'
  AND ui.is_active = true;

-- Get all messages involving a user (sent or received)
SELECT DISTINCT tm.*
FROM telegram_messages tm
JOIN user_integrations ui 
  ON tm.sender_id = ui.external_user_id 
  OR tm.recipient_id = ui.external_user_id
WHERE ui.user_id = 'user_123' 
  AND ui.service_id = 'telegram'
  AND ui.is_active = true;
```

**Note:** `sender_id` and `recipient_id` remain as text fields (no foreign keys) because they can reference external Telegram users who aren't in your system.

---

## 🚨 Breaking Changes Checklist

### Backend Changes Required:

- [ ] Update user authentication flows to query `user_integrations`
- [ ] Update OAuth token refresh logic
- [ ] Update service connection endpoints
- [ ] Update user profile endpoints (remove integration fields from response)
- [ ] Add new endpoints for managing integrations:
  - `GET /users/:id/integrations` - List all integrations
  - `POST /users/:id/integrations` - Connect new service (use `link_service_to_user()`)
  - `DELETE /users/:id/integrations/:integration_id` - Disconnect service (use `unlink_service_from_user()`)
  - `PUT /users/:id/integrations/:integration_id` - Update integration
  - `POST /users/:id/integrations/bulk` - Bulk connect services (use `bulk_link_services_to_user()`)
  - `GET /users/:id/integrations/stats` - Get integration statistics (use `get_user_integration_stats()`)
- [ ] Update Telegram message processing (if it queries `users.telegram_id`)
  - [ ] Update queries that join `telegram_messages` with `users` table
  - [ ] Now join through `user_integrations` instead (see examples in query patterns)
- [ ] Update email processing (if it queries `users.access_token`)
- [ ] Update any cron jobs/background workers that access integration fields
- [ ] Add admin endpoints for monitoring:
  - `GET /admin/integrations/incomplete` - Find incomplete integrations (use `find_incomplete_integrations()`)
  - `POST /admin/integrations/cleanup` - Cleanup orphaned integrations (use `cleanup_orphaned_integrations()`)

### Frontend Changes Required:

- [ ] Update user profile components (remove integration fields)
- [ ] Update OAuth callback handlers
- [ ] Update service connection UI
- [ ] Add support for multiple accounts per service
- [ ] Add "manage integrations" page showing all connected services
- [ ] Update any components that check `user.telegram_id` or `user.access_token`
- [ ] Update TypeScript types/interfaces for User model

### API Response Changes:

#### Old User Response:
```json
{
  "id": "user_123",
  "email": "john@example.com",
  "access_token": "token_gmail",
  "telegram_id": "telegram_456",
  "signal_source_uuid": "signal_789",
  ...
}
```

#### New User Response:
```json
{
  "id": "user_123",
  "email": "john@example.com",
  "display_name": "John Doe",
  "integrations": [
    {
      "id": "uuid_1",
      "service": "gmail",
      "service_name": "Gmail",
      "is_active": true,
      "connected_at": "2025-01-01T00:00:00Z"
    },
    {
      "id": "uuid_2",
      "service": "telegram",
      "service_name": "Telegram",
      "external_user_id": "telegram_456",
      "is_active": true,
      "connected_at": "2025-01-01T00:00:00Z"
    }
  ]
}
```

---

## 🎯 Migration Execution Plan

### Pre-Migration:

1. **Code Freeze:** Freeze deployments to production
2. **Backup Database:** Take full database backup
3. **Test on Staging:** Run migration on staging environment first
4. **Verify Staging:** Run all tests, check queries work
5. **Deploy Backend Changes:** Deploy updated backend code (with new queries)
6. **Deploy Frontend Changes:** Deploy updated frontend code

### During Migration:

1. **Announce Downtime:** Notify users (5-10 minutes)
2. **Stop Application:** Shut down application servers
3. **Run Migration:** Execute `migration_normalize_users.sql`
4. **Verify Data:** Run verification queries (see below)
5. **Start Application:** Bring application back online
6. **Monitor Logs:** Watch for errors in first 30 minutes

### Post-Migration:

1. **Verify Functionality:** Test all integration features
2. **Monitor Errors:** Check error logs for queries to old columns
3. **User Acceptance:** Confirm with users everything works
4. **Keep Backup:** Keep `users_old` table for 1-2 weeks
5. **Cleanup:** After verification, `DROP TABLE dev.users_old`

---

## ✅ Verification Queries

### After Migration, Run These:

```sql
-- 1. Check row counts match
SELECT 'users' as table, count(*) FROM dev.users
UNION ALL
SELECT 'users_old', count(*) FROM dev.users_old
UNION ALL
SELECT 'user_integrations', count(*) FROM dev.user_integrations;

-- 2. Check all users with integrations were migrated
SELECT u.id, u.email, 'Missing Gmail' as issue
FROM dev.users_old u
WHERE u.access_token IS NOT NULL
  AND u.id NOT IN (SELECT user_id FROM dev.user_integrations WHERE service_id = 'gmail')
UNION ALL
SELECT u.id, u.email, 'Missing Telegram'
FROM dev.users_old u
WHERE u.telegram_id IS NOT NULL
  AND u.id NOT IN (SELECT user_id FROM dev.user_integrations WHERE service_id = 'telegram')
UNION ALL
SELECT u.id, u.email, 'Missing Signal'
FROM dev.users_old u
WHERE u.signal_source_uuid IS NOT NULL
  AND u.id NOT IN (SELECT user_id FROM dev.user_integrations WHERE service_id = 'signal');

-- 3. Verify foreign keys work
SELECT 
  tc.table_name,
  tc.constraint_name
FROM information_schema.table_constraints tc
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'dev'
  AND EXISTS (
    SELECT 1 FROM information_schema.constraint_column_usage ccu
    WHERE ccu.constraint_name = tc.constraint_name
      AND ccu.table_name = 'users'
  );

-- 4. Sample integration data
SELECT 
  u.email,
  s.name as service,
  ui.external_user_id,
  ui.is_active
FROM dev.user_integrations ui
JOIN dev.users u ON ui.user_id = u.id
JOIN dev.services s ON ui.service_id = s.id
LIMIT 10;
```

---

## 🔙 Rollback Plan

If something goes catastrophically wrong:

```sql
BEGIN;

-- 1. Drop new tables
DROP TABLE IF EXISTS dev.user_integrations CASCADE;
DROP TABLE IF EXISTS dev.services CASCADE;
DROP TABLE IF EXISTS dev.users CASCADE;

-- 2. Restore old users table
ALTER TABLE dev.users_old RENAME TO users;

-- 3. Recreate foreign key constraints
ALTER TABLE dev.digests ADD CONSTRAINT digests_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES dev.users(id);

ALTER TABLE dev.emails ADD CONSTRAINT emails_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES dev.users(id);

ALTER TABLE dev.preferences ADD CONSTRAINT preferences_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES dev.users(id);

ALTER TABLE dev.user_logs ADD CONSTRAINT user_logs_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES dev.users(id);

-- 4. Verify
SELECT count(*) FROM dev.users;

COMMIT;
```

Then:
- Redeploy old backend code
- Redeploy old frontend code
- Verify application works

---

## 📞 Support & Questions

### Common Issues:

**Q: "My query is returning NULL for access_token"**  
A: You're querying `users.access_token` which doesn't exist. Query `user_integrations` instead.

**Q: "Can users still have multiple Gmail accounts?"**  
A: Yes! They can have unlimited integrations per service. Each is a separate row in `user_integrations`.

**Q: "How do I know which Gmail account is 'primary'?"**  
A: Check `display_label` or `created_at` (earliest = primary). Or set a flag in `metadata`.

**Q: "What if telegram_id is needed frequently?"**  
A: Use the helper function `get_telegram_id(user_id)` for backward compatibility.

**Q: "Should I cache integrations?"**  
A: Yes, consider caching active integrations per user (invalidate on update).

---

## 📈 Benefits of New Schema

1. **Scalability:** Add WhatsApp, Slack, Discord without schema changes
2. **Flexibility:** Users can connect unlimited accounts per service
3. **Maintainability:** Integration logic isolated, easier to update
4. **Security:** Centralized credential management (easier to encrypt)
5. **Queries:** More expressive, can filter by service type, active status, etc.
6. **User Experience:** Can label integrations ("Work Gmail", "Personal Telegram")
7. **Developer Experience:** Comprehensive helper functions for all operations
8. **Admin Tools:** Built-in functions for monitoring and managing integrations
9. **Bulk Operations:** Efficient bulk linking/unlinking for OAuth flows
10. **Error Handling:** Proper validation and error reporting in all functions

---

## 🎉 Summary

This migration modernizes our user data model by separating concerns:
- **Users table:** Identity and profile only
- **Services table:** Catalog of available integrations
- **User_integrations table:** Links users to services with credentials

While this is a breaking change, it sets us up for:
- Faster feature development
- Better multi-account support
- Easier integration management
- Cleaner codebase

**Questions?** Contact the Data Engineering team.

**Good luck with the migration! 🚀**

