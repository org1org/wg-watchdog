# WG Watchdog для KeeneticOS

Лёгкий watchdog для WireGuard на Keenetic с Entware. Проверяет внутренний адрес
сервера и при подтверждённом сбое перезапускает только нужный интерфейс.

![WG Watchdog Manager](docs/terminal-preview.png)

## Возможности

- отдельное cron-задание для каждого `WireguardN`;
- полноэкранное управление через `wgwm`;
- порог ошибок, boot grace и cooldown;
- безопасная работа с full-tunnel;
- транзакционное обновление с SHA-256 и откатом;
- состояние и блокировки в `/tmp` — без частых записей на накопитель Entware.

## Установка

Требуются KeeneticOS 5+, Entware и SSH-доступ от `root`.

```sh
wget -qO- https://raw.githubusercontent.com/org1org/wg-watchdog/main/install.sh | sh
wgwm
```

При переходе с v1.5.4 или более ранней версии добавьте `--force`:

```sh
wget -qO- https://raw.githubusercontent.com/org1org/wg-watchdog/main/install.sh | sh -s -- --force
```

## Команды

```sh
wgwm                         # управление
wgwm --plain                 # текстовый режим
wgwm --uninstall             # удаление
/opt/bin/wg-watchdog.sh --job Wireguard0 --force
```

Подробности по установке, настройке, диагностике и удалению находятся в
[Wiki](https://github.com/org1org/wg-watchdog/wiki). План развития — в
[ROADMAP.md](ROADMAP.md).

WG Watchdog не меняет ключи, пиры и конфигурацию WireGuard. Проект тестируется
mock-сценариями, POSIX shell-проверками и через настоящий PTY.
