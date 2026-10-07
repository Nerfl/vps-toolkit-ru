#!/usr/bin/env bash

F2B_CONFIG=/etc/fail2ban/jail.d/vps-toolkit-sshd.local

fail2ban_status() {
    printf 'Установлен: %s\n' "$(yes_no package_installed fail2ban)"
    printf 'Сервис запущен: %s\n' "$(yes_no service_active fail2ban)"
    if has_cmd fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
        printf 'SSH jail активен: Да\n'
    else printf 'SSH jail активен: Нет или недоступен\n'; fi
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
    printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[sshd]' 'enabled = true' 'backend = systemd' 'port = 22' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h'
}

fail2ban_legacy_config() {
    printf '%s\n' '[sshd]' 'enabled = true' 'backend = systemd' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h'
}

fail2ban_previous_config() {
    printf '%s\n' '# Управляется VPS Toolkit RU. Не редактируйте вручную.' '[sshd]' 'enabled = true' 'backend = systemd' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h'
}

fail2ban_config_managed() {
    [[ ! -L $F2B_CONFIG ]] || return 1
    [[ ! -e $F2B_CONFIG ]] && return 0
    [[ -f $F2B_CONFIG ]] || return 1
    diff -q "$F2B_CONFIG" <(fail2ban_desired_config) >/dev/null 2>&1 \
        || diff -q "$F2B_CONFIG" <(fail2ban_legacy_config) >/dev/null 2>&1 \
        || diff -q "$F2B_CONFIG" <(fail2ban_previous_config) >/dev/null 2>&1
}

