import os
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from dotenv import load_dotenv
import psycopg

load_dotenv(".env")
fname = sys.argv[1] if len(sys.argv) > 1 else "extra_stops.sql"
sql = open(fname, encoding="utf-8").read()
with psycopg.connect(os.getenv("DATABASE_URL"), connect_timeout=15) as conn:
    conn.execute(sql)
    conn.commit()
print(fname + " applied OK")
