# Demo: watch realtime working on any route / bus

This simulates a driver so you can verify the whole realtime pipeline
without moving a physical device:

`simulate_trip.py` (this folder) -> `bus_positions`/`location_pings`/`stop_boardings`
-> DB triggers -> `stop_events` + `trips.running_status`/`current_occupancy`
-> Supabase Realtime -> **student_app** map updates live.

## 1. One-time setup

```powershell
pip install -r demo/requirements.txt
```

In Supabase SQL editor, run in order (if not already done):

1. `schema.sql`
2. `seed_data.sql`
3. `fix_student_role.sql`
4. `fix_rls.sql`
5. `geofence_trigger.sql`
6. `occupancy_trigger.sql`
7. `update_schema.sql` (adds tables to realtime publication)
8. `notification_setup.sql` (optional, push infra)

Root `.env` must contain (same keys the apps use):

```text
Api_url=https://xyz.supabase.co
Anon_key=eyJ...
Service_role=eyJ...   # preferred for the simulator (bypasses RLS)
```

## 2. See what you can demo

```powershell
python demo/simulate_trip.py --list
# Routes (3):
#   - Route A - Electronic City ... buses=[1, 2]
#   ...
```

## 3. Run a live demo on whatever route/bus you want

```powershell
# Terminal 1: start the fake driver
python demo/simulate_trip.py --route "Route A" --bus 1

# Terminal 2 (or another machine): run the student app
cd student_app
flutter run
```

Then in the student app watch:

- bus marker appear and move stop-to-stop on the Cesium map
- bottom “Active Buses” card + occupancy `current/capacity`
- tap bus -> details, “where is bus” (nearest stop + distance), Track on Map
- arrival SnackBar when the `stop_events(arrived)` trigger fires
- `running_status` colour: blue on_time / red late / green arrived
- transfer suggestion banner when one bus is >=90% full and another <=50%

The simulator prints each simulated boarding, e.g.
`[boarding] 4 boarded at Silk Board`, so you can cross-check
`trips.current_occupancy` growing in Supabase Table Editor.

Press `Ctrl+C` in Terminal 1 to complete the trip (bus disappears live).

## Useful flags

```powershell
python demo/simulate_trip.py --help
python demo/simulate_trip.py --route "Route B" --bus 3 --interval 1 --steps-per-leg 30
python demo/simulate_trip.py --route "Route C" --bus 5 --boarding-max 0   # no boardings
python demo/simulate_trip.py --route "Route A" --bus 2 --loop              # run forever
python demo/simulate_trip.py --route "Route A" --bus 1 --dry-run           # plan only
python demo/simulate_trip.py --route "Route A" --bus 1 --complete-others   # clear stale in_progress trips
```

## Real driver app (optional second check)

```powershell
cd driver_app
flutter run
# Sign up with Bus Number 1..6 (must exist in `buses`), START TRIP,
# walk/drive - student app on another device sees it live.
```

## Troubleshooting

- No bus appears: trip must be `status=in_progress` AND have a `bus_positions` row.
  The simulator creates both. Check Table Editor.
- No realtime: `update_schema.sql` must be applied (tables in
  `supabase_realtime` publication) + Realtime enabled in Supabase project settings.
- `stop_events` never fire: `geofence_trigger.sql` + PostGIS extension required,
  and the simulated path must pass within `stops.geofence_radius_m` (default 100m).
  The simulator travels exactly through each stop coordinate, so it will fire.
- Occupancy never rises: `occupancy_trigger.sql` must be applied.
- Map blank: `CESIUM_ION_ACCESS_TOKEN` in `student_app/.env`; the map falls back
  to ArcGIS imagery without a token but needs internet (Cesium CDN).
- `getaddrinfo failed` / `Non-existent domain`: the `Api_url` project ref is
  wrong, paused, or deleted. Open https://supabase.com/dashboard, copy the
  current Project URL + anon/service_role keys into root `.env`,
  `driver_app/.env`, and `student_app/.env`, then retry `--list`.
