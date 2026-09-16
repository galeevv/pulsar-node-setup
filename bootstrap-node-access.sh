#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Выдача SSH-доступа на НОВУЮ ноду (запускать на новом VPS под root).
#
#   bash bootstrap-node-access.sh --key "ssh-ed25519 AAAA... you@host"
#   bash bootstrap-node-access.sh --key "..." --harden   # + выключить пароли
#   bash bootstrap-node-access.sh                         # спросит ключ
#
# Добавляет твой публичный SSH-ключ в /root/.ssh/authorized_keys, настраивает
# sshd (root по ключу) и базовый ufw (22/80/443). Ничего не удаляет —
# существующие ключи сохраняются. Идемпотентный.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

PUBKEY=""
HARDEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --key)    PUBKEY="$2"; shift 2;;
    --harden) HARDEN=1; shift;;
    *) echo "неизвестный аргумент: $1" >&2; exit 1;;
  esac
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "запусти под root (sudo -i)."

# Ключ: из --key, иначе спросить (если есть терминал).
if [ -z "$PUBKEY" ]; then
  if [ -e /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
    read -r -p "Вставь свой публичный SSH-ключ (ssh-ed25519 AAAA... коммент): " PUBKEY </dev/tty
  fi
fi
case "$PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *) ;;
  *) die "нужен публичный SSH-ключ: --key \"ssh-ed25519 AAAA... коммент\"";;
esac

### 1. ключ ---------------------------------------------------------------- ###
log "Добавляю публичный ключ в /root/.ssh/authorized_keys"
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
# гарантируем перевод строки перед добавлением
if [ -s /root/.ssh/authorized_keys ] && [ "$(tail -c1 /root/.ssh/authorized_keys | wc -l)" -eq 0 ]; then
  echo >> /root/.ssh/authorized_keys
fi
fp="$(printf '%s' "$PUBKEY" | awk '{print $2}')"
if grep -qF "$fp" /root/.ssh/authorized_keys; then
  echo "ключ уже был — пропускаю"
else
  printf '%s\n' "$PUBKEY" >> /root/.ssh/authorized_keys
  echo "ключ добавлен"
fi
KEYS_COUNT="$(grep -cE '^(ssh|ecdsa)-' /root/.ssh/authorized_keys || true)"
echo "всего ключей у root: $KEYS_COUNT"

### 2. sshd: пускать по ключу, root — только по ключу --------------------- ###
log "Проверяю конфиг sshd"
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-pulsar.conf <<'EOF'
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF
if [ "$HARDEN" = 1 ]; then
  [ "$KEYS_COUNT" -ge 1 ] || die "нет ни одного ключа — не выключаю пароли, иначе останешься без доступа."
  cat >> /etc/ssh/sshd_config.d/10-pulsar.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  echo "вход по паролю ВЫКЛЮЧЕН (--harden)"
else
  echo "вход по паролю оставлен как был (запусти с --harden позже, когда убедишься, что ключи работают)"
fi
sshd -t || die "sshd -t не прошёл, конфиг не применён — правь /etc/ssh/sshd_config.d/10-pulsar.conf"
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh
echo "sshd перезагружен"

### 3. базовый фаервол ---------------------------------------------------- ###
if command -v ufw >/dev/null; then
  log "ufw: разрешаю 22 (ssh), 80 (Let's Encrypt), 443 (клиенты)"
  ufw allow 22/tcp   >/dev/null
  ufw allow 80/tcp   >/dev/null
  ufw allow 443/tcp  >/dev/null
  ufw --force enable >/dev/null
  ufw status numbered | sed 's/^/    /'
  echo "порт 2222 (панель -> нода) откроем позже только с IP панели"
else
  echo "ufw не установлен — пропускаю (настроим при установке ноды)"
fi

### 4. что сообщить мне --------------------------------------------------- ###
log "Данные для подключения — пришли этот блок целиком"
IP4="$(curl -fsS -4 --max-time 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
cat <<EOF

────────────────────────────────────────────────────────────────────────
IP:        $IP4
OS:        $( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null || uname -a)
Ядро:      $(uname -r)
CPU/RAM:   $(nproc) vCPU / $(free -m | awk '/^Mem:/{print $2" MB"}')
Диск:      $(df -h / | awk 'NR==2{print $2" (свободно "$4")"}')
Пароли:    $( [ "$HARDEN" = 1 ] && echo "отключены" || echo "включены" )

Fingerprints host-ключей (для проверки при первом подключении):
$(for f in /etc/ssh/ssh_host_*_key.pub; do [ -f "$f" ] && ssh-keygen -lf "$f"; done)
────────────────────────────────────────────────────────────────────────

EOF
log "Готово. Не закрывай текущую сессию, пока я не подтвержу, что зашёл."
