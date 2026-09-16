# pulsar-node-setup

Скрипты подготовки нод для панели **Remnawave**. Готовят только саму ноду
(пакеты, сеть, docker, nginx/сертификат по типу, `remnanode`) — профиль,
инбаунд, хост и сквод настраиваются **в панели**. В API панели скрипты не ходят,
поэтому работают с любой Remnawave-панелью.

Только **Ubuntu 24.04**, запуск под `root`.

## Быстрый старт

**1. Доступ** — на новом VPS (из консоли хостинга или по паролю):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/galeevv/pulsar-node-setup/main/bootstrap-node-access.sh) \
  --key "ssh-ed25519 AAAA... твой-ключ"
```

**2. Нода** — по SSH на этот VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/galeevv/pulsar-node-setup/main/new-node.sh) \
  --type cdn --domain static.example.com --cdn-domain media.example.com --panel-ip 1.2.3.4
```

> Запуск именно через `bash <(curl …)`, а **не** `curl … | bash` — иначе
> интерактивные вопросы не сработают (pipe занимает stdin).

На шаге `remnanode` скрипт попросит `SECRET_KEY` панели и остановится — положи
ключ (см. ниже) и запусти ту же команду ещё раз, он продолжит.

## Типы нод

| `--type` | Что делает на ноде | Серт | Сайт | Скорость |
| --- | --- | --- | --- | --- |
| `cdn` | nginx на 443 + туннель в xray на loopback, за российским CDN | origin (LE) | да | ~5 мин |
| `selfsteal` | xray на 443, nginx-сайт на loopback как Reality-таргет | домен (LE) | да | ~5 мин |
| `reality` | только xray на 443, автоподбор SNI (dest), без nginx/серта | — | нет | ~2 мин |
| `hysteria` | Hysteria2 (UDP 443), сертификат для xray, без nginx | домен (LE) | нет | ~3 мин |

Примеры:

```bash
# CDN/LTE (как Польша/Германия LTE)
new-node.sh --type cdn --domain static.example.com --cdn-domain media.example.com --panel-ip 1.2.3.4

# Self-steal Reality со своим сайтом (транспорт потом меняешь в панели)
new-node.sh --type selfsteal --domain node.example.com --panel-ip 1.2.3.4

# Простая Reality (свой SNI или автоподбор)
new-node.sh --type reality --domain node.example.com --sni www.icloud.com --panel-ip 1.2.3.4

# Hysteria2
new-node.sh --type hysteria --domain node.example.com --panel-ip 1.2.3.4
```

Без аргументов — спросит всё интерактивно.

## Ключ панели (`SECRET_KEY`)

Каждая нода авторизуется в панели ключом. Он **одинаковый** у всех нод одной панели.

- есть другие ноды → скопируй `.env` с любой живой:
  `scp -3 root@<живая-нода>:/opt/remnanode/.env root@<новая>:/opt/remnanode/.env`
- первая нода → ключ показывается в панели при создании ноды.

**Не** брать ключ из `GET /api/keygen` — он отдаёт другой ключ, нода не подключится.

Вручную:
```bash
printf 'NODE_PORT=2222\nSECRET_KEY=<ключ>\n' > /opt/remnanode/.env && chmod 600 /opt/remnanode/.env
```

## Что заложено

- Обновление пакетов, swap (2G), BBR + сетевые буферы, лимиты дескрипторов.
- Docker с ротацией логов; контейнеру задан **лимит памяти** (~75% RAM) —
  если xray потечёт, docker перезапустит только его, не роняя сервер.
- ufw: 22/80/443 наружу, порт управления (2222) — только с IP панели;
  для Hysteria дополнительно 443/udp.
- CDN: тюнинг nginx (`worker_connections`), буферизация выключена, keepalive-пул.
- Let's Encrypt с автопродлением (где нужен серт).
- `--node-image` пинит версию образа ноды (по умолчанию `remnawave/node:latest`).

## Полезные флаги

| Флаг | Смысл |
| --- | --- |
| `--panel-ip <IP>` | IP панели (ufw откроет ей 2222). Обязателен. |
| `--sni <домен>` | SNI/dest для `reality` вручную (иначе автоподбор). |
| `--node-image <образ>` | зафиксировать версию образа ноды. |
| `--node-port <порт>` | порт управления, если у панели не 2222. |
| `--mem-limit <напр. 1500m>` | лимит памяти контейнеру вручную. |
| `--harden` | отключить вход по паролю (после проверки ключа). |
| `--yes` | не задавать вопросы (брать значения по умолчанию). |

## После скрипта — в панели

Скрипт печатает готовые параметры. В панели: создать Node → Config profile +
inbound по типу → Host → **добавить inbound в сквод** (иначе порт не откроется).
Каждой Reality-ноде — свои x25519-ключи и свой dest.
