#!/usr/bin/env bash
# Push the local app + Alloy config to the EC2 demo host and re-bootstrap it.
#
# Needed because the host was provisioned before the log pipeline existed: it still
# runs a metrics-only Alloy config, a server.js with no structured logging, and an
# env file with no Loki credentials. Everything to fix that is already in this repo.
#
# Safe to re-run. bootstrap.sh is idempotent — the dnf and npm steps no-op once
# satisfied — so this is also the way to ship any later app change.
#
# Usage: ./deploy.sh [--dry-run | --alloy-only]
#
#   --alloy-only  ships just the Alloy config and push credentials and restarts Alloy.
#                 Leaves server.js, loadgen, and demoapp.service untouched, so it is
#                 safe to run while another demo depends on the app staying up. Note
#                 the app's structured JSON logging lives in server.js, so this alone
#                 gets journal lines into Loki but not per-request logs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EC2_HOST="${EC2_HOST:?set EC2_HOST, e.g. ec2-user@203.0.113.10 - see .env.example}"
EC2_KEY="${EC2_KEY:-$HERE/secrets/ec2_key.pem}"
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

ENV_FILE="$HERE/secrets/grafana_cloud_push.env"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE" >&2; exit 1; }

# Fail locally rather than halfway through a remote bootstrap.
for v in GCLOUD_PROM_URL GCLOUD_PROM_USER GCLOUD_PROM_PASS \
         GCLOUD_LOKI_URL GCLOUD_LOKI_USER GCLOUD_LOKI_PASS; do
  grep -q "^$v=." "$ENV_FILE" || { echo "ERROR: $v missing or empty in secrets/grafana_cloud_push.env" >&2; exit 1; }
done
echo "== local checks passed: all six push variables present =="

if [[ $DRY_RUN -eq 1 ]]; then
  echo "-- dry run: would copy --"
  echo "   app/server.js app/loadgen.js app/package.json  -> $APPDIR/"
  echo "   app/deploy/*                                   -> $APPDIR/deploy/"
  echo "   secrets/grafana_cloud_push.env                  -> $APPDIR/grafana_cloud_push.env"
  echo "   then run $APPDIR/deploy/bootstrap.sh on $EC2_HOST"
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
  # Deliberately not bootstrap.sh: that restarts demoapp and enables loadgen. The render
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
ssh "${SSH_OPTS[@]}" "$EC2_HOST" "rm -rf $STAGE && mkdir -p $STAGE/deploy"
scp "${SSH_OPTS[@]}" -q \
  "$HERE/app/server.js" "$HERE/app/loadgen.js" "$HERE/app/package.json" \
  "$EC2_HOST:$STAGE/"
scp "${SSH_OPTS[@]}" -q "$HERE/app/deploy/"* "$EC2_HOST:$STAGE/deploy/"
# Credentials go over the same authenticated channel and land 0600, root-owned.
scp "${SSH_OPTS[@]}" -q "$ENV_FILE" "$EC2_HOST:$STAGE/grafana_cloud_push.env"

echo "== installing into $APPDIR and re-bootstrapping =="
ssh "${SSH_OPTS[@]}" "$EC2_HOST" "
  set -euo pipefail
  sudo mkdir -p $APPDIR/deploy
  sudo cp $STAGE/server.js $STAGE/loadgen.js $STAGE/package.json $APPDIR/
  sudo cp $STAGE/deploy/* $APPDIR/deploy/
  sudo cp $STAGE/grafana_cloud_push.env $APPDIR/grafana_cloud_push.env
  sudo chown root:root $APPDIR/grafana_cloud_push.env
  sudo chmod 600 $APPDIR/grafana_cloud_push.env
  rm -rf $STAGE
  sudo bash $APPDIR/deploy/bootstrap.sh
"

echo
echo "== post-deploy verification =="
ssh "${SSH_OPTS[@]}" "$EC2_HOST" '
  echo "-- services --"
  for u in demoapp loadgen alloy; do printf "%-9s %s\n" "$u" "$(systemctl is-active $u.service)"; done
  echo "-- loki blocks in rendered config --"
  sudo grep -c "^loki\." /etc/alloy/config.alloy || true
  echo "-- alloy errors since restart (empty is good) --"
  sudo journalctl -u alloy -n 40 --no-pager | grep -iE "level=error|invalid|unauthorized|401" | tail -5 || echo "none"
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
NEXT
