#!/usr/bin/env bash
# Interactively configures email alerting on a Harvester cluster that runs the
# rancher-monitoring add-on. Run it where kubectl works (a Harvester node, or
# the UI's Kubectl Shell).
#
#   MODE 1 (recommended): global Alertmanager config, set through the add-on
#          values. Matches alerts from every namespace (PVC alerts included).
#   MODE 2: a namespaced AlertmanagerConfig object. Only matches alerts that
#          carry namespace=cattle-monitoring-system (node alerts), see the guide.
#
# Usage: ./harvester-alert-email.sh [--dry-run]
#   --dry-run  sends every change with --dry-run=server: validated by the API
#              server, nothing is stored.
set -euo pipefail

NS="cattle-monitoring-system"
ADDON="rancher-monitoring"
CFG_NAME="capacity-email"
SECRET_NAME="smtp-auth"
DRY=()
[[ ${1:-} == "--dry-run" ]] && DRY=(--dry-run=server)

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "Namespace $NS not found; is the $ADDON add-on enabled?" >&2; exit 1; }
[[ ${#DRY[@]} -gt 0 ]] && echo "*** DRY RUN: nothing will be stored ***"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ask VAR "Prompt" [default]
ask() {
  local var=$1 prompt=$2 def=${3:-} val
  while :; do
    if [[ -n $def ]]; then read -r -p "$prompt [$def]: " val; val=${val:-$def}
    else read -r -p "$prompt: " val; fi
    [[ -n $val ]] && break
    echo "  value required"
  done
  printf -v "$var" '%s' "$val"
}
dq() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }   # YAML double-quoted
sq() { printf '%s' "${1//\'/\'\'}"; }                         # YAML single-quoted

echo "== Harvester Alertmanager email setup =="
echo "1) Global config in the add-on values (recommended)"
echo "2) Namespaced AlertmanagerConfig object"
ask MODE "Mode" "1"
[[ $MODE == 1 || $MODE == 2 ]] || { echo "Mode must be 1 or 2" >&2; exit 1; }

ask SMTP_HOST "SMTP server host" "smtp.example.com"
ask SMTP_PORT "SMTP server port" "587"
ask FROM      "Sender (From) address"
ask TO        "Recipient address(es), comma separated"
read -r -p "SMTP username (empty = no auth): " SMTP_USER
SMTP_PASS=""
if [[ -n $SMTP_USER ]]; then read -r -s -p "SMTP password: " SMTP_PASS; echo; fi
read -r -p "Require TLS (STARTTLS)? [Y/n]: " TLS; TLS=${TLS:-Y}
[[ $TLS =~ ^[Yy] ]] && REQUIRE_TLS=true || REQUIRE_TLS=false
ask REPEAT "Repeat interval for unresolved alerts" "4h"
ask ALERTS "Alert names to email (regex)" "KubePersistentVolume.*|NodeFilesystem.*|KubeCPUOvercommit|KubeMemoryOvercommit|NodeMemoryHighUtilization|CustomStorageCapacity.*"
read -r -p "Also add Longhorn disk usage alerts (80% warn / 90% crit)? [Y/n]: " LH; LH=${LH:-Y}

RCPTS=()
IFS=',' read -ra _r <<< "$TO"
for r in "${_r[@]}"; do r=$(echo "$r" | xargs); [[ -n $r ]] && RCPTS+=("$r"); done
[[ ${#RCPTS[@]} -gt 0 ]] || { echo "No recipient given" >&2; exit 1; }

echo
echo "Summary: mode $MODE | smtp $SMTP_HOST:$SMTP_PORT | from $FROM | to ${RCPTS[*]} | auth ${SMTP_USER:-none} | tls $REQUIRE_TLS"
read -r -p "Proceed? [Y/n]: " OK; OK=${OK:-Y}
[[ $OK =~ ^[Yy] ]] || { echo "Aborted."; exit 1; }

# ---------------------------------------------------------------- mode 1
apply_global() {
  local blk=$TMP/block.yaml cur=$TMP/values.yaml new=$TMP/values.new
  {
    echo "  config:"
    echo "    global:"
    echo "      resolve_timeout: 5m"
    echo "      smtp_smarthost: \"$(dq "$SMTP_HOST"):$SMTP_PORT\""
    echo "      smtp_from: \"$(dq "$FROM")\""
    if [[ -n $SMTP_USER ]]; then
      echo "      smtp_auth_username: \"$(dq "$SMTP_USER")\""
      echo "      smtp_auth_password: '$(sq "$SMTP_PASS")'"
    fi
    echo "      smtp_require_tls: $REQUIRE_TLS"
    echo "    route:"
    echo "      receiver: \"null\""
    echo "      group_by: [alertname, namespace]"
    echo "      routes:"
    echo "        - receiver: \"null\""
    echo "          matchers: ['alertname=~\"Watchdog|InfoInhibitor\"']"
    echo "        - receiver: email-ops"
    echo "          repeat_interval: $REPEAT"
    echo "          matchers: ['alertname=~\"$(sq "$(dq "$ALERTS")")\"']"
    echo "    receivers:"
    echo "      - name: \"null\""
    echo "      - name: email-ops"
    echo "        email_configs:"
    for r in "${RCPTS[@]}"; do
      echo "          - to: \"$(dq "$r")\""
      echo "            send_resolved: true"
    done
  } > "$blk"

  kubectl -n "$NS" get addons.harvesterhci.io "$ADDON" -o jsonpath='{.spec.valuesContent}' > "$cur"
  [[ -s $cur ]] || { echo "Add-on $ADDON has no valuesContent; aborting" >&2; exit 1; }
  local backup="./addon-${ADDON}-values.backup.$(date +%Y%m%d-%H%M%S).yaml"
  cp "$cur" "$backup"; echo "Backed up current add-on values to $backup"

  if awk '/^alertmanager:/{a=1;next} a&&/^[^ #]/{a=0} a&&/^  config:/{c=1} END{exit !c}' "$cur"; then
    echo "NOTE: the add-on already has an alertmanager.config; it will be REPLACED (backup above)."
  fi

  # replace (or insert) alertmanager.config inside the top-level alertmanager: block
  awk -v bf="$blk" '
    BEGIN { while ((getline l < bf) > 0) blk = blk l "\n" }
    /^alertmanager:/ { seen=1; inam=1; print; next }
    inam && /^[^ #]/ { if (!done) { printf "%s", blk; done=1 } inam=0 }
    inam && /^  config:/ { skip=1; printf "%s", blk; done=1; next }
    skip { if ($0 ~ /^    / || $0 ~ /^[ ]*$/) next; skip=0 }
    { print }
    END { if (inam && !done) printf "%s", blk
          if (!seen) { print "alertmanager:"; printf "%s", blk } }
  ' "$cur" > "$new"

  # JSON-encode the new values and patch the add-on
  awk 'BEGIN{printf "{\"spec\":{\"valuesContent\":\""}
       { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); printf "%s\\n", $0 }
       END{printf "\"}}"}' "$new" > "$TMP/patch.json"
  kubectl -n "$NS" patch addons.harvesterhci.io "$ADDON" --type merge --patch-file "$TMP/patch.json" "${DRY[@]}"
  echo "Add-on patched. It redeploys in a minute or two; check Advanced -> Addons -> $ADDON."
}

# ---------------------------------------------------------------- mode 2
apply_namespaced() {
  if [[ -n $SMTP_USER ]]; then
    kubectl -n "$NS" create secret generic "$SECRET_NAME" \
      --from-literal=password="$SMTP_PASS" --dry-run=client -o yaml | kubectl apply -f - "${DRY[@]}"
  fi
  local cfgs=""
  for r in "${RCPTS[@]}"; do
    cfgs+="
        - to: \"$(dq "$r")\"
          from: \"$(dq "$FROM")\"
          smarthost: \"$(dq "$SMTP_HOST"):$SMTP_PORT\"
          requireTLS: $REQUIRE_TLS
          sendResolved: true"
    if [[ -n $SMTP_USER ]]; then
      cfgs+="
          authUsername: \"$(dq "$SMTP_USER")\"
          authPassword:
            name: $SECRET_NAME
            key: password"
    fi
  done
  kubectl apply -f - "${DRY[@]}" <<EOF
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: $CFG_NAME
  namespace: $NS
spec:
  route:
    receiver: email-ops
    groupBy: [alertname]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: $REPEAT
    matchers:
      - name: alertname
        matchType: =~
        value: "$(dq "$ALERTS")"
  receivers:
    - name: email-ops
      emailConfigs:$cfgs
EOF
  echo "NOTE: namespaced configs only match alerts labelled namespace=$NS (e.g. NodeFilesystem*)."
  echo "      PVC alerts (KubePersistentVolume*) need mode 1, or alertmanagerConfigMatcherStrategy.type=None."
}

# ---------------------------------------------------------------- rule
apply_rule() {
  kubectl apply -f - "${DRY[@]}" <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: harvester-capacity
  namespace: $NS
  labels:
    release: rancher-monitoring
spec:
  groups:
    - name: harvester-capacity
      rules:
        - alert: CustomStorageCapacityWarning
          expr: (longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes) > 0.80
          for: 10m
          labels: {severity: warning}
          annotations:
            summary: "Longhorn disk {{ \$labels.disk }} on {{ \$labels.node }} above 80%"
        - alert: CustomStorageCapacityCritical
          expr: (longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes) > 0.90
          for: 5m
          labels: {severity: critical}
          annotations:
            summary: "Longhorn disk {{ \$labels.disk }} on {{ \$labels.node }} above 90%"
EOF
}

if [[ $MODE == 1 ]]; then apply_global; else apply_namespaced; fi
if [[ $LH =~ ^[Yy] ]]; then apply_rule; fi
echo "Done."
