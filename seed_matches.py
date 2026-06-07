#!/usr/bin/env python3
"""
Seed / refresh World Cup 2026 matches into Supabase.

Run locally (needs Python 3 + requests):
    pip install requests
    FOOTBALL_TOKEN=your_footballdata_token \
    SUPABASE_URL=https://bocszfurxyyzacgjzmjc.supabase.co \
    SUPABASE_SERVICE_KEY=your_service_role_key \
    python3 seed_matches.py

Where to get the keys:
  - FOOTBALL_TOKEN: football-data.org -> your account -> API token
  - SUPABASE_SERVICE_KEY: Supabase -> Project Settings -> API -> service_role (SECRET).
    Use the SERVICE key here (not anon) so it can write to the matches table,
    which is locked down by RLS. Never put the service key in the website.

Re-run anytime to pull newly-scheduled knockout matches and latest scores.
It UPSERTS by match id, so existing rows are updated, not duplicated.
"""
import os, sys, time, requests

FOOTBALL_TOKEN = os.environ.get("FOOTBALL_TOKEN")
SUPABASE_URL   = os.environ.get("SUPABASE_URL", "https://bocszfurxyyzacgjzmjc.supabase.co")
SERVICE_KEY    = os.environ.get("SUPABASE_SERVICE_KEY")

if not FOOTBALL_TOKEN or not SERVICE_KEY:
    sys.exit("Set FOOTBALL_TOKEN and SUPABASE_SERVICE_KEY env vars. See header.")

# football-data.org v4 stage enum -> our stage code
STAGE_MAP = {
    "LAST_32": "R32",
    "LAST_16": "R16",
    "QUARTER_FINALS": "QF",
    "SEMI_FINALS": "SF",
    "THIRD_PLACE": "3RD",
    "FINAL": "FINAL",
}

def map_stage(m):
    st = m.get("stage", "")
    if st == "GROUP_STAGE":
        md = m.get("matchday") or 1
        return f"MD{min(max(int(md),1),3)}"
    return STAGE_MAP.get(st, st)  # fall back to raw code if unseen

def fetch_matches():
    url = "https://api.football-data.org/v4/competitions/WC/matches"
    attempts = 3
    for n in range(1, attempts + 1):
        try:
            r = requests.get(url, headers={"X-Auth-Token": FOOTBALL_TOKEN}, timeout=30)
        except requests.RequestException as e:
            if n == attempts:
                sys.exit(f"football-data request failed after {attempts} tries: {e}")
            print(f"football-data request error ({e}); retry {n}/{attempts - 1}")
            time.sleep(2 * n)
            continue
        if r.status_code == 200:
            return r.json().get("matches", [])
        # 429 (rate limit) and 5xx are transient; retry. Other 4xx are not.
        if r.status_code in (429, 500, 502, 503, 504) and n < attempts:
            print(f"football-data {r.status_code}; retry {n}/{attempts - 1}")
            time.sleep(2 * n)
            continue
        sys.exit(f"football-data error {r.status_code}: {r.text[:300]}")

def to_row(m):
    ft = (m.get("score") or {}).get("fullTime") or {}
    return {
        "id": m["id"],
        "stage": map_stage(m),
        "home_team": (m.get("homeTeam") or {}).get("name") or "TBD",
        "away_team": (m.get("awayTeam") or {}).get("name") or "TBD",
        "kickoff": m["utcDate"],
        "home_score": ft.get("home"),
        "away_score": ft.get("away"),
        "status": m.get("status", "SCHEDULED"),
    }

def push(rows):
    # upsert on primary key id
    url = f"{SUPABASE_URL}/rest/v1/matches?on_conflict=id"
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }
    r = requests.post(url, headers=headers, json=rows)
    if r.status_code not in (200, 201, 204):
        sys.exit(f"supabase error {r.status_code}: {r.text[:300]}")

def main():
    raw = fetch_matches()
    rows = [to_row(m) for m in raw]
    # skip rows with no real teams yet AND no useful info (keep TBD knockout slots out)
    rows = [r for r in rows if r["home_team"] != "TBD" or r["away_team"] != "TBD"]
    print(f"Fetched {len(raw)} matches, pushing {len(rows)}.")
    counts = {}
    for r in rows:
        counts[r["stage"]] = counts.get(r["stage"], 0) + 1
    for s in sorted(counts):
        print(f"  {s}: {counts[s]}")
    # push in chunks of 50
    for i in range(0, len(rows), 50):
        push(rows[i:i+50])
    print("Done.")

if __name__ == "__main__":
    main()
