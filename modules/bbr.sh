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
    if [[ $cc == bbr && $qdisc == fq ]]; then
        say_info 'После плановой перезагрузки проверьте: net.ipv4.tcp_congestion_control = bbr и net.core.default_qdisc = fq. Автоматической перезагрузки нет.'
    fi
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
    local root=${1:-} file dir canonical canonical_root prefix expected basename link_target
    local managed="$root/etc/sysctl.d/99-vps-toolkit-bbr.conf"
    local -A seen_dirs=() seen_names=() seen_files=()
    has_cmd realpath && has_cmd readlink || return 1
    canonical_root=$(realpath -e -- "${root:-/}") || return 1
    [[ $canonical_root != *$'\n'* ]] || return 1
    prefix=${canonical_root%/}
    file="$root/etc/sysctl.conf"
    if [[ -e $file || -L $file ]]; then
        [[ $file != *$'\n'* && -f $file && ! -L $file && -r $file ]] || return 1
        canonical=$(realpath -e -- "$file") || return 1
        [[ $canonical == "$prefix/etc/sysctl.conf" ]] || return 1
        seen_files[$canonical]=1
        printf '%s\n' "$file"
    fi
    for dir in "$root"/etc/sysctl.d "$root"/run/sysctl.d "$root"/usr/local/lib/sysctl.d "$root"/usr/lib/sysctl.d "$root"/lib/sysctl.d; do
        [[ -e $dir || -L $dir ]] || continue
        [[ -d $dir && -r $dir && -x $dir ]] || return 1
        canonical=$(realpath -e -- "$dir") || return 1
        [[ $canonical != *$'\n'* ]] || return 1
        expected="$prefix${dir#"$root"}"
        if [[ $dir == "$root/lib/sysctl.d" ]]; then
            [[ $canonical == "$expected" || $canonical == "$prefix/usr/lib/sysctl.d" ]] || return 1
        else
            [[ $canonical == "$expected" ]] || return 1
        fi
        [[ -v seen_dirs[$canonical] ]] && continue
        seen_dirs[$canonical]=1
        for file in "$dir"/*.conf; do
            [[ -e $file || -L $file ]] || continue
            [[ $file != *$'\n'* ]] || return 1
            basename=${file##*/}
            if [[ -L $file ]]; then
                [[ $file != "$managed" ]] || return 1
                link_target=$(readlink -- "$file") || return 1
                if [[ $link_target == /dev/null ]]; then
                    [[ $(realpath -e -- "$file") == /dev/null ]] || return 1
                elif [[ $file == "$root/etc/sysctl.d/99-sysctl.conf" \
                    && ( $link_target == ../sysctl.conf || $link_target == "$root/etc/sysctl.conf" ) ]]; then
                    [[ -f $file && -r $file && ! -L "$root/etc/sysctl.conf" ]] || return 1
                    canonical=$(realpath -e -- "$file") || return 1
                    [[ $canonical == "$prefix/etc/sysctl.conf" && -v seen_files[$canonical] ]] || return 1
                else
                    return 1
                fi
                seen_names[$basename]=1
                continue
            fi
            [[ -f $file && -r $file ]] || return 1
            canonical=$(realpath -e -- "$file") || return 1
            [[ $canonical != *$'\n'* ]] || return 1
            [[ -v seen_names[$basename] ]] && continue
            seen_names[$basename]=1
            [[ $file == "$managed" || -v seen_files[$canonical] ]] && continue
            seen_files[$canonical]=1
            printf '%s\n' "$file"
        done
    done
    return 0
}

