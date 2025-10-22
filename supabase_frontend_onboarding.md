# 🔄 Frontend Rewiring: Old Tables → New Tables

**Focus:** Rewire existing frontend components to use new normalized structure  
**Backend:** Helper functions already implemented  
**Components:** Already built, just need data flow updates  
**Goal:** Update data access patterns from old users table to new normalized tables  

---

## 🔄 Key Data Access Changes

### Before (Old Structure)
- Direct access to `user.access_token`, `user.telegram_id`, etc.
- Single user object with all integration fields
- Simple user profile updates

### After (New Structure)  
- User profile + separate integrations array
- Use helper functions for service data
- Manage integrations as separate entities

---

## 1. User Registration Data Flow

### ❌ OLD WAY (Single users table)
```jsx
// Your existing UserRegistrationForm.jsx - UPDATE THIS
const handleSubmit = async (e) => {
  e.preventDefault();
  
  // OLD: Send everything to backend in one request
  const response = await fetch('/api/users/register', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ 
      userData: {
        email: formData.email,
        displayName: formData.displayName,
        // OLD: Integration fields mixed in
        gmailToken: formData.gmailToken,
        telegramId: formData.telegramId,
        signalUuid: formData.signalUuid
      }
    })
  });
};
```

### ✅ NEW WAY (Normalized tables)
```jsx
// Your existing UserRegistrationForm.jsx - UPDATE TO THIS
const handleSubmit = async (e) => {
  e.preventDefault();
  
  try {
    // NEW: Send only profile data to backend
    const response = await fetch('/api/users/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ 
        userData: {
          email: formData.email,
          displayName: formData.displayName,
          position: formData.position,
          role: formData.role,
          phoneNumber: formData.phoneNumber,
          timeZone: formData.timeZone
          // REMOVED: Integration fields (handled separately)
        }
      })
    });
    
    const result = await response.json();
    
    if (response.ok) {
      // NEW: Redirect to service connection flow
      router.push(`/onboarding/services?userId=${result.user.id}`);
    }
  } catch (error) {
    console.error('Registration failed:', error);
  }
};
```

## 2. Service Connection Data Access

### ❌ OLD WAY (Direct user table access)
```jsx
// Your existing service connection components - UPDATE THIS
const loadUserData = async () => {
  try {
    const response = await fetch(`/api/users/${userId}`);
    const userData = await response.json();
    
    // OLD: Direct access to integration fields
    const hasGmail = !!userData.access_token;
    const hasCalendar = !!userData.access_token_2;
    const hasTelegram = !!userData.telegram_id;
    const hasSignal = !!userData.signal_source_uuid;
    
    setUser(userData);
    setServiceStatus({
      gmail: hasGmail,
      calendar: hasCalendar,
      telegram: hasTelegram,
      signal: hasSignal
    });
  } catch (error) {
    console.error('Failed to load user data:', error);
  }
};
```

### ✅ NEW WAY (Using integrations array)
```jsx
// Your existing service connection components - UPDATE TO THIS
const loadUserData = async () => {
  try {
    const response = await fetch(`/api/users/${userId}`);
    const userData = await response.json();
    
    // NEW: Use integrations array
    const integrations = userData.integrations || [];
    const serviceStatus = {
      gmail: integrations.some(i => i.service_id === 'gmail' && i.is_active),
      calendar: integrations.some(i => i.service_id === 'google_calendar' && i.is_active),
      telegram: integrations.some(i => i.service_id === 'telegram' && i.is_active),
      signal: integrations.some(i => i.service_id === 'signal' && i.is_active)
    };
    
    setUser(userData);
    setIntegrations(integrations);
    setServiceStatus(serviceStatus);
  } catch (error) {
    console.error('Failed to load user data:', error);
  }
};
```

## 3. Service Connection Actions

### ❌ OLD WAY (Direct user table updates)
```jsx
// Your existing service connection logic - UPDATE THIS
const connectService = async (serviceId) => {
  try {
    // OLD: Update user table directly
    const response = await fetch(`/api/users/${userId}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        [serviceId === 'gmail' ? 'access_token' : 'access_token_2']: token,
        [serviceId === 'gmail' ? 'refresh_token' : 'refresh_token_2']: refreshToken,
        // ... other service-specific fields
      })
    });
  } catch (error) {
    console.error('Connection failed:', error);
  }
};
```

### ✅ NEW WAY (Using service linking functions)
```jsx
// Your existing service connection logic - UPDATE TO THIS
const connectService = async (serviceId) => {
  try {
    // NEW: Use service linking API
    const response = await fetch(`/api/users/${userId}/integrations`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        service_id: serviceId,
        access_token: token,
        refresh_token: refreshToken,
        external_user_id: externalId
      })
    });
    
    if (response.ok) {
      // Reload user data to update UI
      loadUserData();
    }
  } catch (error) {
    console.error('Connection failed:', error);
  }
};

