"""Seeds the DB road graph from route stops (chain + skip-one edges).

Mirrors RoadGraph.fromStops() in lib/ai/road_graph.dart so the live A*
and the seeded graph agree. Safe to re-run (upserts by id).
Run:  python demo/seed_road_graph.py
"""

from __future__ import annotations

import math
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from dotenv import load_dotenv  # noqa: E402
import psycopg  # noqa: E402
from supabase import create_client  # noqa: E402

SPEED_MPS = 8.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


load_dotenv(".env")
url = os.getenv("Api_url").rstrip("/").removesuffix("/rest/v1")
sb = create_client(url, os.getenv("Service_role"))
stops = sb.table("stops").select("id,name,lat,lon,sequence_no,route_id").order("sequence_no").execute().data

by_route: dict[str, list] = {}
for s in stops:
    by_route.setdefault(s["route_id"], []).append(s)

nodes = []
edges = []
for rid, ss in by_route.items():
    ss.sort(key=lambda s: s["sequence_no"])
    for s in ss:
        nodes.append((f"stop:{s['id']}", s["name"], float(s["lat"]), float(s["lon"])))
    for i in range(len(ss) - 1):
        a, b = ss[i], ss[i + 1]
        d = haversine_m(float(a["lat"]), float(a["lon"]), float(b["lat"]), float(b["lon"]))
        edges.append((f"chain:{rid}:{i}", f"stop:{a['id']}", f"stop:{b['id']}", d, d / SPEED_MPS))
        if i + 2 < len(ss):
            c = ss[i + 2]
            d2 = haversine_m(float(a["lat"]), float(a["lon"]), float(c["lat"]), float(c["lon"]))
            edges.append((f"skip:{rid}:{i}", f"stop:{a['id']}", f"stop:{c['id']}", d2, d2 / SPEED_MPS))

with psycopg.connect(os.getenv("DATABASE_URL"), connect_timeout=15) as conn, conn.cursor() as cur:
    for nid, label, lat, lon in nodes:
        cur.execute(
            "insert into road_nodes (id, label, lat, lon) values (%s,%s,%s,%s) "
            "on conflict (id) do update set label=excluded.label, lat=excluded.lat, lon=excluded.lon;",
            (nid, label, lat, lon),
        )
    for eid, frm, to, dist, t in edges:
        cur.execute(
            "insert into road_edges (from_node, to_node, distance_m, travel_time_s) values (%s,%s,%s,%s) "
            "on conflict (from_node, to_node) do update set distance_m=excluded.distance_m, travel_time_s=excluded.travel_time_s;",
            (frm, to, dist, t),
        )
        cur.execute(
            "insert into road_edges (from_node, to_node, distance_m, travel_time_s) values (%s,%s,%s,%s) "
            "on conflict (from_node, to_node) do update set distance_m=excluded.distance_m, travel_time_s=excluded.travel_time_s;",
            (to, frm, dist, t),
        )
    conn.commit()
print(f"road graph seeded: {len(nodes)} nodes, {len(edges) * 2} directed edges")
