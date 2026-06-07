#!/usr/bin/env python3
"""
Manually post / correct a single match score in Supabase.

This is the secure manual-override path: it writes with the SERVICE key (which
bypasses RLS), so `matches` needs no public write policy and nothing secret ever
touches the website. Normally run via the GitHub Actions "set-result" workflow
(service key kept in repo secrets); can also be run locally for a quick fix.

Usage:
    SUPABASE_URL=https://bocszfurxyyzacgjzmjc.supabase.co \
    SUPABASE_SERVICE_KEY=your_service_role_key \
    python3 set_result.py --match 537xxx --home 2 --away 1 [--status FINISHED]

Find the match id on the football-data fixture, or by reading the `matches`
table. The id is the football-data.org match id (the table's primary key).
"""
import os, sys, argparse, requests

SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://bocszfurxyyzacgjzmjc.supabase.co")
SERVICE_KEY  = os.environ.get("SUPABASE_SERVICE_KEY")

def main():
    ap = argparse.ArgumentParser(description="Set a single match result in Supabase (service key).")
    ap.add_argument("--match", type=int, required=True, help="match id (football-data.org id / table PK)")
    ap.add_argument("--home",  type=int, required=True, help="home score")
    ap.add_argument("--away",  type=int, required=True, help="away score")
    ap.add_argument("--status", default="FINISHED", help="match status (default FINISHED)")
    args = ap.parse_args()

    if not SERVICE_KEY:
        sys.exit("Set SUPABASE_SERVICE_KEY (service_role). Never put it in the website or repo.")
    if args.home < 0 or args.away < 0:
        sys.exit("Scores must be >= 0.")

    url = f"{SUPABASE_URL}/rest/v1/matches?id=eq.{args.match}"
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }
    body = {"home_score": args.home, "away_score": args.away, "status": args.status}
    r = requests.patch(url, headers=headers, json=body)
    if r.status_code not in (200, 204):
        sys.exit(f"supabase error {r.status_code}: {r.text[:300]}")
    rows = r.json() if r.text else []
    if not rows:
        sys.exit(f"No match with id {args.match} found — nothing updated.")
    m = rows[0]
    print(f"Updated: {m.get('home_team')} {args.home}–{args.away} {m.get('away_team')} [{args.status}]")

if __name__ == "__main__":
    main()
