#!/usr/bin/env bash

F2B_GLOBAL_CONFIG=/etc/fail2ban/fail2ban.d/vps-toolkit.local

fail2ban_policy_jail_config() {
    local policy=$1
    printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[sshd]' \
        'enabled = true' 'backend = systemd' 'port = 22' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h'
    case $policy in
        normal) printf '%s\n' 'bantime.increment = false';;
        adaptive|strict)
            printf '%s\n' 'bantime.increment = true' 'bantime.factor = 1'
            if [[ $policy == adaptive ]]; then printf '%s\n' 'bantime.maxtime = 7d'
            else printf '%s\n' 'bantime.maxtime = 30d'; fi;;
        *) return 2;;
    esac
}

fail2ban_policy_global_config() {
    case $1 in adaptive) printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[Definition]' 'dbpurgeage = 30d';;
        strict) printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[Definition]' 'dbpurgeage = 90d';;
        *) return 2;; esac
}

fail2ban_policy_global_managed() {
    [[ ! -L $F2B_GLOBAL_CONFIG ]] || return 1
    [[ ! -e $F2B_GLOBAL_CONFIG ]] && return 0
    [[ -f $F2B_GLOBAL_CONFIG ]] || return 1
    diff -q "$F2B_GLOBAL_CONFIG" <(fail2ban_policy_global_config adaptive) >/dev/null 2>&1 \
        || diff -q "$F2B_GLOBAL_CONFIG" <(fail2ban_policy_global_config strict) >/dev/null 2>&1
}

