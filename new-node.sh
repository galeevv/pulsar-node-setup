#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Подготовка НОВОЙ НОДЫ для Remnawave. Запускать НА САМОЙ НОДЕ под root.
# Ubuntu 24.04. Идемпотентный: повторный запуск дописывает недоделанное.
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
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

PANEL_IP_DEFAULT=""                       # задаётся --panel-ip или интерактивно
XRAY_PORT_DEFAULT_CDN=4444
SELFSTEAL_SITE_PORT=8443
NODE_IMAGE_DEFAULT="remnawave/node:latest"
NODE_PORT_DEFAULT=2222

TYPE=""; DOMAIN=""; CDN_DOMAIN=""; TUNNEL_PATH=""; XRAY_PORT=""; SNI=""
PANEL_IP="$PANEL_IP_DEFAULT"; ASSUME_YES=0; HARDEN=0
NODE_IMAGE="$NODE_IMAGE_DEFAULT"; NODE_PORT="$NODE_PORT_DEFAULT"; MEM_LIMIT=""

c()    { printf '\033[1;36m%s\033[0m\n' "$*"; }
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

# Терминал открываем ОДИН раз на fd 3 и читаем только оттуда. Иначе при
# `bash <(curl …)` повторное `read </dev/tty` ловит EOF и вопросы срываются.
HAVE_TTY=0
if [ -e /dev/tty ] && exec 3</dev/tty 2>/dev/null; then HAVE_TTY=1; fi

ask() { # ask "вопрос" "значение-по-умолчанию"
  local q="$1" def="${2:-}" a
  if [ "$ASSUME_YES" = 1 ] && [ -n "$def" ]; then echo "$def"; return; fi
  if [ "$HAVE_TTY" = 0 ]; then
    [ -n "$def" ] && { echo "$def"; return; }
    die "нет терминала для вопроса «$q» — передай значение аргументом или запусти через ssh -t"
  fi
  if [ -n "$def" ]; then printf '%s [%s]: ' "$q" "$def" >&2; read -r a <&3; echo "${a:-$def}"
  else
    while :; do printf '%s: ' "$q" >&2; read -r a <&3; [ -n "$a" ] && break; done
    echo "$a"
  fi
}

confirm() { # confirm "вопрос" -> 0 да / 1 нет; без терминала считаем «да»
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$HAVE_TTY" = 0 ] && { warn "нет терминала — считаю ответ утвердительным"; return 0; }
  local a; printf '%s [y/N]: ' "$1" >&2; read -r a <&3 || a=""
  case "$a" in y|Y|yes|YES|да|Да|ДА) return 0;; *) return 1;; esac
}

while [ $# -gt 0 ]; do
  case "$1" in
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
    -h|--help)    sed -n '2,45p' "$0"; exit 0;;
    *)            die "неизвестный аргумент: $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "запусти под root"
. /etc/os-release 2>/dev/null || true
case "${VERSION_ID:-}" in
  24.04) ;;
  *) warn "скрипт писался под Ubuntu 24.04, у тебя ${PRETTY_NAME:-неизвестно} — продолжаю, но проверяй вывод";;
esac

### --- параметры ---------------------------------------------------------- ###
if [ -z "$TYPE" ]; then
  echo
  c "Тип ноды:"
  echo "  1) cdn        — за российским CDN (как Польша/Германия LTE)"
  echo "  2) selfsteal  — прямая Reality с маскировкой под свой сайт"
  echo "  3) reality    — простая Reality на 443, без сайта и сертификата (быстро)"
  echo "  4) hysteria   — Hysteria2 (UDP 443), нужен сертификат на домен"
  case "$(ask 'Выбери 1-4' '1')" in
    1|cdn) TYPE="cdn";;
    2|selfsteal) TYPE="selfsteal";;
    3|reality) TYPE="reality";;
    4|hysteria) TYPE="hysteria";;
    *) die "непонятный выбор";;
  esac
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

