#!/bin/bash
# Noema Snitch — установка одной командой:
#   curl -fsSL https://raw.githubusercontent.com/e2ret/noema-snitch/main/install.sh | bash
#
# Скачивает последний релиз с GitHub, ставит приложение в /Applications (заменяя
# старую версию), снимает карантин macOS и запускает его. Правила и настройки
# не трогаются. Сетевой помощник ставится кнопкой в самом приложении.
#
# Переменные (для проверки): NOEMA_INSTALL_DIR — куда ставить (по умолчанию /Applications),
# NOEMA_NO_OPEN=1 — не запускать после установки.
set -euo pipefail

REPO="e2ret/noema-snitch"
APP_NAME="Noema Snitch.app"
INSTALL_DIR="${NOEMA_INSTALL_DIR:-/Applications}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Noema Snitch работает только на macOS."
[ "$(uname -m)" = "arm64" ] || fail "Нужен Mac на Apple Silicon (M1 и новее)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Нужна macOS 14 Sonoma или новее (у вас $(sw_vers -productVersion))."

CURL=(curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2)

say "Ищу последний релиз…"
tag="" url=""
if release=$("${CURL[@]}" "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null); then
    tag=$(printf '%s' "$release" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    url=$(printf '%s' "$release" | grep '"browser_download_url"' | grep -- '-app\.zip"' | head -1 \
          | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')
fi
if [ -z "$url" ]; then
    # Запасной путь без API GitHub: тег берём из редиректа страницы последнего релиза.
    latest=$("${CURL[@]}" -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
        || fail "Не удалось связаться с GitHub. Проверьте интернет и повторите команду."
    tag=${latest##*/}
    case "$tag" in v*) ;; *) fail "Не удалось определить последний релиз." ;; esac
    url="https://github.com/$REPO/releases/download/$tag/NoemaSnitch-${tag#v}-app.zip"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Скачиваю Noema Snitch $tag…"
curl -fL --progress-bar --connect-timeout 15 --retry 3 --retry-delay 2 -o "$tmp/app.zip" "$url" || fail "Не удалось скачать $url"
ditto -x -k "$tmp/app.zip" "$tmp" || fail "Архив повреждён."
[ -d "$tmp/$APP_NAME" ] || fail "В архиве нет $APP_NAME."

# Закрываем только ту копию, которую заменяем.
running="$INSTALL_DIR/$APP_NAME/Contents/MacOS/NoemaSnitch"
if pgrep -f "$running" >/dev/null; then
    say "Закрываю запущенный Noema Snitch…"
    pkill -f "$running" || true
    sleep 1
fi

say "Устанавливаю в $INSTALL_DIR…"
mkdir -p "$INSTALL_DIR"
if [ -w "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR/$APP_NAME"
    ditto "$tmp/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
else
    say "Нужен пароль администратора для записи в $INSTALL_DIR."
    sudo rm -rf "$INSTALL_DIR/$APP_NAME"
    sudo ditto "$tmp/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
fi

# Приложение подписано без сертификата Apple: снимаем карантин, чтобы macOS его открыла.
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME" 2>/dev/null \
    || sudo xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true

say "Готово: Noema Snitch $tag установлен."
if [ "${NOEMA_NO_OPEN:-}" != "1" ]; then
    open "$INSTALL_DIR/$APP_NAME"
    echo "Если помощник ещё не установлен — нажмите в окне «Установить помощника…»."
    echo "Если он устарел — Настройки → «Обновить помощника…»."
fi
