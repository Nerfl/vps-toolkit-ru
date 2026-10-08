#!/usr/bin/env bash

F2B_CONFIG=/etc/fail2ban/jail.d/vps-toolkit-sshd.local
F2B_READY_TIMEOUT_SECONDS=20

fail2ban_status() {
    printf 'Установлен: %s\n' "$(yes_no package_installed fail2ban)"
    printf 'Сервис запущен: %s\n' "$(yes_no service_active fail2ban)"
    if has_cmd fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
        printf 'SSH jail активен: Да\n'
    else printf 'SSH jail активен: Нет или недоступен\n'; fi
    fail2ban_policy_status
}

fail2ban_existing_custom() {
    [[ -s /etc/fail2ban/jail.local ]] && return 0
    local file verify
    for file in /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.d/*.local; do
        [[ -f $file && $file != "$F2B_CONFIG" && $file != /etc/fail2ban/jail.d/defaults-debian.conf ]] || continue
        grep -Eq '^[[:space:]]*[^#;[:space:]]' "$file" && return 0
    done
    if package_installed fail2ban && has_cmd dpkg; then
        verify=$(dpkg -V fail2ban 2>/dev/null) || true
        grep -Eq '/etc/fail2ban/(jail\.conf|jail\.d/defaults-debian\.conf)$' <<< "$verify" && return 0
    fi
    return 1
}

fail2ban_desired_config() {
    printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[sshd]' 'enabled = true' 'backend = systemd' 'port = 22' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h' 'bantime.increment = false'
}

fail2ban_legacy_config() {
    printf '%s\n' '[sshd]' 'enabled = true' 'backend = systemd' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h'
}

fail2ban_previous_config() {
    printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[sshd]' 'enabled = true' 'backend = systemd' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h'
}

fail2ban_pre_policy_config() {
    printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[sshd]' 'enabled = true' 'backend = systemd' 'port = 22' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h'
}

fail2ban_pre_policy_managed() {
    [[ -f $F2B_CONFIG && ! -L $F2B_CONFIG ]] \
        && diff -q "$F2B_CONFIG" <(fail2ban_pre_policy_config) >/dev/null 2>&1
}

fail2ban_config_managed() {
    [[ ! -L $F2B_CONFIG ]] || return 1
    [[ ! -e $F2B_CONFIG ]] && return 0
    [[ -f $F2B_CONFIG ]] || return 1
    diff -q "$F2B_CONFIG" <(fail2ban_desired_config) >/dev/null 2>&1 \
        || diff -q "$F2B_CONFIG" <(fail2ban_legacy_config) >/dev/null 2>&1 \
        || diff -q "$F2B_CONFIG" <(fail2ban_previous_config) >/dev/null 2>&1 \
        || fail2ban_pre_policy_managed \
        || diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config adaptive) >/dev/null 2>&1 \
        || diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config strict) >/dev/null 2>&1
}

fail2ban_ssh_port_safe() {
    local configured listening
    configured=$(ssh_listener_configured_ports) || { say_warn 'Не удалось получить действующую конфигурацию sshd.'; return 1; }
    if [[ $configured != 22 ]]; then
        say_warn "Настроенные порты SSH: ${configured:-неизвестно}; требуется единственный порт 22."; return 1
    fi
    listening=$(ssh_listener_endpoints) || { say_warn "$listening"; return 1; }
    say_info 'Порт SSH 22 подтверждён в sshd -T и listener основного sshd или ssh.socket.'
}

fail2ban_effective_settings() {
    local key value expected result=0
    for key in maxretry findtime bantime; do
        case $key in maxretry) expected=5;; findtime) expected=600;; bantime) expected=3600;; esac
        if ! value=$(fail2ban-client get sshd "$key" 2>/dev/null) || [[ ! $value =~ ^[0-9]+$ ]]; then
            say_warn "Действующее значение $key для jail sshd недоступно."
            result=1
            continue
        fi
        say_info "Действующее значение $key: $value (ожидается $expected)."
        [[ $value == "$expected" ]] || result=1
    done
    (( result == 0 )) || { say_warn 'Действующие параметры jail sshd отличаются или не подтверждены.'; return 1; }
}

fail2ban_restore_config() {
    if (( F2B_CHANGED )); then
        if [[ -n ${F2B_PREVIOUS:-} && -f $F2B_PREVIOUS ]]; then
            cp -a -- "$F2B_PREVIOUS" "$F2B_CONFIG" 2>/dev/null || return 1
        else
            rm -f -- "$F2B_CONFIG" 2>/dev/null || return 1
        fi
    fi
    if (( F2B_WAS_ACTIVE )); then
        say_info 'Откат: перезапуск Fail2Ban...'
        if ! systemctl restart fail2ban >/dev/null 2>&1; then
            fail2ban_readiness_diagnostics 'Перезапуск Fail2Ban при откате завершился ошибкой.'
            return 1
        fi
        say_info 'Откат: ожидание готовности Fail2Ban...'
        fail2ban_wait_ready "$F2B_JAIL_WAS_ACTIVE"
    else
        if service_active fail2ban; then systemctl stop fail2ban >/dev/null 2>&1 && ! service_active fail2ban
        else return 0; fi
    fi
}

fail2ban_readiness_diagnostics() {
    local reason=$1 state ping_output ping_result jail_output jail_result journal
    say_error "$reason"
    state=$(systemctl is-active fail2ban 2>/dev/null) || true
    printf 'Состояние systemd-сервиса Fail2Ban: %s\n' "${state:-недоступно}"
    if ping_output=$(fail2ban-client ping 2>&1); then ping_result=0; else ping_result=$?; fi
    printf 'Ответ сервера или сокета Fail2Ban (код %s): %s\n' "$ping_result" "${ping_output:-нет ответа}"
    if jail_output=$(fail2ban-client status sshd 2>&1); then jail_result=0; else jail_result=$?; fi
    printf 'Проверка jail sshd (код %s):\n' "$jail_result"
    if [[ -n $jail_output ]]; then printf '%s\n' "$jail_output" | awk 'NR <= 4'
    else printf 'Нет ответа.\n'; fi
    if has_cmd journalctl; then
        journal=$(journalctl -u fail2ban.service -n 8 --no-pager -o cat 2>/dev/null) || journal=''
        if [[ -n $journal ]]; then printf 'Последние события Fail2Ban:\n%s\n' "$journal"
        else say_info 'Последние события Fail2Ban недоступны.'; fi
    else say_info 'Команда journalctl недоступна.'; fi
}

fail2ban_wait_ready() {
    local require_jail=${1:-1} attempt state
    for (( attempt=0; attempt<=F2B_READY_TIMEOUT_SECONDS; attempt++ )); do
        state=$(systemctl is-active fail2ban 2>/dev/null) || true
        case "$state" in
            failed|inactive)
                fail2ban_readiness_diagnostics 'Сервис Fail2Ban остановился или завершился с ошибкой; ожидание прекращено.'
                return 1;;
            active)
                if fail2ban-client ping >/dev/null 2>&1; then
                    if (( ! require_jail )) || fail2ban-client status sshd >/dev/null 2>&1; then
                        say_ok 'Сервис Fail2Ban запущен.'
                        if (( require_jail )); then say_ok 'jail sshd активен.'; fi
                        return 0
                    fi
                fi;;
        esac
        if (( attempt < F2B_READY_TIMEOUT_SECONDS )); then sleep 1 || return 1; fi
    done
    fail2ban_readiness_diagnostics 'Истекло время ожидания готовности Fail2Ban или jail sshd.'
    return 1
}

fail2ban_transaction_exit() {
    local result=$1
    trap - EXIT
    trap '' INT TERM
    if [[ -n ${F2B_TMP:-} ]]; then rm -f -- "$F2B_TMP" 2>/dev/null || true; fi
    if (( result != 0 )); then
        if (( F2B_CHANGED || F2B_SERVICE_TOUCHED )); then
            if fail2ban_restore_config; then say_warn 'Прежняя конфигурация и состояние Fail2Ban восстановлены.'
            else say_error 'Откат Fail2Ban не удался; проверьте резервную копию и состояние сервиса.'; fi
        elif (( F2B_INSTALL_ATTEMPTED && ! F2B_WAS_ACTIVE )) && service_active fail2ban; then
            if systemctl stop fail2ban >/dev/null 2>&1 && ! service_active fail2ban; then
                say_warn 'Запущенный во время установки Fail2Ban остановлен после ошибки.'
            else say_error 'Не удалось остановить частично установленный Fail2Ban; проверьте доступ к серверу.'; fi
        fi
        if (( F2B_INSTALL_ATTEMPTED )); then say_warn 'Установка пакета могла завершиться частично; проверьте состояние apt/dpkg и Fail2Ban.'; fi
        log_action ERROR 'Настройка Fail2Ban не завершена' || true
    fi
}

fail2ban_apply_config() (
    F2B_TMP='' F2B_PREVIOUS='' F2B_CHANGED=0 F2B_SERVICE_TOUCHED=0 F2B_INSTALL_ATTEMPTED=0
    F2B_WAS_ACTIVE=0 F2B_JAIL_WAS_ACTIVE=0
    service_active fail2ban && F2B_WAS_ACTIVE=1
    if has_cmd fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then F2B_JAIL_WAS_ACTIVE=1; fi
    trap 'fail2ban_transaction_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local needs_write=1
    require_commands apt-get systemctl install mktemp || return 1
    if ! package_installed fail2ban; then
        F2B_INSTALL_ATTEMPTED=1
        run_step 'Установка Fail2Ban' apt_run install fail2ban || return 1
        package_installed fail2ban || { say_error 'Пакет Fail2Ban не обнаружен после установки.'; return 1; }
        log_action INFO 'Установлен Fail2Ban' || return 1
    fi
    say_ok 'Пакет Fail2Ban установлен.'
    require_commands fail2ban-client || return 1
    mkdir -p -m 0755 /etc/fail2ban/jail.d 2>/dev/null || { say_error 'Не удалось подготовить каталог Fail2Ban.'; return 1; }
    if [[ -f $F2B_CONFIG ]] && diff -q "$F2B_CONFIG" <(fail2ban_desired_config) >/dev/null 2>&1; then needs_write=0; fi
    if (( needs_write )); then
        if [[ -f $F2B_CONFIG ]]; then backup_file "$F2B_CONFIG" || return 1; F2B_PREVIOUS=$BACKUP_LAST; fi
        F2B_TMP=$(mktemp /etc/fail2ban/jail.d/.vps-toolkit-sshd.XXXXXX) || return 1
        fail2ban_desired_config > "$F2B_TMP" || return 1
        chmod 0644 "$F2B_TMP" 2>/dev/null || return 1
        F2B_CHANGED=1
        mv -f -- "$F2B_TMP" "$F2B_CONFIG" 2>/dev/null || return 1
        F2B_TMP=''
    fi
    if ! fail2ban-client -t >/dev/null 2>&1; then say_error 'Проверка конфигурации Fail2Ban не пройдена.'; return 1; fi
    say_ok 'Конфигурация Fail2Ban прошла проверку.'
    F2B_SERVICE_TOUCHED=1
    say_info 'Перезапуск Fail2Ban...'
    if ! systemctl restart fail2ban >/dev/null 2>&1; then
        fail2ban_readiness_diagnostics 'Перезапуск Fail2Ban завершился ошибкой.'
        return 1
    fi
    say_info 'Ожидание готовности Fail2Ban...'
    fail2ban_wait_ready 1 || return 1
    fail2ban_effective_settings || return 1
    log_action INFO 'Настроен и проверен jail sshd Fail2Ban' || return 1
    say_ok 'Fail2Ban настроен, сервис и SSH jail активны.'
)

fail2ban_install_configure() {
    local current_policy
    printf '\nНастройка jail sshd: 5 попыток за 10 минут, блокировка на 1 час.\n'
    say_warn 'Собственный IP может быть временно заблокирован после повторных неудачных входов. Убедитесь, что есть действующий SSH-сеанс.'
    if ! fail2ban_ssh_port_safe; then
        say_warn 'Автоматическая настройка jail отменена, чтобы не создать ложную защиту.'; return 0
    fi
    if fail2ban_existing_custom; then
        say_warn 'Найдена пользовательская настройка Fail2Ban. Она будет сохранена без изменений.'
        if has_cmd fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then fail2ban_effective_settings || true; fi
        say_info 'Безопасный вариант: проверить текущий jail вручную и устранить возможный конфликт приоритетов конфигурации.'
        return 0
    fi
    if ! fail2ban_config_managed; then
        say_warn 'Файл toolkit изменён вручную или является ссылкой; автоматическая перезапись отменена.'
        return 0
    fi
    if [[ -f $F2B_CONFIG ]] && {
        diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config adaptive) >/dev/null 2>&1 \
            || diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config strict) >/dev/null 2>&1;
    }; then
        current_policy=$(fail2ban_policy_detect)
        say_info "Действующая политика $(fail2ban_policy_label "$current_policy") сохранена. Для изменения используйте меню политик."
        return 0
    fi
    if package_installed fail2ban && [[ -f $F2B_CONFIG ]] \
        && diff -q "$F2B_CONFIG" <(fail2ban_desired_config) >/dev/null 2>&1 \
        && service_active fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
        if fail2ban_effective_settings; then say_ok 'Fail2Ban и SSH jail уже настроены.'
        else say_warn 'Автоматический перезапуск отменён до выяснения причины расхождения параметров.'; fi
        return 0
    fi
    if package_installed fail2ban && [[ ! -e $F2B_CONFIG ]] && has_cmd fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
        say_warn 'Уже работает SSH jail без конфигурации toolkit. Существующие правила сохранены.'
        fail2ban_effective_settings || true
        return 0
    fi
    if ! confirm_yes_no 'Установить и настроить Fail2Ban?'; then say_info 'Действие отменено.'; return 0; fi
    if (( DRY_RUN )); then
        if ! package_installed fail2ban; then say_info 'План: установить пакет fail2ban через apt-get.'; fi
        say_info "План: создать или обновить $F2B_CONFIG, проверить конфигурацию и перезапустить сервис."
        return 0
    fi
    if ! confirm_yes_no 'Подтвердите наличие доступа к консоли провайдера или второго рабочего SSH-сеанса'; then
        say_info 'Настройка отменена ради сохранения доступа к серверу.'; return 0
    fi
    prepare_mutation || return 1
    fail2ban_apply_config
}

fail2ban_banned() {
    local status current total list
    if ! has_cmd fail2ban-client || ! status=$(fail2ban-client status sshd 2>/dev/null); then say_warn 'SSH jail недоступен.'; return; fi
    current=$(sed -n 's/.*Currently banned:[[:space:]]*//p' <<< "$status" | head -n 1)
    total=$(sed -n 's/.*Total banned:[[:space:]]*//p' <<< "$status" | head -n 1)
    list=$(sed -n 's/.*Banned IP list:[[:space:]]*//p' <<< "$status" | head -n 1)
    printf 'Сейчас заблокировано: %s\nВсего блокировок: %s\nIP: %s\n' "${current:-Недоступно}" "${total:-Недоступно}" "${list:-Нет}"
}

