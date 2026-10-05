import os
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from dotenv import load_dotenv
from supabase import create_client

load_dotenv(".env")
url = os.getenv("Api_url").rstrip("/").removesuffix("/rest/v1")
sb = create_client(url, os.getenv("Service_role"))
for r in sb.table("routes").select("id,name").execute().data:
    print(repr(r["name"]), r["id"])
