#!/usr/bin/env bash

memory_summary() {
    local value=''
    if has_cmd free; then value=$(LC_ALL=C free -h 2>/dev/null | awk -v row="$1" '$1 == row {print $2 " всего, " $3 " занято, " $4 " свободно"; exit}'); fi
    printf '%s\n' "${value:-Не удалось определить}"
}

cpu_model() {
    local model
    model=$(awk -F ': ' '/^model name[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ -z $model ]] && has_cmd lscpu; then model=$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1); fi
    printf '%s\n' "${model:-$(uname -m)}"
}

system_info() {
    local docker_state f2b_state cc timezone disk
    printf '\n════════ ИНФОРМАЦИЯ О СЕРВЕРЕ ════════\n'
    printf 'ОС: %s\n' "$(os_field PRETTY_NAME)"
    printf 'Ядро: %s\n' "$(uname -r)"
    printf 'Имя сервера: %s\n' "$(hostname)"
    printf 'Процессор: %s\n' "$(cpu_model)"
    printf 'Количество CPU: %s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'Недоступно')"
    printf 'RAM: %s\n' "$(memory_summary Mem:)"
    printf 'Swap: %s\n' "$(memory_summary Swap:)"
    disk=$(df -hP / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')
    printf 'Диск /: %s\n' "${disk:-Не удалось определить}"
    printf 'Время работы: %s\n' "$(uptime_ru)"
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null) || timezone=''
    printf 'Часовой пояс: %s\n' "${timezone:-$(date +%Z)}"
    printf 'IPv4: %s\n' "$(first_public_ip 4)"
    printf 'IPv6: %s\n' "$(first_public_ip 6)"
    printf 'Порт SSH по конфигурации: %s\n' "$(ssh_port)"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'Недоступно')
    printf 'BBR: %s\n' "$cc"
    if package_installed fail2ban; then f2b_state='установлен'; else f2b_state='не установлен'; fi
    if service_active fail2ban; then f2b_state="$f2b_state, запущен"; fi
    printf 'Fail2Ban: %s\n' "$f2b_state"
    if has_cmd docker; then
        docker_state=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        docker_state="установлен, версия ${docker_state:-недоступна}"
    else docker_state='не установлен'; fi
    printf 'Docker: %s\n' "$docker_state"
}
