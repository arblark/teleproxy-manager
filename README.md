# Teleproxy Manager

Скрипт для автоматической установки и управления [Teleproxy](https://github.com/teleproxy/teleproxy) — высокопроизводительным MTProto-прокси для Telegram с защитой от DPI и Fake-TLS маскировкой трафика под обычный HTTPS.

Устанавливается одной командой, предоставляет интерактивное меню и CLI для полного управления прокси-сервером.

## Установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/arblark/teleproxy-manager/main/teleproxy-manager.sh)
```

Скрипт проведёт через интерактивную настройку: предложит выбрать метод установки, порты, количество секретов, Fake-TLS маскировку — и запустит готовый прокси. После установки скрипт сохраняет себя в `/usr/local/bin/teleproxy-manager` и доступен как системная команда.

### Требования

- Linux (Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky Linux и другие)
- Архитектура amd64 или arm64
- Root-доступ
- Для Docker-метода: Docker будет установлен автоматически, если отсутствует
- Для Binary-метода: systemd

### Что происходит при установке

1. Проверяются и устанавливаются зависимости (`curl`, `jq`, `openssl`, `xxd`)
2. Для Docker — скачивается и запускается официальный образ `ghcr.io/teleproxy/teleproxy`
3. Для Binary — скачивается бинарник с GitHub Releases, создаётся systemd-сервис с hardening (NoNewPrivileges, ProtectSystem, ProtectHome)
4. Генерируется конфиг `/etc/teleproxy/config.toml` с выбранными параметрами
5. Генерируются криптографические секреты (16 байт из `/dev/urandom`)
6. Запускается прокси и выводятся готовые ссылки `tg://proxy` для подключения

## Возможности

- **Установка в одну строку** — Docker (рекомендуется) или бинарник + systemd
- **Fake-TLS маскировка** — трафик неотличим от обычного HTTPS, обход DPI
- **До 16 секретов** с метками, лимитами подключений, квотами и rate limit
- **IP-фильтрация** — блоклист / вайтлист по CIDR
- **PROXY Protocol v1/v2** — работа за HAProxy, nginx и другими балансировщиками
- **SOCKS5 upstream** — проксирование исходящего трафика через SOCKS5
- **DC Override** — переопределение адресов Telegram дата-центров
- **Мониторинг** — Prometheus-совместимые метрики на `/stats`, DC Probes
- **Горячая перезагрузка** — смена секретов и настроек без разрыва соединений (SIGHUP)
- **Бэкапы** — создание и восстановление конфигурации одной командой
- **Автообновление** — обновление Teleproxy и самого скрипта

## Интерактивное меню

При запуске без аргументов открывается интерактивное меню с информацией о текущем состоянии прокси:

```
  Teleproxy Manager v1.2  │  Teleproxy v4.9.0
  ● Работает  │  Docker  │  1.2.3.4  │  ⏱ 5ч 23м
  ──────────────────────────────────────────────

  УПРАВЛЕНИЕ
   1) Остановить прокси              работает 5ч 23м
   2) Перезапустить                  2 воркер(а)
   3) Логи                           docker logs
   4) Статус и метрики               3 подкл., 12MB
   5) Ссылки подключения             2 секр., FakeTLS: ✓ google.com

  НАСТРОЙКА
   6) Секреты                        2 шт, 1 с лимитом
   7) Fake-TLS домен                 ✓ www.google.com
   8) Порты                          443 / 8888
   9) IP-фильтры                     не заданы
  10) Расширенные настройки          direct, 2 ворк.
  11) Редактировать конфиг           /etc/teleproxy/config.toml

  СИСТЕМА
  12) Обновить Teleproxy
  13) Бэкап конфигурации
  14) Удалить Teleproxy

   0) Выход
```

В баннере отображаются: версия Teleproxy, статус, метод установки, внешний IP и uptime. Каждый пункт меню показывает текущие значения настроек.

## CLI-команды

Все действия доступны и через командную строку — удобно для автоматизации и crontab:

```bash
# Управление
teleproxy-manager status               # статус, метрики, Docker/systemd info, uptime
teleproxy-manager start                # запустить прокси
teleproxy-manager stop                 # остановить прокси
teleproxy-manager restart              # перезапустить
teleproxy-manager logs                 # последние 50 строк логов
teleproxy-manager logs 200             # последние 200 строк
teleproxy-manager links                # ссылки tg://proxy и t.me/proxy для подключения

# Секреты
teleproxy-manager secrets list         # список всех секретов с метками и лимитами
teleproxy-manager secrets add          # добавить новый секрет
teleproxy-manager secrets remove 2     # удалить секрет #2

# Конфигурация
teleproxy-manager config show          # вывести содержимое config.toml
teleproxy-manager config edit          # открыть в nano/vim/vi

# Обслуживание
teleproxy-manager update               # обновить Teleproxy до последней версии
teleproxy-manager update-self          # обновить скрипт менеджера
teleproxy-manager backup               # бэкап конфига в /root/teleproxy-backups/
teleproxy-manager backup restore FILE  # восстановить конфиг из бэкапа
teleproxy-manager uninstall            # полностью удалить Teleproxy
```

## Конфигурация

### Основные параметры

Конфиг создаётся автоматически при установке:

```toml
# /etc/teleproxy/config.toml
port = 443                    # порт для подключения клиентов
stats_port = 8888             # порт HTTP-статистики и QR-кодов
http_stats = true             # включить веб-страницу со статистикой
workers = 2                   # количество воркеров (обычно = количество ядер)
direct = true                 # прямое подключение к Telegram DC
domain = "www.google.com"     # домен для Fake-TLS маскировки

[[secret]]
key = "a1b2c3d4e5f6a7b8a1b2c3d4e5f6a7b8"
label = "family"              # метка для идентификации пользователя

[[secret]]
key = "deadbeef12345678deadbeef12345678"
label = "friends"
limit = 50                    # макс. одновременных подключений
```

### Расширенные параметры

Доступны через меню (пункт 10) или ручное редактирование конфига:

| Параметр | Описание | Пример |
|---|---|---|
| `proxy_protocol` | Включить PROXY Protocol v1/v2 для работы за балансировщиком | `true` |
| `socks5` | Upstream SOCKS5-прокси для исходящего трафика | `"user:pass@host:1080"` |
| `bind` | Привязка к конкретному IP-адресу | `"10.0.0.1"` |
| `ipv6` | Предпочитать IPv6 при подключении к Telegram DC | `true` |
| `dc_probe_interval` | Интервал мониторинга задержек до DC (в секундах) | `30` |
| `proxy_tag` | Тег от @MTProxybot для продвижения канала | `"abc123..."` |
| `maxconn` | Максимальное количество одновременных соединений | `60000` |
| `ip_blocklist` | Путь к файлу с заблокированными CIDR | `"/etc/teleproxy/blocklist.txt"` |
| `ip_allowlist` | Путь к файлу с разрешёнными CIDR | `"/etc/teleproxy/allowlist.txt"` |

### Квоты и ограничения секретов

Для каждого секрета можно задать индивидуальные ограничения (меню → 10 → 9):

| Параметр | Описание |
|---|---|
| `limit` | Макс. одновременных подключений |
| `quota` | Квота трафика в байтах (напр. 1073741824 = 1 GB) |
| `rate_limit` | Ограничение скорости (напр. `"100mb/h"`, `"1gb/d"`) |
| `max_ips` | Макс. количество уникальных IP-адресов |
| `expires` | Срок действия секрета (Unix timestamp) |

### DC Override

Переопределение адресов Telegram дата-центров — полезно при проблемах с маршрутизацией:

```toml
[[dc_override]]
dc = 2
host = "149.154.167.50"
port = 443
```

### Файлы и пути

| Путь | Описание |
|---|---|
| `/etc/teleproxy/config.toml` | Основной конфиг |
| `/var/lib/teleproxy/` | Рабочие данные (proxy-multi.conf) |
| `/root/teleproxy-backups/` | Бэкапы конфигурации |
| `/usr/local/bin/teleproxy-manager` | Скрипт менеджера |
| `/usr/local/bin/teleproxy` | Бинарник (при binary-установке) |
| `/etc/systemd/system/teleproxy.service` | Systemd-юнит (при binary-установке) |

## Fake-TLS маскировка

Fake-TLS — ключевая функция для обхода DPI (Deep Packet Inspection). При включении:

- Прокси притворяется обычным HTTPS-сервером указанного домена (напр. `www.google.com`)
- Клиентское соединение начинается с настоящего TLS handshake
- DPI-системы провайдера видят обычный HTTPS-трафик и не могут его заблокировать
- Секрет клиента автоматически получает префикс `ee` + hex-кодированный домен

Рекомендуется использовать домены крупных сервисов (`www.google.com`, `www.microsoft.com`, `cloudflare.com`) — их блокировка маловероятна.

## Мониторинг и статистика

При включённом `http_stats = true` (по умолчанию) доступны:

- **`http://<IP>:8888/stats`** — текстовая страница с метриками (активные соединения, трафик, uptime). Совместима с Prometheus scraping.
- **`http://<IP>:8888/link`** — страница с QR-кодами для подключения к каждому секрету. Удобно показать с телефона.

Доступ к `/stats` по умолчанию ограничен приватными сетями (RFC 1918). Расширить можно через параметр `stats_allow_net` в конфиге или через меню (пункт 9 → 3).

## Совместимость

| ОС | Docker | Binary + systemd |
|---|---|---|
| Ubuntu 20.04+ | да | да |
| Debian 11+ | да | да |
| CentOS 8+ / RHEL 8+ | да | да |
| AlmaLinux / Rocky Linux | да | да |
| Другие Linux (amd64, arm64) | да | — |

## FAQ

**Как поднять MTProto-прокси для Telegram за минуту?**
Запустите команду установки — скрипт всё сделает сам: установит Docker, создаст конфиг с Fake-TLS и секретом, запустит контейнер и выдаст готовую ссылку `tg://proxy`.

**Как подключиться к прокси?**
После установки скрипт покажет ссылки вида `tg://proxy?server=...&port=...&secret=...`. Откройте ссылку на устройстве с Telegram — прокси добавится автоматически. Также ссылки доступны на странице QR-кодов `http://<IP>:8888/link` и через команду `teleproxy-manager links`.

**Как включить маскировку трафика (Fake-TLS)?**
При установке скрипт предложит включить автоматически. Для уже работающего прокси — `teleproxy-manager` → пункт 7.

**Как добавить нового пользователя?**
```bash
teleproxy-manager secrets add
```
Каждый секрет — отдельная ссылка подключения. Можно задать метку (для идентификации), лимит соединений, квоту трафика, rate limit и срок действия.

**Как раздать прокси нескольким людям с разными лимитами?**
Создайте отдельный секрет для каждого пользователя с индивидуальными ограничениями. Через меню (пункт 6) или CLI. Максимум 16 секретов, у каждого своя ссылка, метка и лимиты.

**Как обновить Teleproxy до последней версии?**
```bash
teleproxy-manager update
```
Для Docker обновляется образ и пересоздаётся контейнер. Для binary — скачивается новый бинарник и перезапускается сервис.

**Как обновить сам скрипт менеджера?**
```bash
teleproxy-manager update-self
```

**Как сменить порт?**
`teleproxy-manager` → пункт 8. Для Docker контейнер пересоздаётся автоматически.

**Статистика показывает 404?**
Проверьте что в конфиге есть `http_stats = true`. Скрипт ставит это по умолчанию, но при ручном создании конфига параметр может отсутствовать.

**Работает ли за NAT / Cloudflare / с PROXY Protocol?**
Да — в расширенных настройках (пункт 10) можно включить PROXY Protocol v1/v2, задать SOCKS5 upstream и привязать к конкретному IP через Bind.

**Как сделать бэкап перед обновлением?**
```bash
teleproxy-manager backup
```
Бэкапы сохраняются в `/root/teleproxy-backups/` с датой в имени файла. Восстановление: `teleproxy-manager backup restore /root/teleproxy-backups/config_20250401_120000.toml`.

**Как продвигать свой канал через прокси?**
Получите Proxy Tag у бота [@MTProxybot](https://t.me/MTProxybot) и укажите его в расширенных настройках (пункт 10 → 7). Пользователи прокси увидят ваш канал в списке рекомендованных.

**Как полностью удалить?**
```bash
teleproxy-manager uninstall
```
Скрипт остановит и удалит контейнер/сервис, бинарники, и предложит удалить конфигурационные файлы.

## Благодарности

- [Teleproxy](https://github.com/teleproxy/teleproxy) — MTProto proxy server
- [Telegram](https://t.me/teleproxy_dev) — канал разработчика

## Лицензия

MIT

<!--
mtproto proxy install script, telegram proxy server setup, teleproxy docker,
fake tls mtproto, anti dpi telegram proxy, one line proxy install,
mtproto proxy manager bash, telegram proxy ubuntu vps, proxy protocol mtproto,
установка прокси телеграм, настройка mtproto, обход блокировки телеграм,
прокси сервер telegram с маскировкой, teleproxy auto installer
-->
