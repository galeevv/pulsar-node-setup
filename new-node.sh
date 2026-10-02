#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Подготовка НОВОЙ НОДЫ для Remnawave. Запускать НА САМОЙ НОДЕ под root.
# Ubuntu 24.04. Повторный запуск использует сохранённые параметры и ключи.
#
# Скрипт готовит только САМУ НОДУ (пакеты, сеть, docker, nginx/сертификат
# по типу, remnanode). Профиль/инбаунд/хост/сквод настраиваются В ПАНЕЛИ —
# скрипт в API панели не ходит.
#
# Четыре типа нод:
#
#   --type cdn        нода за российским CDN («LTE»). nginx держит 443 с
#                     сертификатом origin-домена, секретный путь уходит в xray
#                     на loopback, остальное — сайт-прикрытие. Клиент ходит на
#                     CDN-домен, CDN — на origin.
#
#   --type selfsteal  прямая VLESS+Reality с маскировкой под свой сайт. 443
#                     занимает xray, nginx с настоящим сертификатом слушает
#                     только 127.0.0.1:8443 и служит Reality-таргетом. Транспорт
#                     (xhttp/raw/…) выбираешь потом в панели.
#
#   --type reality    самая простая и быстрая: прямая VLESS+Reality на 443,
#                     БЕЗ nginx, БЕЗ сертификата, БЕЗ сайта (Reality сам
#                     терминирует TLS). Скрипт подбирает/проверяет SNI (dest).
#
#   --type hysteria   Hysteria2 (UDP 443). Нужен настоящий TLS-сертификат на
#                     домен (его использует сам xray), nginx не нужен.
#
# Примеры:
#   bash new-node.sh --type cdn --domain static.example.com --cdn-domain media.example.com
#   bash new-node.sh --type selfsteal --domain node7.example.com
#   bash new-node.sh --type reality  --domain node8.example.com --sni www.icloud.com
#   bash new-node.sh --type hysteria --domain node9.example.com
#   bash new-node.sh                      # спросит всё интерактивно
#
# Обязательный флаг для подключения к панели:
#   --panel-ip <IP>   IP твоей Remnawave-панели (ufw откроет ей порт 2222).
#
# Что делает: обновление пакетов, swap, BBR+буферы, лимиты, docker (с лимитом
# памяти контейнеру), ufw, для нужных типов — сайт-прикрытие и Let's Encrypt
# с автопродлением, nginx под тип, remnanode.
# ---------------------------------------------------------------------------
set +x  # Never trace secrets, even when invoked with bash -x.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive

PANEL_IP_DEFAULT=""                       # задаётся --panel-ip или интерактивно
XRAY_PORT_DEFAULT_CDN=4444
SELFSTEAL_SITE_PORT=8443
NODE_IMAGE_DEFAULT="remnawave/node:latest"
NODE_PORT_DEFAULT=2222
STATE_DIR="${PULSAR_SETUP_DIR:-/opt/pulsar-node-setup}"
NODE_DIR="${PULSAR_NODE_DIR:-/opt/remnanode}"
SECRET_KEY_FILE=""; SECRET_KEY=""; PLAN=0; UPGRADE=0
STEP="параметры"
trap 'printf "\nОшибка на этапе: %s (строка %s). Повторите ту же команду после исправления.\n" "$STEP" "$LINENO" >&2' ERR

TYPE=""; DOMAIN=""; CDN_DOMAIN=""; TUNNEL_PATH=""; XRAY_PORT=""; SNI=""
PANEL_IP="$PANEL_IP_DEFAULT"; ASSUME_YES=0; HARDEN=0
NODE_IMAGE="$NODE_IMAGE_DEFAULT"; NODE_PORT="$NODE_PORT_DEFAULT"; MEM_LIMIT=""

c()    { printf '\033[1;36m%s\033[0m\n' "$*"; }
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

