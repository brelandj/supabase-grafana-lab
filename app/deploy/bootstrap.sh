#!/usr/bin/env bash
# Run on the EC2 host (Amazon Linux 2023) after /opt/demoapp is populated.
# Installs Node + Alloy, deploys the app + baseline load as services, wires remote_write.
set -euo pipefail
APPDIR=/opt/demoapp

echo "== preflight =="
# deploy.sh puts these in place. Without them the services start, throw on a missing
# SB_REF / password file, and crash-loop — check up front so the failure is legible.
[[ -f "$APPDIR/app.env" ]] || { echo "ERROR: $APPDIR/app.env missing (run deploy.sh from the repo)" >&2; exit 1; }
grep -q '^SB_REF=.' "$APPDIR/app.env" || { echo "ERROR: SB_REF not set in $APPDIR/app.env" >&2; exit 1; }
SB_TARGET="$(sed -n 's/^SB_TARGET=//p' "$APPDIR/app.env")"; SB_TARGET="${SB_TARGET:-prebaked}"
[[ -s "$APPDIR/secrets/pw_$SB_TARGET" ]] || { echo "ERROR: $APPDIR/secrets/pw_$SB_TARGET missing or empty" >&2; exit 1; }
[[ -f "$APPDIR/grafana_cloud_push.env" ]] || { echo "ERROR: $APPDIR/grafana_cloud_push.env missing" >&2; exit 1; }

echo "== packages =="
sudo dnf install -y nodejs npm gettext >/dev/null

echo "== alloy =="
sudo rpm --import https://rpm.grafana.com/gpg.key
printf '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=1\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\n' | sudo tee /etc/yum.repos.d/grafana.repo >/dev/null
sudo dnf install -y alloy >/dev/null

echo "== app deps =="
cd "$APPDIR" && npm install --omit=dev >/dev/null

echo "== render alloy config =="
set -a; source "$APPDIR/grafana_cloud_push.env"; set +a
# envsubst substitutes unset variables with an empty string, which yields a config
# that starts cleanly and silently pushes nothing. Fail here instead.
for v in GCLOUD_PROM_URL GCLOUD_PROM_USER GCLOUD_PROM_PASS \
         GCLOUD_LOKI_URL GCLOUD_LOKI_USER GCLOUD_LOKI_PASS; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: $v is not set in grafana_cloud_push.env" >&2
    exit 1
  fi
done
envsubst < "$APPDIR/deploy/config.alloy.tmpl" | sudo tee /etc/alloy/config.alloy >/dev/null
sudo chmod 640 /etc/alloy/config.alloy

# Alloy runs as its own user and cannot read the journal without this.
sudo usermod -a -G systemd-journal alloy

echo "== services =="
sudo cp "$APPDIR/deploy/demoapp.service" "$APPDIR/deploy/fixd.service" \
        "$APPDIR/deploy/loadgen.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable demoapp.service fixd.service
# `enable --now` starts a unit only if it is stopped, so on a host that is already
# running it leaves the old process serving the previous code indefinitely — the new
# server.js sits on disk, inert, and the deploy looks like it succeeded. Restart
# explicitly so shipping an app change actually ships it.
sudo systemctl restart demoapp.service
# fixd must hold its connection BEFORE any fault starts (see fixd.js); bring it up now.
sudo systemctl restart fixd.service

# loadgen drives continuous traffic against Supabase and Grafana Cloud, so a deploy must
# not silently resurrect it once it has been deliberately turned off. Preserve whatever
# state it was in, and require START_LOADGEN=1 to turn it on.
if [ "${START_LOADGEN:-0}" = "1" ]; then
  sudo systemctl enable --now loadgen.service
  sudo systemctl restart loadgen.service
elif systemctl is-active --quiet loadgen.service; then
  sudo systemctl restart loadgen.service   # already running: pick up the new code
else
  echo "loadgen left stopped (START_LOADGEN=1 to start it)"
fi
sudo systemctl restart alloy
# Node needs a moment before /healthz answers; without this the check below can fail
# on a perfectly good deploy.
sleep 3
sleep 2
echo "== status =="
systemctl is-active demoapp.service fixd.service loadgen.service alloy || true
curl -s localhost:8080/healthz && echo
echo "== routes =="
# Proves the running process is the code we just copied, rather than a stale one.
curl -s localhost:8080/ && echo

echo "== log pipeline =="
# Confirm the app is actually emitting JSON; an empty result here means Loki will
# receive nothing useful no matter how the Alloy side is configured. Healthy requests
# are sampled 1-in-LOG_SAMPLE_N, so generate enough traffic to clear the sampler.
for _ in $(seq 1 60); do curl -s -o /dev/null localhost:8080/order; done
journalctl -u demoapp.service -n 40 --no-pager -o cat | grep -c '^{' \
  | xargs -I{} echo "json log lines in last 40 journal entries: {}"
echo "bootstrap complete"
