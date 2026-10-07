#!/usr/bin/env bash

BBR_CONFIG=/etc/sysctl.d/99-vps-toolkit-bbr.conf

bbr_current() { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null; }
bbr_qdisc() { sysctl -n net.core.default_qdisc 2>/dev/null; }
bbr_available() { sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null; }

bbr_supported() {
    local available
    available=$(bbr_available) || return 1
    [[ " $available " == *' bbr '* ]] && return 0
    has_cmd modinfo && modinfo tcp_bbr >/dev/null 2>&1
}

bbr_status() {
    local cc qdisc available
    cc=$(bbr_current || printf 'Недоступно')
    qdisc=$(bbr_qdisc || printf 'Недоступно')
    available=$(bbr_available || printf 'Недоступно')
    printf 'Текущий алгоритм TCP: %s\nОчередь по умолчанию: %s\nДоступные алгоритмы: %s\n' "$cc" "$qdisc" "$available"
    printf 'BBR доступен: %s\n' "$(yes_no bbr_supported)"
    if [[ $cc == bbr ]]; then say_ok 'BBR активен для TCP.'; else say_info 'BBR не активен.'; fi
    if has_cmd lsmod; then
        if lsmod | awk '$1 == "tcp_bbr" {found=1} END {exit !found}'; then say_info 'Модуль tcp_bbr загружен.'
        else say_info 'Модуль tcp_bbr не виден в lsmod; он может быть встроен в ядро.'; fi
    fi
    say_info 'BBR влияет на TCP; прямого эффекта на UDP, QUIC и Hysteria2 нет.'
}

bbr_config_content() {
    local previous_cc=$1 previous_qdisc=$2
    printf '# Управляется VPS Toolkit RU. Предыдущие значения нужны для отключения.\n'
    printf '# previous_cc=%s\n# previous_qdisc=%s\n' "$previous_cc" "$previous_qdisc"
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n'
}

bbr_saved_value() {
    local key=$1 value
    value=$(sed -n "s/^# ${key}=//p" "$BBR_CONFIG" | head -n 1)
    [[ $value =~ ^[a-zA-Z0-9_]+$ ]] || return 1
    printf '%s\n' "$value"
}

bbr_file_owned() {
    local saved_cc saved_qdisc actual expected
    [[ -f $BBR_CONFIG && ! -L $BBR_CONFIG ]] || return 1
    saved_cc=$(bbr_saved_value previous_cc) || return 1
    saved_qdisc=$(bbr_saved_value previous_qdisc) || return 1
    actual=$(cat -- "$BBR_CONFIG") || return 1
    expected=$(bbr_config_content "$saved_cc" "$saved_qdisc") || return 1
    [[ $actual == "$expected" ]]
}

