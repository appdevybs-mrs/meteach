# Deploy Secure API + Protect Keys

## 1) Upload PHP files

Upload `backend/php_secure_api/*` to your server path (recommended):

- `/app/secure/upload_secure.php`
- `/app/secure/push_secure.php`
- `/app/secure/list_items_secure.php`
- `/app/secure/create_folder_secure.php`
- `/app/secure/rename_item_secure.php`
- `/app/secure/delete_item_secure.php`
- `/app/secure/upload_file_secure.php`
- `/app/secure/delete_file_secure.php`

Also upload shared files:

- `/app/secure/bootstrap.php`
- `/app/secure/file_ops.php`

## 2) Install backend dependency

On server inside `/app/secure`:

```bash
composer require kreait/firebase-php
```

## 3) Configure server environment variables

Set these in Apache/Nginx/PHP-FPM env:

- `GOOGLE_APPLICATION_CREDENTIALS=/absolute/path/service-account.json`
- `FIREBASE_DB_URL=https://<your-project>.firebaseio.com`
- `YBS_STORAGE_DIR=/absolute/path/to/public/file/storage`
- `YBS_PUBLIC_BASE_URL=https://www.yourbridgeschool.com/uploads`

## 4) Lock folder permissions

- Make PHP files read-only for web user
- Make only `YBS_STORAGE_DIR` writable
- Disable directory listing in storage folders

## 5) Rotate compromised secrets immediately

These were previously embedded in app code and must be considered leaked:

1. Legacy upload key used with old `/app/upload.php`
2. Legacy push shared secret used with old push API
3. Legacy `my_super_secret_key` used with old admin file APIs

Action:

- Disable or remove old key-based endpoints (`/app/upload.php`, `/api/admin/*`, old push endpoint)
- Generate fresh server-only secrets (if still needed internally)
- Do not expose shared secrets to mobile/web client again

## 6) Firebase rules hardening

- Enforce role-based access from trusted claims or server-written role fields
- Restrict `mail_threads`, `mail_messages`, and admin collections by UID/role
- Deny write access by default and explicitly allow required paths

## 7) Flutter app endpoint config (optional)

You can override base secure API URL using:

```bash
flutter run --dart-define=YBS_SECURE_API_BASE=https://www.yourbridgeschool.com/app/secure
```

## 8) Smoke test checklist

1. Teacher/Learner profile photo upload works
2. Mail attachment upload works (admin/teacher/learner)
3. Admin file manager list/create/upload/rename/delete works
4. Push notification send works for admin/teacher actions
5. Invalid or expired token returns HTTP 401
