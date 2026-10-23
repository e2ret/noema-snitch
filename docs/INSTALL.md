# Noema Snitch — установка

[![Translate](https://img.shields.io/badge/Translate-To_Your_Language-red)](https://translate.google.com/translate?sl=auto&u=https://github.com/e2ret/noema-snitch/blob/main/docs/INSTALL.md)
[![Made with Claude Code](https://img.shields.io/badge/Made_with-Claude_Code-D97757)](https://claude.com/claude-code)

## Одной командой

Вставьте в Терминал:

    curl -fsSL https://raw.githubusercontent.com/e2ret/noema-snitch/main/install.sh | bash

Скрипт скачает последний релиз, поставит приложение в «Программы», снимет карантин и запустит его.
Дальше — шаг 3 ниже. Та же команда обновляет до новой версии.

## Вручную

1. Перетащите «Noema Snitch» в папку «Программы».
2. Первый запуск: приложение не подписано сертификатом Apple, поэтому macOS не откроет его
   двойным щелчком. Щёлкните по приложению правой кнопкой → «Открыть» → «Открыть».
   Если macOS пишет, что приложение повреждено, выполните в Терминале:

       xattr -dr com.apple.quarantine "/Applications/Noema Snitch.app"

3. В окне «Монитор» нажмите «Установить помощника…» и введите пароль администратора.
   Помощник — системная служба, которая фильтрует соединения; он запускается сам при
   включении Mac.
4. По желанию: Настройки → «Открывать при входе в систему».

Если пропал интернет: Настройки → «Удалить помощника…» или в Терминале:

    sudo launchctl bootout system/com.noema.snitch.helper
    sudo pfctl -a com.apple/noemasnitch -F all

Данные IP-геолокации: DB-IP (https://db-ip.com), лицензия CC BY 4.0.

Проект полностью сделан с помощью Claude Code (https://claude.com/claude-code).
