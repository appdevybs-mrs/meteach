# Website Data Reuse Plan

This document defines safe reuse of existing app data for a future public website.

## Current Data Sources (RTDB)

- `courses`: course metadata, variants, pricing fields.
- `users`: teacher profile fields (`role`, names, email, optional public metadata).
- `payments`: transaction records used for fee/financial tracking.
- `classes`: course/class relationships and schedule references.

## Public Website Scope

Expose only:

- course list and details,
- fee information,
- teacher public details.

Do not expose:

- learner/private user data,
- payment logs,
- auth tokens,
- internal operational notes.

## Recommended Contract Layer

Create a read-only mapping layer (server side) that transforms internal schema into stable public payloads.

### Proposed payloads

- `public_courses`
  - `courseId`, `title`, `code`, `description`, `deliveryModes`, `fees`, `updatedAt`
- `public_teachers`
  - `teacherId`, `fullName`, `bio`, `specialties`, `photoUrl`, `updatedAt`

## Safety Rules

- Keep internal app nodes unchanged to avoid regressions.
- Compute website payloads from internal data, do not duplicate business logic in frontend.
- Add explicit allow-list of public fields.
- Validate missing/null fields with defaults before publishing.

## Migration Strategy

1. Build read-only exporter (cron or trigger).
2. Publish normalized public nodes.
3. Point website to normalized nodes only.
4. Keep app logic reading original nodes.