bbr_sysctl_conflicts() {
    local root=${1:-} file files definitions key value ignore basename target label note
    local issues='' earlier='' LC_ALL=C
    files=$(bbr_sysctl_files "$root") || { printf 'Не удалось полностью перечислить безопасные файлы sysctl.\n'; return 1; }
    [[ -n $files ]] || return 0
    while IFS= read -r file; do
        if [[ ! -f $file || -L $file || ! -r $file ]]; then
            issues+="Недоступен или необычен источник sysctl: $file"$'\n'
            continue
        fi
        definitions=$(awk -v path="$file" '
            /^[[:space:]]*[#;]/ {next}
            {
                line=$0
                sub(/[[:space:]]+[#;].*$/, "", line)
                separator=index(line, "=")
                if (!separator) {
                    bare=line
                    gsub(/[[:space:]]/, "", bare)
                    ignore_bare=(substr(bare, 1, 1) == "-")
                    sub(/^-+/, "", bare)
                    gsub(/\//, ".", bare)
                    if (!ignore_bare && (bare == "net.ipv4.tcp_congestion_control" || bare == "net.core.default_qdisc"))
                        errors=errors sprintf("Неоднозначное определение sysctl: %s:%d\n", path, FNR)
                    next
                }
                key=substr(line, 1, separator-1)
                value=substr(line, separator+1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                normalized=key
                sub(/^-+/, "", normalized)
                gsub(/\//, ".", normalized)
                compact=normalized
                gsub(/[[:space:]]/, "", compact)
                if (normalized != "net.ipv4.tcp_congestion_control" && normalized != "net.core.default_qdisc") {
                    if (compact == "net.ipv4.tcp_congestion_control" || compact == "net.core.default_qdisc")
                        errors=errors sprintf("Неоднозначное определение sysctl: %s:%d\n", path, FNR)
                    next
                }
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                canonical=key
                sub(/^-/, "", canonical)
                gsub(/\//, ".", canonical)
                if (canonical != normalized || value !~ /^[a-zA-Z0-9_]+$/) {
                    errors=errors sprintf("Неоднозначное определение sysctl: %s:%d\n", path, FNR)
                    next
                }
                ignore=(substr(key, 1, 1) == "-" ? 1 : 0)
                if (seen[normalized] && (previous[normalized] != value || previous_ignore[normalized] != ignore)) {
                    errors=errors sprintf("Противоречивые определения sysctl: %s:%d\n", path, FNR)
                    next
                }
                if (!seen[normalized]++) records[++count]=normalized "\t" value "\t" ignore
                previous[normalized]=value
                previous_ignore[normalized]=ignore
            }
            END {
                if (errors != "") {printf "%s", errors; exit 2}
                for (i=1; i<=count; i++) print records[i]
            }
        ' "$file") || { issues+="${definitions:-Ошибка чтения: $file}"$'\n'; continue; }
        [[ -n $definitions ]] || continue
        basename=${file##*/}
        while IFS=$'\t' read -r key value ignore; do
            if [[ $key == net.core.default_qdisc ]]; then target=fq label=qdisc
            else target=bbr label='TCP congestion control'; fi
            note=''
            [[ $ignore == 1 ]] && note=' (ведущий «-»: ошибка применения игнорируется)'
            if [[ $file == "$root/etc/sysctl.conf" ]]; then
                [[ $value == "$target" ]] || issues+="Позднее определение в $file: $key = $value$note"$'\n'
            elif [[ $basename < 99-vps-toolkit-bbr.conf ]]; then
                [[ $value == "$target" ]] || earlier+="Более ранняя настройка $label: $file = $value$note"$'\n'
            else
                issues+="Определение может примениться после файла toolkit: $file: $key = $value$note"$'\n'
            fi
        done <<< "$definitions"
    done <<< "$files"
    if [[ -n $issues ]]; then printf '%s' "$issues"; return 1; fi
    [[ -z $earlier ]] || printf '%s' "$earlier"
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
    BBR_TMP=$(mktemp "${BBR_CONFIG}.XXXXXX") || { say_error 'Не удалось создать временный файл BBR.'; return 1; }
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
    local sysctl_root=${1:-} old_cc old_qdisc saved_cc saved_qdisc analysis line
    old_cc=$(bbr_current) || { say_error 'Не удалось прочитать текущий TCP-алгоритм.'; return 1; }
    old_qdisc=$(bbr_qdisc) || { say_error 'Не удалось прочитать текущую очередь.'; return 1; }
    if [[ ! -e $BBR_CONFIG && ! -L $BBR_CONFIG && $old_cc == bbr && $old_qdisc == fq ]]; then
        say_ok 'BBR уже активен: bbr / fq.'
        say_info 'Настройка выполнена вне VPS Toolkit RU.'
        say_info 'Существующие настройки сохранены без изменений.'
        return 0
    fi
    if [[ ! -e $BBR_CONFIG && ! -L $BBR_CONFIG && $old_cc == bbr ]]; then
        say_warn "BBR активен, но текущий qdisc — $old_qdisc (ожидается fq)."
        say_info 'Настройка выполнена вне VPS Toolkit RU; автоматическое изменение отменено.'
        return 0
    fi
    if [[ -e $BBR_CONFIG || -L $BBR_CONFIG ]] && ! bbr_file_owned; then
        say_warn 'Файл BBR изменён вручную или является ссылкой; автоматическая перезапись отменена.'; return 0
    fi
    analysis=$(bbr_sysctl_conflicts "$sysctl_root") || {
        say_warn "$analysis"
        say_warn 'Порядок или содержимое sysctl не подтверждены. Включение BBR отменено; чужие файлы не изменяются.'
        return 0
    }
    if [[ $old_cc == bbr && $old_qdisc == fq && -f $BBR_CONFIG ]]; then
        say_ok 'BBR сейчас активен; конфликтующих определений в проверенных файлах не найдено.'
        say_info 'Постоянство настройки после перезагрузки не гарантируется; проверьте её после плановой перезагрузки.'
        return 0
    fi
    if ! bbr_supported; then say_error 'Ядро не сообщает о поддержке BBR.'; return 1; fi
    if [[ ! $old_cc =~ ^[a-zA-Z0-9_]+$ || ! $old_qdisc =~ ^[a-zA-Z0-9_]+$ ]]; then say_error 'Текущие параметры ядра имеют неожиданный формат.'; return 1; fi
    if [[ -n $analysis ]]; then
        while IFS= read -r line; do say_info "$line"; done <<< "$analysis"
        say_info 'Исходные файлы изменяться не будут.'
        say_info "Более поздний файл $BBR_CONFIG установит bbr и fq."
    fi
    saved_cc=$old_cc saved_qdisc=$old_qdisc
    if [[ -f $BBR_CONFIG ]]; then
        saved_cc=$(bbr_saved_value previous_cc) || return 1
        saved_qdisc=$(bbr_saved_value previous_qdisc) || return 1
    fi
    say_info 'BBR не гарантирует улучшение для любого трафика.'
    say_info "Текущий алгоритм TCP: $old_cc; текущий qdisc: $old_qdisc."
    say_info 'Будет применено: алгоритм TCP bbr; очередь по умолчанию fq.'
    if ! confirm_yes_no 'Включить BBR для TCP и очередь fq?'; then say_info 'Действие отменено.'; return 0; fi
    if (( DRY_RUN )); then say_info "План: сохранить копию при необходимости, записать $BBR_CONFIG и применить два параметра ядра. Перезагрузка не выполняется."; return 0; fi
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
    if ! confirm_yes_no "Удалить файл toolkit и установить $restore_cc / $restore_qdisc?"; then say_info 'Действие отменено.'; return 0; fi
    if (( DRY_RUN )); then say_info "План: сохранить копию, удалить $BBR_CONFIG и применить $restore_cc / $restore_qdisc."; return 0; fi
    prepare_mutation || return 1
    bbr_apply_disable "$restore_cc" "$restore_qdisc" "$active_cc" "$active_qdisc"
}

bbr_menu() {
    local choice
    while true; do
        printf '\n════════ BBR ════════\n'; bbr_status
        printf '1. Проверить поддержку BBR\n2. Включить BBR\n3. Проверить состояние BBR\n4. Отключить BBR\n0. Назад\nВыберите пункт: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) if bbr_supported; then say_ok 'Поддержка BBR обнаружена.'; else say_warn 'Поддержка BBR не обнаружена.'; fi; pause_menu;;
            2) bbr_enable; pause_menu;;
            3) bbr_status; pause_menu;;
            4) bbr_disable; pause_menu;;
            0) return;;
            *) say_warn 'Неизвестный пункт меню.';;
        esac
    done
}