MYIP="$(curl -fsS -4 --max-time 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
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
confirm "Продолжать?" || die "отменено"

### --- DNS --------------------------------------------------------------- ###
log "Проверяю DNS"
resolved="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
[ -n "$resolved" ] || resolved="$(python3 -c "import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass" "$DOMAIN")"
if [ "$resolved" = "$MYIP" ]; then
  ok "$DOMAIN -> $resolved (совпадает с IP ноды)"
else
  warn "$DOMAIN -> ${resolved:-не резолвится}, а IP ноды $MYIP"
  warn "без корректной A-записи Let's Encrypt не выдаст сертификат"
  confirm "Всё равно продолжать?" || die "поправь DNS и запусти снова"
fi
if [ "$TYPE" = "cdn" ] && [ -n "$CDN_DOMAIN" ]; then
  cdnip="$(python3 -c "import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass" "$CDN_DOMAIN")"
  [ -n "$cdnip" ] && ok "$CDN_DOMAIN -> $cdnip (edge CDN)" || warn "$CDN_DOMAIN не резолвится — CDN-ресурс ещё собирается?"
fi

### --- 1. пакеты --------------------------------------------------------- ###
log "Обновляю пакеты и ставлю зависимости"
apt-get update -qq
apt-get -y -qq upgrade
apt-get -y -qq install curl ca-certificates gnupg jq ufw nginx certbot \
                       unattended-upgrades openssl python3
ok "nginx $(nginx -v 2>&1 | grep -oE '[0-9.]+' | head -1), certbot $(certbot --version 2>&1 | awk '{print $2}')"

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
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOF
systemctl restart docker

### --- 5. ufw ------------------------------------------------------------ ###
log "ufw ($NODE_PORT — только с панели $PANEL_IP)"
ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp  >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
[ "$TYPE" = "hysteria" ] && ufw allow 443/udp >/dev/null   # Hysteria2 — UDP
ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
ufw --force enable >/dev/null
ufw status | sed 's/^/    /'

### --- 6. сайт-прикрытие ------------------------------------------------- ###
if [ "$NEEDS_SITE" = 1 ]; then
log "Сайт-прикрытие в $WEBROOT"
mkdir -p "$WEBROOT/assets" /var/www/certbot
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
fi  # NEEDS_SITE

### --- 7. сертификат ----------------------------------------------------- ###
if [ "$NEEDS_CERT" = 1 ]; then
log "Сертификат Let's Encrypt для $DOMAIN"
mkdir -p /var/www/certbot
if [ "$NEEDS_NGINX" = 1 ]; then
  # cdn/selfsteal: nginx уже нужен — выпускаем через webroot
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
  systemctl reload nginx
  CERTBOT_MODE="--webroot -w /var/www/certbot"
else
  # hysteria: постоянный nginx не нужен — выпускаем в standalone-режиме
  systemctl stop nginx 2>/dev/null || true
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
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
if [ "$NEEDS_NGINX" = 1 ]; then
  printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
else
  # hysteria: продление в standalone, после — перезапустить ноду, чтобы xray
  # подхватил новый серт (Remnawave монтирует /etc/letsencrypt в контейнер).
  printf '#!/bin/sh\ncd /opt/remnanode && docker compose restart >/dev/null 2>&1 || true\n' \
    > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
fi
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable certbot.timer >/dev/null 2>&1 || true
ok "автопродление: $(systemctl is-enabled certbot.timer 2>/dev/null || echo '?')"
fi  # NEEDS_CERT