const disconnectService = async (serviceId) => {
  try {
    // NEW: Use service unlinking API
    const response = await fetch(`/api/users/${userId}/integrations/${serviceId}`, {
      method: 'DELETE'
    });
    
    if (response.ok) {
      // Reload user data to update UI
      loadUserData();
    }
  } catch (error) {
    console.error('Disconnection failed:', error);
  }
};
```

## 4. User Profile Data Access

### ❌ OLD WAY (Direct field access)
```jsx
// Your existing UserProfile component - UPDATE THIS
const UserProfile = ({ user }) => {
  return (
    <div className="user-profile">
      <h2>{user.display_name}</h2>
      <p>{user.email}</p>
      
      {/* OLD: Direct access to integration fields */}
      <div className="integrations">
        <div className={`integration ${user.access_token ? 'connected' : 'disconnected'}`}>
          Gmail: {user.access_token ? 'Connected' : 'Not Connected'}
        </div>
        <div className={`integration ${user.access_token_2 ? 'connected' : 'disconnected'}`}>
          Calendar: {user.access_token_2 ? 'Connected' : 'Not Connected'}
        </div>
        <div className={`integration ${user.telegram_id ? 'connected' : 'disconnected'}`}>
          Telegram: {user.telegram_id ? 'Connected' : 'Not Connected'}
        </div>
        <div className={`integration ${user.signal_source_uuid ? 'connected' : 'disconnected'}`}>
          Signal: {user.signal_source_uuid ? 'Connected' : 'Not Connected'}
        </div>
      </div>
    </div>
  );
};
```

### ✅ NEW WAY (Using integrations array)
```jsx
// Your existing UserProfile component - UPDATE TO THIS
const UserProfile = ({ user }) => {
  const integrations = user.integrations || [];
  
  const getServiceStatus = (serviceId) => {
    const integration = integrations.find(i => i.service_id === serviceId && i.is_active);
    return integration ? 'Connected' : 'Not Connected';
  };

  const getServiceName = (serviceId) => {
    const integration = integrations.find(i => i.service_id === serviceId);
    return integration?.service_name || serviceId;
  };

  return (
    <div className="user-profile">
      <h2>{user.display_name}</h2>
      <p>{user.email}</p>
      <p>{user.position} • {user.role}</p>
      
      {/* NEW: Use integrations array */}
      <div className="integrations">
        {['gmail', 'google_calendar', 'telegram', 'signal'].map(serviceId => (
          <div 
            key={serviceId}
            className={`integration ${getServiceStatus(serviceId) === 'Connected' ? 'connected' : 'disconnected'}`}
          >
            {getServiceName(serviceId)}: {getServiceStatus(serviceId)}
          </div>
        ))}
      </div>
    </div>
  );
};
```

## 5. Token Management

### ❌ OLD WAY (Direct token access)
```jsx
// Your existing token management - UPDATE THIS
const getGmailToken = async (userId) => {
  try {
    const response = await fetch(`/api/users/${userId}`);
    const user = await response.json();
    
    // OLD: Direct access to token fields
    const token = user.access_token;
    const refreshToken = user.refresh_token;
    const expiresAt = user.token_expiration_date;
    
    // Check if expired
    const isExpired = !token || !expiresAt || new Date(expiresAt) < new Date();
    
    return { token, refreshToken, isExpired, expiresAt };
  } catch (error) {
    console.error('Failed to get Gmail token:', error);
    return null;
  }
};
```

### ✅ NEW WAY (Using helper functions)
```jsx
// Your existing token management - UPDATE TO THIS
const getGmailToken = async (userId) => {
  try {
    // NEW: Use helper function API
    const response = await fetch(`/api/users/${userId}/tokens/gmail`);
    const tokenData = await response.json();
    
    // NEW: Helper function returns structured data
    return {
      token: tokenData.token,
      refreshToken: tokenData.refresh_token,
      isExpired: tokenData.is_expired,
      expiresAt: tokenData.expires_at,
      clientId: tokenData.client_id,
      grantedScopes: tokenData.granted_scopes
    };
  } catch (error) {
    console.error('Failed to get Gmail token:', error);
    return null;
  }
};

// Generic service token getter
const getServiceToken = async (userId, serviceId) => {
  try {
    const response = await fetch(`/api/users/${userId}/tokens/${serviceId}`);
    return await response.json();
  } catch (error) {
    console.error(`Failed to get ${serviceId} token:`, error);
    return null;
  }
};
```

## 6. Service Status Checks

### ❌ OLD WAY (Direct field checks)
```jsx
// Your existing service status checks - UPDATE THIS
const checkServiceStatus = (user) => {
  return {
    hasGmail: !!user.access_token,
    hasCalendar: !!user.access_token_2,
    hasTelegram: !!user.telegram_id,
    hasSignal: !!user.signal_source_uuid
  };
};

