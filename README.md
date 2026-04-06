# Teleproxy Manager

Скрипт автоматической установки и управления [Teleproxy](https://github.com/teleproxy/teleproxy) — высокопроизводительным MTProto-прокси для Telegram с защитой от DPI и Fake-TLS маскировкой.

## Установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/arblark/teleproxy-manager/main/teleproxy-manager.sh)
```

Скрипт установит Teleproxy через интерактивное меню и сохранит себя в `/usr/local/bin/teleproxy-manager` для дальнейшего управления.

## Возможности

- **Два метода установки** — Docker (рекомендуется) или бинарник + systemd
- **Fake-TLS** — маскировка трафика под обычный HTTPS
- **До 16 секретов** с метками, лимитами подключений, квотами и rate limit
- **IP-фильтрация** — блоклист / вайтлист по CIDR
- **PROXY Protocol v1/v2** — для работы за балансировщиками
- **SOCKS5 upstream** — проксирование исходящего трафика
- **DC Override** — переопределение адресов Telegram DC
- **DC Probes** — мониторинг задержек до дата-центров
- **Prometheus метрики** — HTTP-эндпоинт `/stats`
- **SIGHUP-перезагрузка** — смена секретов без разрыва соединений
- **Бэкапы и восстановление** конфигурации
- **Обновление** одной командой

## CLI-команды

После установки скрипт доступен как `teleproxy-manager`:

```
teleproxy-manager                      # интерактивное меню
teleproxy-manager status               # статус, метрики, uptime
teleproxy-manager start                # запустить прокси
teleproxy-manager stop                 # остановить прокси
teleproxy-manager restart              # перезапустить
teleproxy-manager logs [N]             # последние N строк логов (умолч. 50)
teleproxy-manager links                # ссылки подключения для Telegram

teleproxy-manager secrets list         # список секретов
teleproxy-manager secrets add          # добавить секрет
teleproxy-manager secrets remove N     # удалить секрет #N

teleproxy-manager config show          # показать конфиг
teleproxy-manager config edit          # открыть в редакторе

teleproxy-manager update               # обновить Teleproxy
teleproxy-manager update-self          # обновить скрипт
teleproxy-manager backup               # бэкап конфига
teleproxy-manager backup restore FILE  # восстановить из бэкапа
teleproxy-manager uninstall            # удалить Teleproxy

teleproxy-manager help                 # справка
```

## Интерактивное меню

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

## Конфигурация

Конфиг создаётся автоматически при установке:

```toml
# /etc/teleproxy/config.toml
port = 443
stats_port = 8888
http_stats = true
workers = 2
direct = true
domain = "www.google.com"

[[secret]]
key = "a1b2c3d4e5f6a7b8a1b2c3d4e5f6a7b8"
label = "family"

[[secret]]
key = "deadbeef12345678deadbeef12345678"
label = "friends"
limit = 50
```

Файлы:
- `/etc/teleproxy/config.toml` — конфигурация прокси
- `/var/lib/teleproxy/` — данные (proxy-multi.conf)
- `/root/teleproxy-backups/` — бэкапы

## FAQ

**Как сменить порт?**
```bash
teleproxy-manager   # меню → 8) Порты
```

**Как включить Fake-TLS?**
```bash
teleproxy-manager   # меню → 7) Fake-TLS
```
Или при установке — скрипт спросит автоматически.

**Как обновить Teleproxy?**
```bash
teleproxy-manager update
```

**Как добавить секрет для нового пользователя?**
```bash
teleproxy-manager secrets add
```

**Статистика показывает 404?**
Убедитесь, что в конфиге есть `http_stats = true`. Скрипт ставит его по умолчанию, но если конфиг был создан вручную — добавьте.

## Благодарности

- [Teleproxy](https://github.com/teleproxy/teleproxy) — оригинальный MTProto-прокси
- [Telegram](https://t.me/teleproxy_dev) — канал разработчика

## Лицензия

MIT