### --- 8. nginx под тип ноды --------------------------------------------- ###
if [ "$NEEDS_NGINX" = 1 ]; then
if [ "$TYPE" = "cdn" ]; then
  # CDN гонит много коротких uplink-GET → дефолтные 768 соединений малы,
  # под нагрузкой упираемся в них (волна 500-х). Поднимаем воркеры.
  if ! grep -q 'pulsar-node-tuning' /etc/nginx/nginx.conf; then
    install -d /etc/nginx/conf.d
    sed -i 's/^\(\s*\)worker_connections .*/\1worker_connections 16384;\n\1multi_accept on;/' /etc/nginx/nginx.conf 2>/dev/null || true
    grep -q 'worker_rlimit_nofile' /etc/nginx/nginx.conf || \
      sed -i '1i worker_rlimit_nofile 65535;  # pulsar-node-tuning' /etc/nginx/nginx.conf
    grep -q 'pulsar-node-tuning' /etc/nginx/nginx.conf || \
      sed -i '1i # pulsar-node-tuning' /etc/nginx/nginx.conf
  fi
  log "nginx: origin для CDN (443 у nginx, туннель $TUNNEL_PATH -> 127.0.0.1:$XRAY_PORT)"
  cat > /etc/nginx/sites-available/pulsar-node.conf <<EOF
# --- Origin для российского CDN ------------------------------------------
# Клиент -> $CDN_DOMAIN (edge CDN) -> сюда ($DOMAIN:443) -> xray на loopback.
# Всё, кроме секретного пути, отдаётся как обычный сайт.
upstream xray_backend {
    server 127.0.0.1:$XRAY_PORT;
    keepalive 512;
    keepalive_requests 100000;
    keepalive_timeout 300s;
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

    # edge держит соединения долго — не рвём их каждые 1000 запросов
    keepalive_timeout 300s;
    keepalive_requests 100000;

    root  $WEBROOT;
    index index.html;
    charset utf-8;

    location = /health {
        default_type application/json;
        return 200 "{\"status\":\"ok\",\"service\":\"media-gateway\"}";
        access_log off;
    }

    location ^~ $TUNNEL_PATH {
        # некоторые CDN срезают хвостовой слэш, а xhttp-инбаунд его ждёт
        rewrite ^${TUNNEL_PATH%/}\$ $TUNNEL_PATH break;

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
        proxy_socket_keepalive on;

        proxy_connect_timeout 10s;
        proxy_read_timeout 600s;
        proxy_send_timeout 3600s;
        client_body_timeout 3600s;
        send_timeout 3600s;

        add_header X-Accel-Buffering no always;
        add_header Cache-Control "no-store, no-cache, no-transform, max-age=0" always;
        add_header Pragma "no-cache" always;

        access_log /var/log/nginx/tunnel_access.log;
    }

    location ^~ /assets/ { expires 7d; add_header Cache-Control "public"; }
    location / { try_files \$uri \$uri/ \$uri.html =404; }

    access_log /var/log/nginx/origin.access.log;
    error_log  /var/log/nginx/origin.error.log;
}
EOF
else
  log "nginx: сайт только на 127.0.0.1:$SELFSTEAL_SITE_PORT (443 займёт xray)"
  cat > /etc/nginx/sites-available/pulsar-node.conf <<EOF
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
nginx -t || die "nginx -t не прошёл, конфиг не применён (старый остался рабочим)"
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
ok "nginx перезагружен"
else
  # reality / hysteria: nginx на ноде не нужен, 443 занимает xray.
  systemctl disable --now nginx >/dev/null 2>&1 || true
  ok "nginx не используется для типа $TYPE (443 займёт xray)"
fi  # NEEDS_NGINX

### --- 9. remnanode ------------------------------------------------------ ###
log "remnanode"
mkdir -p /opt/remnanode && chmod 700 /opt/remnanode

# Лимит памяти контейнеру: если xray потечёт, docker убьёт и перезапустит
# ТОЛЬКО его, не роняя SSH и весь сервер. По умолчанию ~75% RAM.
if [ -z "$MEM_LIMIT" ]; then
  ram_mb=$(free -m | awk '/^Mem:/{print $2}')
  MEM_LIMIT="$(( ram_mb * 75 / 100 ))m"
fi
ok "лимит памяти контейнера: $MEM_LIMIT (RAM ноды: $(free -m | awk '/^Mem:/{print $2}') MB)"

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