const isGmailConnected = (user) => {
  return !!user.access_token && 
         user.token_expiration_date && 
         new Date(user.token_expiration_date) > new Date();
};
```

### ✅ NEW WAY (Using helper functions)
```jsx
// Your existing service status checks - UPDATE TO THIS
const checkServiceStatus = async (userId) => {
  try {
    const response = await fetch(`/api/users/${userId}`);
    const user = await response.json();
    const integrations = user.integrations || [];
    
    return {
      hasGmail: integrations.some(i => i.service_id === 'gmail' && i.is_active),
      hasCalendar: integrations.some(i => i.service_id === 'google_calendar' && i.is_active),
      hasTelegram: integrations.some(i => i.service_id === 'telegram' && i.is_active),
      hasSignal: integrations.some(i => i.service_id === 'signal' && i.is_active)
    };
  } catch (error) {
    console.error('Failed to check service status:', error);
    return { hasGmail: false, hasCalendar: false, hasTelegram: false, hasSignal: false };
  }
};

const isGmailConnected = async (userId) => {
  try {
    const response = await fetch(`/api/users/${userId}/tokens/gmail`);
    const tokenData = await response.json();
    return tokenData && !tokenData.is_expired;
  } catch (error) {
    console.error('Failed to check Gmail connection:', error);
    return false;
  }
};
```

## 7. Quick Reference: Data Access Patterns

### ❌ OLD WAY (Direct user table access)
```jsx
// OLD: Direct access patterns to remove
const user = await fetchUser(userId);

// Check services
const hasGmail = !!user.access_token;
const hasCalendar = !!user.access_token_2;
const hasTelegram = !!user.telegram_id;
const hasSignal = !!user.signal_source_uuid;

// Get tokens
const gmailToken = user.access_token;
const calendarToken = user.access_token_2;
const telegramId = user.telegram_id;
const signalUuid = user.signal_source_uuid;

// Check token expiration
const isGmailExpired = !user.access_token || 
  !user.token_expiration_date || 
  new Date(user.token_expiration_date) < new Date();
```

### ✅ NEW WAY (Using integrations array)
```jsx
// NEW: Use integrations array patterns
const user = await fetchUser(userId);
const integrations = user.integrations || [];

// Check services
const hasGmail = integrations.some(i => i.service_id === 'gmail' && i.is_active);
const hasCalendar = integrations.some(i => i.service_id === 'google_calendar' && i.is_active);
const hasTelegram = integrations.some(i => i.service_id === 'telegram' && i.is_active);
const hasSignal = integrations.some(i => i.service_id === 'signal' && i.is_active);

// Get tokens (use helper functions)
const gmailTokenData = await getServiceToken(userId, 'gmail');
const calendarTokenData = await getServiceToken(userId, 'google_calendar');
const telegramData = await getServiceToken(userId, 'telegram');
const signalData = await getServiceToken(userId, 'signal');

// Check token expiration (handled by helper functions)
const isGmailExpired = gmailTokenData?.is_expired || false;
```

## 8. Implementation Checklist

### Data Access Updates
- [ ] **Update user registration** - Remove integration fields from form data
- [ ] **Update service connection** - Use integrations array instead of direct fields
- [ ] **Update user profile display** - Use integrations array for service status
- [ ] **Update token management** - Use helper function APIs
- [ ] **Update service status checks** - Use integrations array patterns
- [ ] **Update OAuth callbacks** - Verify using integrations array

### API Endpoint Updates
- [ ] **Update user registration API** - Only send profile data
- [ ] **Update service connection APIs** - Use service linking functions
- [ ] **Update user profile API** - Return integrations array
- [ ] **Update token APIs** - Use helper functions
- [ ] **Update service management APIs** - Use service linking/unlinking

### Frontend Component Updates
- [ ] **UserRegistrationForm** - Remove integration fields
- [ ] **ServiceConnection components** - Use integrations array
- [ ] **UserProfile components** - Use integrations array
- [ ] **Token management** - Use helper function APIs
- [ ] **Service status displays** - Use integrations array
- [ ] **Dashboard components** - Use integrations array

### Testing
- [ ] **Test user registration** - Verify profile creation only
- [ ] **Test service connection** - Verify integrations array updates
- [ ] **Test service disconnection** - Verify integrations array updates
- [ ] **Test token management** - Verify helper function responses
- [ ] **Test service status checks** - Verify integrations array patterns

---

## 🎯 Summary

This guide shows you exactly how to rewire your existing frontend components from the old users table structure to the new normalized structure. The key changes are:

1. **Remove integration fields** from user registration forms
2. **Use integrations array** instead of direct field access  
3. **Use helper function APIs** for token management
4. **Update service status checks** to use integrations array
5. **Update API calls** to use new service linking endpoints

Your existing components can stay the same - you just need to update the data access patterns! 🚀
