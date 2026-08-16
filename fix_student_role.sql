-- Fix: Allow 'student' role in users table
-- The original schema only allows 'driver' role

-- Drop the existing CHECK constraint and add a new one
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (role in ('driver', 'student'));

-- Update default to 'driver' (already is, but making explicit)
-- Students will be inserted with role = 'student'
