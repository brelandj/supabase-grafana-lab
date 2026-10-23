# Run-of-show panel map — "Supabase Project" dashboard

Stack: `https://<your-stack>.grafana.net` · Dashboard uid: whatever the 1-click integration provisions in your stack
Vars: `$job`, `$project` = `supabase_project_ref` (your project ref), `$supabase_identifier`.

## The cascade, in the order to click through

**1. Root cause — CPU pegs**
- `[77] CPU Basic` (timeseries) — `rate(node_cpu_seconds_total{mode="system|user|iowait",...})*100`. **Headline** — climbs to ~100% under the fault.
- `[20] CPU Busy` (gauge) — `clamp_min(100 - avg(rate(node_cpu_seconds_total{mode="idle"}))*100,0)`. At-a-glance opener.

**2. Connection pile-up**
- `[323] Client connections` (timeseries):
  - `pg_stat_database_num_backends` → **"postgres connections"** — climbs toward the pool ceiling (~15).
  - `sum(supavisor_connections_active)` / `pgbouncer_used_clients` → pooler activity / clients waiting = queuing.
  - **This is the money panel for "connections piling up."**

**3. Query impact**
- `[330] Query stats` (timeseries):
  - `rate(supabase_usage_metrics_user_queries_total[...])` — query volume.
  - `rate(pg_stat_statements_total_time_seconds[...])` — **total query time rising = latency climbing.**
- `[342] pg stats` — Tx committed rate (throughput dips as the DB chokes).

**4. Supporting IO**
- `[152] Disk Space Used, EBS IO Balance`, `[229] Disk IOps` — `rate(node_disk_reads_completed_total[...])` from seq scans.

**5. Health / context (stay green — "up but struggling")**
- `[319] Postgres status` (`pg_up`), `[341] pgbouncer status` (`pgbouncer_up`), `[324] DB Mode` (ReadWrite), `[325] In Recovery` (No), `[307] OOM Killer` (flat — CPU-bound, not memory).
- `[321] Database size` (`pg_database_size_mb`) — ~207 MB confirms it's the prebaked project.

## Remediation beat
`./demo.sh remediate prebaked` → `create index on orders(status)`. Then watch `[77] CPU Basic` drop, `[323] Client connections` drain, `[330] Query stats` total-time fall. Story closes.

## Don't-get-fooled notes
- The **RAM Used gauge (~95%, red)** is NORMAL for Postgres (shared buffers/cache) — not the problem.
- Connection numbers cap ~15 (pooler session `pool_size`); push `M_FAULT` past ~14 and you also get `EMAXCONNSESSION` (a real connection-exhaustion error you can show as an aside).
