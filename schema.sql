-- Enable PostGIS extension for geofencing support
create extension if not exists postgis;

-- Users table (stores driver profile details)
create table users (
  id uuid primary key references auth.users(id),
  name text not null,
  role text not null default 'driver' check (role in ('driver')),
  phone text,
  created_at timestamptz default now()
);

-- Routes table (bus routes)
create table routes (
  id uuid primary key default gen_random_uuid(),
  name text not null
);

-- Stops table (geofenced stops along a route)
create table stops (
  id uuid primary key default gen_random_uuid(),
  route_id uuid references routes(id),
  name text not null,
  lat double precision not null,
  lon double precision not null,
  geofence_radius_m int default 100,
  sequence_no int not null,
  scheduled_time time not null
);

-- Buses table (physical bus units)
create table buses (
  id uuid primary key default gen_random_uuid(),
  bus_number text unique not null,   -- e.g. "Bus 4" — this is what students see on the map
  route_id uuid references routes(id),
  capacity int
);

-- Driver to Bus assignments (drivers link accounts at signup)
create table driver_bus_assignments (
  driver_id uuid references users(id),
  bus_id uuid references buses(id),
  primary key (driver_id, bus_id)
);

-- Trips table (individual route runs)
create table trips (
  id uuid primary key default gen_random_uuid(),
  bus_id uuid references buses(id),
  driver_id uuid references users(id),
  route_id uuid references routes(id),
  trip_date date not null,
  status text default 'scheduled' check (status in ('scheduled','in_progress','completed')),
  running_status text check (running_status in ('on_time','late','arrived')),
  current_occupancy int default 0,
  started_at timestamptz,
  ended_at timestamptz
);

-- Boarding headcounts at stops
create table stop_boardings (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid references trips(id),
  stop_id uuid references stops(id),
  boarding_count int not null check (boarding_count >= 0),
  recorded_at timestamptz default now()
);

-- Periodic raw location logs
create table location_pings (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid references trips(id),
  lat double precision not null,
  lon double precision not null,
  speed double precision,
  recorded_at timestamptz default now()
);

-- Current live position per active trip
create table bus_positions (
  trip_id uuid primary key references trips(id),
  bus_id uuid references buses(id),
  lat double precision not null,
  lon double precision not null,
  updated_at timestamptz default now()
);

-- Geofence entry and exit logs
create table stop_events (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid references trips(id),
  stop_id uuid references stops(id),
  event_type text check (event_type in ('arrived','departed')),
  actual_time timestamptz default now()
);

-- Enable RLS on all tables
alter table users enable row level security;
alter table routes enable row level security;
alter table stops enable row level security;
alter table buses enable row level security;
alter table driver_bus_assignments enable row level security;
alter table trips enable row level security;
alter table stop_boardings enable row level security;
alter table location_pings enable row level security;
alter table bus_positions enable row level security;
alter table stop_events enable row level security;

-- Row Level Security (RLS) Policies

-- 1. Routes and Stops: Publicly readable, no client-side writes.
create policy "Allow public read access to routes" on routes for select using (true);
create policy "Allow public read access to stops" on stops for select using (true);

-- 2. Buses: Publicly readable, no client-side writes.
create policy "Allow public read access to buses" on buses for select using (true);

-- 3. Users (Drivers):
create policy "Allow drivers to read any user profile" on users for select using (true);
create policy "Allow drivers to insert/update their own profile" on users
  for all using (auth.uid() = id) with check (auth.uid() = id);

-- 4. Driver Bus Assignments:
create policy "Allow public read access to assignments" on driver_bus_assignments for select using (true);
create policy "Allow drivers to link themselves to a bus" on driver_bus_assignments
  for insert with check (auth.uid() = driver_id);

-- 5. Trips:
create policy "Allow public read access to trips" on trips for select using (true);
create policy "Allow drivers to insert their own trips" on trips
  for insert with check (auth.uid() = driver_id);
create policy "Allow drivers to update their own active trips" on trips
  for update using (auth.uid() = driver_id) with check (auth.uid() = driver_id);

-- 6. Location Pings:
create policy "Allow public read access to location_pings" on location_pings for select using (true);
create policy "Allow drivers to insert pings for their own trips" on location_pings
  for insert with check (
    exists (
      select 1 from trips
      where trips.id = trip_id and trips.driver_id = auth.uid()
    )
  );

-- 7. Bus Positions:
create policy "Allow public read access to bus_positions" on bus_positions for select using (true);
create policy "Allow drivers to insert/update position for their own active trips" on bus_positions
  for all using (
    exists (
      select 1 from trips
      where trips.id = trip_id and trips.driver_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from trips
      where trips.id = trip_id and trips.driver_id = auth.uid()
    )
  );

-- 8. Stop Boardings:
create policy "Allow public read access to stop_boardings" on stop_boardings for select using (true);
create policy "Allow drivers to insert boarding headcounts for their own trips" on stop_boardings
  for insert with check (
    exists (
      select 1 from trips
      where trips.id = trip_id and trips.driver_id = auth.uid()
    )
  );

-- 9. Stop Events:
create policy "Allow public read access to stop_events" on stop_events for select using (true);
create policy "Allow drivers to insert stop events for their own trips" on stop_events
  for insert with check (
    exists (
      select 1 from trips
      where trips.id = trip_id and trips.driver_id = auth.uid()
    )
  );