bbr_sysctl_files() {
    local root=${1:-} file dir
    for dir in "$root"/etc/sysctl.d "$root"/run/sysctl.d "$root"/usr/local/lib/sysctl.d "$root"/usr/lib/sysctl.d "$root"/lib/sysctl.d; do
        if [[ -d $dir && ( ! -r $dir || ! -x $dir ) ]]; then return 1; fi
    done
    for file in "$root"/etc/sysctl.conf "$root"/etc/sysctl.d/*.conf "$root"/run/sysctl.d/*.conf \
        "$root"/usr/local/lib/sysctl.d/*.conf "$root"/usr/lib/sysctl.d/*.conf "$root"/lib/sysctl.d/*.conf; do
        [[ -f $file && $file != "$BBR_CONFIG" ]] && printf '%s\n' "$file"
    done
    return 0
}

bbr_sysctl_conflicts() {
    local file files found=0
    files=$(bbr_sysctl_files "${1:-}") || { printf 'Не удалось перечислить файлы sysctl.\n'; return 1; }
    [[ -n $files ]] || return 0
    while IFS= read -r file; do
        [[ -r $file ]] || { printf 'Недоступен для чтения: %s\n' "$file"; found=1; continue; }
        awk -v path="$file" '
            /^[[:space:]]*[#;]/ {next}
            {
                sub(/[[:space:]]*[#;].*$/, "")
                separator=index($0, "=")
                if (!separator) next
                key=substr($0, 1, separator-1)
                value=substr($0, separator+1)
                gsub(/[[:space:]]/, "", key)
                normalized=key
                sub(/^-+/, "", normalized)
                if (normalized != "net.ipv4.tcp_congestion_control" && normalized != "net.core.default_qdisc") next
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if ((key != normalized && key != "-" normalized) || value !~ /^[a-zA-Z0-9_]+$/) {
                    printf "Неоднозначное определение sysctl: %s:%d\n", path, FNR
                    invalid=1
                    next
                }
                if ((normalized == "net.ipv4.tcp_congestion_control" && value != "bbr") ||
                    (normalized == "net.core.default_qdisc" && value != "fq"))
                    printf "%s: %s = %s\n", path, normalized, value
            }
            END {if (invalid) exit 2}
        ' "$file" || { printf 'Ошибка чтения: %s\n' "$file"; found=1; }
    done <<< "$files"
    (( found == 0 ))
}

bbr_transaction_exit() {
    local result=$1 restored=1
    trap - EXIT
    trap '' INT TERM
    if [[ -n ${BBR_TMP:-} ]]; then rm -f -- "$BBR_TMP" 2>/dev/null || true; fi
    if (( result != 0 )); then
        if (( BBR_CHANGED )); then
            if [[ -n ${BBR_PREVIOUS:-} && -f $BBR_PREVIOUS ]]; then
                cp -a -- "$BBR_PREVIOUS" "$BBR_CONFIG" 2>/dev/null || restored=0
            else
                rm -f -- "$BBR_CONFIG" 2>/dev/null || restored=0
            fi
        fi
        if (( BBR_LIVE_TOUCHED )); then
            sysctl -w "net.ipv4.tcp_congestion_control=$BBR_OLD_CC" >/dev/null 2>&1 || restored=0
            sysctl -w "net.core.default_qdisc=$BBR_OLD_QDISC" >/dev/null 2>&1 || restored=0
            [[ $(bbr_current) == "$BBR_OLD_CC" && $(bbr_qdisc) == "$BBR_OLD_QDISC" ]] || restored=0
        fi
        if (( BBR_CHANGED || BBR_LIVE_TOUCHED )); then
            if (( restored )); then say_warn 'Предыдущая конфигурация BBR восстановлена.'
            else say_error 'Откат BBR не удался; проверьте резервную копию и текущие параметры.'; fi
        fi
        log_action ERROR 'Операция BBR не завершена' || true
    fi
}

bbr_apply_enable() (
    local saved_cc=$1 saved_qdisc=$2
    BBR_OLD_CC=$3 BBR_OLD_QDISC=$4 BBR_PREVIOUS='' BBR_TMP='' BBR_CHANGED=0 BBR_LIVE_TOUCHED=0
    trap 'bbr_transaction_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    require_commands sysctl mktemp || return 1
    if [[ -f $BBR_CONFIG ]]; then backup_file "$BBR_CONFIG" || return 1; BBR_PREVIOUS=$BACKUP_LAST; fi
    BBR_TMP=$(mktemp /etc/sysctl.d/.vps-toolkit-bbr.XXXXXX) || { say_error 'Не удалось создать временный файл BBR.'; return 1; }
    bbr_config_content "$saved_cc" "$saved_qdisc" > "$BBR_TMP" || return 1
    chmod 0644 "$BBR_TMP" 2>/dev/null || return 1
    BBR_CHANGED=1
    mv -f -- "$BBR_TMP" "$BBR_CONFIG" 2>/dev/null || { say_error 'Не удалось записать конфигурацию BBR.'; return 1; }
    BBR_TMP=''
    if [[ " $(bbr_available) " != *' bbr '* ]]; then
        if ! has_cmd modprobe || ! modprobe tcp_bbr >/dev/null 2>&1; then say_error 'Модуль tcp_bbr не удалось загрузить.'; return 1; fi
    fi
    BBR_LIVE_TOUCHED=1
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 \
        || ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 \
        || [[ $(bbr_current) != bbr || $(bbr_qdisc) != fq ]]; then
        say_error 'Не удалось применить или проверить BBR.'
        return 1
    fi
    log_action INFO 'Включён и проверен BBR для TCP' || return 1
    say_ok 'BBR включён и проверен. Новые параметры очереди действуют для новых соединений.'
)

bbr_enable() {
    local old_cc old_qdisc saved_cc saved_qdisc conflicts
    if [[ -e $BBR_CONFIG || -L $BBR_CONFIG ]] && ! bbr_file_owned; then
        say_warn 'Файл BBR изменён вручную или является ссылкой; автоматическая перезапись отменена.'; return 0
    fi
    old_cc=$(bbr_current) || { say_error 'Не удалось прочитать текущий TCP-алгоритм.'; return 1; }
    old_qdisc=$(bbr_qdisc) || { say_error 'Не удалось прочитать текущую очередь.'; return 1; }
    conflicts=$(bbr_sysctl_conflicts) || { say_warn "$conflicts"; say_warn 'Проверка других файлов sysctl неполная; включение BBR отменено.'; return 0; }
    if [[ -n $conflicts ]]; then
        say_warn 'Найдены конфликтующие определения sysctl:'
        printf '%s\n' "$conflicts"
        say_warn 'После перезагрузки порядок применения файлов может изменить результат. Включение BBR отменено; чужие файлы не изменяются.'
        return 0
    fi
    if [[ $old_cc == bbr && ! -e $BBR_CONFIG ]]; then
        say_info 'BBR уже настроен вне toolkit. Эта настройка сохранена без изменений.'; return 0
    fi
    if [[ $old_cc == bbr && $old_qdisc == fq && -f $BBR_CONFIG ]]; then
        say_ok 'BBR сейчас активен; конфликтующих определений в проверенных файлах не найдено.'
        say_info 'Постоянство настройки после перезагрузки не гарантируется; проверьте её после плановой перезагрузки.'
        return 0
    fi
    if ! bbr_supported; then say_error 'Ядро не сообщает о поддержке BBR.'; return 1; fi
    if [[ ! $old_cc =~ ^[a-zA-Z0-9_]+$ || ! $old_qdisc =~ ^[a-zA-Z0-9_]+$ ]]; then say_error 'Текущие параметры ядра имеют неожиданный формат.'; return 1; fi
    saved_cc=$old_cc saved_qdisc=$old_qdisc
    if [[ -f $BBR_CONFIG ]]; then
        saved_cc=$(bbr_saved_value previous_cc) || return 1
        saved_qdisc=$(bbr_saved_value previous_qdisc) || return 1
    fi
    say_info 'BBR не гарантирует улучшение для любого трафика.'
    if ! confirm 'Включить BBR для TCP и очередь fq?'; then say_info 'Действие отменено.'; return 0; fi
    if (( DRY_RUN )); then say_info "План: сохранить копию при необходимости, записать $BBR_CONFIG и применить два параметра ядра."; return 0; fi
    prepare_mutation || return 1
    bbr_apply_enable "$saved_cc" "$saved_qdisc" "$old_cc" "$old_qdisc" || return 1
    bbr_status
    say_info 'Постоянство настройки после перезагрузки не гарантируется; проверьте её после плановой перезагрузки.'
}

bbr_apply_disable() (
    local restore_cc=$1 restore_qdisc=$2
    BBR_OLD_CC=$3 BBR_OLD_QDISC=$4 BBR_PREVIOUS='' BBR_TMP='' BBR_CHANGED=0 BBR_LIVE_TOUCHED=0
    trap 'bbr_transaction_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    require_commands sysctl || return 1
    backup_file "$BBR_CONFIG" || return 1
    BBR_PREVIOUS=$BACKUP_LAST
    BBR_CHANGED=1
    rm -f -- "$BBR_CONFIG" 2>/dev/null || { say_error 'Не удалось удалить конфигурацию BBR.'; return 1; }
    BBR_LIVE_TOUCHED=1
    if ! sysctl -w "net.ipv4.tcp_congestion_control=$restore_cc" >/dev/null 2>&1 \
        || ! sysctl -w "net.core.default_qdisc=$restore_qdisc" >/dev/null 2>&1 \
        || [[ $(bbr_current) != "$restore_cc" || $(bbr_qdisc) != "$restore_qdisc" ]]; then
        say_error 'Не удалось восстановить или проверить предыдущие параметры.'
        return 1
    fi
    log_action INFO 'Удалена настройка BBR и восстановлены предыдущие параметры' || return 1
    say_ok 'Настройка BBR удалена, предыдущие параметры восстановлены.'
)

bbr_disable() {
    local restore_cc restore_qdisc active_cc active_qdisc available
    if [[ ! -e $BBR_CONFIG && ! -L $BBR_CONFIG ]]; then say_info 'Конфигурация BBR toolkit отсутствует; другие настройки не меняются.'; return 0; fi
    if ! bbr_file_owned; then say_warn 'Файл BBR изменён вручную или является ссылкой; удаление отменено.'; return 0; fi
    active_cc=$(bbr_current) || { say_error 'Не удалось прочитать текущий TCP-алгоритм.'; return 1; }
    active_qdisc=$(bbr_qdisc) || { say_error 'Не удалось прочитать текущую очередь.'; return 1; }
    if [[ $active_cc != bbr || $active_qdisc != fq ]]; then
        say_warn 'Текущие параметры отличаются от настройки toolkit; автоматическое отключение отменено.'; return 0
    fi
    restore_cc=$(bbr_saved_value previous_cc) || { say_error 'Не найден предыдущий TCP-алгоритм.'; return 1; }
    restore_qdisc=$(bbr_saved_value previous_qdisc) || { say_error 'Не найдена предыдущая очередь.'; return 1; }
    available=$(bbr_available) || { say_error 'Не удалось получить список доступных TCP-алгоритмов.'; return 1; }
    if [[ $restore_cc == bbr || " $available " != *" $restore_cc "* ]]; then
        if [[ " $available " == *' cubic '* ]]; then
            say_warn "Предыдущий алгоритм $restore_cc недоступен или равен BBR. Будет использован cubic."
            restore_cc=cubic
        else say_error 'Безопасный алгоритм для возврата не найден; отключение отменено.'; return 1; fi
    fi
    if ! confirm "Удалить файл toolkit и установить $restore_cc / $restore_qdisc?"; then say_info 'Действие отменено.'; return 0; fi
    if (( DRY_RUN )); then say_info "План: сохранить копию, удалить $BBR_CONFIG и применить $restore_cc / $restore_qdisc."; return 0; fi
    prepare_mutation || return 1
    bbr_apply_disable "$restore_cc" "$restore_qdisc" "$active_cc" "$active_qdisc"
}

bbr_menu() {
    local choice
    while true; do
        printf '\n════════ BBR ════════\n'; bbr_status
        printf '1. Проверить поддержку BBR\n2. Включить BBR\n3. Проверить состояние BBR\n4. Отключить BBR\n5. Назад\nВыберите пункт: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) if bbr_supported; then say_ok 'Поддержка BBR обнаружена.'; else say_warn 'Поддержка BBR не обнаружена.'; fi; pause_menu;;
            2) bbr_enable; pause_menu;;
            3) bbr_status; pause_menu;;
            4) bbr_disable; pause_menu;;
            5) return;;
            *) say_warn 'Неизвестный пункт меню.';;
        esac
    done
}
