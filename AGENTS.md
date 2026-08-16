# Project Instructions

## Project

This is a Flutter Android application.

## Architecture

- Flutter is the mobile frontend.
- Supabase is the backend.
- Supabase PostgreSQL stores application data.
- Supabase Auth handles authentication.
- Supabase Realtime is used for real-time updates where appropriate.

## Important

- Do NOT introduce Firebase unless explicitly requested.
- Inspect the existing project before making changes.
- Preserve existing working functionality.
- Avoid unnecessary dependencies.
- Never hardcode API keys, passwords, or secrets.
- Keep database changes compatible with existing foreign keys and UUID relationships.
- Test important changes before declaring them complete.

## Development

Before modifying code:

1. Inspect relevant files.
2. Understand existing architecture.
3. Identify dependencies.
4. Implement the smallest appropriate change.
5. Test the change.
6. Review for regressions.

## Quality

Prioritize:

1. Correctness
2. Security
3. Maintainability
4. Performance
5. Simplicity