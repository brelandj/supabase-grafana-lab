# Run of show — Supabase × Grafana enablement (target ~12–15 min)

Two dashboards open in tabs:
- **App:** "Demo App - Request Health" (import `app-dashboard.json` into your stack and use its uid) — the user-experience layer.
- **DB:** "Supabase Project" (provisioned in your stack by the 1-click integration) — the Supabase integration dashboard.
Alert: **"Supabase CPU Busy >= 85%"** → your email. (Rate window is `[2m]`; bump to `[5m]` to avoid baseline flicker.)

## Pre-demo staging (before the call) — IMPORTANT
- **Let the instances' CPU credits recover** (Supabase nano + EC2 t3.micro are burstable). Don't run heavy rehearsals right before; a throttled box shows a slow/erratic baseline.
- Baseline load (`/order`) running; both dashboards open; alert armed.
- **Start the fault ~5 minutes BEFORE you open**, so the alert is already `firing` and CPU is genuinely pegged when you begin — don't trigger it live and wait (CPU is a lagging signal; see caveats).
- Backup recording + screenshots ready.

## The narrative

**0. Frame (1 min).** "You connected Supabase to Grafana in one click. Here's what that's worth the moment something breaks."

**1. OPEN ON THE ALERT — proactive hook (1–2 min).** Show the fired alert / email.
> "We didn't wait for a support ticket — **Grafana paged us**: CPU on the Supabase project is pegged. No user has complained yet."
Do NOT open with "we got user reports" — that frames it reactive, which is how Supabase's own tools would surface it.

**2. What users feel — App dashboard (3 min).** "Demo App - Request Health":
- **Request rate by route:** `/order` (healthy, indexed) **throughput collapses to ~0** while the bad `/report` query runs → "one runaway query starved an unrelated, well-tuned endpoint — that's the blast radius."
- **Latency p95:** `/report` p95 jumps to the **~3 s query-timeout ceiling** (from ~47 ms); `/order` drags up too. "Requests are crawling."
- **Error rate (5xx):** spikes — requests exceeding the 3 s timeout return **500**. "Users aren't just slow — they're getting errors."
- **In-flight requests** climb (~33 → ~55): "requests piling up behind the DB."
This app layer is the "something's wrong" surface — invisible in Supabase's own dashboards.

**3. Follow it down — DB dashboard (3 min).** "Supabase Project":
- `CPU Basic` pegged ~100%; `Client connections` climbing to the pool cap.
> "Why is the app slow? The database is saturated. Supabase can only show you THIS slice; we walked from the app down to the DB in one pane."
- ⚠️ Red **RAM gauge (~95%)** is normal for Postgres (buffers/cache) — not the problem.

**4. Root cause (2 min).** `Query stats` shows query time spiking; drill in / ask **Grafana Assistant** "why is CPU high?".
> "A report query filters `order_items.batch`, which has **no index** — every run is a **full 1.25M-row sequential scan**. Under load those scans saturate CPU; queries back up, connections pile up. Connection pressure is a *symptom*; the un-indexed scan is the cause."

**5. Fix + recovery (2 min).** Add the index (`./demo.sh remediate prebaked` → `create index on order_items(batch)`).
> "One index." → **App p95 `/report` collapses ~3 s → ~47 ms and the 5xx errors vanish, under the same load**, and `/order` throughput recovers. CPU and the alert follow a few minutes later (5-min window) — narrate: "app's already recovered; CPU/alert catch up as the window clears."

**6. Punchline (1 min).**
> "App, database, and the alert that paged us — one pane, and it caught it **before users noticed**. Supabase shows the database slice; Grafana shows the whole stack, with 13 months of history and alerting, correlated with everything else you run."

## Panel-reading cheatsheet
- **Request rate by route:** watch `/order` (blue) crater during the fault (starved), recover after. `/report` (orange) only has traffic during the fault.
- **Latency p95 by route:** p95 per route (p50 removed). `/report` p95 rises to the ~3 s timeout ceiling, back to ~47 ms after the fix. Lines only render where a route has traffic.
- **Error rate (5xx/s):** `/report` 5xx spikes during the fault (queries exceeding the 3 s timeout return 500), back to 0 after the index.
- **In-flight requests:** ~33 → ~55 under load = pressure building.

## Fault drive commands (operator) — run from the repo root (`supabase-grafana-lab`)
| When | Command |
|------|---------|
| **Kick off the issue** (~5 min before you open) | `./demo.sh app-fault-start` |
| **Add the index — THE FIX** (live, the climax) | `./demo.sh remediate prebaked` |
| **Stop the fault** (after the demo) | `./demo.sh app-fault-stop` |
| **Reset the hook** for a re-run (drop the index) | `./demo.sh unremediate prebaked` |
| Sanity check anytime | `./demo.sh status` |

Sequence for a run: `app-fault-start` → (wait ~4 min, alert fires) → narrate → `remediate` (watch recovery) → `app-fault-stop` when done. To rehearse again: `unremediate` then `app-fault-start`.

## Timing & caveats (validated 2026-07-27)
- **App latency is the hero signal** — instant, dramatic (~3 s → 47 ms), reliable every run. Lead the recovery on it.
- **CPU is a lagging signal**: Supabase scrapes `node_cpu` ~every 60 s, so it's only stable over a `[5m]`-ish window → the CPU panel and the alert take a few minutes to both fire and resolve. Stage the fault early; be patient on CPU recovery.
- **Alert fires ~4 min into sustained fault** (`pending` → `firing`). Have it running before you open.
- **5xx via a 3 s query timeout** (`STMT_TIMEOUT_MS` on the app): slow `/report` queries are cancelled → 500 (real error spike, back to 0 after the fix). This also caps `/report` p95 at ~3 s — still ~60× the 47 ms baseline.
- **Burstable credits:** rest the instances before the demo; a throttled box shows a slow, erratic baseline (a "baseline" query took 10 s right after heavy rehearsals).