# A dedicated terminal also works for curl | bash; EOF is never approval.
HAVE_TTY=0
if { exec 3</dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
ask() {
  local q="$1" def="${2:-}" a
  if [ "$ASSUME_YES" = 1 ] || [ "$HAVE_TTY" = 0 ]; then
    [ -n "$def" ] || die "Не задано: $q. Передайте соответствующий флаг (см. --help)."
    printf '%s\n' "$def"; return
  fi
  while :; do
    printf '%s%s: ' "$q" "${def:+ [$def]}" >&2
    read -r a <&3 || die "Ввод прерван."
    a="${a:-$def}"
    [ -n "$a" ] && { printf '%s\n' "$a"; return; }
  done
}
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$HAVE_TTY" = 1 ] || die "Нет терминала. Проверьте --plan, затем используйте --yes."
  local a
  printf '%s [y/N]: ' "$1" >&2
  read -r a <&3 || return 1
  case "$a" in y|Y|yes|да|Да) return 0;; *) return 1;; esac
}
help() {
  cat <<'EOF'
Мастер подготовки Remnawave-ноды (Ubuntu 24.04). Запускать НА НОДЕ.
  bash new-node.sh                         интерактивный мастер
  bash new-node.sh --plan [параметры]       показать план, ничего не менять
  bash new-node.sh --yes [все параметры]    установка без вопросов

Типы: --type reality | selfsteal | cdn | hysteria
  reality   RAW Reality, без nginx и сертификата
  selfsteal XHTTP Reality, свой TLS-сайт на 127.0.0.1:8443
  cdn       XHTTP через CDN; nginx 443 → Xray 127.0.0.1:4444
  hysteria  Hysteria2, UDP 443, сертификат на домен

Общие: --panel-ip IPv4 --domain ДОМЕН
Ключ:  --secret-key-file /root/node-secret.txt (только значение Secret Key)
       Без флага мастер предложит скрытый ввод. Существующий .env сохраняется.
CDN:   --cdn-domain ДОМЕН --path /content/gallery/preview/ --port 4444
Reality: --sni www.icloud.com
Другие: --node-port 2222 --node-image remnawave/node:VERSION --mem-limit 1500m
        --upgrade-packages (полное apt upgrade, по умолчанию выключено)
        --harden (только после проверки входа по SSH-ключу)

Порядок: параметры → Secret Key → проверка → установка → инструкция для панели.
Параметры сохраняются в /opt/pulsar-node-setup/settings.tsv; повторный запуск
использует их. Смена типа/домена существующей ноды требует отдельной миграции.
Скрипт НЕ создаёт профиль/Host/сквод и НЕ переоборудует работающую ноду.
EOF
}
valid_domain() {
  local label
  [[ "$1" =~ ^[a-zA-Z0-9.-]+$ && "$1" == *.* && ${#1} -le 253 ]] || return 1
  local IFS=.; local -a labels
  read -ra labels <<< "$1"
  [[ "$1" != *. ]] || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
  done
}
valid_ip() {
  local part; local -a parts
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  local IFS=.; read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    [[ "$part" == 0 || "$part" != 0* ]] || return 1
    [[ ${#part} -le 3 ]] && ((10#$part <= 255)) || return 1
  done
}
valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 < 65536)); }
load_settings() {
  [ -f "$STATE_DIR/settings.tsv" ] || return 0
  local key value
  while IFS=$'\t' read -r key value; do
    case "$key" in TYPE|DOMAIN|CDN_DOMAIN|TUNNEL_PATH|XRAY_PORT|SNI|PANEL_IP|NODE_IMAGE|NODE_PORT|MEM_LIMIT)
      printf -v "$key" '%s' "$value";;
    esac
  done < "$STATE_DIR/settings.tsv"
}
save_settings() {
  install -d -m 700 "$STATE_DIR"
  local key tmp; tmp=$(mktemp "$STATE_DIR/settings.XXXXXX")
  for key in TYPE DOMAIN CDN_DOMAIN TUNNEL_PATH XRAY_PORT SNI PANEL_IP NODE_IMAGE NODE_PORT MEM_LIMIT; do
    printf '%s\t%s\n' "$key" "${!key}"
  done > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$STATE_DIR/settings.tsv"
}
read_secret() {
  if [ -n "$SECRET_KEY_FILE" ]; then
    [ -r "$SECRET_KEY_FILE" ] || die "Не читается файл Secret Key."
    SECRET_KEY=$(cat "$SECRET_KEY_FILE")
    SECRET_KEY="${SECRET_KEY%$'\r'}"
  elif [ -f "$NODE_DIR/.env" ]; then
    # Read literal data, never source an env file as shell code.
    SECRET_KEY=$(sed -n 's/^SECRET_KEY=//p' "$NODE_DIR/.env")
    SECRET_KEY="${SECRET_KEY%$'\r'}"
    if [[ "$SECRET_KEY" == \"*\" || "$SECRET_KEY" == \'*\' ]]; then SECRET_KEY="${SECRET_KEY:1:${#SECRET_KEY}-2}"; fi
  fi
  if [ -z "$SECRET_KEY" ]; then
    [ "$ASSUME_YES" = 0 ] && [ "$HAVE_TTY" = 1 ] || die "Нужен --secret-key-file или существующий $NODE_DIR/.env."
    printf '\nВ панели Remnawave откройте установку ноды и скопируйте значение Secret Key.\nНе API token и не Reality privateKey. Вставьте одну строку, затем Enter.\n' >&2
    read -r -s -p 'Secret Key (ввод скрыт): ' SECRET_KEY <&3 || die "Ввод ключа прерван."
    printf '\n' >&2
  fi
  [[ "$SECRET_KEY" =~ ^[a-zA-Z0-9_+/=-]+$ ]] || die "Secret Key пуст или содержит пробелы/неподдерживаемые символы. Нужна только строка значения."
}
write_secret() {
  install -d -m 700 "$NODE_DIR"
  local tmp; tmp=$(mktemp "$NODE_DIR/.env.XXXXXX")
  if [ -f "$NODE_DIR/.env" ]; then
    sed '/^SECRET_KEY=/d; /^NODE_PORT=/d' "$NODE_DIR/.env" > "$tmp"
    printf '\n' >> "$tmp"
  fi
  printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$SECRET_KEY" >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$NODE_DIR/.env"
  unset SECRET_KEY
}
# Tests can source helpers without touching the host.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
load_settings
PREVIOUS_TYPE="$TYPE"; PREVIOUS_DOMAIN="$DOMAIN"
while [ $# -gt 0 ]; do
  case "$1" in
    --type|--domain|--cdn-domain|--path|--port|--sni|--panel-ip|--node-image|--node-port|--mem-limit|--secret-key-file)
      [ $# -ge 2 ] && [[ "$2" != --* ]] || die "Для $1 нужно значение.";;
  esac
  case "$1" in
    --secret-key-file) SECRET_KEY_FILE="$2"; shift 2;;
    --plan) PLAN=1; shift;;
    --upgrade-packages) UPGRADE=1; shift;;
    --type)       TYPE="$2"; shift 2;;
    --domain)     DOMAIN="$2"; shift 2;;
    --cdn-domain) CDN_DOMAIN="$2"; shift 2;;
    --path)       TUNNEL_PATH="$2"; shift 2;;
    --port)       XRAY_PORT="$2"; shift 2;;
    --sni)        SNI="$2"; shift 2;;
    --panel-ip)   PANEL_IP="$2"; shift 2;;
    --node-image) NODE_IMAGE="$2"; shift 2;;
    --node-port)  NODE_PORT="$2"; shift 2;;
    --mem-limit)  MEM_LIMIT="$2"; shift 2;;
    --harden)     HARDEN=1; shift;;
    --yes|-y)     ASSUME_YES=1; shift;;
    -h|--help)    help; exit 0;;
    *)            die "неизвестный аргумент: $1";;
  esac
done

### --- параметры ---------------------------------------------------------- ###
if [ -z "$TYPE" ]; then
  echo
  c "Какую ноду поднимаем? Выбери цифру:"
  echo
  echo "  1) VLESS Reality           — простая, на 443, без сайта и сертификата (самая быстрая)"
  echo "  2) VLESS Reality + свой сайт — маскировка под собственный сайт (self-steal)"
  echo "  3) YCDN / LTE              — за российским CDN (Yandex/VK), как Польша/Германия LTE"
  echo "  4) Hysteria2              — UDP 443, с сертификатом на домен"
  echo
  case "$(ask 'Твой выбор (1-4)' '1')" in
    1|reality)   TYPE="reality";;
    2|selfsteal) TYPE="selfsteal";;
    3|cdn|ycdn)  TYPE="cdn";;
    4|hysteria)  TYPE="hysteria";;
    *) die "непонятный выбор";;
  esac
  ok "выбрано: $TYPE"
fi
case "$TYPE" in cdn|selfsteal|reality|hysteria) ;; *) die "--type: cdn | selfsteal | reality | hysteria";; esac

# Флаги — что этому типу нужно на ноде:
NEEDS_SITE=0; NEEDS_CERT=0; NEEDS_NGINX=0
case "$TYPE" in
  cdn)       NEEDS_SITE=1; NEEDS_CERT=1; NEEDS_NGINX=1;;
  selfsteal) NEEDS_SITE=1; NEEDS_CERT=1; NEEDS_NGINX=1;;
  reality)   : ;;                                  # ничего: xray сам на 443
  hysteria)  NEEDS_CERT=1;;                         # серт есть, nginx нет
esac

MYIP="(будет определён при установке)"
log "Шаг 1/7 — параметры ноды (до изменений системы)"
ok "публичный IP этой ноды: $MYIP"

# IP панели нужен всем — ufw откроет ей порт управления.
[ -n "$PANEL_IP" ] || PANEL_IP="$(ask 'IP твоей Remnawave-панели (для ufw порт 2222)')"

