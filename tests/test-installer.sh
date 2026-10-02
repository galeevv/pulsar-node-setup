#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
scratch=$(mktemp -d)
export PULSAR_SETUP_DIR="$scratch/state" PULSAR_NODE_DIR="$scratch/node"
source ./new-node.sh
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for type in reality selfsteal cdn hysteria; do
  args=(--plan --yes --type "$type" --domain node.example.com --panel-ip 192.0.2.1)
  [ "$type" != cdn ] || args+=(--cdn-domain cdn.example.com)
  bash ./new-node.sh "${args[@]}" > "$scratch/plan"
  grep -q 'Ничего не изменено' "$scratch/plan" || fail "plan $type"
done
[ ! -e "$STATE_DIR" ] && [ ! -e "$NODE_DIR" ] || fail 'plan wrote state'
for ip in 999.2.3.4 1.2.3 1.2.3.4/0 '1.2.3.4;id'; do
  if bash ./new-node.sh --plan --yes --type reality --domain n.example.com --panel-ip "$ip" >/dev/null 2>&1; then fail "invalid IP $ip"; fi
done
for domain in '-bad.example.com' 'a..com' 'x.com;id' '../etc/passwd' 'x.com/'; do
  if bash ./new-node.sh --plan --yes --type reality --domain "$domain" --panel-ip 192.0.2.1 >/dev/null 2>&1; then fail "invalid domain $domain"; fi
done
if bash ./new-node.sh --panel-ip >/dev/null 2>&1; then fail 'missing flag value'; fi
if bash ./new-node.sh --plan --yes --type cdn --domain n.example.com --cdn-domain c.example.com --panel-ip 192.0.2.1 --path '/foo;bad' >/dev/null 2>&1; then fail 'path injection'; fi
HAVE_TTY=0; ASSUME_YES=0
if (confirm 'test') >/dev/null 2>&1; then fail 'EOF approval'; fi
ASSUME_YES=1
if (read_secret) >/dev/null 2>&1; then fail 'missing key accepted'; fi
mkdir -p "$NODE_DIR"
printf "EXTRA_OPTION=keep\nSECRET_KEY='fixture-OLD_key=='\nNODE_PORT=1234\n" > "$NODE_DIR/.env"
read_secret
[ "$SECRET_KEY" = 'fixture-OLD_key==' ] || fail 'existing quoted key'
NODE_PORT=2222
write_secret
[ "$(grep -c '^NODE_PORT=' "$NODE_DIR/.env")" = 1 ] || fail 'duplicate port'
grep -q '^EXTRA_OPTION=keep$' "$NODE_DIR/.env" || fail 'extra env lost'
grep -q '^SECRET_KEY=fixture-OLD_key==$' "$NODE_DIR/.env" || fail 'key lost'
SECRET_KEY_FILE="$scratch/key"
printf 'fixture-NEW_key==\n' > "$SECRET_KEY_FILE"
read_secret; write_secret
read_secret; write_secret
grep -q '^SECRET_KEY=fixture-NEW_key==$' "$NODE_DIR/.env" || fail 'key file import'
TYPE=cdn; DOMAIN=node.example.com; CDN_DOMAIN=cdn.example.com; TUNNEL_PATH=/stream/; XRAY_PORT=4444
SNI=''; PANEL_IP=192.0.2.1; NODE_IMAGE=remnawave/node:latest; NODE_PORT=2222; MEM_LIMIT=1500m
save_settings
TYPE=''; DOMAIN=''; load_settings
[ "$TYPE" = cdn ] && [ "$DOMAIN" = node.example.com ] || fail 'resume settings'
if bash ./new-node.sh --plan --yes --type selfsteal >/dev/null 2>&1; then fail 'silent type conversion'; fi
# Ensure no deployment routine ran: only helper state exists under scratch.
bash -n new-node.sh
bash -n bootstrap-node-access.sh
echo 'PASS: four plans; input validation; no implicit approval; key import/reuse; preserved env; saved settings; migration guard; Bash syntax'
