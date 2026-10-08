"""
Demo trip simulator for the College Bus Tracker.

Pretends to be a driver moving along a route so you can watch
the STUDENT app update in realtime (bus marker, stop events,
running_status, occupancy) without needing a real device/GPS.

What it does:
  1. Lets you pick ANY route + bus from your Supabase data (--list to see them).
  2. Creates a real `trips` row with status='in_progress'.
  3. Interpolates lat/lon from stop to stop and upserts `bus_positions`
     every `--interval` seconds (this is exactly what driver_app does).
  4. Inserts `location_pings` periodically (raw trail).
  5. Inserts a random `stop_boardings` row when "arriving" at each stop
     (this fires the occupancy trigger -> trips.current_occupancy).
  6. Your DB triggers then fire automatically:
       bus_positions -> stop_events (arrived/departed) + trips.running_status
  7. Holds the trip open at the terminus until Ctrl+C, then marks completed.

Run:
  pip install -r requirements.txt
  python simulate_trip.py --list
  python simulate_trip.py --route "Route A" --bus 1
  # then open student_app (flutter run) and watch the bus move live.

Keys are read from ../.env (root), ../driver_app/.env or ../student_app/.env.
Never hardcodes secrets. Prefers Service_role (bypasses RLS like a
trusted simulator); falls back to Anon_key.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import random
import sys
import time
from pathlib import Path

try:
    from dotenv import load_dotenv
except ImportError:
    print("Missing dependency: pip install -r requirements.txt", file=sys.stderr)
    sys.exit(1)

try:
    from supabase import create_client
except ImportError:
    print("Missing dependency: pip install -r requirements.txt", file=sys.stderr)
    sys.exit(1)


def _fix_windows_console() -> None:
    """Allow printing route names with unicode arrows on Windows consoles."""
    try:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        if hasattr(sys.stderr, "reconfigure"):
            sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001 - best effort only
        pass


_fix_windows_console()


def load_config() -> tuple[str, str, bool]:
    here = Path(__file__).resolve().parent
    root = here.parent
    for p in (root / ".env", root / "driver_app" / ".env", root / "student_app" / ".env"):
        if p.exists():
            load_dotenv(p, override=False)
    # Support both project key names (Api_url/Anon_key) and standard names.
    url = (
        os.getenv("Api_url")
        or os.getenv("SUPABASE_URL")
        or os.getenv("ApiUrl")
        or ""
    ).strip().strip('"').strip("'")
    service = (
        os.getenv("Service_role")
        or os.getenv("SUPABASE_SERVICE_ROLE_KEY")
        or os.getenv("SERVICE_ROLE_KEY")
        or ""
    ).strip().strip('"').strip("'")
    anon = (
        os.getenv("Anon_key")
        or os.getenv("SUPABASE_ANON_KEY")
        or os.getenv("ANON_KEY")
        or ""
    ).strip().strip('"').strip("'")
    key = service or anon
    if not url or not key:
        print(
            "ERROR: Supabase URL/key not found. Put Api_url + Service_role (or Anon_key) "
            "in .env at repo root (see demo/README.md).",
            file=sys.stderr,
        )
        sys.exit(2)
    return url, key, bool(service)


def pick(items: list[dict], query: str, keys: list[str]) -> dict | None:
    q = query.strip().lower()
    for it in items:
        if str(it.get("id", "")).lower() == q:
            return it
    for k in keys:
        for it in items:
            if str(it.get(k, "")).strip().lower() == q:
                return it
    matches = [it for it in items for k in keys if q in str(it.get(k, "")).lower()]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        names = ", ".join(f"\"{it.get(keys[0], it.get('id'))}\"" for it in matches)
        print(f'Ambiguous "{query}" - matches {len(matches)}: {names}. Use the full name.', file=sys.stderr)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Simulate a live bus trip for realtime testing.")
    ap.add_argument("--list", action="store_true", help="List routes/buses/stops and exit (read-only).")
    ap.add_argument("--route", default="", help="Route name (fuzzy) or id. Omit for interactive pick.")
    ap.add_argument("--bus", default="", help="Bus number (e.g. 4) or id. Omit for interactive pick.")
    ap.add_argument("--steps-per-leg", type=int, default=20, help="Position updates between stops (default 20).")
    ap.add_argument("--interval", type=float, default=2.0, help="Seconds between position updates (default 2).")
    ap.add_argument("--boarding-max", type=int, default=5, help="Max random boardings per stop (default 5, 0 to disable).")
    ap.add_argument("--loop", action="store_true", help="Loop the route until Ctrl+C.")
    ap.add_argument("--complete-others", action="store_true", help="Complete other in_progress trips for this bus first.")
    ap.add_argument("--dry-run", action="store_true", help="Print the plan without writing anything.")
    ap.add_argument("--seed", type=int, default=7, help="Random seed for boardings.")
    args = ap.parse_args()

    random.seed(args.seed)
    url, key, is_service = load_config()
    # supabase-py expects the project base URL (https://xyz.supabase.co).
    # Some .env files store Api_url with a trailing /rest/v1 - strip it.
    base_url = url.rstrip("/")
    if base_url.endswith("/rest/v1"):
        base_url = base_url[: -len("/rest/v1")]
    sb = create_client(base_url, key)
    print(f"Connected to {base_url} ({'service_role' if is_service else 'anon key'}).")

    try:
        routes = sb.table("routes").select("id,name").order("name").execute().data or []
        buses = sb.table("buses").select("id,bus_number,route_id,capacity").order("bus_number").execute().data or []
    except Exception as e:  # noqa: BLE001 - demo script, explain connectivity clearly
        print(f"\nERROR: could not reach Supabase at {base_url}", file=sys.stderr)
        print(f"Detail: {e}", file=sys.stderr)
        print(
            "\nChecklist:\n"
            "  1. Is Api_url in .env correct? It should look like https://xyzcompany.supabase.co\n"
            "     (no trailing /rest/v1 needed - the script strips it if present).\n"
            "  2. Does the project still exist? A 'Non-existent domain' / getaddrinfo\n"
            "     failure means the project ref is wrong, paused, or deleted.\n"
            "     Open https://supabase.com/dashboard and verify the project URL.\n"
            "  3. Is this machine online? (nslookup google.com should resolve).\n"
            "  4. If you changed the URL, update root .env + driver_app/.env + student_app/.env.",
            file=sys.stderr,
        )
        return 3
    if not routes:
        print("No routes found. Run schema.sql + seed_data.sql in Supabase first.")
        return 1

    if args.list:
        print(f"\nRoutes ({len(routes)}):")
        for r in routes:
            rb = [b["bus_number"] for b in buses if b["route_id"] == r["id"]]
            print(f"  - {r['name']}  id={r['id']}  buses=[{', '.join(rb) or 'none'}]")
        print(f"\nBuses ({len(buses)}):")
        for b in buses:
            rn = next((r["name"] for r in routes if r["id"] == b["route_id"]), "?")
            print(f"  - bus {b['bus_number']}  id={b['id']}  route={rn}  capacity={b.get('capacity')}")
        print("\nExample: python simulate_trip.py --route \"Route A\" --bus 1")
        return 0

    # --- pick route ---
    route = pick(routes, args.route, ["name"]) if args.route else None
    if route is None and not args.route:
        print("\nAvailable routes:")
        for i, r in enumerate(routes):
            print(f"  [{i}] {r['name']}")
        route = routes[int(input("Pick route number: ").strip() or "0")]
    if route is None:
        print(f'Route "{args.route}" not found. Use --list to see names.', file=sys.stderr)
        return 1

    route_buses = [b for b in buses if b["route_id"] == route["id"]]
    if not route_buses:
        print(f'No buses assigned to route "{route["name"]}". Add one in Supabase first.', file=sys.stderr)
        return 1
    bus = pick(route_buses, args.bus, ["bus_number"]) if args.bus else None
    if bus is None and not args.bus:
        print(f"\nBuses on {route['name']}:")
        for i, b in enumerate(route_buses):
            print(f"  [{i}] bus {b['bus_number']} (capacity {b.get('capacity')})")
        bus = route_buses[int(input("Pick bus number: ").strip() or "0")]
    if bus is None:
        print(f'Bus "{args.bus}" not on route "{route["name"]}". Use --list.', file=sys.stderr)
        return 1

    stops = (
        sb.table("stops")
        .select("id,name,lat,lon,sequence_no,geofence_radius_m,scheduled_time")
        .eq("route_id", route["id"])
        .order("sequence_no")
        .execute()
        .data
        or []
    )
    if not stops:
        print(f'No stops for route "{route["name"]}". Seed stops first.', file=sys.stderr)
        return 1

    # --- find a driver for the trip (driver_id is nullable, but prefer a real one) ---
    driver_id = None
    try:
        link = (
            sb.table("driver_bus_assignments")
            .select("driver_id")
            .eq("bus_id", bus["id"])
            .limit(1)
            .execute()
            .data
            or []
        )
        if link:
            driver_id = link[0]["driver_id"]
    except Exception as e:  # noqa: BLE001 - demo script, keep going
        print(f"(warn) could not look up driver assignment: {e}")

    print(f"\nPlan: bus {bus['bus_number']} on \"{route['name']}\" ({len(stops)} stops)")
    for s in stops:
        print(f"   {s['sequence_no']}. {s['name']} ({s['lat']},{s['lon']}) r={s.get('geofence_radius_m')}m")
    print(f"Driver: {driver_id or '(none linked - trip will have NULL driver_id)'}")
    print(f"Steps/leg={args.steps_per_leg} interval={args.interval}s boarding_max={args.boarding_max}")
    if args.dry_run:
        print("Dry run - nothing written.")
        return 0

    if args.complete_others:
        others = (
            sb.table("trips")
            .select("id")
            .eq("bus_id", bus["id"])
            .eq("status", "in_progress")
            .execute()
            .data
            or []
        )
        for o in others:
            sb.table("trips").update(
                {"status": "completed", "ended_at": dt.datetime.now(dt.timezone.utc).isoformat()}
            ).eq("id", o["id"]).execute()
            print(f"Completed stale trip {o['id']}")

    # --- create trip ---
    trip = (
        sb.table("trips")
        .insert(
            {
                "bus_id": bus["id"],
                "driver_id": driver_id,
                "route_id": route["id"],
                "trip_date": dt.date.today().isoformat(),
                "status": "in_progress",
                "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            }
        )
        .select("id")
        .single()
        .execute()
        .data
    )
    trip_id = trip["id"]
    print(f"\nTrip {trip_id} started. Open the STUDENT app now - the bus will appear live.")
    print("Watch: bus marker moving, stop_events arrived/departed, running_status on_time/late, occupancy rising.")
    print("Press Ctrl+C to end the trip.\n")

    def push(lat: float, lon: float, speed: float = 8.0) -> None:
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        sb.table("bus_positions").upsert(
            {"trip_id": trip_id, "bus_id": bus["id"], "lat": lat, "lon": lon, "updated_at": now}
        ).execute()
        # raw trail every 2nd update to avoid spamming location_pings
        push.counter += 1
        if push.counter % 2 == 0:
            sb.table("location_pings").insert(
                {"trip_id": trip_id, "lat": lat, "lon": lon, "speed": speed}
            ).execute()

    push.counter = 0

    def board(stop: dict) -> None:
        if args.boarding_max <= 0:
            return
        n = random.randint(0, args.boarding_max)
        sb.table("stop_boardings").insert(
            {"trip_id": trip_id, "stop_id": stop["id"], "boarding_count": n}
        ).execute()
        print(f"  [boarding] {n} boarded at {stop['name']} -> trips.current_occupancy increments via trigger")

    try:
        run = 0
        while True:
            run += 1
            for i, stop in enumerate(stops):
                print(f"-> arriving {stop['name']} ({i + 1}/{len(stops)})")
                board(stop)
                if i == len(stops) - 1:
                    push(float(stop["lat"]), float(stop["lon"]), speed=0)
                    break
                nxt = stops[i + 1]
                for step in range(1, args.steps_per_leg + 1):
                    f = step / args.steps_per_leg
                    lat = float(stop["lat"]) + (float(nxt["lat"]) - float(stop["lat"])) * f
                    lon = float(stop["lon"]) + (float(nxt["lon"]) - float(stop["lon"])) * f
                    push(lat, lon)
                    time.sleep(args.interval)
            if not args.loop:
                break
            print(f"--- loop {run} done, restarting route ---")
        # Hold at terminus so students can still see the live bus until Ctrl+C.
        print("\nRoute finished. Holding live position - press Ctrl+C to complete the trip.")
        last = stops[-1]
        while True:
            push(float(last["lat"]), float(last["lon"]), speed=0)
            time.sleep(10)
    except KeyboardInterrupt:
        print("\nStopping simulator...")
    finally:
        sb.table("trips").update(
            {"status": "completed", "ended_at": dt.datetime.now(dt.timezone.utc).isoformat()}
        ).eq("id", trip_id).execute()
        print(f"Trip {trip_id} marked completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
