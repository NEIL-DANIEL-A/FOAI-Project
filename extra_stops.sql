-- ============================================
-- EXTRA STOPS: 5 more per route (extends each route past stop 4,
-- so sequences run 1..9). Run AFTER seed_data.sql / existing data.
-- Safe to re-run: each block skips stops that already exist.
-- ============================================

-- Tidy: route name with a trailing newline breaks UI labels
-- (note: postgres trim() only strips spaces, hence regexp_replace)
update routes set name = regexp_replace(name, '\s+$', '')
where id = '11111111-0000-0000-0000-000000000002';

-- Campus -> Ambattur (continues north-west)
insert into stops (route_id, name, lat, lon, sequence_no, scheduled_time)
select '11111111-0000-0000-0000-000000000001', s.name, s.lat, s.lon, s.seq, s.t
from (values
  ('Ambattur OT',              13.1098, 80.1295, 5, '08:40'::time),
  ('Ambattur Bus Stand',       13.1122, 80.1278, 6, '08:50'::time),
  ('Menambedu',                13.1145, 80.1262, 7, '09:00'::time),
  ('Karukku Main Road',        13.1168, 80.1246, 8, '09:10'::time),
  ('Ambattur Industrial Estate', 13.1190, 80.1230, 9, '09:20'::time)
) as s(name, lat, lon, seq, t)
where not exists (
  select 1 from stops
  where route_id = '11111111-0000-0000-0000-000000000001'
    and sequence_no = s.seq
);

-- Campus -> Kancheepuram (continues south-east)
insert into stops (route_id, name, lat, lon, sequence_no, scheduled_time)
select '11111111-0000-0000-0000-000000000003', s.name, s.lat, s.lon, s.seq, s.t
from (values
  ('Sipcot Corner',        12.960, 77.632, 5, '08:40'::time),
  ('Kanchipuram Road',     12.956, 77.640, 6, '08:50'::time),
  ('Sunguvarchatram',      12.950, 77.650, 7, '09:00'::time),
  ('Sriperumbudur Toll',   12.945, 77.660, 8, '09:10'::time),
  ('Kancheepuram Bus Stand', 12.940, 77.670, 9, '09:20'::time)
) as s(name, lat, lon, seq, t)
where not exists (
  select 1 from stops
  where route_id = '11111111-0000-0000-0000-000000000003'
    and sequence_no = s.seq
);

-- Campus -> Medavakkam (continues west past Railway Station)
insert into stops (route_id, name, lat, lon, sequence_no, scheduled_time)
select '11111111-0000-0000-0000-000000000004', s.name, s.lat, s.lon, s.seq, s.t
from (values
  ('Guindy Estate',          12.992, 77.540, 5, '08:40'::time),
  ('Guindy Railway Station', 12.994, 77.530, 6, '08:50'::time),
  ('Ekkattuthangal',         12.996, 77.520, 7, '09:00'::time),
  ('Alandur',                12.998, 77.510, 8, '09:10'::time),
  ('St. Thomas Mount',       13.000, 77.500, 9, '09:20'::time)
) as s(name, lat, lon, seq, t)
where not exists (
  select 1 from stops
  where route_id = '11111111-0000-0000-0000-000000000004'
    and sequence_no = s.seq
);

-- Campus -> Pallavaram (continues north-east)
insert into stops (route_id, name, lat, lon, sequence_no, scheduled_time)
select '11111111-0000-0000-0000-000000000002', s.name, s.lat, s.lon, s.seq, s.t
from (values
  ('Pallavaram Main Road',     12.980, 77.603, 5, '08:40'::time),
  ('Pallavaram Bus Stand',     12.982, 77.605, 6, '08:50'::time),
  ('Chromepet Corner',         12.984, 77.607, 7, '09:00'::time),
  ('MIT Gate',                 12.986, 77.609, 8, '09:10'::time),
  ('Pallavaram Railway Station', 12.988, 77.611, 9, '09:20'::time)
) as s(name, lat, lon, seq, t)
where not exists (
  select 1 from stops
  where route_id = '11111111-0000-0000-0000-000000000002'
    and sequence_no = s.seq
);