if [ ! -s /opt/remnanode/.env ] || ! grep -q '^SECRET_KEY' /opt/remnanode/.env; then
  cat <<EOF

──────────────────────────────────────────────────────────────────────────
Не хватает /opt/remnanode/.env с ключом панели (SECRET_KEY).

Где взять ключ:
  • если у тебя УЖЕ есть ноды в этой панели — скопируй .env с любой живой:
      scp -3 root@<живая-нода>:/opt/remnanode/.env root@$MYIP:/opt/remnanode/.env
  • если это ПЕРВАЯ нода — ключ показывается в панели при создании ноды
    (Remnawave → Nodes → создать → там будет SECRET_KEY).

ВАЖНО: НЕ брать ключ из GET /api/keygen — он отдаёт другой (ротируемый) ключ,
нода с ним к панели не подключится.

Либо создай файл вручную (порт совпадает с тем, что ждёт панель):
  printf 'NODE_PORT=$NODE_PORT\nSECRET_KEY=<ключ>\n' > /opt/remnanode/.env && chmod 600 /opt/remnanode/.env

Затем запусти этот скрипт ещё раз — он продолжит с этого места.
──────────────────────────────────────────────────────────────────────────
EOF
  exit 0
fi
chmod 600 /opt/remnanode/.env
grep -q '^NODE_PORT' /opt/remnanode/.env || echo "NODE_PORT=$NODE_PORT" >> /opt/remnanode/.env
cd /opt/remnanode
docker compose up -d >/dev/null 2>&1 || docker compose up -d
sleep 8
docker ps --format '    {{.Names}} {{.Image}} {{.Status}}' | grep remnanode || warn "контейнер не поднялся, смотри docker logs remnanode"
ss -ltn | grep -q ":$NODE_PORT" && ok "порт $NODE_PORT слушает (снаружи открыт только для $PANEL_IP)" \
                                || warn "порт $NODE_PORT не слушает"

### --- 10. опциональное закручивание SSH -------------------------------- ###
if [ "$HARDEN" = 1 ]; then
  log "Отключаю вход по паролю"
  keys="$(grep -cE '^(ssh|ecdsa)-' /root/.ssh/authorized_keys 2>/dev/null || echo 0)"
  if [ "$keys" -ge 1 ]; then
    install -d -m 755 /etc/ssh/sshd_config.d
    printf 'PubkeyAuthentication yes\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
      > /etc/ssh/sshd_config.d/10-pulsar.conf
    sshd -t && { systemctl reload ssh 2>/dev/null || systemctl restart ssh; ok "пароли выключены ($keys ключ(а) в authorized_keys)"; }
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
      out="$(echo | timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 2>/dev/null)"
      tls=$(echo "$out" | grep -c "TLSv1.3")
      alpn=$(echo "$out" | grep -c "ALPN protocol: h2")
      ver=$(echo "$out" | grep -c "Verify return code: 0")
      if [ "$tls" -ge 1 ] && [ "$alpn" -ge 1 ] && [ "$ver" -ge 1 ]; then
        printf '    %-22s OK\n' "$d"; [ -z "$BEST" ] && BEST="$d"
      else
        printf '    %-22s пропуск\n' "$d"
      fi
    done
    SNI="${BEST:-www.icloud.com}"
    ok "рекомендую SNI: $SNI  (можно задать свой через --sni)"
  fi
fi

### --- 11. проверки и итог ---------------------------------------------- ###
log "Проверки"
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
  1) Node   — адрес $MYIP, порт $NODE_PORT.
  2) Config profile + inbound — по типу:
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
  3) Host — адрес подключения клиента, fingerprint edge.
  4) Добавь inbound в сквод — ИНАЧЕ панель не отдаст его на ноду и порт
     $([ "$TYPE" = cdn ] && echo "$XRAY_PORT" || echo 443) не откроется.

Reality-ноды: КАЖДОЙ свои x25519-ключи и свой dest (общий конфиг → бан пачкой).
────────────────────────────────────────────────────────────────────────
EOF
