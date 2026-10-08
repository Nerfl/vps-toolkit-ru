#!/usr/bin/env bash

# Возвращает только порты основного sshd, заданные эффективной конфигурацией.
ssh_listener_configured_ports() {
    local output ports port
    has_cmd sshd || return 1
    output=$(sshd -T 2>/dev/null) || return 1
    ports=$(awk '$1 == "port" {print $2}' <<< "$output" | sort -n -u) || return 1
    [[ -n $ports ]] || return 1
    while IFS= read -r port; do
        [[ $port =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    done <<< "$ports"
    tr '\n' ' ' <<< "$ports" | sed 's/ $//'
}

ssh_listener_socket_ports() {
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
            printf '%s\n' "$((10#$port))"
            previous=$token
        done
    done <<< "$output"
}

# Успех: уникальные адреса listener, по одному на строку. Ошибка: причина.
ssh_listener_endpoints() {
    local configured socket_ports='' main_pid='' listening line state recv send endpoint peer rest port endpoints='' actual
    configured=$(ssh_listener_configured_ports) || { printf 'Действующие порты sshd не определены.\n'; return 1; }
    has_cmd ss || { printf 'Команда ss недоступна.\n'; return 1; }
    if service_active ssh.socket; then
        socket_ports=$(ssh_listener_socket_ports) || { printf 'Не удалось прочитать TCP ListenStream активного ssh.socket.\n'; return 1; }
        socket_ports=$(sort -n -u <<< "$socket_ports" | paste -sd ' ' -)
        [[ -n $socket_ports ]] || { printf 'TCP ListenStream активного ssh.socket не определён.\n'; return 1; }
        [[ $socket_ports == "$configured" ]] || {
            printf 'Порты ssh.socket: %s; настроенные порты sshd: %s.\n' "$socket_ports" "$configured"; return 1;
        }
    fi
    if service_active ssh.service; then
        main_pid=$(systemctl show -p MainPID --value ssh.service 2>/dev/null) || {
            printf 'Не удалось определить MainPID службы ssh.service.\n'; return 1;
        }
        main_pid=${main_pid#MainPID=}
        [[ $main_pid =~ ^[1-9][0-9]*$ ]] || { printf 'MainPID службы ssh.service не определён однозначно.\n'; return 1; }
    fi
    [[ -n $main_pid || -n $socket_ports ]] || { printf 'Ни ssh.service, ни ssh.socket не подтверждены как активные.\n'; return 1; }
    listening=$(ss -H -ltnp 2>/dev/null) || { printf 'Не удалось получить список TCP listener через ss.\n'; return 1; }
    while IFS= read -r line; do
        read -r state recv send endpoint peer rest <<< "$line"
        [[ $state == LISTEN && $endpoint == *:* ]] || continue
        port=${endpoint##*:}
        [[ $port =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || {
            printf 'Не удалось разобрать фактический порт SSH.\n'; return 1;
        }
        if [[ -n $main_pid && $line == *"\"sshd\",pid=$main_pid,"* ]]; then :
        elif [[ -n $socket_ports && " $socket_ports " == *" $((10#$port)) "* && $line == *'"systemd",pid=1,'* ]]; then :
        else continue; fi
        endpoints+="$endpoint"$'\n'
    done <<< "$listening"
    [[ -n $endpoints ]] || { printf 'Фактический TCP listener SSH не определён.\n'; return 1; }
    actual=$(printf '%s' "$endpoints" | awk -F: 'NF {print $NF+0}' | sort -n -u | paste -sd ' ' -)
    [[ $actual == "$configured" ]] || {
        printf 'Фактические порты SSH: %s; настроенные: %s.\n' "$actual" "$configured"; return 1;
    }
    printf '%s' "$endpoints" | awk 'NF && !seen[$0]++'
}
