#!/usr/bin/env bash

ssh_event_summary() {
    local mode=$1 summary
    has_cmd journalctl || return 1
    summary=$(journalctl -u ssh.service --since '24 hours ago' --no-pager -o cat 2>/dev/null | awk -v mode="$mode" '
        /Failed password|Failed publickey|Failed none|Failed keyboard-interactive/ {
            failed++
            for (i=1; i<=NF; i++) if ($i=="from" && $(i+1) ~ /^[0-9a-fA-F:.]+$/) counts[$(i+1)]++
        }
        /Accepted password|Accepted publickey|Accepted keyboard-interactive/ {accepted++}
        END {
            if (mode == "all") printf "Неудачные входы за 24 часа: %d\nУспешные входы за 24 часа: %d\n", failed, accepted
            print "TOP-10 IP по неудачным входам (попытки, IP):"
            found=0
            for (rank=1; rank<=10; rank++) {
                best=""; maximum=0
                for (ip in counts) if (counts[ip] > maximum) {best=ip; maximum=counts[ip]}
                if (best == "") break
                printf "%d %s\n", maximum, best
                delete counts[best]
                found++
            }
            if (!found) print "Нет данных"
        }
    ') || return 1
    printf '%s\n' "$summary"
}

audit_ssh_events() {
    ssh_event_summary all || say_warn 'Журнал SSH за 24 часа недоступен.'
}

audit_firewall() {
    local ufw_state
    if has_cmd ufw; then
        ufw_state=$(ufw status 2>/dev/null | head -n 1)
        case "$ufw_state" in
            *active*|*актив*) [[ $ufw_state == *inactive* || $ufw_state == *неактив* ]] && printf 'UFW: выключен\n' || printf 'UFW: включён\n';;
            *) printf 'UFW: состояние недоступно\n';;
        esac
    else printf 'UFW: не установлен\n'; fi
    if has_cmd nft; then
        if nft list ruleset 2>/dev/null | awk '/^[[:space:]]*(table|chain|type) / {found=1} END {exit !found}'; then
            printf 'nftables: есть правила\n'
        else printf 'nftables: правила не обнаружены или недоступны\n'; fi
    else printf 'nftables: команда не найдена\n'; fi
    if has_cmd iptables; then
        if iptables -S 2>/dev/null | awk '/^-A |^-P (INPUT|FORWARD|OUTPUT) (DROP|REJECT)/ {found=1} END {exit !found}'; then
            printf 'iptables: есть правила или ограничения по умолчанию\n'
        else printf 'iptables: ограничения не обнаружены или недоступны\n'; fi
    else printf 'iptables: команда не найдена\n'; fi
}

audit_server() {
    local root_setting pass_setting cc available banned ports
    printf '\n════════ АУДИТ СЕРВЕРА ════════\n'
    system_info
    printf 'Текущее время: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '\nИспользование дисков:\n'
    if has_cmd df; then
        printf 'Устройство  Размер  Занято  Свободно  Заполнение  Точка подключения\n'
        df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2 || say_warn 'Не удалось получить сведения о дисках.'
    else say_warn 'Команда df не найдена.'; fi
    printf '\nСостояние SSH:\n'
    printf 'Сервис SSH: %s\n' "$(yes_no service_active ssh)"
    if has_cmd ss; then
        ports=$(ss -ltnp 2>/dev/null | awk '/sshd/ {print $4}' | sort -u)
        printf 'SSH слушает: %s\n' "${ports:-Не удалось определить}"
    else printf 'Слушающие адреса SSH: команда ss недоступна\n'; fi
    root_setting=$(ssh_setting permitrootlogin)
    pass_setting=$(ssh_setting passwordauthentication)
    printf 'PermitRootLogin: %s\n' "$root_setting"
    printf 'PasswordAuthentication: %s\n' "$pass_setting"
    printf 'PubkeyAuthentication: %s\n' "$(ssh_setting pubkeyauthentication)"
    printf 'MaxAuthTries: %s\n' "$(ssh_setting maxauthtries)"
    printf 'LoginGraceTime: %s\n' "$(ssh_setting logingracetime)"
    audit_ssh_events
    printf '\nFail2Ban:\n'
    fail2ban_status
    banned=$(fail2ban-client status sshd 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*//p' | head -n 1)
    printf 'Сейчас заблокировано IP: %s\n' "${banned:-Недоступно}"
    printf '\nBBR:\n'
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'Недоступно')
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf 'Недоступно')
    printf 'Текущий алгоритм: %s\nДоступные алгоритмы: %s\n' "$cc" "$available"
    if [[ " $available " == *' bbr '* ]]; then say_ok 'BBR доступен.'; else say_info 'BBR не обнаружен среди доступных алгоритмов.'; fi
    printf '\nFirewall:\n'; audit_firewall
    printf '\nСлушающие TCP/UDP порты:\n'
    if has_cmd ss; then
        printf 'Протокол  Адрес и порт\n'
        ss -H -lntup 2>/dev/null | awk '{print $1 "  " $5}' || say_warn 'Не удалось получить список портов.'
    else say_warn 'Команда ss не найдена.'; fi
    printf '\nDocker:\n'
    if has_cmd docker; then
        printf 'Версия: %s\n' "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
        local containers
        if containers=$(docker ps -q 2>/dev/null); then
            if [[ -z $containers ]]; then printf 'Запущенных контейнеров: 0\n'
            else printf 'Запущенных контейнеров: %s\n' "$(wc -l <<< "$containers" | tr -d ' ')"; fi
        else say_warn 'Не удалось получить количество контейнеров.'; fi
    else say_info 'Docker не установлен.'; fi
    printf '\nИтог:\n'
    if service_active ssh; then say_ok 'SSH запущен.'; else say_critical 'SSH не запущен или его состояние неизвестно.'; fi
    if package_installed fail2ban; then say_ok 'Fail2Ban установлен.'; else say_critical 'Fail2Ban не установлен.'; fi
    if [[ $root_setting == yes && $pass_setting == yes ]]; then say_warn 'Разрешён вход root по паролю; оцените необходимость этого режима.'; fi
    if [[ $(ssh_port) == 22 ]]; then say_info 'SSH настроен на стандартный порт 22.'; fi
    if [[ $cc == bbr ]]; then say_ok 'BBR включён для TCP.'; else say_info 'BBR выключен или состояние неизвестно.'; fi
    say_info 'Наличие обновлений безопасности этим аудитом не подтверждается; используйте меню обновления.'
}