if [ "$TYPE" = "cdn" ]; then
  echo
  c "Нужны два имени:"
  echo "  origin-домен — A-запись на $MYIP, на него ходит CDN"
  echo "  CDN-домен    — CNAME на технический домен CDN, к нему подключается клиент"
  [ -n "$DOMAIN" ]      || DOMAIN="$(ask 'origin-домен (A-запись)')"
  [ -n "$CDN_DOMAIN" ]  || CDN_DOMAIN="$(ask 'CDN-домен (CNAME)')"
  [ -n "$TUNNEL_PATH" ] || TUNNEL_PATH="$(ask 'секретный путь туннеля' '/content/gallery/preview/')"
  [ -n "$XRAY_PORT" ]   || XRAY_PORT="$(ask 'loopback-порт для xray' "$XRAY_PORT_DEFAULT_CDN")"
  case "$TUNNEL_PATH" in /*) ;; *) die "путь должен начинаться со /";; esac
elif [ "$TYPE" = "selfsteal" ]; then
  echo
  c "Нужно одно имя: домен, A-записью на $MYIP (он же Reality-SNI и адрес сайта)."
  [ -n "$DOMAIN" ]      || DOMAIN="$(ask 'домен (A-запись)')"
  [ -n "$TUNNEL_PATH" ] || TUNNEL_PATH="$(ask 'путь xhttp внутри туннеля (можно поменять в панели)' '/assets/media/stream/')"
  XRAY_PORT=443
elif [ "$TYPE" = "hysteria" ]; then
  echo
  c "Нужно одно имя: домен, A-записью на $MYIP (для TLS-сертификата Hysteria2)."
  [ -n "$DOMAIN" ] || DOMAIN="$(ask 'домен (A-запись)')"
  XRAY_PORT=443
else   # reality
  echo
  c "Нужно одно имя: домен, A-записью на $MYIP (адрес подключения клиента)."
  [ -n "$DOMAIN" ] || DOMAIN="$(ask 'домен (A-запись)')"
  XRAY_PORT=443
fi

valid_ip "$PANEL_IP" || die "IP панели должен быть корректным IPv4."
valid_domain "$DOMAIN" || die "Некорректный домен (без https://, пути и порта)."
[ -z "$CDN_DOMAIN" ] || valid_domain "$CDN_DOMAIN" || die "Некорректный CDN-домен."
[ -z "$SNI" ] || valid_domain "$SNI" || die "Некорректный SNI."
valid_port "$NODE_PORT" && valid_port "$XRAY_PORT" || die "Порт должен быть от 1 до 65535."
[[ "$NODE_PORT" != "$XRAY_PORT" && "$NODE_PORT" != 22 && "$NODE_PORT" != 80 && "$NODE_PORT" != 443 && "$NODE_PORT" != 8443 ]] || die "Порт управления конфликтует с другим сервисом."
if [ "$TYPE" = cdn ]; then
  [[ "$XRAY_PORT" != 22 && "$XRAY_PORT" != 80 && "$XRAY_PORT" != 443 && "$XRAY_PORT" != 8443 ]] || die "Loopback-порт конфликтует с другим сервисом."
fi
if [ -n "$TUNNEL_PATH" ]; then
  [[ "$TUNNEL_PATH" =~ ^/[a-zA-Z0-9/_-]+$ && "$TUNNEL_PATH" != / ]] || die "Путь: / и буквы, цифры, _, -; без query и пробелов."
  case "$TUNNEL_PATH" in /health|/health/*|/.well-known/*|/assets|/assets/) die "Путь конфликтует с сайтом или health.";; esac
fi
[[ "$NODE_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]+$ ]] || die "Некорректный образ Docker."
[[ -z "$MEM_LIMIT" || "$MEM_LIMIT" =~ ^[1-9][0-9]*[mgMG]$ ]] || die "Лимит памяти: например 1500m или 2g."
if [ -n "$PREVIOUS_TYPE" ] && { [ "$PREVIOUS_TYPE" != "$TYPE" ] || [ "$PREVIOUS_DOMAIN" != "$DOMAIN" ]; }; then
  die "Смена типа/домена существующей установки требует отдельной миграции."
fi
WEBROOT="/var/www/${DOMAIN}"
BRAND="$(echo "${DOMAIN%%.*}" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')"

echo
c "Проверь параметры:"
echo "  тип ноды        : $TYPE"
echo "  домен           : $DOMAIN"
[ "$TYPE" = "cdn" ] && echo "  домен для клиента: $CDN_DOMAIN"
[ -n "$TUNNEL_PATH" ] && echo "  путь туннеля    : $TUNNEL_PATH"
echo "  порт xray       : $XRAY_PORT$([ "$NEEDS_NGINX" = 0 ] && echo ' (публичный, занимает xray)' || { [ "$TYPE" = selfsteal ] && echo ' (публичный, занимает xray)' || echo ' (loopback)'; })"
echo "  IP панели (ufw) : $PANEL_IP"
echo "  образ ноды      : $NODE_IMAGE"
[ "$NEEDS_SITE" = 1 ] && echo "  сайт в          : $WEBROOT"
[ "$NEEDS_CERT" = 1 ] && echo "  сертификат      : Let's Encrypt на $DOMAIN"
[ "$NEEDS_CERT" = 0 ] && echo "  сертификат      : не нужен (Reality терминирует TLS сам)"
if [ "$PLAN" = 1 ]; then
  echo "План: Secret Key → DNS → пакеты/сеть/Docker/UFW → сертификат/nginx → remnanode → инструкция панели."
  echo "Ничего не изменено. Ключ не читался."
  exit 0
fi
[ "$(id -u)" -eq 0 ] || die "Запустите под root (sudo -i)."
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] || die "Поддерживается Ubuntu 24.04."
if [ -f "$NODE_DIR/docker-compose.yml" ] && [ ! -f "$STATE_DIR/settings.tsv" ]; then
  die "Обнаружена нода, созданная другим установщиком. Автоматическая миграция не выполняется."
fi
if [ "$NEEDS_NGINX" = 0 ] && systemctl is-active --quiet nginx; then
  die "nginx уже работает; этот тип требует отдельной проверки занятых портов."
fi
if [ "$NEEDS_NGINX" = 1 ] && [ -d /etc/nginx/sites-enabled ]; then
  for site in /etc/nginx/sites-enabled/*; do
    [ -e "$site" ] || continue
    case "${site##*/}" in default|pulsar-node.conf) ;; *) die "На сервере есть чужой nginx virtual host: $site. Нужна отдельная миграция.";; esac
  done
