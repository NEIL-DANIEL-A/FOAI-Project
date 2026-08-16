-- Add members_count to stops table to record waiting student count
alter table public.stops add column if not exists members_count int default 0;

-- Enable Realtime replication for the relevant tables in Supabase.
-- This adds the tables to the public publication for realtime.
begin;
  -- Remove them first if they exist to prevent duplicates
  alter publication supabase_realtime drop table if exists public.bus_positions;
  alter publication supabase_realtime drop table if exists public.trips;
  alter publication supabase_realtime drop table if exists public.stop_events;
  alter publication supabase_realtime drop table if exists public.stops;

  -- Add tables to the realtime publication
  alter publication supabase_realtime add table public.bus_positions;
  alter publication supabase_realtime add table public.trips;
  alter publication supabase_realtime add table public.stop_events;
  alter publication supabase_realtime add table public.stops;
commit;
