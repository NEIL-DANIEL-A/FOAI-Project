-- Add members_count to stops table to record waiting student count
alter table public.stops add column if not exists members_count int default 0;

-- Enable Realtime replication for the relevant tables in Supabase.
-- This adds the tables to the public publication for realtime.
-- NOTE: ALTER PUBLICATION has no DROP ... IF EXISTS, so membership is
-- checked first via pg_publication_tables (idempotent, safe to re-run).
do $$
declare
  tbl text;
begin
  foreach tbl in array array['bus_positions', 'trips', 'stop_events', 'stops'] loop
    if exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = tbl
    ) then
      execute format('alter publication supabase_realtime drop table public.%I', tbl);
    end if;
  end loop;
end $$;

-- Add tables to the realtime publication
alter publication supabase_realtime add table public.bus_positions;
alter publication supabase_realtime add table public.trips;
alter publication supabase_realtime add table public.stop_events;
alter publication supabase_realtime add table public.stops;