fail2ban_duration_seconds() {
    local value=${1,,} number multiplier
    if [[ $value =~ ^([0-9]+)\.0+$ ]]; then value=${BASH_REMATCH[1]}; fi
    [[ $value =~ ^([0-9]+)([smhdw]?)$ ]] || return 1
    number=${BASH_REMATCH[1]}
    case ${BASH_REMATCH[2]} in s|'') multiplier=1;; m) multiplier=60;; h) multiplier=3600;; d) multiplier=86400;; w) multiplier=604800;; esac
    (( ${#number} <= 9 )) || return 1
    printf '%s\n' "$((10#$number * multiplier))"
}

fail2ban_foreign_db_files() {
    local file
    for file in /etc/fail2ban/fail2ban.local /etc/fail2ban/fail2ban.d/*.conf /etc/fail2ban/fail2ban.d/*.local; do
        [[ -e $file && $file != "$F2B_GLOBAL_CONFIG" ]] && printf '%s\n' "$file"
    done
}

fail2ban_foreign_db_policy() {
    local required=$1 file values value seconds
    F2B_FOREIGN_DB=0
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        if [[ ! -f $file || ! -r $file ]]; then say_warn "Невозможно прочитать конфигурацию $file; изменение политики отменено."; return 1; fi
        values=$(awk '
            /^[[:space:]]*[#;]/ {next}
            /^[[:space:]]*\[/ {definition=($0 ~ /^[[:space:]]*\[[[:space:]]*Definition[[:space:]]*\]/); next}
            definition && /^[[:space:]]*dbpurgeage[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*[#;].*$/, ""); sub(/[[:space:]]+$/, "")
                if ($0=="") print "<пусто>"; else print
            }
        ' "$file") || return 1
        [[ -z $values ]] && continue
        if [[ $values == *$'\n'* ]]; then say_warn "Несколько определений dbpurgeage в $file; изменение отменено."; return 1; fi
        value=$values
        seconds=$(fail2ban_duration_seconds "$value") || { say_warn "Неоднозначное значение dbpurgeage в $file; изменение отменено."; return 1; }
        if (( seconds < required )); then
            say_warn "Чужой dbpurgeage в $file меньше необходимого; настройка сохранена, изменение отменено."
            return 1
        fi
        F2B_FOREIGN_DB=1
        say_info "Чужой dbpurgeage в $file достаточен; файл будет сохранён."
    done < <(fail2ban_foreign_db_files)
}

fail2ban_policy_get_dbpurgeage() {
    local output pattern=$'^Current database purge age is:\n`- (0|[1-9][0-9]*)seconds$'
    output=$(fail2ban-client get dbpurgeage 2>/dev/null) || return 1
    [[ $output =~ $pattern ]] || return 1
    (( ${#BASH_REMATCH[1]} <= 15 )) || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

fail2ban_policy_get_dbfile() {
    local output pattern=$'^Current database file is:\n`- (/[^[:cntrl:]]+)$'
    output=$(fail2ban-client get dbfile 2>/dev/null) || return 1
    if [[ $output == 'Database currently disabled' ]]; then
        printf 'disabled\n'
    elif [[ $output =~ $pattern ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

fail2ban_policy_read_effective() {
    F2B_EFFECTIVE_RETRY=$(fail2ban-client get sshd maxretry 2>/dev/null) || return 1
    F2B_EFFECTIVE_FIND=$(fail2ban-client get sshd findtime 2>/dev/null) || return 1
    F2B_EFFECTIVE_BAN=$(fail2ban-client get sshd bantime 2>/dev/null) || return 1
    F2B_EFFECTIVE_INCREMENT=$(fail2ban-client get sshd bantime.increment 2>/dev/null) || return 1
    [[ $F2B_EFFECTIVE_RETRY =~ ^[0-9]+$ && $F2B_EFFECTIVE_FIND =~ ^[0-9]+$ \
        && $F2B_EFFECTIVE_BAN =~ ^[0-9]+$ ]] || return 1
    case $F2B_EFFECTIVE_INCREMENT in
        True|true) F2B_EFFECTIVE_INCREMENT=true;;
        False|false) F2B_EFFECTIVE_INCREMENT=false;;
        None)
            if [[ $F2B_EFFECTIVE_RETRY == 5 && $F2B_EFFECTIVE_FIND == 600 && $F2B_EFFECTIVE_BAN == 3600 ]] \
                && fail2ban_pre_policy_managed && service_active fail2ban \
                && fail2ban-client status sshd >/dev/null 2>&1 && ! fail2ban_existing_custom; then
                F2B_EFFECTIVE_INCREMENT=false
            else
                return 1
            fi;;
        *) return 1;;
    esac
    F2B_EFFECTIVE_FACTOR='' F2B_EFFECTIVE_MAX='' F2B_EFFECTIVE_DB='' F2B_EFFECTIVE_DBFILE=''
    if [[ $F2B_EFFECTIVE_INCREMENT == false ]]; then
        if F2B_EFFECTIVE_DBFILE=$(fail2ban_policy_get_dbfile); then
            if [[ $F2B_EFFECTIVE_DBFILE != disabled ]]; then
                F2B_EFFECTIVE_DB=$(fail2ban_policy_get_dbpurgeage) || F2B_EFFECTIVE_DB=''
            fi
        fi
        return 0
    fi
    F2B_EFFECTIVE_FACTOR=$(fail2ban-client get sshd bantime.factor 2>/dev/null) || return 1
    F2B_EFFECTIVE_MAX=$(fail2ban-client get sshd bantime.maxtime 2>/dev/null) || return 1
    [[ $F2B_EFFECTIVE_FACTOR =~ ^[0-9]+(\.[0-9]+)?$ \
        && $F2B_EFFECTIVE_MAX =~ ^[0-9]+(\.0+)?$ ]] || return 1
    F2B_EFFECTIVE_MAX=$(fail2ban_duration_seconds "$F2B_EFFECTIVE_MAX") || return 1
    F2B_EFFECTIVE_DBFILE=$(fail2ban_policy_get_dbfile) || return 1
    [[ $F2B_EFFECTIVE_DBFILE != disabled ]] || return 1
    F2B_EFFECTIVE_DB=$(fail2ban_policy_get_dbpurgeage) || return 1
}

fail2ban_policy_classify() {
    local max_seconds effective=custom recorded
    if [[ $F2B_EFFECTIVE_RETRY == 5 && $F2B_EFFECTIVE_FIND == 600 && $F2B_EFFECTIVE_BAN == 3600 ]]; then
        if [[ $F2B_EFFECTIVE_INCREMENT == false ]]; then
            effective=normal
        elif [[ $F2B_EFFECTIVE_INCREMENT == true && $F2B_EFFECTIVE_FACTOR =~ ^1(\.0+)?$ \
            && $F2B_EFFECTIVE_DBFILE != disabled ]]; then
            max_seconds=$(fail2ban_duration_seconds "$F2B_EFFECTIVE_MAX") || max_seconds=''
            if [[ $max_seconds == 604800 ]] && (( F2B_EFFECTIVE_DB >= 2592000 )); then effective=adaptive
            elif [[ $max_seconds == 2592000 ]] && (( F2B_EFFECTIVE_DB >= 7776000 )); then effective=strict; fi
        fi
    fi
    # Совпадение файла не доказывает работу политики, но расхождение с runtime её опровергает.
    for recorded in normal adaptive strict; do
        if [[ -f $F2B_CONFIG ]] && diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config "$recorded") >/dev/null 2>&1; then
            [[ $recorded == "$effective" ]] || effective=custom
            break
        fi
    done
    printf '%s\n' "$effective"
}

fail2ban_policy_detect() {
    if ! has_cmd fail2ban-client || ! fail2ban_policy_read_effective; then printf 'custom\n'; return; fi
    fail2ban_policy_classify
}

fail2ban_policy_files_match() {
    local policy=$1
    [[ -f $F2B_CONFIG ]] && diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config "$policy") >/dev/null 2>&1 || return 1
    if [[ $policy == normal || ${F2B_FOREIGN_DB:-0} == 1 ]]; then [[ ! -e $F2B_GLOBAL_CONFIG ]]
    else [[ -f $F2B_GLOBAL_CONFIG ]] && diff -q "$F2B_GLOBAL_CONFIG" <(fail2ban_policy_global_config "$policy") >/dev/null 2>&1; fi
}

fail2ban_policy_label() {
    case $1 in normal) printf 'Обычная';; adaptive) printf 'Адаптивная';; strict) printf 'Строгая';;
        *) printf 'Пользовательская / неизвестная';; esac
}

fail2ban_policy_status() {
    local policy find_label ban_label db_label
    if ! has_cmd fail2ban-client || ! fail2ban_policy_read_effective; then
        printf 'Политика: Пользовательская / неизвестная\n'
        return 0
    fi
    policy=$(fail2ban_policy_classify)
    find_label="$F2B_EFFECTIVE_FIND секунд"
    ban_label="$F2B_EFFECTIVE_BAN секунд"
    db_label='не подтверждена'
    [[ $F2B_EFFECTIVE_FIND == 600 ]] && find_label='10 минут'
    [[ $F2B_EFFECTIVE_BAN == 3600 ]] && ban_label='1 час'
    if [[ $F2B_EFFECTIVE_DBFILE == disabled ]]; then
        db_label='база отключена'
    elif [[ $F2B_EFFECTIVE_DB =~ ^[0-9]+$ ]]; then
        db_label="$F2B_EFFECTIVE_DB секунд"
        if (( F2B_EFFECTIVE_DB % 86400 == 0 )); then db_label="$((F2B_EFFECTIVE_DB / 86400)) суток ($F2B_EFFECTIVE_DB секунд)"; fi
    fi
    printf 'Политика: %s\n' "$(fail2ban_policy_label "$policy")"
    printf 'Попыток до бана: %s\nОкно попыток: %s\nПервичный бан: %s\n' \
        "$F2B_EFFECTIVE_RETRY" "$find_label" "$ban_label"
    printf 'Увеличение повторных банов: %s\n' "$( [[ $F2B_EFFECTIVE_INCREMENT == true ]] && printf 'Да' || printf 'Нет')"
    case $policy in
        normal) printf 'Максимальный бан: 1 час\n';;
        adaptive) printf 'Максимальный бан: 7 суток\n';;
        strict) printf 'Максимальный бан: 30 суток\n';;
        *) printf 'Максимальный бан: не подтверждён\n';;
    esac
    printf 'История банов: %s\n' "$db_label"
}

fail2ban_policy_restore_one() {
    local changed=$1 previous=$2 target=$3
    (( changed )) || return 0
    if [[ -n $previous ]]; then [[ -f $previous ]] || return 1; cp -a -- "$previous" "$target"
    else rm -f -- "$target"; fi
}

fail2ban_policy_rollback() {
    local restored=0
    fail2ban_policy_restore_one "$F2B_POLICY_JAIL_CHANGED" "$F2B_POLICY_JAIL_BACKUP" "$F2B_CONFIG" || restored=1
    fail2ban_policy_restore_one "$F2B_POLICY_GLOBAL_CHANGED" "$F2B_POLICY_GLOBAL_BACKUP" "$F2B_GLOBAL_CONFIG" || restored=1
    (( restored == 0 )) || return 1
    if (( F2B_POLICY_WAS_ACTIVE )); then
        say_info 'Откат: перезапуск и ожидание готовности Fail2Ban...'
        systemctl restart fail2ban >/dev/null 2>&1 || return 1
        fail2ban_wait_ready "$F2B_POLICY_JAIL_WAS_ACTIVE"
    elif service_active fail2ban; then
        systemctl stop fail2ban >/dev/null 2>&1 && ! service_active fail2ban
    fi
}

fail2ban_policy_transaction_exit() {
    local result=$1
    trap - EXIT
    trap '' INT TERM
    [[ -z ${F2B_POLICY_JAIL_TMP:-} ]] || rm -f -- "$F2B_POLICY_JAIL_TMP" 2>/dev/null || true
    [[ -z ${F2B_POLICY_GLOBAL_TMP:-} ]] || rm -f -- "$F2B_POLICY_GLOBAL_TMP" 2>/dev/null || true
    if (( result != 0 )) && (( F2B_POLICY_JAIL_CHANGED || F2B_POLICY_GLOBAL_CHANGED || F2B_POLICY_SERVICE_TOUCHED )); then
        if fail2ban_policy_rollback; then
            say_warn "Оба файла, политика $(fail2ban_policy_label "$F2B_POLICY_PREVIOUS") и прежнее состояние Fail2Ban восстановлены."
        else say_error 'Откат политики не удался; проверьте резервные копии и состояние Fail2Ban.'; fi
        log_action ERROR 'Изменение политики Fail2Ban не завершено' || true
    fi
}

fail2ban_policy_apply() (
    local policy=$1 required=0 needs_jail=1 needs_global=0
    F2B_POLICY_JAIL_BACKUP='' F2B_POLICY_GLOBAL_BACKUP=''
    F2B_POLICY_JAIL_CHANGED=0 F2B_POLICY_GLOBAL_CHANGED=0 F2B_POLICY_SERVICE_TOUCHED=0
    F2B_POLICY_JAIL_TMP='' F2B_POLICY_GLOBAL_TMP=''
    F2B_POLICY_WAS_ACTIVE=0 F2B_POLICY_JAIL_WAS_ACTIVE=0
    service_active fail2ban && F2B_POLICY_WAS_ACTIVE=1
    if fail2ban-client status sshd >/dev/null 2>&1; then F2B_POLICY_JAIL_WAS_ACTIVE=1; fi
    F2B_POLICY_PREVIOUS=$(fail2ban_policy_detect)
    trap 'fail2ban_policy_transaction_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ $policy == normal || $policy == adaptive || $policy == strict ]] || return 2
    if fail2ban_existing_custom || ! fail2ban_ssh_port_safe; then
        say_warn 'Перед записью обнаружена чужая настройка jail или неизвестный порт SSH; изменение отменено.'
        return 1
    fi
    fail2ban_config_managed && fail2ban_policy_global_managed || { say_warn 'Найден изменённый файл toolkit; политика не меняется.'; return 1; }
    if [[ $policy == adaptive ]]; then required=2592000
    elif [[ $policy == strict ]]; then required=7776000; fi
    if (( required )); then fail2ban_foreign_db_policy "$required" || return 1; fi
    if [[ -f $F2B_CONFIG ]] && diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config "$policy") >/dev/null 2>&1; then needs_jail=0; fi
    if (( needs_jail )) && [[ -f $F2B_CONFIG ]]; then backup_file "$F2B_CONFIG" || return 1; F2B_POLICY_JAIL_BACKUP=$BACKUP_LAST; fi
    if [[ -f $F2B_GLOBAL_CONFIG ]]; then
        if [[ $policy == normal || ${F2B_FOREIGN_DB:-0} == 1 ]] || ! diff -q "$F2B_GLOBAL_CONFIG" <(fail2ban_policy_global_config "$policy") >/dev/null 2>&1; then
            needs_global=1
            backup_file "$F2B_GLOBAL_CONFIG" || return 1
            F2B_POLICY_GLOBAL_BACKUP=$BACKUP_LAST
        fi
    elif [[ $policy != normal && ${F2B_FOREIGN_DB:-0} != 1 ]]; then needs_global=1; fi
    if (( needs_jail )); then
        mkdir -p -m 0755 -- "$(dirname -- "$F2B_CONFIG")" || return 1
        F2B_POLICY_JAIL_TMP=$(mktemp "${F2B_CONFIG}.XXXXXX") || return 1
        fail2ban_policy_jail_config "$policy" > "$F2B_POLICY_JAIL_TMP" || return 1
        chmod 0644 "$F2B_POLICY_JAIL_TMP" || return 1
        F2B_POLICY_JAIL_CHANGED=1
        mv -f -- "$F2B_POLICY_JAIL_TMP" "$F2B_CONFIG" || return 1
        F2B_POLICY_JAIL_TMP=''
    fi
    if (( needs_global )); then
        F2B_POLICY_GLOBAL_CHANGED=1
        if [[ $policy == normal || ${F2B_FOREIGN_DB:-0} == 1 ]]; then rm -f -- "$F2B_GLOBAL_CONFIG" || return 1
        else
            mkdir -p -m 0755 -- "$(dirname -- "$F2B_GLOBAL_CONFIG")" || return 1
            F2B_POLICY_GLOBAL_TMP=$(mktemp "${F2B_GLOBAL_CONFIG}.XXXXXX") || return 1
            fail2ban_policy_global_config "$policy" > "$F2B_POLICY_GLOBAL_TMP" || return 1
            chmod 0644 "$F2B_POLICY_GLOBAL_TMP" || return 1
            mv -f -- "$F2B_POLICY_GLOBAL_TMP" "$F2B_GLOBAL_CONFIG" || return 1
            F2B_POLICY_GLOBAL_TMP=''
        fi
    fi
    if ! fail2ban-client -t >/dev/null 2>&1; then say_error 'Новая конфигурация Fail2Ban не прошла проверку.'; return 1; fi
    say_ok 'Конфигурация Fail2Ban прошла проверку.'
    F2B_POLICY_SERVICE_TOUCHED=1
    say_info 'Перезапуск Fail2Ban и ожидание готовности jail sshd...'
    systemctl restart fail2ban >/dev/null 2>&1 || { say_error 'Перезапуск Fail2Ban завершился ошибкой.'; return 1; }
    fail2ban_wait_ready 1 || return 1
    fail2ban_policy_read_effective || { say_error 'Не удалось подтвердить действующие параметры политики.'; return 1; }
    if [[ $(fail2ban_policy_classify) != "$policy" ]]; then say_error 'Действующие параметры не соответствуют выбранной политике.'; return 1; fi
    if [[ -n $F2B_EFFECTIVE_DB ]]; then
        say_ok "Политика $(fail2ban_policy_label "$policy") применена. История банов: $F2B_EFFECTIVE_DB секунд."
    else
        say_ok "Политика $(fail2ban_policy_label "$policy") применена."
    fi
    log_action INFO "Применена политика Fail2Ban: $(fail2ban_policy_label "$policy")" || return 1
)

fail2ban_policy_select() {
    local policy=$1 label required=0 current
    [[ $policy == normal || $policy == adaptive || $policy == strict ]] || return 2
    label=$(fail2ban_policy_label "$policy")
    if ! package_installed fail2ban || ! has_cmd fail2ban-client; then say_warn 'Сначала установите Fail2Ban через основное меню.'; return 0; fi
    fail2ban_ssh_port_safe || { say_warn 'Порт SSH не подтверждён; изменение политики отменено.'; return 0; }
    if fail2ban_existing_custom || ! fail2ban_config_managed || ! fail2ban_policy_global_managed; then
        say_warn 'Обнаружена чужая или изменённая вручную конфигурация Fail2Ban; автоматическое изменение отменено.'
        return 0
    fi
    if [[ ! -e $F2B_CONFIG ]] && fail2ban-client status sshd >/dev/null 2>&1; then
        say_warn 'Работает чужой jail sshd без файла toolkit; изменение отменено.'; return 0
    fi
    case $policy in adaptive) required=2592000;; strict) required=7776000;; esac
    if (( required )); then fail2ban_foreign_db_policy "$required" || return 0; fi
    current=$(fail2ban_policy_detect)
    if fail2ban_pre_policy_managed; then
        if [[ $current != normal ]]; then
            say_warn 'Прежняя конфигурация toolkit не подтверждена действующим jail; миграция отменена.'
            return 0
        fi
        say_info 'Текущая политика: Обычная.'
        say_info "План перехода: прежняя обычная политика → $label."
    fi
    if [[ $current == "$policy" ]] && fail2ban_policy_files_match "$policy"; then
        say_ok "Политика $label уже действует; изменений не требуется."; return 0
    fi
    say_info "Выбрана политика: $label. Первичный бан: 1 час; 5 попыток за 10 минут."
    case $policy in
        normal) say_info 'Повторные блокировки не увеличиваются. Максимальный бан: 1 час.';;
        adaptive) say_info 'Повторные баны увеличиваются; предел 7 суток, история 30 суток.';;
        strict) say_info 'Повторные баны увеличиваются; предел 30 суток, история 90 суток.';;
    esac
    say_info "План: изменить $F2B_CONFIG; проверить конфигурацию и перезапустить Fail2Ban."
    if [[ $policy == normal || ${F2B_FOREIGN_DB:-0} != 1 ]]; then
        say_info "План: создать, обновить или удалить управляемый файл $F2B_GLOBAL_CONFIG."
    else say_info 'Чужая достаточная настройка dbpurgeage будет сохранена.'; fi
    if ! confirm_yes_no "Применить политику $label?"; then say_info 'Действие отменено.'; return 0; fi
    if (( DRY_RUN )); then say_info 'Режим просмотра: файлы, база и сервис не изменены.'; return 0; fi
    if ! confirm_yes_no 'Подтвердите наличие консоли провайдера или второго рабочего SSH-сеанса'; then
        say_info 'Изменение отменено ради сохранения доступа к серверу.'; return 0
    fi
    prepare_mutation || return 1
    fail2ban_policy_apply "$policy"
}

fail2ban_policy_menu() {
    local choice current
    while true; do
        current=$(fail2ban_policy_detect)
        printf '\n════════ ПОЛИТИКА БЛОКИРОВОК ════════\nТекущая политика: %s\n' "$(fail2ban_policy_label "$current")"
        printf '1. Обычная — 5 попыток за 10 минут, каждый бан 1 час\n'
        printf '2. Адаптивная [РЕКОМЕНДУЕТСЯ] — 1 час → 2 часа → 4 часа; максимум 7 суток, история 30 суток\n'
        printf '3. Строгая — рост повторных банов; максимум 30 суток, история 90 суток\n'
        printf '0. Назад\nВыберите пункт: '
        IFS= read -r choice || return 0
        case $choice in
            1) fail2ban_policy_select normal; pause_menu;;
            2) fail2ban_policy_select adaptive; pause_menu;;
            3) fail2ban_policy_select strict; pause_menu;;
            0) return 0;;
            *) say_warn 'Неизвестный пункт меню.';;
        esac
    done
}