fail2ban_top_attackers() {
    ssh_event_summary top || say_warn 'Журнал SSH за 24 часа недоступен.'
}

fail2ban_unban() {
    local ip
    if ! has_cmd fail2ban-client; then say_error 'Fail2Ban не установлен.'; return 1; fi
    printf 'Введите IP для разблокировки: '
    IFS= read -r ip || return
    if ! valid_ip "$ip"; then say_error 'Некорректный IP-адрес.'; return 1; fi
    if ! confirm_yes_no "Разблокировать IP $ip?"; then say_info 'Действие отменено.'; return; fi
    if (( DRY_RUN )); then say_info "План: разблокировать IP $ip в jail sshd."; return; fi
    prepare_mutation || return 1
    if fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1; then
        log_action INFO 'Разблокирован IP в jail sshd' || return 1
        say_ok 'IP разблокирован.'
    else
        say_error 'Не удалось разблокировать IP.'
        log_action ERROR 'Не удалось разблокировать IP в jail sshd' || true
        return 1
    fi
}

fail2ban_format_log() {
    local line event ip candidate
    local -a fields
    while IFS= read -r line; do
        read -r -a fields <<< "$line"
        event='Служебное событие'
        case " $line " in
            *' Ban '*) event='Блокировка';;
            *' Unban '*) event='Разблокировка';;
            *' Found '*) event='Обнаружена попытка входа';;
            *ERROR*) event='Ошибка';;
            *WARNING*) event='Предупреждение';;
        esac
        ip=''
        for candidate in "${fields[@]}"; do
            if valid_ip "$candidate"; then ip=$candidate; fi
        done
        printf '%s %s %s %s\n' "${fields[0]:-}" "${fields[1]:-}" "$event" "$ip"
    done
}

