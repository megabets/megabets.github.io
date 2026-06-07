# malakabet — World Cup 2026 friends betting league

A static web app (GitHub Pages) where friends predict match scores. Data lives in
Supabase. No build step, no framework — open `index.html` and it runs.

**Live:** https://nuxblock.github.io/malakabet/

**Scoring:** exact score = 3 · correct outcome (incl. draw) = 1 · wrong = 0
**Betting:** organised by round; the whole round locks at its first kickoff.
**Identity:** nickname only, stored in the browser (friends-trust model, no passwords).

---

## Files
| file | what it is |
|------|------------|
| `index.html`                        | the whole app (HTML/CSS/JS in one file) |
| `schema.sql`                        | run once in Supabase to create the tables + security rules |
| `seed_matches.py`                   | pulls/refreshes all WC fixtures + scores from football-data.org |
| `set_result.py`                     | posts/corrects a single match score (service key) |
| `.github/workflows/fetch-scores.yml`| cron that runs `seed_matches.py` every 15 min |
| `.github/workflows/set-result.yml`  | manual "Run workflow" to set one score |
| `.gitignore`                        | keeps secrets out of git |

---

## Security model (read this)

There are three keys. Only one is meant to be public:

- **Supabase anon key** — *public by design.* It's embedded in `index.html`; Row
  Level Security is what protects the data. (Confirm with: it decodes to `role:anon`.)
- **Supabase `service_role` key** — *secret.* Bypasses RLS. Lives ONLY in GitHub
  Actions secrets (and your shell when running scripts locally). Never in the repo
  or the browser.
- **football-data.org token** — *secret.* GitHub Actions secrets / local shell only.

Because all match-score writes go through the service key (via GitHub Actions),
`matches` has **no public write policy** — so a visitor holding the public anon key
**cannot** tamper with scores. There is no admin password anywhere (nothing to leak).

---

## One-time setup

### 1. Supabase
1. Project already exists (URL is hard-coded in `index.html` / scripts).
2. In Supabase → **SQL Editor**, run the contents of `schema.sql` once.
   (Leave the commented-out `update matches` policy commented — see the file.)

### 2. Add the GitHub Actions secrets
Repo → **Settings → Secrets and variables → Actions → New repository secret**
(or use `gh secret set` — see below). Add all three:

| secret | value |
|--------|-------|
| `SUPABASE_URL`         | `https://bocszfurxyyzacgjzmjc.supabase.co` |
| `SUPABASE_SERVICE_KEY` | Supabase → Project Settings → API → `service_role` (SECRET) |
| `FOOTBALL_TOKEN`       | football-data.org → your account → API token |

```bash
gh secret set SUPABASE_URL --repo nuxblock/malakabet --body "https://bocszfurxyyzacgjzmjc.supabase.co"
gh secret set SUPABASE_SERVICE_KEY --repo nuxblock/malakabet   # paste when prompted
gh secret set FOOTBALL_TOKEN --repo nuxblock/malakabet          # paste when prompted
```

### 3. Seed the matches (first time)
Either trigger the workflow once…
```bash
gh workflow run fetch-scores.yml --repo nuxblock/malakabet
```
…or run it locally (same script the cron uses):
```bash
pip install requests
FOOTBALL_TOKEN=your_footballdata_token \
SUPABASE_URL=https://bocszfurxyyzacgjzmjc.supabase.co \
SUPABASE_SERVICE_KEY=your_service_role_key \
python3 seed_matches.py
```
Expect ~72 group matches. Knockout matchups (R32 onward) only exist once teams are
known — the cron picks them up automatically on later runs. It upserts by match id,
so re-running updates rows and scores without creating duplicates.

### 4. Deploy to GitHub Pages
Already wired to deploy from branch `main`, folder `/root`. Site is live at
**https://nuxblock.github.io/malakabet/**. Share that link with your friends.
(To re-enable from scratch: Repo → **Settings → Pages** → Source: branch `main`, `/root`.)

---

## Entering / correcting results

Scores normally arrive automatically: **`fetch-scores`** runs every 15 minutes and
upserts the latest from football-data.org. The free tier's scores are *delayed*
(not live), so to post a result the instant a match ends, override it manually.

**Manual override (secure, service-key only):**
- From GitHub: Actions tab → **set-result** → **Run workflow**, enter the match id,
  home score, away score. Triggering it requires repo access — that's the gate.
- Or locally:
  ```bash
  SUPABASE_URL=https://bocszfurxyyzacgjzmjc.supabase.co \
  SUPABASE_SERVICE_KEY=your_service_role_key \
  python3 set_result.py --match 537123 --home 2 --away 1
  ```
The match id is the football-data.org id (the `matches` table primary key) — find it
in the Supabase table editor.

---

## How scoring is computed
Points are calculated in the browser from `matches` (final scores) + `predictions`.
Nothing is stored as "points" — change a result and standings recompute instantly.
Tie-break on the leaderboard: most exact-score hits.

## Notes / limitations
- Nicknames are unique; first to claim one owns it. No passwords for players, so
  anyone who knows a nickname could bet as that player — fine for a trusted group.
- A round locks for everyone at the first match's kickoff in that round.
- Group rounds are MD1/MD2/MD3 (mapped from the API's matchday number).
