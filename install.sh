#!/usr/bin/env bash
set -u
set -o pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$BASE_DIR/lib/colors.sh"
source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/logging.sh"
source "$BASE_DIR/lib/backup.sh"
source "$BASE_DIR/modules/system-info.sh"
source "$BASE_DIR/modules/fail2ban.sh"
source "$BASE_DIR/modules/fail2ban-policy.sh"
source "$BASE_DIR/modules/audit.sh"
source "$BASE_DIR/modules/update.sh"
source "$BASE_DIR/modules/bbr.sh"

read_version() {
    local value=''
    [[ -r $BASE_DIR/VERSION ]] || return 1
    IFS= read -r value < "$BASE_DIR/VERSION" || [[ -n $value ]]
    [[ $value =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

show_menu() {
    printf '\n╔══════════════════════════════════════════════╗\n'
    printf '║               VPS TOOLKIT RU               ║\n'
    printf '║         Управление и защита VPS            ║\n'
    printf '╚══════════════════════════════════════════════╝\n'
    printf 'Версия: %s\nОС: %s\nIPv4: %s\nВремя работы: %s\n' "$TOOL_VERSION" "$(os_field PRETTY_NAME)" "$(first_public_ip 4)" "$(uptime_ru)"
    if (( DRY_RUN )); then say_warn 'Режим просмотра: изменения не выполняются.'; fi
    printf '\n1. Аудит сервера\n2. Обновление системы\n3. Fail2Ban / защита SSH\n4. BBR\n5. Информация о сервере\n6. История действий\n0. Выход\nВыберите пункт: '
}

toolkit_is_root() { (( EUID == 0 )); }

main() {
    local choice
    case "${1:-}" in
        --dry-run) DRY_RUN=1;;
        '') DRY_RUN=0;;
        --version) read_version; return;;
        *) say_error 'Допустимый аргумент: --dry-run или --version.'; return 2;;
    esac
    TOOL_VERSION=$(read_version) || { say_error 'Файл VERSION отсутствует или имеет неверный формат.'; return 1; }
    if ! toolkit_is_root; then say_error 'Запустите инструмент от root через sudo.'; return 1; fi
    if ! check_platform; then say_error 'Поддерживаются только Ubuntu 22.04 LTS и 24.04 LTS.'; return 1; fi
    while true; do
        show_menu
        IFS= read -r choice || { printf '\n'; return 0; }
        case "$choice" in
            1) audit_server; pause_menu;;
            2) update_menu;;
            3) fail2ban_menu;;
            4) bbr_menu;;
            5) system_info; pause_menu;;
            6) show_file_tail "$TOOL_LOG" 50; pause_menu;;
            0) say_info 'Работа завершена.'; return 0;;
            *) say_warn 'Неизвестный пункт меню.';;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