fail2ban_log() {
    local lines
    if [[ -r /var/log/fail2ban.log ]]; then lines=$(tail -n 40 /var/log/fail2ban.log)
    elif has_cmd journalctl; then lines=$(journalctl -u fail2ban.service -n 40 --no-pager -o short-iso 2>/dev/null) || { say_warn 'Журнал Fail2Ban недоступен.'; return; }
    else say_warn 'Журнал Fail2Ban недоступен.'; return; fi
    if [[ -z $lines ]]; then say_info 'Журнал Fail2Ban пуст.'; return; fi
    printf 'Последние события Fail2Ban (дата, время, тип, IP при наличии):\n'
    fail2ban_format_log <<< "$lines"
}

fail2ban_menu() {
    local choice
    while true; do
        printf '\n════════ FAIL2BAN / ЗАЩИТА SSH ════════\n'; fail2ban_status
        printf '1. Установить и настроить Fail2Ban\n2. Проверить состояние\n3. Показать заблокированные IP\n4. Показать TOP атакующих IP\n5. Разблокировать IP\n6. Показать журнал Fail2Ban\n7. Политика блокировок\n0. Назад\nВыберите пункт: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) fail2ban_install_configure; pause_menu;;
            2) fail2ban_status; pause_menu;;
            3) fail2ban_banned; pause_menu;;
            4) fail2ban_top_attackers; pause_menu;;
            5) fail2ban_unban; pause_menu;;
            6) fail2ban_log; pause_menu;;
            7) fail2ban_policy_menu;;
            0) return;;
            *) say_warn 'Неизвестный пункт меню.';;
        esac
    done
}
