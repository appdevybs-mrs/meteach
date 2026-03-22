# Secure PHP API (Firebase-authenticated)

This folder contains secure replacements for legacy key-based PHP endpoints.

## Requirements

- PHP 8.1+
- Composer
- Service account JSON file for Firebase Admin SDK
- Writable storage path for uploaded files

## Install dependencies

```bash
cd backend/php_secure_api
composer require kreait/firebase-php
```

## Required environment variables

- `GOOGLE_APPLICATION_CREDENTIALS` → absolute path to service account JSON
- `FIREBASE_DB_URL` → your Realtime Database URL
- `YBS_STORAGE_DIR` → absolute path where server stores files
- `YBS_PUBLIC_BASE_URL` → base URL where those files are publicly served

## Endpoints in this folder

- `upload_secure.php`
- `push_secure.php`
- `list_items_secure.php`
- `create_folder_secure.php`
- `rename_item_secure.php`
- `delete_item_secure.php`
- `upload_file_secure.php`
- `delete_file_secure.php`

All endpoints require `Authorization: Bearer <Firebase ID token>`.
