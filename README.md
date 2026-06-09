# megabets — World Cup 2026 friends betting league

A static web app (GitHub Pages) where friends predict match scores. Data lives in
Supabase. No build step, no framework — open `index.html` and it runs.

**Live:** https://megabets.github.io/

**Scoring:** exact score = 3 · correct outcome (incl. draw) = 1 · wrong = 0
**Betting:** organised by round; the whole round locks at its first kickoff.
**Identity:** nickname + a PIN you choose on first join, stored in the browser (friends-trust model — the PIN is a client-side deterrent, not bank-grade security).

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

**Player PINs** (`players.pin_hash`): each nickname is locked with a PIN the first
time it joins. The PIN is hashed in the browser (SHA-256 of `nickname:pin`) and
compared client-side, so it's a deterrent against casual impersonation — *not* a
hard server-side guarantee (someone determined could still call the REST API with
the public anon key). The one server-side guard is the `claim pin` RLS policy:
a PIN can only be set while `pin_hash` is null, so a *claimed* nickname can't be
re-PINned by someone else. Pre-PIN players keep `pin_hash = null` and claim a PIN
on their next login. To harden this to true enforcement, move the bet write into a
`pgcrypto` `SECURITY DEFINER` Postgres function and lock down the predictions RLS.

---

## One-time setup

### 1. Supabase
1. Project already exists (URL is hard-coded in `index.html` / scripts).
2. In Supabase → **SQL Editor**, run the contents of `schema.sql` once.
   (Leave the commented-out `update matches` policy commented — see the file.)
   If the tables already exist, run the **migration** block at the bottom of
   `schema.sql` instead to add `players.pin_hash` + the `claim pin` policy.

### 2. Add the GitHub Actions secrets
Repo → **Settings → Secrets and variables → Actions → New repository secret**
(or use `gh secret set` — see below). Add all three:

| secret | value |
|--------|-------|
| `SUPABASE_URL`         | `https://bocszfurxyyzacgjzmjc.supabase.co` |
| `SUPABASE_SERVICE_KEY` | Supabase → Project Settings → API → `service_role` (SECRET) |
| `FOOTBALL_TOKEN`       | football-data.org → your account → API token |

```bash
gh secret set SUPABASE_URL --repo megabets/megabets.github.io --body "https://bocszfurxyyzacgjzmjc.supabase.co"
gh secret set SUPABASE_SERVICE_KEY --repo megabets/megabets.github.io   # paste when prompted
gh secret set FOOTBALL_TOKEN --repo megabets/megabets.github.io          # paste when prompted
```

### 3. Seed the matches (first time)
Either trigger the workflow once…
```bash
gh workflow run fetch-scores.yml --repo megabets/megabets.github.io
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
**https://megabets.github.io/**. Share that link with your friends.
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
- Nicknames are unique; first to claim one owns it, and the PIN set on first join
  guards it from then on. The PIN check is client-side (a deterrent) — fine for a
  trusted group; see the Security model section for the limits and how to harden it.
- A round locks for everyone at the first match's kickoff in that round.
- Group rounds are MD1/MD2/MD3 (mapped from the API's matchday number).
