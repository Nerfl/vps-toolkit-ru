#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install.sh"
fail() { printf 'ОШИБКА: %s\n' "$1" >&2; exit 1; }

fixture=$(mktemp -d) || fail 'Не удалось создать временный каталог backup.'
successful_session=''
unsafe_session=''
cleanup() {
    rm -f -- "$fixture/config" "$fixture/link"
    if [[ -n $successful_session && $successful_session == "$fixture/backups/"* ]]; then
        rm -f -- "$successful_session/config"
        rmdir -- "$successful_session" 2>/dev/null || true
    fi
    if [[ -n $unsafe_session && $unsafe_session == "$fixture/backups/"* ]]; then
        rmdir -- "$unsafe_session" 2>/dev/null || true
    fi
    rmdir -- "$fixture/backups" "$fixture/elsewhere" "$fixture" 2>/dev/null || true
}
trap cleanup EXIT
TOOL_BACKUPS=$fixture/backups
mkdir -m 0700 -- "$TOOL_BACKUPS" "$fixture/elsewhere" || fail 'Не удалось создать тестовые каталоги backup.'
printf 'Тестовая конфигурация\n' > "$fixture/config"
cd -- "$fixture" || fail 'Не удалось перейти в тестовый каталог.'
DRY_RUN=0
MOCK_BASE_OWNER=0 MOCK_BASE_MODE=700 MOCK_SESSION_OWNER=0 MOCK_SESSION_MODE=700
log_action() { return 0; }
stat() {
    if [[ ${1:-} == -c && ${2:-} == '%u %a' ]]; then
        if [[ ${4:-} == "$TOOL_BACKUPS" ]]; then printf '%s %s\n' "$MOCK_BASE_OWNER" "$MOCK_BASE_MODE"
        else printf '%s %s\n' "$MOCK_SESSION_OWNER" "$MOCK_SESSION_MODE"; fi
    else command stat "$@"; fi
}

backup_file config >/dev/null || fail 'Безопасный каталог root ошибочно отклонён.'
successful_session=$BACKUP_SESSION
cmp -s config "$successful_session/config" || fail 'Резервная копия в безопасном каталоге неверна.'
printf 'OK: root-owned каталог и закрытый сеанс принимаются.\n'

BACKUP_SESSION=''
MOCK_BASE_MODE=777
if backup_file config >/dev/null 2>&1; then fail 'Каталог, доступный другим на запись, принят.'; fi
MOCK_BASE_MODE=700 MOCK_BASE_OWNER=1000
if backup_file config >/dev/null 2>&1; then fail 'Каталог не-root владельца принят.'; fi
MOCK_BASE_OWNER=0
TOOL_BACKUPS=$fixture/link
ln -s "$fixture/elsewhere" "$TOOL_BACKUPS" || fail 'Не удалось создать тестовую ссылку.'
if backup_file config >/dev/null 2>&1; then fail 'Symlink каталога backup принят.'; fi
TOOL_BACKUPS=$fixture/backups
printf 'OK: чужой владелец, запись group/other и symlink блокируются.\n'

unsafe_session=$TOOL_BACKUPS/19990101-000000
mkdir -m 0700 -- "$unsafe_session" || fail 'Не удалось создать заранее подготовленный сеанс.'
BACKUP_SESSION=$unsafe_session
MOCK_SESSION_MODE=777
if backup_file config >/dev/null 2>&1; then fail 'Небезопасный заранее подготовленный сеанс принят.'; fi
[[ ! -e $unsafe_session/config ]] || fail 'Резервная копия записана в небезопасный сеанс.'
MOCK_SESSION_MODE=700 MOCK_SESSION_OWNER=1000
if backup_file config >/dev/null 2>&1; then fail 'Сеанс не-root владельца принят.'; fi
printf 'OK: небезопасный или чужой заранее подготовленный сеанс останавливает backup.\n'