fi
log "Шаг 2/7 — ключ подключения к панели"
read_secret
[ "$HARDEN" = 0 ] || [ -s /root/.ssh/authorized_keys ] || die "Для --harden сначала установите SSH-ключ."
confirm "Установить с этими параметрами?" || die "Отменено до изменений системы."
install -d -m 700 "$STATE_DIR"
exec 9>"$STATE_DIR/install.lock"
flock -n 9 || die "Другой установщик уже работает."
save_settings
write_secret
STEP="DNS"
MYIP="$(curl -fsS -4 --max-time 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
valid_ip "$MYIP" || die "Не удалось определить IPv4 ноды."


### --- DNS --------------------------------------------------------------- ###
log "Проверяю DNS"
resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
if [ "$resolved" = "$MYIP" ]; then
  ok "$DOMAIN -> $resolved (совпадает с IP ноды)"
else
  warn "$DOMAIN -> ${resolved:-не резолвится}, а IP ноды $MYIP"
  warn "без корректной A-записи Let's Encrypt не выдаст сертификат"
  [ "$NEEDS_CERT" = 0 ] || die "Исправьте A-запись на $MYIP и повторите запуск; параметры и ключ уже сохранены."
fi
if [ "$TYPE" = "cdn" ] && [ -n "$CDN_DOMAIN" ]; then
  cdnip="$(getent ahostsv4 "$CDN_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  [ -n "$cdnip" ] && ok "$CDN_DOMAIN -> $cdnip (edge CDN)" || warn "$CDN_DOMAIN не резолвится — CDN-ресурс ещё собирается?"
fi

### --- 1. пакеты --------------------------------------------------------- ###
STEP="пакеты и сеть"
log "Шаг 3/7 — пакеты, сеть и Docker"
apt-get update -qq
if [ "$UPGRADE" = 1 ]; then apt-get -y -qq upgrade; fi
apt-get -y -qq install curl ca-certificates gnupg jq ufw openssl python3
[ "$NEEDS_CERT" = 0 ] || apt-get -y -qq install certbot
[ "$NEEDS_NGINX" = 0 ] || apt-get -y -qq install nginx

### --- 2. swap ----------------------------------------------------------- ###
log "swap"
if swapon --show | grep -q .; then
  ok "уже есть: $(swapon --show --noheadings | head -1 | awk '{print $3}')"
else
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/98-pulsar-swap.conf
  ok "создан 2G"
fi

### --- 3. сеть ----------------------------------------------------------- ###
log "sysctl: BBR + буферы"
cat > /etc/sysctl.d/99-pulsar-node.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 10000 65000
fs.file-max = 1000000
EOF
sysctl --system >/dev/null
ok "qdisc=$(sysctl -n net.core.default_qdisc) cc=$(sysctl -n net.ipv4.tcp_congestion_control)"
grep -q 'pulsar-node' /etc/security/limits.conf || \
  printf '* soft nofile 1000000\n* hard nofile 1000000\n# pulsar-node\n' >> /etc/security/limits.conf

### --- 4. docker --------------------------------------------------------- ###
log "docker"
if command -v docker >/dev/null; then
  ok "уже стоит: $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get -y -qq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "поставлен $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
# Rotation is scoped to the node compose file; preserve daemon.json and other containers.
systemctl enable --now docker
docker compose version >/dev/null || die "Нужен Docker Compose plugin."

### --- 5. ufw ------------------------------------------------------------ ###
STEP="firewall"
log "Шаг 4/7 — firewall ($NODE_PORT только с $PANEL_IP); существующие правила сохраняются"
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
SSH_PORT="${SSH_CONNECTION:-}"
SSH_PORT="${SSH_PORT##* }"
SSH_PORT="${SSH_PORT:-22}"
valid_port "$SSH_PORT" || die "Не удалось определить SSH-порт."
ufw allow "$SSH_PORT/tcp" >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
[ "$TYPE" = "hysteria" ] && ufw allow 443/udp >/dev/null   # Hysteria2 — UDP
ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
ufw --force enable >/dev/null
ufw status | sed 's/^/    /'

