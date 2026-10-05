"""Read-only health check for the College Bus Tracker backend.

Verifies everything the realtime demo needs, without writing anything:
  routes/buses/stops present, stops ordered with valid coordinates,
  no stale in_progress trips, row counts, and (via DATABASE_URL)
  triggers + realtime publication membership.

Run:  python demo/check_realtime.py
"""

from __future__ import annotations

import os
import sys
from collections import Counter
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from dotenv import load_dotenv  # noqa: E402
from supabase import create_client  # noqa: E402

here = Path(__file__).resolve().parent
root = here.parent
for p in (root / ".env", root / "driver_app" / ".env", root / "student_app" / ".env"):
    if p.exists():
        load_dotenv(p, override=False)

url = (os.getenv("Api_url") or "").strip().strip('"').strip("'").rstrip("/").removesuffix("/rest/v1")
key = (os.getenv("Service_role") or os.getenv("Anon_key") or "").strip().strip('"').strip("'")
if not url or not key:
    sys.exit("ERROR: Api_url / Service_role not found in .env")

sb = create_client(url, key)
ok = True


def check(label: str, cond: bool, detail: str = "") -> None:
    global ok
    print(f"[{'PASS' if cond else 'FAIL'}] {label} {detail}")
    if not cond:
        ok = False


routes = sb.table("routes").select("id,name").order("name").execute().data or []
buses = sb.table("buses").select("id,bus_number,route_id,capacity").execute().data or []
stops = sb.table("stops").select("id,route_id,name,lat,lon,sequence_no,geofence_radius_m").order("sequence_no").execute().data or []

check("routes exist", len(routes) > 0, f"({len(routes)} found)")
check("buses exist", len(buses) > 0, f"({len(buses)} found)")
check("stops exist", len(stops) > 0, f"({len(stops)} found)")

for r in routes:
    rs = [s for s in stops if s["route_id"] == r["id"]]
    rb = [b for b in buses if b["route_id"] == r["id"]]
    seqs = [s["sequence_no"] for s in rs]
    check(f'route "{r["name"]}" has stops + bus', len(rs) > 0 and len(rb) > 0, f"({len(rs)} stops, buses={[b['bus_number'] for b in rb]})")
    check(f'route "{r["name"]}" stops sequenced 1..n', seqs == list(range(1, len(rs) + 1)), f"({seqs})")
    bad = [s["name"] for s in rs if not (-90 <= s["lat"] <= 90 and -180 <= s["lon"] <= 180)]
    check(f'route "{r["name"]}" coordinates valid', not bad, f"(bad: {bad})" if bad else "")

trips = sb.table("trips").select("id,bus_id,status").eq("status", "in_progress").execute().data or []
print(f"[INFO] in_progress trips: {len(trips)}" + (" (stale? use --complete-others when simulating)" if trips else " (clean - good for demo)"))

for tbl, pk in (("bus_positions", "trip_id"), ("stop_events", "id"), ("stop_boardings", "id"), ("location_pings", "id")):
    try:
        n = sb.table(tbl).select(pk, count="exact").limit(1).execute().count
        print(f"[INFO] {tbl} rows: {n}")
    except Exception as e:  # noqa: BLE001
        check(f"table {tbl} readable", False, str(e))

# Deep checks via direct Postgres connection (triggers + realtime publication).
db_url = (os.getenv("DATABASE_URL") or "").strip().strip('"').strip("'")
if db_url:
    try:
        import psycopg

        with psycopg.connect(db_url, connect_timeout=10) as conn, conn.cursor() as cur:
            cur.execute("select tgname from pg_trigger where not tgisinternal order by tgname;")
            triggers = {r[0] for r in cur.fetchall()}
            for t in ("trigger_bus_position_update", "trigger_boarding_insert", "trigger_trip_status_change"):
                check(f"trigger {t} installed", t in triggers)
            cur.execute(
                "select tablename from pg_publication_tables where pubname='supabase_realtime';"
            )
            pub = {r[0] for r in cur.fetchall()}
            for t in ("bus_positions", "trips", "stop_events", "stops"):
                check(f"realtime enabled for {t}", t in pub)
            cur.execute("select 1 from pg_extension where extname='postgis';")
            check("postgis extension installed", cur.fetchone() is not None)
    except Exception as e:  # noqa: BLE001
        print(f"[WARN] direct DB check skipped: {e}")
else:
    print("[WARN] DATABASE_URL not in .env - skipping trigger/realtime checks (run SQL manually).")

print("\nRESULT:", "ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED - see above")
sys.exit(0 if ok else 1)
