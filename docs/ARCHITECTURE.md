# Noema Snitch — архитектура

[![Translate](https://img.shields.io/badge/Translate-To_Your_Language-red)](https://translate.google.com/translate?sl=auto&u=https://github.com/e2ret/noema-snitch/blob/main/docs/ARCHITECTURE.md)
[![Made with Claude Code](https://img.shields.io/badge/Made_with-Claude_Code-D97757)](https://claude.com/claude-code)

Проект полностью сделан с помощью [Claude Code](https://claude.com/claude-code): анализ Little Snitch и LuLu
(REA + Ghidra), архитектура, весь код, иконка, документация и релизы.

Своё приложение-аналог Little Snitch, написанное с нуля на Swift/SwiftUI.
Интерфейс: русский и английский, язык берётся из системы macOS
(`CFBundleLocalizations = [en, ru]`). Платный Apple Developer аккаунт не нужен.

## Что показал анализ оригиналов (REA + codesign)

| | Little Snitch 6.0.4 | LuLu 4.3.0 |
|---|---|---|
| Фильтр трафика | System Extension `NEFilterDataProvider` | System Extension `NEFilterDataProvider` |
| DNS | `NEDNSProxyProvider` | — |
| Процессы | Endpoint Security system extension | — |
| UI | приложение + Agent (меню-бар/алерты) + Network Monitor | приложение + popover |

Оба требуют entitlement `com.apple.developer.networking.networkextension`,
который выдаётся только платному аккаунту. Поэтому Noema Snitch перехватывает
трафик по-другому. LuLu — GPL-3: читаем для понимания, код не копируем.

## Как работает перехват (без Network Extension)

```
 приложение ──TCP──▶ pf (anchor com.apple/noemasnitch)
                       │ route-to lo0 + rdr → 127.0.0.1:47900
                       ▼
               NoemaHelper (root LaunchDaemon)
               1. оригинальный адрес: DIOCNATLOOK на /dev/pf (запасной путь — pfctl -s state)
               2. процесс: libproc ищет сокет с этим локальным портом
               3. хост: TLS SNI / HTTP Host (подглядываем, не читая)
               4. правило? → разрешить/запретить
                  нет правила → окно «Разрешить/Запретить» в приложении, соединение ждёт
               5. разрешено → соединяемся сами и прокачиваем байты; запрещено → RST
                       │
                       ▼  Unix-сокет /var/run/com.noema.snitch.sock (JSON-строки)
               Noema Snitch.app (SwiftUI): окно запроса, правила, журнал, список соединений
```

- Свои сокеты помощник помечает группой `_noemasnitch`; pf их не заворачивает
  (`group != _noemasnitch`), поэтому петли нет.
- `/etc/pf.conf` не меняется: якорь висит под `com.apple/*`.
- QUIC (UDP 443) по умолчанию блокируется — браузеры переходят на TCP, который фильтруется.
- Остальной UDP (DNS, звонки, игры) пока не фильтруется по приложению.
- При остановке помощник удаляет правила pf. Если сеть пропала:
  `sudo ./scripts/emergency-off.sh`.

## Правила
Приложение (путь к исполняемому файлу или «любое»), хост/IP (`*.domain` — с поддоменами
или «любой»), порт, действие, срок: один раз / до выхода процесса / всегда.
Выигрывает самое конкретное правило, при равенстве — запрет.
Постоянные правила: `/Library/Application Support/NoemaSnitch/rules.json`.

## Сборка и установка
```bash
./scripts/build-app.sh          # → build/Noema Snitch.app (swiftc напрямую)
./scripts/make-dmg.sh           # → build/NoemaSnitch-<версия>.dmg для передачи другим
./scripts/make-icon.sh          # перерисовать иконку → Resources/AppIcon.icns
```
- Помощник ставится из приложения: баннер в мониторе или Настройки → «Сетевой помощник»
  (скрипты `install-helper.sh` / `uninstall-helper.sh` лежат внутри .app и запускаются
  через `osascript … with administrator privileges`). Если помощник в приложении новее
  установленного — кнопка «Обновить помощника…».
- Помощник — LaunchDaemon (`RunAtLoad`, `KeepAlive`): стартует при загрузке Mac, до входа
  пользователя; фильтрует трафик всех пользователей; правила общие.
- Приложение при входе в систему: Настройки → «Открывать при входе» (`SMAppService.mainApp`).
- Подпись ad-hoc: на другом Mac первый запуск — правый клик → «Открыть» (см. [docs/INSTALL.md](INSTALL.md)).
- Лог помощника: `/var/log/noemasnitch.log`. Аварийно: `sudo ./scripts/emergency-off.sh`.

## Глобус соединений
Монитор сети показывает вращающийся глобус (мышь — повернуть, колесо/щипок — приблизить):
дуги от этого Mac к городам, куда идут соединения (оранжевые — запрещённые).
- Суша: Natural Earth 1:110m (общественное достояние) → `Resources/Geo/land.bin`.
- IP → город: DB-IP City Lite (CC BY 4.0, подпись «IP data by DB-IP» в окне обязательна)
  → `Resources/Geo/ipcity.bin.lzfse`, всё офлайн. Пересборка: `scripts/build-geodata.py`.
- Своё местоположение — по часовому поясу macOS (`/usr/share/zoneinfo/zone.tab`), без сети.

## Дальше
- Фильтрация UDP по приложению.
- Подпись правил по code signature, а не по пути.
- Статистика трафика, карта соединений, профили, импорт/экспорт правил.