### --- 6. сайт-прикрытие ------------------------------------------------- ###
if [ "$NEEDS_SITE" = 1 ]; then
(
umask 022
log "Сайт-прикрытие в $WEBROOT"
install -d -m 755 "$WEBROOT" "$WEBROOT/assets" /var/www/certbot
if [ -f "$WEBROOT/index.html" ]; then
  ok "index.html уже есть — не перезаписываю (свой сайт сохраняется)"
else
  cat > "$WEBROOT/assets/style.css" <<'EOF'
:root{--ink:#16181c;--muted:#6b7280;--line:#e5e7eb;--bg:#fafafa;--panel:#fff;--accent:#7c5c3b}
*{box-sizing:border-box}
body{margin:0;font-family:Georgia,serif;color:var(--ink);background:var(--bg);line-height:1.65;font-size:17px}
a{color:var(--accent)}
.wrap{max-width:1060px;margin:0 auto;padding:0 24px}
header{border-bottom:1px solid var(--line);background:var(--panel)}
header .wrap{display:flex;justify-content:space-between;align-items:baseline;min-height:80px;flex-wrap:wrap;gap:16px}
.brand{font-size:22px;letter-spacing:.12em;text-transform:uppercase;text-decoration:none;color:var(--ink)}
nav a{margin-left:20px;text-decoration:none;color:var(--muted);font-family:system-ui,sans-serif;font-size:14px;letter-spacing:.05em;text-transform:uppercase}
nav a:hover{color:var(--accent)}
.hero{padding:60px 0 40px}
.hero h1{font-size:40px;font-weight:400;line-height:1.15;margin:0 0 16px}
.hero p{font-size:19px;color:var(--muted);max-width:62ch;margin:0 0 24px}
section{padding:40px 0}
section.alt{background:var(--panel);border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
h2{font-size:28px;font-weight:400;margin:0 0 10px}
p.sub{color:var(--muted);font-family:system-ui,sans-serif;font-size:15px;margin:0 0 26px}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:20px}
.two{display:grid;grid-template-columns:1fr 1fr;gap:36px}
figure{margin:0}figure img{width:100%;height:auto;display:block}
figcaption{font-family:system-ui,sans-serif;font-size:13px;color:var(--muted);padding-top:8px}
table{width:100%;border-collapse:collapse;font-family:system-ui,sans-serif;font-size:15px}
th,td{text-align:left;padding:13px 10px;border-bottom:1px solid var(--line)}
th{font-size:12px;letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}
td.num{text-align:right;white-space:nowrap}
footer{border-top:1px solid var(--line);background:var(--panel);padding:34px 0;font-family:system-ui,sans-serif;font-size:14px;color:var(--muted)}
footer .cols{display:grid;grid-template-columns:repeat(3,1fr);gap:24px}
footer a{color:var(--muted)}
@media(max-width:840px){.grid,.two,footer .cols{grid-template-columns:1fr}.hero h1{font-size:30px}nav a{margin:0 16px 0 0}}
EOF
  i=1
  for pal in "#c9b28a:#8a7355:#e8ddc9" "#a8b8c4:#5f7480:#dfe7ec" "#c7a48b:#7d5a44:#eadfd4" \
             "#b9bfae:#6f7a63:#e4e8de" "#cbb6b0:#836a66:#ece1de" "#aab2bd:#61697a:#e2e6ec"; do
    a="${pal%%:*}"; rest="${pal#*:}"; b="${rest%%:*}"; d="${rest#*:}"
    cat > "$WEBROOT/assets/img-$i.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 260" width="360" height="260">
<defs><linearGradient id="g$i" x1="0" y1="0" x2=".7" y2="1">
<stop offset="0" stop-color="$d"/><stop offset=".55" stop-color="$a"/><stop offset="1" stop-color="$b"/>
</linearGradient></defs>
<rect width="360" height="260" fill="url(#g$i)"/>
<rect y="$((146 + i * 5))" width="360" height="$((114 - i * 5))" fill="$b" opacity=".35"/>
<circle cx="$((68 + i * 26))" cy="$((58 + i * 7))" r="$((17 + i * 3))" fill="$d" opacity=".55"/>
<rect x="8" y="8" width="344" height="244" fill="none" stroke="#fff" stroke-opacity=".25" stroke-width="2"/>
</svg>
EOF
    i=$((i + 1))
  done
  cat > "$WEBROOT/assets/logo.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64"><rect width="64" height="64" rx="6" fill="#16181c"/><circle cx="32" cy="32" r="13" fill="none" stroke="#7c5c3b" stroke-width="4"/><rect x="27" y="10" width="10" height="6" rx="2" fill="#7c5c3b"/></svg>
EOF
  nav='<nav><a href="/">Start</a><a href="/works.html">Works</a><a href="/contact.html">Contact</a></nav>'
  foot="<footer><div class=\"wrap cols\"><div><strong>$BRAND</strong><br>Studio &amp; workshop</div><div><a href=\"/works.html\">Works</a><br><a href=\"/contact.html\">Contact</a></div><div><a href=\"mailto:studio@$DOMAIN\">studio@$DOMAIN</a><br>Tue–Sat 11:00–19:00</div></div></footer>"
  head_of() { cat <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$1 — $BRAND</title><meta name="description" content="$2">
<link rel="stylesheet" href="/assets/style.css"><link rel="icon" href="/assets/logo.svg" type="image/svg+xml">
</head><body><header><div class="wrap"><a class="brand" href="/">$BRAND</a>$nav</div></header>
EOF
  }
  { head_of "$BRAND" "Studio and workshop: prints, small-batch production, restoration."
    cat <<EOF
<div class="wrap hero"><h1>Careful work, in small batches</h1>
<p>A studio and workshop. We print, restore and make things one at a time, and we are happy to explain how before you decide.</p>
<p><a href="/contact.html">Get in touch</a></p></div>
<section class="alt"><div class="wrap"><h2>Recent work</h2><p class="sub">A few pieces from the last months</p>
<div class="grid">
<figure><img src="/assets/img-1.svg" width="360" height="260" alt=""><figcaption>Series one · print</figcaption></figure>
<figure><img src="/assets/img-2.svg" width="360" height="260" alt=""><figcaption>Series two · restoration</figcaption></figure>
<figure><img src="/assets/img-3.svg" width="360" height="260" alt=""><figcaption>Commission · framing</figcaption></figure>
</div></div></section>
<section><div class="wrap two">
<div><h2>How it works</h2><p>Write to us with a short description and, if you have one, a photograph. We answer the same working day with a price and a realistic date.</p></div>
<div><h2>Visiting</h2><p>The workshop is open Tuesday to Saturday, 11:00–19:00. Drop by without an appointment; larger jobs are better discussed by mail first.</p></div>
</div></section>
$foot</body></html>
EOF
  } > "$WEBROOT/index.html"
  { head_of "Works" "Selected works from the studio."
    cat <<EOF
<div class="wrap hero"><h1>Works</h1><p>Published with the permission of the people and clients involved.</p></div>
<section><div class="wrap"><div class="grid">
<figure><img src="/assets/img-4.svg" width="360" height="260" alt=""><figcaption>Large format</figcaption></figure>
<figure><img src="/assets/img-5.svg" width="360" height="260" alt=""><figcaption>Detail, second series</figcaption></figure>
<figure><img src="/assets/img-6.svg" width="360" height="260" alt=""><figcaption>Framed commission</figcaption></figure>
</div></div></section>
<section class="alt"><div class="wrap"><h2>Prices</h2><table>
<tr><th>Service</th><th>Notes</th><th class="num">From</th></tr>
<tr><td>Print, 30×40</td><td>cotton paper</td><td class="num">95</td></tr>
<tr><td>Print, 50×70</td><td>cotton paper</td><td class="num">180</td></tr>
<tr><td>Restoration</td><td>per item, after review</td><td class="num">140</td></tr>
<tr><td>Framing</td><td>oak, matte glass</td><td class="num">160</td></tr>
</table></div></section>
$foot</body></html>
EOF
  } > "$WEBROOT/works.html"
  { head_of "Contact" "How to reach the studio."
    cat <<EOF
<div class="wrap hero"><h1>Contact</h1><p>We answer the same working day.</p></div>
<section><div class="wrap two">
<div><h2>Studio</h2><p><strong>Mail</strong><br><a href="mailto:studio@$DOMAIN">studio@$DOMAIN</a></p>
<p><strong>Hours</strong><br>Tuesday–Saturday, 11:00–19:00</p></div>
<div><h2>Before you write</h2><p>Tell us what the piece is, its size, and when you need it. A photograph helps more than a long description.</p></div>
</div></section>
$foot</body></html>
EOF
  } > "$WEBROOT/contact.html"
  cat > "$WEBROOT/robots.txt" <<EOF
User-agent: *
Allow: /
EOF
  ok "сгенерирован сайт: $(ls "$WEBROOT" | wc -l) файлов + $(ls "$WEBROOT/assets" | wc -l) ассетов"
  warn "это болванка — при желании замени файлы в $WEBROOT на свой сайт"
fi
)
fi  # NEEDS_SITE

### --- 7. сертификат ----------------------------------------------------- ###
if [ "$NEEDS_CERT" = 1 ]; then
STEP="сертификат и nginx"
log "Шаг 5/7 — сертификат и nginx для $DOMAIN"
install -d -m 755 /var/www/certbot
if [ "$NEEDS_NGINX" = 1 ]; then
  # cdn/selfsteal: nginx уже нужен — выпускаем через webroot
  if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/pulsar-node.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN _;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}
EOF
  ln -sfn /etc/nginx/sites-available/pulsar-node.conf /etc/nginx/sites-enabled/pulsar-node.conf
  nginx -t >/dev/null 2>&1 || die "nginx -t не прошёл на минимальном конфиге"
  systemctl start nginx
  systemctl reload nginx
  fi
  CERTBOT_MODE="--webroot -w /var/www/certbot"