fail2ban_socket_listen_ports() {
    local output line token previous endpoint port
    local -a tokens
    output=$(systemctl show -p Listen --value ssh.socket 2>/dev/null) || return 1
    [[ -n $output ]] || return 1
    while IFS= read -r line; do
        read -r -a tokens <<< "$line"
        previous=''
        for token in "${tokens[@]}"; do
            case "$token" in
                ListenStream=*) endpoint=${token#ListenStream=} ;;
                '(Stream)') endpoint=${previous#Listen=} ;;
                *) previous=$token; continue ;;
            esac
            port=${endpoint##*:}
            [[ $port =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
            printf '%s\n' "$port"
            previous=$token
        done
    done <<< "$output"
}

fail2ban_ssh_port_safe() {
    local configured listening line endpoint port ports='' socket_ports='' main_pid='' state recv send peer rest
    if ! has_cmd sshd || ! has_cmd ss; then
        say_warn 'Нет sshd или ss: невозможно сверить настроенный и фактический порт SSH.'; return 1
    fi
    configured=$(sshd -T 2>/dev/null) || { say_warn 'Не удалось получить действующую конфигурацию sshd.'; return 1; }
    configured=$(awk '$1 == "port" {print $2}' <<< "$configured" | sort -u)
    if [[ $configured != 22 ]]; then
        say_warn "Настроенные порты SSH: ${configured:-неизвестно}; требуется единственный порт 22."; return 1
    fi
    if service_active ssh.socket; then
        socket_ports=$(fail2ban_socket_listen_ports) || { say_warn 'Не удалось прочитать TCP ListenStream активного ssh.socket.'; return 1; }
        socket_ports=$(awk 'NF && !seen[$0]++ {printf "%s%s", sep, $0; sep=" "} END {print ""}' <<< "$socket_ports")
        [[ -n $socket_ports ]] || { say_warn 'TCP ListenStream активного ssh.socket не определён.'; return 1; }
        [[ $socket_ports == 22 ]] || { say_warn "Порты ssh.socket: $socket_ports; требуется единственный порт 22."; return 1; }
    fi
    if service_active ssh.service; then
        main_pid=$(systemctl show -p MainPID --value ssh.service 2>/dev/null) || {
            say_warn 'Не удалось определить MainPID службы ssh.service.'; return 1;
        }
        main_pid=${main_pid#MainPID=}
        [[ $main_pid =~ ^[1-9][0-9]*$ ]] || { say_warn 'MainPID службы ssh.service не определён однозначно.'; return 1; }
    fi
    [[ -n $main_pid || -n $socket_ports ]] || { say_warn 'Ни ssh.service, ни ssh.socket не подтверждены как активные.'; return 1; }
    listening=$(ss -H -ltnp 2>/dev/null) || { say_warn 'Не удалось получить список TCP listener через ss.'; return 1; }
    while IFS= read -r line; do
        read -r state recv send endpoint peer rest <<< "$line"
        [[ $state == LISTEN && $endpoint == *:* ]] || continue
        port=${endpoint##*:}
        [[ $port =~ ^[0-9]+$ ]] || { say_warn 'Не удалось разобрать фактический порт SSH.'; return 1; }
        if [[ -n $main_pid && $line == *"\"sshd\",pid=$main_pid,"* ]]; then :
        elif [[ -n $socket_ports && " $socket_ports " == *" $port "* && $line == *'"systemd",pid=1,'* ]]; then :
        else continue; fi
        ports+="$port "
    done <<< "$listening"
    [[ -n $ports ]] || { say_warn 'Фактический TCP listener SSH не определён.'; return 1; }
    ports=$(tr ' ' '\n' <<< "$ports" | awk 'NF && !seen[$0]++ {printf "%s%s", sep, $0; sep=" "} END {print ""}')
    [[ $ports == 22 ]] || {
        say_warn "Фактические порты SSH: $ports; требуется единственный порт 22."; return 1;
    }
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
        systemctl restart fail2ban >/dev/null 2>&1 && service_active fail2ban \
            && { (( ! F2B_JAIL_WAS_ACTIVE )) || fail2ban-client status sshd >/dev/null 2>&1; }
    else
        if service_active fail2ban; then systemctl stop fail2ban >/dev/null 2>&1 && ! service_active fail2ban
        else return 0; fi
    fi
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
    F2B_SERVICE_TOUCHED=1
    if ! systemctl restart fail2ban >/dev/null 2>&1 || ! service_active fail2ban || ! fail2ban-client status sshd >/dev/null 2>&1; then
        say_error 'Fail2Ban или SSH jail не запустился.'
        return 1
    fi
    fail2ban_effective_settings || return 1
    log_action INFO 'Настроен и проверен jail sshd Fail2Ban' || return 1
    say_ok 'Fail2Ban настроен, сервис и SSH jail активны.'
)

fail2ban_install_configure() {
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
    if ! confirm 'Установить и настроить Fail2Ban?'; then say_info 'Действие отменено.'; return 0; fi
    if (( DRY_RUN )); then
        if ! package_installed fail2ban; then say_info 'План: установить пакет fail2ban через apt-get.'; fi
        say_info "План: создать или обновить $F2B_CONFIG, проверить конфигурацию и перезапустить сервис."
        return 0
    fi
    if ! confirm 'Подтвердите наличие доступа к консоли провайдера или второго рабочего SSH-сеанса'; then
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
    if ! confirm "Разблокировать IP $ip?"; then say_info 'Действие отменено.'; return; fi
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

fail2ban_log() {
    local lines
    if [[ -r /var/log/fail2ban.log ]]; then lines=$(tail -n 40 /var/log/fail2ban.log)
    elif has_cmd journalctl; then lines=$(journalctl -u fail2ban.service -n 40 --no-pager -o short-iso 2>/dev/null) || { say_warn 'Журнал Fail2Ban недоступен.'; return; }
    else say_warn 'Журнал Fail2Ban недоступен.'; return; fi
    if [[ -z $lines ]]; then say_info 'Журнал Fail2Ban пуст.'; return; fi
    printf 'Последние события Fail2Ban (дата, время, тип, IP при наличии):\n'
    awk '
        {
            event="Служебное событие"
            if ($0 ~ / Ban /) event="Блокировка"
            else if ($0 ~ / Unban /) event="Разблокировка"
            else if ($0 ~ / Found /) event="Обнаружена попытка входа"
            else if ($0 ~ /ERROR/) event="Ошибка"
            else if ($0 ~ /WARNING/) event="Предупреждение"
            ip=""
            for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip=$i
            print $1, $2, event, ip
        }
    ' <<< "$lines"
}

fail2ban_menu() {
    local choice
    while true; do
        printf '\n════════ FAIL2BAN / ЗАЩИТА SSH ════════\n'; fail2ban_status
        printf '1. Установить и настроить Fail2Ban\n2. Проверить состояние\n3. Показать заблокированные IP\n4. Показать TOP атакующих IP\n5. Разблокировать IP\n6. Показать журнал Fail2Ban\n7. Назад\nВыберите пункт: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) fail2ban_install_configure; pause_menu;;
            2) fail2ban_status; pause_menu;;
            3) fail2ban_banned; pause_menu;;
            4) fail2ban_top_attackers; pause_menu;;
            5) fail2ban_unban; pause_menu;;
            6) fail2ban_log; pause_menu;;
            7) return;;
            *) say_warn 'Неизвестный пункт меню.';;
        esac
    done
}
