#!/usr/bin/env bash

set -euo pipefail

cat <<'LOG'
COMMIT_LOG_VERSION=1
DATE=2026-04-14
COMMIT="TBD_AFTER_COMMIT"
TITLE="Fix recorded syllabus sync and quarantine sensitive archives"
BRANCH=main
PUSHED=false

[SUMMARY]
- Added a server-truth sync action for Recorded Syllabi so icon status reflects real files.
- Auto-clears stale RTDB URLs when linked video/material files are missing on server.
- Quarantined credential-bearing local archives into a locked local-only vault and removed them from git tracking.

[CHANGES]
- file=lib/admin/course_syllabus_screen.dart
  what=Changed recorded lesson refresh into a full sync against server files and stale-URL cleanup flow.
  why=RTDB URL presence caused false blue/green status icons after bulk uploads and stale links.
  how=Server file checks now drive status, missing URLs are cleared in-memory and saved back to RTDB, and the app bar action uses a clear sync icon/label.

- file=.gitignore
  what=Added strict ignore rules for local transfer archives and the locked local vault.
  why=Prevent accidental recommit of sensitive artifacts.
  how=Ignored local transfer directory, top-level app archives, and the new local vault path.

- file=cpanel_upload_secure_hotfix.zip
  what=Removed from git tracking.
  why=Archive may contain deployment-sensitive materials and should not live in repository history going forward.
  how=Moved to local locked vault and committed deletion from tracked tree.

- file=dream_english_academy.zip
  what=Removed from git tracking.
  why=Local project archive should not be versioned.
  how=Moved to local locked vault and committed deletion from tracked tree.

- file=local_transfer_2026-04-14_api_your-bridge-school/TRANSFER_LOG.txt
  what=Removed from git tracking.
  why=Transfer log references credential archive handling and must remain local-only.
  how=Moved to local locked vault and committed deletion from tracked tree.

- file=local_transfer_2026-04-14_api_your-bridge-school/api-config.bak.zip
  what=Removed from git tracking.
  why=Backup archive includes sensitive API/service-account configuration.
  how=Moved to local locked vault and committed deletion from tracked tree.

- file=local_transfer_2026-04-14_api_your-bridge-school/firebase-service-account.json.zip
  what=Removed from git tracking.
  why=Contains service account key material.
  how=Moved to local locked vault and committed deletion from tracked tree.

- file=local_transfer_2026-04-14_api_your-bridge-school/secure.zip
  what=Removed from git tracking.
  why=Contains secure runtime configuration.
  how=Moved to local locked vault and committed deletion from tracked tree.

- file=local_transfer_2026-04-14_api_your-bridge-school/storage.zip
  what=Removed from git tracking.
  why=Archive can include sensitive storage artifacts.
  how=Moved to local locked vault and committed deletion from tracked tree.

[VALIDATION]
- command="flutter analyze lib/admin/course_syllabus_screen.dart"
  result="No new errors introduced by this change (only existing project warnings/infos)."
- command="git status --short --branch"
  result="Only intended tracked file updates/deletions present before commit."
- command="chmod 500 _LOCAL_LOCKED_SECRETS_DO_NOT_DELETE && chmod 400 _LOCAL_LOCKED_SECRETS_DO_NOT_DELETE/*"
  result="Local vault permissions tightened (read-only)."
- command="chattr +i _LOCAL_LOCKED_SECRETS_DO_NOT_DELETE ..."
  result="Immutable flag unsupported on current filesystem; permission lock retained."
LOG