else
  # hysteria: постоянный nginx не нужен — выпускаем в standalone-режиме
  CERTBOT_MODE="--standalone"
fi

if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  ok "сертификат уже есть (истекает $(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | cut -d= -f2))"
else
  certbot certonly $CERTBOT_MODE -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email --key-type ecdsa \
    || die "certbot не смог выдать сертификат — проверь A-запись и что порт 80 открыт"
  ok "выдан"
fi
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
if [ "$NEEDS_NGINX" = 1 ]; then
  printf '#!/bin/sh\nnginx -t && systemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/pulsar-node-renew.sh
else
  # hysteria: продление в standalone, после — перезапустить ноду, чтобы xray
  # подхватил новый серт (Remnawave монтирует /etc/letsencrypt в контейнер).
  printf '#!/bin/sh\ncd /opt/remnanode && docker compose restart remnanode\n' \
    > /etc/letsencrypt/renewal-hooks/deploy/pulsar-node-renew.sh
fi
chmod 700 /etc/letsencrypt/renewal-hooks/deploy/pulsar-node-renew.sh
systemctl enable --now certbot.timer
ok "автопродление: $(systemctl is-enabled certbot.timer 2>/dev/null || echo '?')"
fi  # NEEDS_CERT

### --- 8. nginx под тип ноды --------------------------------------------- ###
if [ "$NEEDS_NGINX" = 1 ]; then
if [ "$TYPE" = "cdn" ]; then
  # Keep global nginx limits intact; tune only this virtual host.
  log "nginx: origin для CDN (443 у nginx, туннель $TUNNEL_PATH -> 127.0.0.1:$XRAY_PORT)"
  NGINX_CANDIDATE=$(mktemp /etc/nginx/sites-available/pulsar-node.XXXXXX)
  cat > "$NGINX_CANDIDATE" <<EOF
# --- Origin для российского CDN ------------------------------------------
# Клиент -> $CDN_DOMAIN (edge CDN) -> сюда ($DOMAIN:443) -> xray на loopback.
# Всё, кроме секретного пути, отдаётся как обычный сайт.
upstream xray_backend {
    server 127.0.0.1:$XRAY_PORT;
    keepalive 64;
    keepalive_requests 1000;
    keepalive_timeout 75s;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN _;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name $DOMAIN _;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:PulsarTLS:10m;
    ssl_session_timeout 1d;
    large_client_header_buffers 4 32k;
    gzip off;

    # edge держит соединения долго — не рвём их каждые 1000 запросов
    keepalive_timeout 75s;
    keepalive_requests 1000;

    root  $WEBROOT;
    index index.html;
    charset utf-8;

    location = /health {
        default_type application/json;
        return 200 "{\"status\":\"ok\",\"service\":\"media-gateway\"}";
        access_log off;
    }

    # Match the exact endpoint AND subpaths, without an HTTP redirect.
    location = ${TUNNEL_PATH%/} {
        rewrite ^ ${TUNNEL_PATH%/}/ last;
    }
    location ^~ ${TUNNEL_PATH%/}/ {

        client_max_body_size 0;
        if (\$request_method = HEAD) { return 204; }

        proxy_pass http://xray_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";

        # КРИТИЧНО: без этого edge буферизует downlink и туннель встаёт
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_next_upstream off;
        gzip off;
        proxy_socket_keepalive on;

        proxy_connect_timeout 10s;
        proxy_read_timeout 600s;
        proxy_send_timeout 3600s;
        client_body_timeout 3600s;
        send_timeout 3600s;

        add_header X-Accel-Buffering no always;
        add_header Cache-Control "no-store, no-cache, no-transform, max-age=0" always;
        add_header Pragma "no-cache" always;

        access_log off; # Tunnel paths/session metadata do not belong in access logs.
    }

    location ^~ /assets/ { expires 7d; add_header Cache-Control "public"; }
    location / { try_files \$uri \$uri/ \$uri.html =404; }

    access_log /var/log/nginx/origin.access.log;
    error_log  /var/log/nginx/origin.error.log;
}
EOF
else
  log "nginx: сайт только на 127.0.0.1:$SELFSTEAL_SITE_PORT (443 займёт xray)"
  NGINX_CANDIDATE=$(mktemp /etc/nginx/sites-available/pulsar-node.XXXXXX)
  cat > "$NGINX_CANDIDATE" <<EOF
# --- Сайт-прикрытие для Reality (target = 127.0.0.1:$SELFSTEAL_SITE_PORT) ---
# Публичный 443 занимает xray. Reality сам терминирует TLS для своих клиентов,
# а всех остальных (браузеры, активные пробы) прозрачно отдаёт сюда.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN _;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}

server {
    # ТОЛЬКО loopback: снаружи сюда попасть нельзя, вход лишь через Reality
    listen 127.0.0.1:$SELFSTEAL_SITE_PORT ssl http2 default_server;
    server_name $DOMAIN;

    # Reality требует от target TLS 1.3 и h2 в ALPN
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    root  $WEBROOT;
    index index.html;
    charset utf-8;

    add_header Strict-Transport-Security "max-age=15768000" always;
    add_header X-Content-Type-Options "nosniff" always;

    location ^~ /assets/ { expires 7d; add_header Cache-Control "public"; }
    location / { try_files \$uri \$uri/ \$uri.html =404; }

    access_log /var/log/nginx/camouflage.access.log;
    error_log  /var/log/nginx/camouflage.error.log;
}
EOF
fi
NGINX_CONFIG=/etc/nginx/sites-available/pulsar-node.conf
NGINX_BACKUP="$STATE_DIR/nginx-before-$(date -u +%Y%m%dT%H%M%SZ).conf"
had_config=0
if [ -f "$NGINX_CONFIG" ]; then cp -p "$NGINX_CONFIG" "$NGINX_BACKUP"; had_config=1; fi
chmod 644 "$NGINX_CANDIDATE"
mv "$NGINX_CANDIDATE" "$NGINX_CONFIG"
ln -sfn "$NGINX_CONFIG" /etc/nginx/sites-enabled/pulsar-node.conf
if ! nginx -t; then
  if [ "$had_config" = 1 ]; then cp -p "$NGINX_BACKUP" "$NGINX_CONFIG"; else rm -f /etc/nginx/sites-enabled/pulsar-node.conf "$NGINX_CONFIG"; fi
  die "nginx -t отклонил конфигурацию; предыдущий файл восстановлен."
fi
systemctl enable --now nginx
if ! systemctl reload nginx; then
  if [ "$had_config" = 1 ]; then cp -p "$NGINX_BACKUP" "$NGINX_CONFIG"; nginx -t && systemctl reload nginx; fi
  die "Reload nginx завершился ошибкой."
