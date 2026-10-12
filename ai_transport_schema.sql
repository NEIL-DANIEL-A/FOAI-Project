-- ============================================
-- AI TRANSPORT SCHEMA (MACTMS: CSP + A* support)
-- Run AFTER schema.sql / seed data. Safe to re-run.
--
-- New entities:
--   operating_slots   Admin-defined (route, time slot), e.g. R1 07:30 AM
--   slot_buses        which buses are scheduled per slot + availability
--   stop_assignments  CSP output: each slot stop -> one bus
--   road_nodes/edges  road graph for A* (seeded from stops by
--                     demo/seed_road_graph.py; sim uses in-code graphs)
--   trips.slot_id     links a live trip to its operating slot
-- ============================================

-- 1. Operating slots (Admin-defined)
create table if not exists operating_slots (
  id uuid primary key default gen_random_uuid(),
  route_id uuid references routes(id) on delete cascade,
  label text not null,
  slot_time time not null,
  is_active boolean default true,
  created_at timestamptz default now(),
  unique (route_id, label)
);

-- 2. Scheduled buses per slot (+ live availability flag)
create table if not exists slot_buses (
  slot_id uuid references operating_slots(id) on delete cascade,
  bus_id uuid references buses(id) on delete cascade,
  is_available boolean default true,
  note text,
  primary key (slot_id, bus_id)
);

-- 3. CSP output: every required stop of a slot assigned to exactly one bus
create table if not exists stop_assignments (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid references operating_slots(id) on delete cascade,
  stop_id uuid references stops(id) on delete cascade,
  bus_id uuid references buses(id) on delete cascade,
  created_at timestamptz default now(),
  unique (slot_id, stop_id)
);

-- 4. Link live trips to their slot (additive, nullable -> old rows unaffected)
alter table trips add column if not exists slot_id uuid references operating_slots(id);

-- 5. Road graph for A*
create table if not exists road_nodes (
  id text primary key,
  label text not null,
  lat double precision not null,
  lon double precision not null
);

create table if not exists road_edges (
  id uuid primary key default gen_random_uuid(),
  from_node text references road_nodes(id) on delete cascade,
  to_node text references road_nodes(id) on delete cascade,
  distance_m double precision not null,
  travel_time_s double precision not null,
  is_blocked boolean default false,
  unique (from_node, to_node)
);

-- 6. RLS (same style as schema.sql: public read; writes need auth)
alter table operating_slots enable row level security;
alter table slot_buses enable row level security;
alter table stop_assignments enable row level security;
alter table road_nodes enable row level security;
alter table road_edges enable row level security;

drop policy if exists "Allow public read access to operating_slots" on operating_slots;
create policy "Allow public read access to operating_slots" on operating_slots
  for select using (true);

drop policy if exists "Allow public read access to slot_buses" on slot_buses;
create policy "Allow public read access to slot_buses" on slot_buses
  for select using (true);

drop policy if exists "Allow authenticated users to update slot bus availability" on slot_buses;
create policy "Allow authenticated users to update slot bus availability" on slot_buses
  for update using (auth.uid() is not null) with check (auth.uid() is not null);

drop policy if exists "Allow public read access to stop_assignments" on stop_assignments;
create policy "Allow public read access to stop_assignments" on stop_assignments
  for select using (true);

drop policy if exists "Allow authenticated users to manage stop_assignments" on stop_assignments;
create policy "Allow authenticated users to manage stop_assignments" on stop_assignments
  for all using (auth.uid() is not null) with check (auth.uid() is not null);

drop policy if exists "Allow public read access to road_nodes" on road_nodes;
create policy "Allow public read access to road_nodes" on road_nodes
  for select using (true);

drop policy if exists "Allow public read access to road_edges" on road_edges;
create policy "Allow public read access to road_edges" on road_edges
  for select using (true);

-- 7. Realtime publication (idempotent pattern from update_schema.sql)
do $$
declare
  tbl text;
begin
  foreach tbl in array array['operating_slots', 'slot_buses', 'stop_assignments'] loop
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

alter publication supabase_realtime add table public.operating_slots;
alter publication supabase_realtime add table public.slot_buses;
alter publication supabase_realtime add table public.stop_assignments;

-- 8. Seed: two morning slots per route with that route's buses scheduled
insert into operating_slots (route_id, label, slot_time)
select r.id, s.label, s.slot_time
from routes r
cross join (values ('07:00 AM', '07:00'::time), ('07:30 AM', '07:30'::time)) as s(label, slot_time)
on conflict (route_id, label) do nothing;

insert into slot_buses (slot_id, bus_id)
select os.id, b.id
from operating_slots os
join buses b on b.route_id = os.route_id
on conflict do nothing;
