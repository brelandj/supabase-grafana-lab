# Lab: from alert to root cause on a Supabase project (~45 min)

You will break a Supabase-backed app with a realistic fault, get paged by Grafana, and
work the incident from the symptom down to the root cause and fix — using the Supabase
integration dashboard, an app dashboard, Loki logs, and an alert, all on one timeline.

**Before you start:** every box in the README's *Ready-to-start checklist* is ticked, and you
have these open in browser tabs:

- **App dashboard** — "Demo App - Request Health" (imported from `app-dashboard.json`)
- **DB dashboard** — "Supabase Project" (provisioned by the one-click integration)
- **Explore** with the Loki datasource selected

Keep a terminal in the repo root. All commands below are run from there.

---

## Part 0 — Know what healthy looks like (5 min)

1. Confirm the fix daemon is holding its connection. This must be up *before* the fault
   starts; you'll see why in Part 4.

   ```bash
   ./demo.sh fixd-start
   ```
   Expect `held=yes ... fault_index=none`.

2. On the **App dashboard**, note the baseline for the `/order` route: request rate ~20 rps,
   p95 latency in the tens of milliseconds, error rate 0, in-flight requests low. `/report`
   has no traffic yet — nobody is running reports.

3. On the **DB dashboard**, note *CPU Basic*, *Client connections*, and *Query stats* at rest.
   Also look at the *RAM Used* gauge: it is probably ~95% and red. That is normal for
   Postgres (shared buffers and page cache) and will not change during the incident — don't
   let it distract you later.

> **Checkpoint:** you can name the baseline p95 for `/order` and the idle CPU percentage.

---

## Part 1 — Create the alert that will page you (5 min)

Rather than watching dashboards and hoping, set up Grafana to tell you when the database
is in trouble.

1. In Grafana: **Alerting → Alert rules → New alert rule**.
2. Query (Prometheus datasource):
   ```promql
   clamp_min(100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100, 0)
   ```
   Add a label filter for your project if your stack has more than one Supabase project
   connected (the integration labels series with `supabase_project_ref`).
3. Condition: **is above 85**. Pending period: **2m**.
4. Name it `Supabase CPU Busy >= 85%`, pick or create a contact point (email to yourself
   is fine), save.

A `[5m]` rate window is deliberate: Supabase scrapes CPU roughly once a minute, so a
shorter window flickers.

> **Checkpoint:** the rule shows as *Normal* in the alert list.

---

## Part 2 — Break it (2 min, then wait ~5)

Someone starts running a heavy report, repeatedly, during business hours.

```bash
./demo.sh app-fault-start
```

This drives ~30 requests/s at `/report` on the EC2 host, *through the app*, while the
healthy `/order` traffic keeps running. Nothing else changes.

Now wait. Watch the alert rule: it goes *Normal → Pending → Firing* over roughly 4 minutes.
While you wait, keep an eye on the App dashboard and write down the first thing you see move.

> **Checkpoint:** you received the alert notification (or the rule shows *Firing*).

---

## Part 3 — Work the incident (15 min)

You've been paged: *database CPU is pegged*. No user has complained yet. Your job is to find
out what users would be experiencing, why, and what to do about it. Resist the urge to jump
to the fix — the point is to see how each layer explains the next.

### 3a. What are users feeling? — App dashboard

Look at each panel and answer the question next to it.

| Panel | What you should see | Question |
|-------|---------------------|----------|
| Request rate by route | `/report` appears at ~30 rps. `/order` **collapses toward 0**. | `/order` is a well-indexed query that nobody changed. Why did its throughput fall? |
| Latency p95 by route | `/report` p95 jumps from ~50 ms to **~3 s** and flat-lines there. `/order` drags up too. | Why does `/report` stop at exactly ~3 s instead of climbing further? |
| Error rate (5xx/s) | `/report` starts returning 500s. | Are the errors a separate bug, or the same problem as the latency? |
| In-flight requests | Climbs from ~30 to ~55. | What does a rising in-flight count mean when request *rate* is constant? |

The ~3 s ceiling is the app's `statement_timeout`: requests whose query exceeds it are
cancelled by Postgres and returned as 500. So the errors *are* the latency, and `/order` is
collateral — it is starved of pool connections and DB CPU by `/report`. That is the blast
radius of one bad query.

### 3b. Why is the app slow? — DB dashboard

Follow the symptom down a layer. On the **Supabase Project** dashboard (panel ids in
`PANELS.md`):

- **CPU Basic / CPU Busy** — pegged near 100%. This is what paged you.
- **Client connections** — `pg_stat_database_num_backends` climbing toward the pooler's
  session cap (~15). Connections are piling up *because* queries are slow, not the reverse.
- **Query stats** — `pg_stat_statements_total_time_seconds` rate rising sharply: total query
  time is climbing while query *count* barely moved. Each query got much more expensive.