fi
ok "nginx проверен и перечитал конфигурацию"
else
  ok "nginx для $TYPE не устанавливается"
fi  # NEEDS_NGINX

### --- 9. remnanode ------------------------------------------------------ ###
STEP="remnanode"
log "Шаг 6/7 — запуск remnanode"
mkdir -p /opt/remnanode && chmod 700 /opt/remnanode

# Лимит памяти контейнеру: если xray потечёт, docker убьёт и перезапустит
# ТОЛЬКО его, не роняя SSH и весь сервер. По умолчанию ~75% RAM.
if [ -z "$MEM_LIMIT" ]; then
  ram_mb=$(free -m | awk '/^Mem:/{print $2}')
  MEM_LIMIT="$(( ram_mb * 75 / 100 ))m"
fi
ok "лимит памяти контейнера: $MEM_LIMIT (RAM ноды: $(free -m | awk '/^Mem:/{print $2}') MB)"

if [ -f /opt/remnanode/docker-compose.yml ]; then
  cp -p /opt/remnanode/docker-compose.yml "$STATE_DIR/compose-before-$(date -u +%Y%m%dT%H%M%SZ).yml"
fi
cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    image: $NODE_IMAGE
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    env_file:
      - .env
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
    mem_limit: $MEM_LIMIT
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
ok "compose записан (образ $NODE_IMAGE)"

cd /opt/remnanode
docker compose config --quiet
docker compose up -d --pull missing
for attempt in $(seq 1 30); do
  [ -n "$(ss -H -ltn "sport = :$NODE_PORT")" ] && break
  sleep 2
 done
docker ps --format '    {{.Names}} {{.Image}} {{.Status}}' | grep remnanode || warn "контейнер не поднялся, смотри docker logs remnanode"
[ -n "$(ss -H -ltn "sport = :$NODE_PORT")" ] && ok "порт $NODE_PORT слушает; правило доступа панели $PANEL_IP добавлено" \
                                || die "Порт $NODE_PORT не слушает. Проверьте docker logs remnanode; ключ и параметры сохранены."

### --- 10. опциональное закручивание SSH -------------------------------- ###
if [ "$HARDEN" = 1 ]; then
  log "Отключаю вход по паролю"
  keys="$(grep -cE '^(ssh|ecdsa)-' /root/.ssh/authorized_keys 2>/dev/null || true)"
  keys="${keys:-0}"
  if [ "$keys" -ge 1 ]; then
    install -d -m 755 /etc/ssh/sshd_config.d
    SSH_BACKUP="$STATE_DIR/sshd-before.conf"
    had_ssh_config=0
    if [ -f /etc/ssh/sshd_config.d/10-pulsar.conf ]; then cp -p /etc/ssh/sshd_config.d/10-pulsar.conf "$SSH_BACKUP"; had_ssh_config=1; fi
    printf 'PubkeyAuthentication yes\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
      > /etc/ssh/sshd_config.d/10-pulsar.conf
    if ! sshd -t; then
      if [ "$had_ssh_config" = 1 ]; then cp -p "$SSH_BACKUP" /etc/ssh/sshd_config.d/10-pulsar.conf; else rm -f /etc/ssh/sshd_config.d/10-pulsar.conf; fi
      die "sshd -t не прошёл; конфигурация SSH восстановлена."
    fi
    systemctl reload ssh
    ok "пароли выключены ($keys ключ(а) в authorized_keys)"
  else
    warn "в authorized_keys нет ключей — пароли НЕ выключаю, иначе потеряешь доступ"
  fi
fi

### --- 10.5 подбор SNI для reality --------------------------------------- ###
# Для простой Reality нужен dest/SNI — чужой сайт, под который маскируемся.
# Требования: TLS 1.3 + ALPN h2 + валидный серт, и не заблокирован в РФ.
# Проверяем кандидатов ПРЯМО С НОДЫ (у ДЦ-IP видимость иная, чем у клиента).
if [ "$TYPE" = "reality" ]; then
  log "Подбор SNI (dest) для Reality"
  if [ -n "$SNI" ]; then
    ok "SNI задан вручную: $SNI"
  else
    CANDIDATES="www.icloud.com www.microsoft.com www.samsung.com www.amd.com www.nvidia.com dl.google.com www.cloudflare.com www.bing.com www.tesla.com www.intel.com"
    echo "  проверяю кандидатов (TLS1.3 + h2 + валидный серт):"
    BEST=""
    for d in $CANDIDATES; do
      out="$(echo | timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 2>/dev/null || true)"
      tls=$(echo "$out" | grep -c "TLSv1.3" || true)
      alpn=$(echo "$out" | grep -c "ALPN protocol: h2" || true)
      ver=$(echo "$out" | grep -c "Verify return code: 0" || true)
      if [ "$tls" -ge 1 ] && [ "$alpn" -ge 1 ] && [ "$ver" -ge 1 ]; then
        printf '    %-22s OK\n' "$d"; [ -z "$BEST" ] && BEST="$d"
      else
        printf '    %-22s пропуск\n' "$d"
      fi
    done
    [ -n "$BEST" ] || die "Ни один SNI не прошёл проверку; задайте --sni после проверки вручную."
    SNI="$BEST"
    ok "рекомендую SNI: $SNI  (можно задать свой через --sni)"
  fi
fi

### --- 10.7 генерация ключей Reality ------------------------------------- ###
# Для reality/selfsteal нужны СВОИ x25519-ключи и shortId на КАЖДУЮ ноду.
# Генерим прямо в контейнере (ядро то же, что будет работать) и печатаем.
REALITY_PRIV=""; REALITY_PUB=""; SHORT_ID=""
if [ "$TYPE" = "reality" ] || [ "$TYPE" = "selfsteal" ]; then
  log "Генерирую ключи Reality (свои для этой ноды)"
  if [ -s "$STATE_DIR/reality.keys" ]; then
    kp="$(cat "$STATE_DIR/reality.keys")"
  else
    kp="$(docker exec remnanode xray x25519)"
    printf '%s\n' "$kp" > "$STATE_DIR/reality.keys"
    chmod 600 "$STATE_DIR/reality.keys"
  fi
  REALITY_PRIV="$(printf '%s\n' "$kp" | awk -F': ' '/PrivateKey|Private key/{print $2; exit}')"
  REALITY_PUB="$(printf '%s\n' "$kp" | awk -F': ' '/Password|Public key|PublicKey/{print $2; exit}')"
  [ -s "$STATE_DIR/reality.shortid" ] || openssl rand -hex 8 > "$STATE_DIR/reality.shortid"
  SHORT_ID="$(cat "$STATE_DIR/reality.shortid")"
  if [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ]; then
    ok "Reality-ключи готовы (повторный запуск сохраняет прежние)"
  else
    die "Не удалось прочитать Reality-ключи. Проверьте версию Xray и $STATE_DIR/reality.keys."
  fi
