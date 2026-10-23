#!/usr/bin/env bash
# Control script for the Supabase <-> Grafana hands-on lab.
# Drives baseline load and the "resource cascade" fault against a demo project.
#
# Connectivity: Supabase direct DB host is IPv6-only; we use the pooler.
#   host=aws-0-us-east-1.pooler.supabase.com port=5432 (session) user=postgres.<ref> db=postgres
#
# Usage: ./demo.sh <command> [prebaked|live]     (target defaults to prebaked)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load .env (copied from .env.example) so SB_REF_*, EC2_HOST, etc. are available.
# Only fills in variables that are not already set, so inline overrides such as
# `M_FAULT=8 ./demo.sh fault-start` still win. Strips `# comments`; values must not contain '#'.
load_env() {
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    eval "[ -z \"\${$key+x}\" ]" && export "$key=$val"
  done < "$1"
}
load_env "$HERE/.env"

# psql: Homebrew libpq on macOS, otherwise whatever is on PATH.
PSQL="${PSQL:-$([ -x /opt/homebrew/opt/libpq/bin/psql ] && echo /opt/homebrew/opt/libpq/bin/psql || echo psql)}"
HOST="${HOST:-${PGHOST:-aws-0-us-east-1.pooler.supabase.com}}"
PORT="${PORT:-${PGPORT:-5432}}"
SECRETS="${SECRETS_DIR:-$HERE/secrets}"
case "$SECRETS" in /*) ;; *) SECRETS="$HERE/${SECRETS#./}" ;; esac
RUNDIR="$HERE/run"; mkdir -p "$RUNDIR"

# project refs resolved per-target below (case), for bash 3.2 compatibility

# tuning (override via env): baseline worker count, fault worker count
# NOTE: Supabase pooler session mode caps at pool_size=15 total connections.
# Keep N_BASELINE + M_FAULT + 1 (observer) <= 15 or the load driver gets EMAXCONNSESSION.
N_BASELINE="${N_BASELINE:-2}"
M_FAULT="${M_FAULT:-12}"

# EC2 running the whole-stack demo app; app-fault-* drive the fault THROUGH the app
EC2_HOST="${EC2_HOST:?set EC2_HOST, e.g. ec2-user@203.0.113.10 - see .env.example}"
EC2_KEY="${EC2_KEY:-$SECRETS/ec2_key.pem}"
APP_FAULT_CONC="${APP_FAULT_CONC:-20}"
# Offered request rate for the fault, in req/s (open loop). Fixed-rate traffic is what
# makes the fix visible on DB CPU: ~30 rps of 1.25M-row seq scans saturates the DB, and
# the same ~30 rps of index lookups is trivial. A closed loop (APP_FAULT_CONC) instead
# accelerates to ~700 rps on recovery and keeps CPU pegged. See app/loadgen.js.
APP_FAULT_RATE="${APP_FAULT_RATE:-30}"
APP_BASELINE_RATE="${APP_BASELINE_RATE:-20}"

# The app serves each endpoint under two names: /report + /order (what LAB.md uses),
# plus /recommendations + /play as aliases if you want to re-skin the scenario for a
# different narrative. The Prometheus `route` label follows whichever path
# is requested, so driving load at the aliases is enough to re-theme the dashboards
# without redeploying:
#   FAULT_PATHS=/recommendations BASELINE_PATHS=/play ./demo.sh app-fault-start
FAULT_PATHS="${FAULT_PATHS:-/report}"
BASELINE_PATHS="${BASELINE_PATHS:-/order}"
APP_BASELINE_CONC="${APP_BASELINE_CONC:-3}"

usage() {
  cat <<U
Usage: $0 <command> [prebaked|live]   (target defaults to prebaked)

  status           connections snapshot + order_items indexes + EXPLAIN of the fault query
  app-fault-start  START THE FAULT: app-driven load on EC2 (loadgen RATE=$APP_FAULT_RATE req/s -> $FAULT_PATHS)
  app-fault-stop   stop the app-driven fault on EC2
  app-baseline-start  themed baseline load -> $BASELINE_PATHS (leaves loadgen.service alone)
  app-baseline-stop   stop the themed baseline
  fixd-start       start/restart the fix daemon (holds a dedicated DB connection) -- run before the fault
  fixd-status      is the connection held? index present? current DB connection count
  remediate        THE FIX: add missing index on order_items(batch) -> query recovers
  unremediate      drop that index (restore the fault hook, for a re-run)
  baseline         start $N_BASELINE local direct-DB steady workers (EC2 baseline already runs; rarely needed)
  baseline-stop    stop local baseline workers
  fault-start      start $M_FAULT local direct-DB fault workers (bypasses the app; use app-fault-start for the lab)
  fault-stop       stop local direct-DB fault workers
  reset            stop local workers, truncate events, drop the batch index (clean baseline)

Env overrides: APP_FAULT_CONC, APP_BASELINE_CONC, FAULT_PATHS, BASELINE_PATHS,
               EC2_HOST, EC2_KEY, N_BASELINE, M_FAULT, PSQL, HOST, PORT

Re-skinned variant (same demo, aliased routes):
  BASELINE_PATHS=/play ./demo.sh app-baseline-start
  FAULT_PATHS=/recommendations ./demo.sh app-fault-start
U
}

cmd="${1:-}"; target="${2:-prebaked}"
case "$target" in
  prebaked) ref="${SB_REF_PREBAKED:?set SB_REF_PREBAKED - see .env.example}" ;;
  live)     ref="${SB_REF_LIVE:?set SB_REF_LIVE - see .env.example}" ;;
  *) echo "unknown target: $target (use prebaked|live)"; exit 1 ;;
esac
pwfile="$SECRETS/pw_$target"; [ -f "$pwfile" ] || { echo "missing password file: $pwfile"; exit 1; }

psql_run() { PGPASSWORD="$(cat "$pwfile")" "$PSQL" -h "$HOST" -p "$PORT" -U "postgres.$ref" -d postgres "$@"; }
# transaction-mode pooler (6543): use for remediate/unremediate so the DDL still connects
# when the session pool (5432) is saturated by the fault ("too many clients already").
psql_tx()  { PGPASSWORD="$(cat "$pwfile")" "$PSQL" -h "$HOST" -p 6543 -U "postgres.$ref" -d postgres "$@"; }

ssh_box() { ssh -i "$EC2_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$EC2_HOST" "$@"; }

# fixd holds ONE dedicated session-mode connection for the whole demo, so the fix can be
# applied even once the cascade has filled every connection slot (max_connections=60, 57
# usable). It MUST be up before the fault starts — grabbing a slot mid-incident is the
# thing that fails ("remaining connection slots are reserved ...").
ensure_fixd() {
  ssh_box 'systemctl is-active --quiet fixd || sudo systemctl start fixd' || return 1
  for _ in 1 2 3 4 5; do
    out=$(ssh_box 'curl -s --max-time 10 localhost:8081/status' 2>/dev/null)
    case "$out" in held=yes*) echo "$out"; return 0 ;; esac
  done
  echo "[warn] fixd is not holding a connection yet"; return 1
}

# the deliberately-expensive query: full seq scan of 1.25M order_items on the UN-indexed batch column
FAULT_SQL="select count(*), coalesce(sum(qty*price),0) from shop.order_items where batch='42';"

baseline_worker() {
  while :; do
    psql_run -qtAc "select id,total from shop.orders where customer_id=$((RANDOM%20000+1)) order by created_at desc limit 20;" >/dev/null 2>&1
    psql_run -qtAc "insert into shop.events(customer_id,type,payload) values ($((RANDOM%20000+1)),'view',jsonb_build_object('p',$((RANDOM%2000+1))));" >/dev/null 2>&1
    sleep 0.3
  done
}
fault_worker() { while :; do psql_run -qtAc "$FAULT_SQL" >/dev/null 2>&1; done }

start_pool() { # <count> <fn> <pidfile>
  : > "$3"
  for _ in $(seq 1 "$1"); do "$2" & echo $! >> "$3"; done
  echo "[$target] started $1 x $2 (pids -> $3)"
}
stop_pool() { # <pidfile>
  [ -f "$1" ] || { echo "[$target] no workers for $(basename "$1")"; return 0; }
  while read -r p; do kill "$p" 2>/dev/null || true; done < "$1"
  rm -f "$1"; echo "[$target] stopped $(basename "$1")"
}

case "$cmd" in
  status)
    echo "== connections =="
    psql_run -c "select count(*) filter (where state='active') as active, count(*) as total, max(now()-query_start) filter (where state='active') as longest_active from pg_stat_activity where datname='postgres';"
    echo "== order_items indexes =="
    psql_run -c "select indexname, indexdef from pg_indexes where schemaname='shop' and tablename='order_items' order by 1;"
    echo "== fault query plan =="
    psql_run -c "explain $FAULT_SQL"
    ;;
  baseline)      start_pool "$N_BASELINE" baseline_worker "$RUNDIR/baseline.$target.pids" ;;
  baseline-stop) stop_pool "$RUNDIR/baseline.$target.pids" ;;
  fault-start)   start_pool "$M_FAULT" fault_worker "$RUNDIR/fault.$target.pids" ;;
  fault-stop)    stop_pool "$RUNDIR/fault.$target.pids" ;;
  app-fault-start)
    # Reserve the fix's connection BEFORE saturating the DB, or the fix cannot be applied.
    ensure_fixd || { echo "[abort] start fixd first (./demo.sh fixd-start) — without a held connection the fix will be refused at peak"; exit 1; }
    ssh_box "sudo systemctl stop faultgen 2>/dev/null; sudo systemd-run --unit=faultgen --setenv=RATE=$APP_FAULT_RATE --setenv=PATHS=$FAULT_PATHS --setenv=APP_URL=http://localhost:8080 /usr/bin/node /opt/demoapp/loadgen.js" \
      && echo "[app] fault STARTED on $EC2_HOST (RATE=$APP_FAULT_RATE req/s -> $FAULT_PATHS)"
    ;;
  fixd-start)  ssh_box 'sudo systemctl enable --now fixd >/dev/null 2>&1; sudo systemctl restart fixd'; ensure_fixd ;;
  fixd-status) ssh_box 'curl -s --max-time 10 localhost:8081/status' ;;
  app-fault-stop)  ssh -i "$EC2_KEY" -o StrictHostKeyChecking=accept-new "$EC2_HOST" "sudo systemctl stop faultgen" && echo "[app] fault stopped" ;;
  # Themed baseline as a transient unit, so loadgen.service keeps its /order default and
  # this demo's scripted numbers are unaffected.
  app-baseline-start) ssh_box "sudo systemctl stop themedbaseline 2>/dev/null; sudo systemd-run --unit=themedbaseline --setenv=RATE=$APP_BASELINE_RATE --setenv=PATHS=$BASELINE_PATHS --setenv=APP_URL=http://localhost:8080 /usr/bin/node /opt/demoapp/loadgen.js" && echo "[app] themed baseline STARTED (RATE=$APP_BASELINE_RATE req/s -> $BASELINE_PATHS)" ;;
  app-baseline-stop)  ssh -i "$EC2_KEY" -o StrictHostKeyChecking=accept-new "$EC2_HOST" "sudo systemctl stop themedbaseline" && echo "[app] themed baseline stopped" ;;
  remediate)
    # THE FIX, applied over the connection fixd has been holding since arm time. Opening
    # a fresh connection here is what used to fail at peak: the fault fills all 57 usable
    # slots, so both local psql and the on-box fix.js get refused. Retrying cannot work
    # because nothing frees a slot while the fault runs.
    if [ "$target" = "prebaked" ]; then
      # The HTTP response is buffered until CREATE INDEX returns, which takes ~30s while
      # the DB is pinned at 100% CPU. Without this line the terminal looks hung.
      echo "[$target] applying fix: CREATE INDEX on shop.order_items(batch)"
      echo "          (~30s - the build is competing with the saturated DB)"
      out=$(ssh_box 'curl -s -S --max-time 240 localhost:8081/fix' 2>&1)
      echo "$out"
      case "$out" in
        *"CREATE INDEX"*) echo "[$target] remediated via held connection -> query recovers" ;;
        *) echo "[warn] fixd path failed; falling back to a fresh connection (may be refused under load)"
           ssh_box "SB_TARGET=$target node /opt/demoapp/fix.js" ;;
      esac
    else
      psql_tx -c "create index if not exists idx_oi_batch on shop.order_items(batch);" \
        && echo "[$target] index on order_items(batch) added -> fault query should recover"
    fi
    ;;
  unremediate)
    if [ "$target" = "prebaked" ]; then
      out=$(ssh_box 'curl -s -S --max-time 60 localhost:8081/unfix' 2>&1)
      case "$out" in
        *"index dropped"*) echo "$out"; echo "[$target] fault hook re-armed" ;;
        *) psql_tx -c "drop index if exists shop.idx_oi_batch;" \
             && echo "[$target] index dropped -> fault hook restored" ;;
      esac
    else
      psql_tx -c "drop index if exists shop.idx_oi_batch;" \
        && echo "[$target] index dropped -> fault hook restored"
    fi
    ;;
  reset)
    stop_pool "$RUNDIR/fault.$target.pids"
    stop_pool "$RUNDIR/baseline.$target.pids"
    psql_run -c "truncate shop.events;" >/dev/null
    psql_run -c "drop index if exists shop.idx_oi_batch;" >/dev/null
    echo "[$target] reset: workers stopped, events truncated, batch index dropped"
    ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; echo; usage; exit 1 ;;
esac
