import os
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from dotenv import load_dotenv
from supabase import create_client

load_dotenv(".env")
url = os.getenv("Api_url").rstrip("/").removesuffix("/rest/v1")
sb = create_client(url, os.getenv("Service_role"))
routes = {r["id"]: r["name"] for r in sb.table("routes").select("id,name").execute().data}
stops = sb.table("stops").select("route_id,name,lat,lon,sequence_no").execute().data
stops.sort(key=lambda s: (routes.get(s["route_id"], ""), s["sequence_no"]))
last = None
for s in stops:
    rn = routes.get(s["route_id"], "?")
    if rn != last:
        print("--- " + rn + " ---")
        last = rn
    print(str(s["sequence_no"]) + ". " + s["name"] + " " + str(s["lat"]) + "," + str(s["lon"]))
