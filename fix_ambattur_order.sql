-- ============================================
-- FIX: reorder Campus -> Ambattur stops geographically (east to west).
-- Before: ICMR, park, Selvi, Ganesh, Lake, Church, Cycle, Dunlop, Miller
--   (bus jumped Ganesh -> Lake, skipping the middle of the road).
-- After: T.I Miller -> Dunlop -> Cycle shop -> Church -> Ayapakkam Lake
--   -> ICMR -> Ayapakkam park -> Selvi mahal -> Ganesh Bhavan
-- ============================================

-- Temp negatives first so renumbering can't collide
update stops set sequence_no = -sequence_no
where route_id = '11111111-0000-0000-0000-000000000001';

update stops set sequence_no = 1 where id = '33333333-0000-0000-0001-000000000009'; -- T.I Miller
update stops set sequence_no = 2 where id = '33333333-0000-0000-0001-000000000008'; -- Dunlop
update stops set sequence_no = 3 where id = '33333333-0000-0000-0001-000000000007'; -- Cycle shop
update stops set sequence_no = 4 where id = '33333333-0000-0000-0001-000000000006'; -- Church
update stops set sequence_no = 5 where id = '33333333-0000-0000-0001-000000000005'; -- Ayapakkam Lake
update stops set sequence_no = 6 where id = '33333333-0000-0000-0001-000000000004'; -- ICMR
update stops set sequence_no = 7 where id = '33333333-0000-0000-0001-000000000003'; -- Ayapakkam park
update stops set sequence_no = 8 where id = '33333333-0000-0000-0001-000000000002'; -- Selvi mahal
update stops set sequence_no = 9 where id = '33333333-0000-0000-0001-000000000001'; -- Ganesh Bhavan

-- Tidy trailing whitespace in stop names on this route ('ICMR ')
update stops set name = regexp_replace(name, '\s+$', '')
where route_id = '11111111-0000-0000-0000-000000000001';
