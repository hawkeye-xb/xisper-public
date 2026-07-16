# Logto Configuration for Admin Platform

## Required Logto Application Settings

To ensure proper logout and account switching functionality, configure the following in your Logto Cloud application:

### Beta Environment (App ID: `your-beta-logto-app-id`)

1. **Redirect URIs** (already configured):
   - `https://<YOUR_BETA_ADMIN_DOMAIN>/callback`

2. **Post Sign-out Redirect URIs** (MUST be configured):
   - `https://<YOUR_BETA_ADMIN_DOMAIN>/`

### Production Environment (App ID: `your-production-logto-app-id`)

1. **Redirect URIs** (already configured):
   - `https://<YOUR_ADMIN_DOMAIN>/callback`

2. **Post Sign-out Redirect URIs** (MUST be configured):
   - `https://<YOUR_ADMIN_DOMAIN>/`

## Why These Changes Are Needed

### Problem 1: Logout Error
Without proper post-logout redirect URIs, the Logto SDK throws an error when calling `signOut()`, causing console errors and potentially leaving the app in an inconsistent state.

### Problem 2: Cached Session Blocks Account Switching
When a user logs in with one account (e.g., non-admin), then tries to log in with a different account (e.g., admin), Logto's localStorage cache prevents the login prompt from appearing, making it impossible to switch accounts.

### Solution
1. **Code changes** (already deployed):
   - Added `prompt: 'login'` to Logto config to force fresh login flow
   - Clear localStorage before sign-in and sign-out
   - Proper error handling with fallback to force reload

2. **Logto Cloud configuration** (needs manual setup):
   - Add post-logout redirect URIs in Logto Cloud console
   - Navigate to: Applications → [Your App] → Settings → Post Sign-out Redirect URIs
   - Add the URLs listed above

Set `VITE_API_BASE_URL` to the self-hosted Services Worker URL when building the
admin application. It defaults to `http://localhost:8787` for local development.

## Testing

After configuration:

1. **Test logout**:
   - Log in to admin platform
   - Click "Sign Out" in dropdown menu
   - Should redirect to sign-in page without errors

2. **Test account switching**:
   - Log in with a non-admin account
   - Should see "Access Denied" message
   - Click "Sign Out"
   - Click "Sign In" again
   - Should see Logto login prompt (not auto-login)
   - Log in with admin account
   - Should successfully access admin panel

## Troubleshooting

If logout still shows errors:
1. Check browser console for specific error messages
2. Verify post-logout redirect URIs are correctly configured in Logto Cloud
3. Clear browser cache and localStorage manually
4. Try in incognito/private browsing mode

If account switching still doesn't work:
1. Open browser DevTools → Application → Local Storage
2. Verify all `logto:*` keys are cleared after sign-in/sign-out
3. Check Network tab for failed OAuth/OIDC requests
4. Verify the `prompt=login` parameter is present in the Logto authorization URL
