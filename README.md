# Teleproxy Manager

Скрипт автоматической установки и управления [Teleproxy](https://github.com/teleproxy/teleproxy) — MTProto прокси для Telegram с защитой от DPI.

## Установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/arblark/teleproxy-install/main/teleproxy-manager.sh)
```

## Возможности

- Установка через Docker или бинарник + systemd
- Fake-TLS маскировка, до 16 секретов, IP-фильтрация
- PROXY Protocol, SOCKS5, DC Override, Prometheus метрики
- Обновление, бэкапы, полное удаление

## Лицензия

MIT