fi

### --- 11. проверки и итог ---------------------------------------------- ###
STEP="проверки"
log "Шаг 7/7 — проверки и передача параметров в панель"
save_settings
case "$TYPE" in
  cdn)
    printf '    сайт (origin)  = %s\n' "$(curl -sk --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN/")"
    printf '    /health        = %s\n' "$(curl -sk --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN/health")"
    printf '    путь туннеля   = %s (400 = xray отвечает, 502 = инбаунда ещё нет)\n' \
           "$(curl -sk --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN$TUNNEL_PATH")"
    ;;
  selfsteal)
    printf '    сайт (loopback) = %s\n' "$(curl -sk --resolve "$DOMAIN:$SELFSTEAL_SITE_PORT:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$SELFSTEAL_SITE_PORT/")"
    alpn="$(echo | openssl s_client -connect "127.0.0.1:$SELFSTEAL_SITE_PORT" -servername "$DOMAIN" -alpn h2 2>/dev/null | grep -o 'ALPN protocol: h2' || true)"
    printf '    TLS1.3 + %s\n' "${alpn:-ALPN h2 НЕ согласован — Reality этого требует!}"
    ;;
  hysteria)
    [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && ok "сертификат на $DOMAIN готов" || warn "сертификата нет"
    ;;
  reality)
    ok "nginx не задействован, публичный 443 свободен для xray"
    ;;
esac

# Итоговые параметры для настройки в ПАНЕЛИ
cat <<EOF

────────────────────────────────────────────────────────────────────────
НОДА ГОТОВА. Дальше настрой в ПАНЕЛИ (Remnawave) — скрипт в панель не лезет.

Параметры:
  тип ноды   : $TYPE
  IP ноды    : $MYIP        (порт управления: $NODE_PORT)
  домен      : $DOMAIN
EOF
[ "$TYPE" = "cdn" ]     && echo "  CDN-домен  : $CDN_DOMAIN   (это адрес подключения клиента)"
[ -n "$TUNNEL_PATH" ]   && echo "  путь       : $TUNNEL_PATH"
[ "$TYPE" = "cdn" ]     && echo "  xray порт  : 127.0.0.1:$XRAY_PORT  (сюда nginx проксирует туннель)"
[ "$TYPE" = "selfsteal" ] && echo "  Reality target: 127.0.0.1:$SELFSTEAL_SITE_PORT (локальный сайт-таргет)"
[ "$TYPE" = "reality" ] && echo "  SNI / dest : $SNI"
cat <<EOF

Что создать в панели:
  1) Config profile + inbound — по типу:
$(case "$TYPE" in
  cdn)       echo "       vless + xhttp, listen 127.0.0.1:$XRAY_PORT, path $TUNNEL_PATH,";
             echo "       security none (TLS терминирует nginx/CDN). Host: $CDN_DOMAIN, fp=edge.";;
  selfsteal) echo "       vless + reality (транспорт на выбор: raw/xhttp), listen 0.0.0.0:443,";
             echo "       target 127.0.0.1:$SELFSTEAL_SITE_PORT, serverNames [$DOMAIN], свои ключи. fp=edge.";;
  reality)   echo "       vless + reality, listen 0.0.0.0:443, dest $SNI:443,";
             echo "       serverNames [$SNI], свои x25519-ключи + shortId. fp=edge.";;
  hysteria)  echo "       hysteria2, listen 0.0.0.0:443 (UDP), TLS-серт";
             echo "       /etc/letsencrypt/live/$DOMAIN/ (примонтирован в контейнер).";;
esac)
  2) Node — адрес $MYIP, порт $NODE_PORT; назначь профиль и его inbound.
  3) Host — адрес подключения клиента, fingerprint edge (для Hysteria не нужен).
  4) Добавь inbound в сквод — ИНАЧЕ панель не отдаст его на ноду и порт
     $([ "$TYPE" = cdn ] && echo "$XRAY_PORT" || echo 443) не откроется.
────────────────────────────────────────────────────────────────────────
EOF

# --- готовые значения и JSON для панели -----------------------------------
if [ "$TYPE" = "reality" ]; then
  cat > "$STATE_DIR/panel-reality.txt" <<EOF

════════════════ ДАННЫЕ ДЛЯ ПАНЕЛИ (VLESS Reality) ════════════════════════
  privateKey (в inbound) : $REALITY_PRIV
  publicKey  (клиентам/pbk): $REALITY_PUB
  shortId                : $SHORT_ID
  dest / serverName      : $SNI
  адрес подключения (Host): $MYIP : 443, fingerprint edge

── JSON инбаунда (вставь в Config Profile → inbound, ключи уже подставлены) ──
{
  "tag": "REALITY_$(echo "$DOMAIN" | tr '.:' '__')",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "dest": "$SNI:443",
      "show": false,
      "xver": 0,
      "serverNames": ["$SNI"],
      "privateKey": "$REALITY_PRIV",
      "shortIds": ["$SHORT_ID"]
    }
  },
  "sniffing": { "enabled": false }
}
═══════════════════════════════════════════════════════════════════════════
EOF
elif [ "$TYPE" = "selfsteal" ]; then
  cat > "$STATE_DIR/panel-reality.txt" <<EOF

════════════════ ДАННЫЕ ДЛЯ ПАНЕЛИ (VLESS Reality self-steal) ═════════════
  privateKey (в inbound) : $REALITY_PRIV
  publicKey  (клиентам/pbk): $REALITY_PUB
  shortId                : $SHORT_ID
  serverName / SNI       : $DOMAIN
  Reality target         : 127.0.0.1:$SELFSTEAL_SITE_PORT (локальный сайт)
  адрес подключения (Host): $DOMAIN : 443, fingerprint edge

── JSON инбаунда (XHTTP Reality со своим сайтом) ──────
{
  "tag": "SELFSTEAL_$(echo "$DOMAIN" | tr '.:' '__')",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": { "mode": "auto", "path": "$TUNNEL_PATH" },
    "security": "reality",
    "realitySettings": {
      "target": "127.0.0.1:$SELFSTEAL_SITE_PORT",
      "show": false,
      "xver": 0,
      "serverNames": ["$DOMAIN"],
      "privateKey": "$REALITY_PRIV",
      "shortIds": ["$SHORT_ID"]
    }
  },
  "sniffing": { "enabled": false }
}
═══════════════════════════════════════════════════════════════════════════
EOF
fi

echo
if [ -f "$STATE_DIR/panel-reality.txt" ]; then
  chmod 600 "$STATE_DIR/panel-reality.txt"
  echo "JSON с Reality-ключом сохранён: $STATE_DIR/panel-reality.txt (root only)."
  echo "Откройте его локально на VPS и перенесите inbound в панель. Не публикуйте файл."
fi
echo "Подготовка завершена. VPN заработает после настройки профиля, Host и сквода в панели."