- **Disk IOps** — reads up, from sequential scans.
- **Postgres status / pgbouncer status / OOM Killer** — all still green and flat. The
  database is *up but struggling*, and it is CPU-bound, not memory-bound.

> **Checkpoint:** you can say in one sentence what the DB dashboard adds that the app
> dashboard couldn't tell you.

### 3c. What exactly is failing? — Logs

The metrics say *where* (the DB, via `/report`). The logs say *what*. In **Explore** (Loki):

```logql
{job="demoapp", level="error"} | json
```

Each line is one failed request. Look at `route`, `duration_ms`, `query`, `db_error`, and
`pg_code`. You should see `duration_ms` ≈ 3000, `query = report_revenue_by_batch`,
`db_error = canceling statement due to statement timeout`, **`pg_code = 57014`**.

`57014` is Postgres's *query cancelled* code. It tells you these are not connection failures,
auth errors, or crashes — the query itself is too slow. Two more useful views:

```logql
{job="demoapp", level="warn", route="/order"} | json      # the healthy route, gone slow
sum by (route) (count_over_time({job="demoapp", level="error"}[5m]))
```

> **Checkpoint:** you know the name of the query that is timing out.

### 3d. Root cause — the query plan

You now have a named query. Ask the database how it runs it:

```bash
./demo.sh status
```

The **fault query plan** section shows `EXPLAIN` for the report query. Look for
`Seq Scan on order_items` — Postgres is reading all 1.25M rows to find the ~1,250 that match
`batch = '42'`. The **order_items indexes** section confirms there is no index on `batch`.

Under load, dozens of concurrent full-table scans saturate the CPU. Everything else you saw —
latency, timeouts, 500s, connection pile-up, the starved `/order` route — follows from that.

If your stack has Grafana Assistant, this is a good moment to ask it *"why is CPU high on this
Supabase project?"* and compare its answer with yours.

> **Checkpoint:** you can state the root cause and the fix in one line each.

---

## Part 4 — Fix it and watch it recover (10 min)

The fix is a single index. Apply it:

```bash
./demo.sh remediate
```

Note two things about *how* this runs:

- It takes **~30 s**, because `CREATE INDEX` is competing with a database pinned at 100% CPU.
  The terminal is not hung.
- It is executed over the connection `fixd` has been holding since Part 0. Try to understand
  why that matters: at peak, the fault has consumed every available connection slot. A *new*
  connection to run the fix would be refused (`remaining connection slots are reserved…`),
  and no slot frees up while the fault keeps running. Holding a connection *before* an
  incident is a real operational pattern; `app/fixd.js` has the details.

Now watch the recovery, in this order:

1. **App dashboard, immediately:** `/report` p95 drops from ~3 s to ~50 ms, the 5xx rate
   goes to 0, and `/order` throughput comes back — *under the same 30 rps of report
   traffic*. Nothing about the load changed; each query just became ~100× cheaper.
2. **DB dashboard, over the next few minutes:** CPU falls, connections drain, query time
   drops. CPU lags because of the ~60 s scrape interval and the `[5m]` rate window.
3. **Alert:** resolves a few minutes after CPU falls below the threshold.

Re-run `./demo.sh status`: the plan now says `Index Scan` (or `Bitmap Index Scan`) using
`idx_oi_batch`.

> **Checkpoint:** you can explain why the app recovered instantly while the CPU graph took
> minutes to agree.

---

## Part 5 — Clean up / reset (2 min)

Stop the report traffic:

```bash
./demo.sh app-fault-stop
```

To run the lab again from scratch, drop the index so the fault hook is back:

```bash
./demo.sh unremediate
```

Give the Supabase instance and the EC2 host ~30 minutes before the next run — both are
burstable and a drained CPU-credit balance makes the baseline look erratic.

---

## What you worked through

- An **alert** paged you on a database signal before any user reported a problem.
- The **app dashboard** showed the user impact and the blast radius onto an unrelated route.
- The **DB dashboard** showed the database was CPU-bound and up-but-struggling.
- **Logs** named the query and the exact failure mode (`57014`, statement timeout).
- `EXPLAIN` gave the root cause: a sequential scan on an un-indexed, selective column.
- One index fixed it, and the dashboards showed the recovery propagating layer by layer.

## Things that catch people out

- **The red RAM gauge.** ~95% is normal Postgres behaviour. If you went there first, note how
  the OOM Killer panel (flat) would have ruled it out.
- **CPU is a lagging signal.** Lead on app latency when judging whether a fix worked.
- **Pushing the load higher** (`M_FAULT` past ~14) hits the pooler's session cap and produces
  `EMAXCONNSESSION` — a genuine connection-exhaustion error, but a different incident.
- **`demo.sh remediate` failing with a connection error** means `fixd` wasn't running before
  the fault. Stop the fault, `./demo.sh fixd-start`, and start again.
