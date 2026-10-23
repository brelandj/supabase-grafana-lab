#!/usr/bin/env bash
# Render /etc/alloy/config.alloy from the template and restart Alloy. Nothing else.
#
# Split out of bootstrap.sh so the Alloy pipeline can be updated without restarting
# demoapp or enabling loadgen — necessary when another demo depends on the app
# staying up. Must run as root: grafana_cloud_push.env is 0600 root-owned.
set -euo pipefail
APPDIR=/opt/demoapp

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)" >&2; exit 1; }

set -a; source "$APPDIR/grafana_cloud_push.env"; set +a

# envsubst turns unset variables into empty strings, producing a config that starts
# cleanly and silently pushes nothing. Fail here instead.
for v in GCLOUD_PROM_URL GCLOUD_PROM_USER GCLOUD_PROM_PASS \
         GCLOUD_LOKI_URL GCLOUD_LOKI_USER GCLOUD_LOKI_PASS; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: $v is not set in $APPDIR/grafana_cloud_push.env" >&2
    exit 1
  fi
done

envsubst < "$APPDIR/deploy/config.alloy.tmpl" > /etc/alloy/config.alloy
chmod 640 /etc/alloy/config.alloy

# Alloy runs as its own user and reads nothing from the journal without this. It logs a
# permissions warning rather than failing, so a missing group looks like "no logs".
usermod -a -G systemd-journal alloy

systemctl restart alloy
sleep 5

echo "-- alloy: $(systemctl is-active alloy) --"
echo "-- loki blocks rendered: $(grep -c '^loki\.' /etc/alloy/config.alloy) --"
echo "-- errors in the last minute (none is good) --"
# Anchored on real signals. A bare '401' also matches nanosecond timestamps such as
# .04011756Z, which reports a scary-looking failure on a perfectly healthy restart.
journalctl -u alloy --since '-1min' --no-pager \
  | grep -iE 'level=error|status=40[0-9]|unauthorized|permission denied|failed to (send|push)' \
  | tail -8 || echo "none"
