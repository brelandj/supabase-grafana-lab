# Supabase ↔ Grafana enablement demo

Live demo kit for showing how the Grafana Cloud integration troubleshoots a Supabase
project problem that native Supabase dashboards struggle with.

## Projects (Supabase, Free tier, us-east-1)

| Name | Ref | Role |
|------|-----|------|
| `grafana-demo-prebaked` | `$SB_REF_PREBAKED` | Connect to Grafana **ahead of the session**; run the fault here so there's history |
| `grafana-demo-live` | `$SB_REF_LIVE` | Connect **live** to show the 1-click flow |

Create both projects in your own Supabase org. Free tier is enough to run this, but note
Free allows only **2 active projects per org** (paused projects don't count). Put each project's
DB password in `secrets/pw_prebaked` / `secrets/pw_live` (gitignored, chmod 600) — they're
resettable from the Supabase dashboard if lost.

## Setup

1. `cp .env.example .env` and fill in your own values — project refs, EC2 host, and
   Grafana Cloud push credentials. `demo.sh` and `deploy.sh` read `.env` automatically
   (anything already exported in your shell wins). Nothing is shared; the repo ships no
   credentials.
2. Create `secrets/` and add your DB passwords (`pw_prebaked`, `pw_live`) and your EC2
   key (`ec2_key.pem`), all `chmod 600`. The whole directory is gitignored.
3. Seed the database: see **Rebuild schema from scratch** below.
4. Launch an EC2 host (Amazon Linux 2023, t3.micro is enough) with ports 22 open to you,
   then `./deploy.sh`. It ships the app, the project ref + DB password for `SB_TARGET`, and
   the Grafana Cloud push credentials, then runs `app/deploy/bootstrap.sh` on the host to
   install Node + Alloy and start the `demoapp`, `fixd`, and `alloy` services.
   `./deploy.sh --dry-run` shows exactly what would be copied.
5. Connect the project to Grafana Cloud from the Supabase dashboard (**Connect to Grafana**).
6. Import `app-dashboard.json` into your stack for the app-side panels.

Required tooling: `psql` (libpq), Node 18+, an SSH key for the EC2 host, and a Grafana
Cloud stack.

## Connectivity

Direct DB host is IPv6-only (won't resolve on the demo laptop). Use the **pooler**:
`aws-0-us-east-1.pooler.supabase.com:5432`, user `postgres.<ref>`, db `postgres`.
`psql` via libpq: `/opt/homebrew/opt/libpq/bin/psql`.

## The scenario: resource cascade

Dataset: `shop` schema (customers 20k, products 2k, orders 500k, order_items 1.25M, events; ~207 MB).
`order_items.batch` is **intentionally un-indexed**. The `/report` query filters on `batch`
(selective, ~1/1000 rows) and forces a full 1.25M-row seq scan; run under concurrency on the nano
instance it saturates CPU/IO → query latency climbs → connections pile up.
**Remediation = `create index on shop.order_items(batch)`.**

**Validated 2026-07-23:** solo fault query ~0.35 s → ~4.5 s under 12 workers (~14×), active
connections 1→14. The Supabase **pooler session pool caps at 15 connections**, so defaults are
`M_FAULT=12` / `N_BASELINE=2` (keep `N_BASELINE + M_FAULT + 1 ≤ 15`; higher counts trigger
`EMAXCONNSESSION`).

Why it favors Grafana over native Supabase dashboards: cross-signal correlation on one timeline,
long retention, and alerting — all weak spots of the built-in siloed widgets.

## Logs → Loki

Gives the cascade a second signal on the same timeline, so you can walk from metrics into logs
without leaving the dashboard — useful for live demos and for any agent that has to pivot from
metrics to logs during an incident.

`app/server.js` writes one JSON line per interesting request to stdout; systemd captures it and Alloy
ships the journal to Loki. Volume is deliberately controlled: baseline load runs ~60 rps, so healthy
requests are sampled 1-in-`LOG_SAMPLE_N` (default 50), while **all** 5xx and all requests slower than
`LOG_SLOW_MS` (default 1000 ms) are always logged. `/metrics` and `/healthz` are excluded.

A timed-out report query looks like this — `pg_code` `57014` is the signal that identifies it as a
slow query rather than a connectivity fault:

```json
{"ts":"...","level":"error","msg":"request failed","method":"GET","route":"/report",
 "status":500,"duration_ms":3004,"query":"report_revenue_by_batch",
 "db_error":"canceling statement due to statement timeout","pg_code":"57014"}
```

Labels are kept low-cardinality (`job`, `instance`, `unit`, `level`, `route`); everything else stays a
field. Useful queries:

```logql
{job="demoapp", level="error"} | json                      # the fault
{job="demoapp", level="warn", route="/order"} | json        # blast radius: healthy route gone slow
sum by (route) (count_over_time({job="demoapp", level="error"}[5m]))
{job="demoapp"} | json | pg_code = "57014"                  # statement timeouts specifically
```

**Loki push credentials are required alongside the Prometheus ones.** Set them in `.env`
(`GCLOUD_LOKI_URL`, `GCLOUD_LOKI_USER`, `GCLOUD_LOKI_PASS`) — or, if you prefer to keep them
out of `.env`, in `secrets/grafana_cloud_push.env` with all six `GCLOUD_*` values; `deploy.sh`
uses that file when it exists. Both `deploy.sh` and `bootstrap.sh` fail loudly if any are
missing, because `envsubst` would otherwise render a config that starts fine and silently
pushes nothing.

Two host-level gotchas, both handled in `bootstrap.sh` but worth knowing if you debug by hand:

- Alloy runs as its own user and **cannot read the journal** without being in the `systemd-journal`
  group.
- Alloy's config uses `stage.timestamp` to take the app's own `ts` field, so log and metric spikes
  align exactly. Without it, ingestion time drifts and the correlation story falls apart.

`app/deploy/config.alloy.tmpl` is kept in `alloy fmt` canonical form and passes `alloy validate`
(checked against Alloy v1.21.2 with placeholder credentials). If you edit it, re-run both on a
rendered copy before deploying.

## Control script

```bash
# The demo path: fault driven THROUGH the app on EC2 (what RUNOFSHOW.md uses)
./demo.sh fixd-start                        # arm: hold the connection the fix will need
./demo.sh app-fault-start                   # trigger the cascade (~5 min before you present)
./demo.sh remediate      [prebaked|live]    # THE FIX: add index on order_items(batch) -> recovery
./demo.sh app-fault-stop
./demo.sh unremediate    [prebaked|live]    # drop the index again (re-arm for another run)
./demo.sh status         [prebaked|live]    # connections + indexes + EXPLAIN of the fault query

# Direct-to-DB workers from your laptop (bypass the app; handy for testing the schema)
./demo.sh baseline | baseline-stop | fault-start | fault-stop | reset   [prebaked|live]
```
Target defaults to `prebaked`. `./demo.sh help` lists every command and env override.

## Rebuild schema from scratch

```bash
PGPASSWORD="$(cat secrets/pw_prebaked)" /opt/homebrew/opt/libpq/bin/psql \
  -h aws-0-us-east-1.pooler.supabase.com -p 5432 -U "postgres.$SB_REF_PREBAKED" -d postgres \
  -v ON_ERROR_STOP=1 -f schema_seed.sql
```

## Pre-session checklist

Work through these in order, ideally a day or two ahead so the prebaked project has history:

- [ ] Both Supabase projects created; `.env` and `secrets/` filled in (see **Setup**).
- [ ] Schema seeded on the prebaked project (`./demo.sh status` shows a `Seq Scan` plan and no `idx_oi_batch`).
- [ ] EC2 host deployed (`./deploy.sh`); `demoapp`, `fixd`, `alloy` all `active`; `{job="demoapp"}` returns logs in Explore.
- [ ] Prebaked project connected to your Grafana stack via **Connect to Grafana**; the Supabase integration dashboard shows CPU / connections for it.
- [ ] `app-dashboard.json` imported; the four app panels show the baseline load.
- [ ] Alert created on CPU busy ≥ 85% (see RUNOFSHOW.md); fire it once with a rehearsal fault so you know the lead time on your instance.
- [ ] Panel map in PANELS.md checked against what the integration actually provisioned in your stack (panel ids can shift between integration versions).
- [ ] One full rehearsal of RUNOFSHOW.md, then `unremediate` + `app-fault-stop` and let the burstable instances recover CPU credits before the real run.
