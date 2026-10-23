#!/usr/bin/env bash
# Install or update the demo app + Alloy on the EC2 host.
#
# Ships everything the host needs and then runs app/deploy/bootstrap.sh there:
#   - the Node app (server.js, loadgen.js, fixd.js, fix.js, hog.js) and its package.json
#   - systemd units + Alloy config template
#   - /opt/demoapp/app.env         SB_REF / SB_TARGET / PGHOST / PGPORT for the services
#   - /opt/demoapp/secrets/pw_*    the Supabase DB password the app connects with
#   - /opt/demoapp/grafana_cloud_push.env   remote_write credentials for Alloy
#
# Safe to re-run: bootstrap.sh is idempotent (dnf/npm no-op once satisfied), so this is
# also how you ship any later change. Reads .env from the repo root (see .env.example).
#
# Usage: ./deploy.sh [--dry-run | --alloy-only]
#
#   --alloy-only  ships just the Alloy config and push credentials and restarts Alloy.
#                 Leaves the app and its services untouched, so it is safe to run while
#                 a demo depends on the app staying up.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env, filling in only variables that are not already set (see demo.sh).
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

SECRETS="${SECRETS_DIR:-$HERE/secrets}"
case "$SECRETS" in /*) ;; *) SECRETS="$HERE/${SECRETS#./}" ;; esac

EC2_HOST="${EC2_HOST:?set EC2_HOST, e.g. ec2-user@203.0.113.10 - see .env.example}"
EC2_KEY="${EC2_KEY:-$SECRETS/ec2_key.pem}"
case "$EC2_KEY" in /*) ;; *) EC2_KEY="$HERE/${EC2_KEY#./}" ;; esac
APPDIR=/opt/demoapp
STAGE=/tmp/demoapp-stage
SSH_OPTS=(-i "$EC2_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

DRY_RUN=0
ALLOY_ONLY=0
case "${1:-}" in
  --dry-run)    DRY_RUN=1 ;;
  --alloy-only) ALLOY_ONLY=1 ;;
  "")           ;;
  *) echo "unknown option: $1 (use --dry-run or --alloy-only)" >&2; exit 1 ;;
esac

# ---- which Supabase project the host should talk to --------------------------------
SB_TARGET="${SB_TARGET:-prebaked}"
case "$SB_TARGET" in
  prebaked) SB_REF="${SB_REF_PREBAKED:?set SB_REF_PREBAKED in .env}" ;;
  live)     SB_REF="${SB_REF_LIVE:?set SB_REF_LIVE in .env}" ;;
  *) echo "SB_TARGET must be prebaked or live (got: $SB_TARGET)" >&2; exit 1 ;;
esac
PW_FILE="$SECRETS/pw_$SB_TARGET"
[[ -f "$PW_FILE" ]] || { echo "missing DB password file: $PW_FILE (see README: Setup)" >&2; exit 1; }
[[ -f "$EC2_KEY" ]]  || { echo "missing EC2 key: $EC2_KEY" >&2; exit 1; }

# ---- Grafana Cloud push credentials ------------------------------------------------
# Either a ready-made secrets/grafana_cloud_push.env, or the six GCLOUD_* values from
# .env, rendered to a temp file. Fail locally rather than halfway through a remote run.
PUSH_VARS=(GCLOUD_PROM_URL GCLOUD_PROM_USER GCLOUD_PROM_PASS
           GCLOUD_LOKI_URL GCLOUD_LOKI_USER GCLOUD_LOKI_PASS)
TMPFILES=(); trap 'rm -f ${TMPFILES[@]+"${TMPFILES[@]}"}' EXIT   # only files we generated, never secrets/
ENV_FILE="$SECRETS/grafana_cloud_push.env"
if [[ -f "$ENV_FILE" ]]; then
  for v in "${PUSH_VARS[@]}"; do
    grep -q "^$v=." "$ENV_FILE" || { echo "ERROR: $v missing or empty in $ENV_FILE" >&2; exit 1; }
  done
else
  for v in "${PUSH_VARS[@]}"; do
    [[ -n "${!v:-}" ]] || { echo "ERROR: $v not set. Fill it in .env or create $ENV_FILE" >&2; exit 1; }
    case "${!v}" in *your_*|*XX*) echo "ERROR: $v still has the placeholder from .env.example" >&2; exit 1 ;; esac
  done
  ENV_FILE="$(mktemp)"; TMPFILES+=("$ENV_FILE")
  for v in "${PUSH_VARS[@]}"; do printf '%s=%s\n' "$v" "${!v}"; done > "$ENV_FILE"
fi
echo "== local checks passed: target=$SB_TARGET ref=$SB_REF, password file + six push variables present =="

# ---- app.env: what the systemd units need beyond the baked-in defaults --------------
APP_ENV="$(mktemp)"; TMPFILES+=("$APP_ENV")
{
  echo "SB_TARGET=$SB_TARGET"
  echo "SB_REF=$SB_REF"
  echo "PGHOST=${PGHOST:-aws-0-us-east-1.pooler.supabase.com}"
  echo "PGPORT=${PGPORT:-5432}"
  for v in PG_POOL_MAX STMT_TIMEOUT_MS TIGHT_TIMEOUT_MS TIGHT_TIMEOUT_PATHS INIT_ERROR_ROUTES \
           LOG_SAMPLE_N LOG_SLOW_MS FIXD_PORT; do
    [[ -n "${!v:-}" ]] && echo "$v=${!v}"
  done
} > "$APP_ENV"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "-- dry run: would copy --"
  echo "   app/*.js app/fix.sh app/package.json  -> $APPDIR/"
  echo "   app/deploy/*                           -> $APPDIR/deploy/"
  echo "   (generated app.env)                    -> $APPDIR/app.env"
  echo "   $PW_FILE  -> $APPDIR/secrets/pw_$SB_TARGET  (0600 ec2-user)"
  echo "   $ENV_FILE -> $APPDIR/grafana_cloud_push.env (0600 root)"
  echo "   then run $APPDIR/deploy/bootstrap.sh on $EC2_HOST"
  echo "-- app.env --"; cat "$APP_ENV"
  exit 0
fi

chmod 600 "$EC2_KEY"

if [[ $ALLOY_ONLY -eq 1 ]]; then
  echo "== alloy-only: shipping config + credentials, restarting Alloy only =="
  ssh "${SSH_OPTS[@]}" "$EC2_HOST" "rm -rf $STAGE && mkdir -p $STAGE"
  scp "${SSH_OPTS[@]}" -q \
    "$HERE/app/deploy/config.alloy.tmpl" "$HERE/app/deploy/render-alloy.sh" \
    "$EC2_HOST:$STAGE/"
  scp "${SSH_OPTS[@]}" -q "$ENV_FILE" "$EC2_HOST:$STAGE/grafana_cloud_push.env"
  # Deliberately not bootstrap.sh: that restarts demoapp and may enable loadgen. The render
  # runs from a script under sudo because the credentials file is 0600 root-owned and
  # cannot be sourced as ec2-user.
  ssh "${SSH_OPTS[@]}" "$EC2_HOST" "
    set -euo pipefail
    sudo mkdir -p $APPDIR/deploy
    sudo cp $STAGE/config.alloy.tmpl $APPDIR/deploy/config.alloy.tmpl
    sudo cp $STAGE/render-alloy.sh $APPDIR/deploy/render-alloy.sh
    sudo cp $STAGE/grafana_cloud_push.env $APPDIR/grafana_cloud_push.env
    sudo chown root:root $APPDIR/grafana_cloud_push.env
    sudo chmod 600 $APPDIR/grafana_cloud_push.env
    rm -rf $STAGE
    sudo bash $APPDIR/deploy/render-alloy.sh
  "
  echo
  echo "Give Alloy ~60s, then verify in Grafana Cloud: run LogQL \`{job=\"demoapp\"}\` in Explore."
  echo "Expect journal lines under job=demoapp. Per-request JSON needs server.js, which"
  echo "this mode intentionally did not deploy."
  exit 0
fi

echo "== staging files on $EC2_HOST =="
ssh "${SSH_OPTS[@]}" "$EC2_HOST" "rm -rf $STAGE && mkdir -p $STAGE/deploy $STAGE/secrets"
scp "${SSH_OPTS[@]}" -q \
  "$HERE"/app/*.js "$HERE/app/fix.sh" "$HERE/app/package.json" \
  "$EC2_HOST:$STAGE/"
scp "${SSH_OPTS[@]}" -q "$HERE/app/deploy/"* "$EC2_HOST:$STAGE/deploy/"
scp "${SSH_OPTS[@]}" -q "$APP_ENV" "$EC2_HOST:$STAGE/app.env"
# Credentials go over the same authenticated channel. The DB password must be readable by
# ec2-user (the services run as that user); the push creds are root-only (read by Alloy's
# render step under sudo).
scp "${SSH_OPTS[@]}" -q "$PW_FILE" "$EC2_HOST:$STAGE/secrets/pw_$SB_TARGET"
scp "${SSH_OPTS[@]}" -q "$ENV_FILE" "$EC2_HOST:$STAGE/grafana_cloud_push.env"

echo "== installing into $APPDIR and bootstrapping =="
ssh "${SSH_OPTS[@]}" "$EC2_HOST" "
  set -euo pipefail
  sudo mkdir -p $APPDIR/deploy $APPDIR/secrets
  sudo cp $STAGE/*.js $STAGE/fix.sh $STAGE/package.json $APPDIR/
  sudo cp $STAGE/deploy/* $APPDIR/deploy/
  sudo cp $STAGE/app.env $APPDIR/app.env
  sudo cp $STAGE/secrets/pw_$SB_TARGET $APPDIR/secrets/pw_$SB_TARGET
  sudo cp $STAGE/grafana_cloud_push.env $APPDIR/grafana_cloud_push.env
  sudo chown -R ec2-user:ec2-user $APPDIR
  sudo chmod 700 $APPDIR/secrets
  sudo chmod 600 $APPDIR/secrets/pw_$SB_TARGET $APPDIR/app.env
  sudo chown root:root $APPDIR/grafana_cloud_push.env
  sudo chmod 600 $APPDIR/grafana_cloud_push.env
  rm -rf $STAGE
  sudo bash $APPDIR/deploy/bootstrap.sh
"

echo
echo "== post-deploy verification =="
ssh "${SSH_OPTS[@]}" "$EC2_HOST" '
  echo "-- services --"
  for u in demoapp fixd loadgen alloy; do printf "%-9s %s\n" "$u" "$(systemctl is-active $u.service)"; done
  echo "-- fixd holding its connection? --"
  curl -s --max-time 10 localhost:8081/status || echo "(fixd not answering yet)"
  echo "-- loki blocks in rendered config --"
  sudo grep -c "^loki\." /etc/alloy/config.alloy || true
  echo "-- alloy errors since restart (empty is good) --"
  sudo journalctl -u alloy -n 40 --no-pager | grep -iE "level=error|unauthorized|status=40[0-9]" | tail -5 || echo "none"
  echo "-- JSON log lines in the last 50 journal entries --"
  sudo journalctl -u demoapp.service -n 50 --no-pager -o cat | grep -c "^{" || true
'

cat <<'NEXT'

Next: give Alloy ~60s, then confirm the lines actually arrived in Grafana Cloud by
running LogQL `{job="demoapp"}` in Explore. A healthy run shows per-request JSON lines
with level=info/warn/error.

If Loki reports zero streams, the credentials are the first thing to check —
GCLOUD_LOKI_USER is the Loki instance id (a short integer from the stack's "Send Logs"
details), which is neither the Prometheus user nor the stack id. A wrong id fails as
a bare 401 in the Alloy journal.

If demoapp is not active: `sudo journalctl -u demoapp -n 30` on the host. The usual
cause is a wrong project ref or password in app.env / secrets/pw_<target>.
NEXT
