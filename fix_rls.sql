-- ============================================
-- FIX: Add UPDATE policy for driver_bus_assignments
-- Run this if you already ran schema.sql
-- ============================================

-- Allow drivers to update their own bus assignments (needed for upsert)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'driver_bus_assignments'
    AND policyname = 'Allow drivers to update their own bus assignments'
  ) THEN
    CREATE POLICY "Allow drivers to update their own bus assignments" ON driver_bus_assignments
      FOR UPDATE USING (auth.uid() = driver_id) WITH CHECK (auth.uid() = driver_id);
  END IF;
END $$;

-- Also allow drivers to delete their own bus assignments
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'driver_bus_assignments'
    AND policyname = 'Allow drivers to delete their own bus assignments'
  ) THEN
    CREATE POLICY "Allow drivers to delete their own bus assignments" ON driver_bus_assignments
      FOR DELETE USING (auth.uid() = driver_id);
  END IF;
END $$;
