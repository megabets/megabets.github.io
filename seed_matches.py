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
from datetime import datetime, timezone, timedelta

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

# Source status quirk: football-data.org sometimes backfills the fullTime score but
# leaves status stuck at TIMED (the TIMED->IN_PLAY->FINISHED transition never fires).
# When a match has a full score AND kicked off long enough ago that it can't still be
# live, we treat it as FINISHED ourselves so the app stops showing it as LIVE and
# settles points. Only promote from these scheduled/live states — never override a
# POSTPONED/CANCELLED/SUSPENDED row (or one already FINISHED/AWARDED).
LIVE_OR_SCHEDULED = {"SCHEDULED", "TIMED", "IN_PLAY", "PAUSED"}
# Comfortably past full time even with extra time + penalties for knockout games.
STALE_AFTER = timedelta(hours=3, minutes=30)

def _kickoff_done(utc_date, now=None):
    """True if the kickoff is far enough in the past that the match must be over."""
    if not utc_date:
        return False
    try:
        ko = datetime.fromisoformat(utc_date.replace("Z", "+00:00"))
    except ValueError:
        return False
    if ko.tzinfo is None:
        ko = ko.replace(tzinfo=timezone.utc)
    return (now or datetime.now(timezone.utc)) - ko > STALE_AFTER

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

def to_row(m, now=None):
    ft = (m.get("score") or {}).get("fullTime") or {}
    home_score, away_score = ft.get("home"), ft.get("away")
    status = m.get("status", "SCHEDULED")
    # Auto-heal a source that has the score but never advanced the status (see note above).
    if (home_score is not None and away_score is not None
            and status in LIVE_OR_SCHEDULED and _kickoff_done(m.get("utcDate"), now)):
        status = "FINISHED"
    return {
        "id": m["id"],
        "stage": map_stage(m),
        "home_team": (m.get("homeTeam") or {}).get("name") or "TBD",
        "away_team": (m.get("awayTeam") or {}).get("name") or "TBD",
        "kickoff": m["utcDate"],
        "home_score": home_score,
        "away_score": away_score,
        "status": status,
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
    now = datetime.now(timezone.utc)
    rows = [to_row(m, now) for m in raw]
    # Surface how many rows we auto-promoted to FINISHED (source had score but stale status).
    healed = sum(1 for m in raw
                 if m.get("status") in LIVE_OR_SCHEDULED
                 and (m.get("score") or {}).get("fullTime", {}).get("home") is not None
                 and (m.get("score") or {}).get("fullTime", {}).get("away") is not None
                 and _kickoff_done(m.get("utcDate"), now))
    if healed:
        print(f"Auto-healed {healed} match(es) to FINISHED (score present, status was stale).")
    # skip rows with no real teams yet AND no useful info (keep TBD knockout slots out)
    rows = [r for r in rows if r["home_team"] != "TBD" or r["away_team"] != "TBD"]
    print(f"Fetched {len(raw)} matches, pushing {len(rows)}.")
    counts = {}
    for r in rows:
        counts[r["stage"]] = counts.get(r["stage"], 0) + 1
    for s in sorted(counts):
        print(f"  {s}: {counts[s]}")

    # Flag finished matches the source hasn't given a score for (e.g. a persistent
    # data gap). These need a manual set_result.py; surface them in the log.
    for r in rows:
        if r["status"] in ("FINISHED", "AWARDED") and (r["home_score"] is None or r["away_score"] is None):
            print(f"WARN: {r['home_team']} v {r['away_team']} is {r['status']} but has no score "
                  f"(id {r['id']}); leaving any existing score untouched.")

    # Only write scores when the source actually has both — otherwise a source gap
    # (or a manual correction) would get nulled out on every run. merge-duplicates
    # only updates the columns present in the payload, so dropping the score keys
    # leaves existing home_score/away_score intact on conflict (and new rows still
    # default to NULL, which is correct for unplayed matches).
    with_score, without_score = [], []
    for r in rows:
        if r["home_score"] is not None and r["away_score"] is not None:
            with_score.append(r)
        else:
            without_score.append({k: v for k, v in r.items() if k not in ("home_score", "away_score")})

    # push each group in chunks of 50
    for group in (with_score, without_score):
        for i in range(0, len(group), 50):
            push(group[i:i+50])
    print("Done.")

if __name__ == "__main__":
    main()
