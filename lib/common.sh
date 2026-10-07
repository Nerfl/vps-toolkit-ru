#!/usr/bin/env bash

TOOL_LOG=/var/log/vps-toolkit-ru.log
TOOL_BACKUPS=/var/backups/vps-toolkit-ru
DRY_RUN=${DRY_RUN:-0}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

os_field() {
    local key=$1 value
    [[ -r /etc/os-release ]] || return 1
    value=$(sed -n "s/^${key}=//p" /etc/os-release | head -n 1)
    value=${value#\"}; value=${value%\"}
    printf '%s\n' "$value"
}

check_platform() {
    local id version
    id=$(os_field ID) || return 1
    version=$(os_field VERSION_ID) || return 1
    [[ $id == ubuntu && ( $version == 22.04 || $version == 24.04 ) ]]
}

confirm_yes_no() {
    local answer
    printf '%s [y/N]: ' "$1"
    IFS= read -r answer || return 1
    case "$answer" in
        y|Y) return 0;;
        ''|n|N) return 1;;
        *) say_warn 'Ответ не распознан; действие отменено.'; return 1;;
    esac
}

pause_menu() {
    local unused
    printf '\nНажмите Enter для продолжения...'
    IFS= read -r unused || true
}

show_file_tail() {
    local file=$1 lines=${2:-30}
    if [[ -r $file ]]; then tail -n "$lines" -- "$file"; else say_info 'Журнал пока отсутствует или недоступен.'; fi
}

require_commands() {
    local cmd
    for cmd in "$@"; do
        if ! has_cmd "$cmd"; then say_error "Не найдена команда: $cmd"; return 1; fi
    done
}

run_step() {
    local label=$1 result; shift
    if (( DRY_RUN )); then say_info "План: $label"; return 0; fi
    prepare_mutation || return 1
    say_info "$label"
    if "$@"; then return 0; else result=$?; fi
    say_error "Действие не выполнено: $label"
    log_action ERROR "Действие не выполнено: $label" || true
    return "$result"
}

valid_ipv4() {
    local ip=$1 part
    local -a octets
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    [[ ${#octets[@]} == 4 ]] || return 1
    for part in "${octets[@]}"; do
        [[ ${#part} -le 3 && ( ${#part} -eq 1 || ${part:0:1} != 0 ) ]] \
            && (( 10#$part <= 255 )) || return 1
    done
}

valid_ipv6() {
    local ip=$1 rest part count=0
    local -a groups
    if [[ $ip == *.* ]]; then
        [[ $ip == *:* ]] || return 1
        valid_ipv4 "${ip##*:}" || return 1
        ip="${ip%:*}:0:0"
    fi
    [[ $ip == *:* && $ip =~ ^[0-9a-fA-F:]+$ && $ip != *:::* ]] || return 1
    rest=$ip
    if [[ $ip == *::* ]]; then
        rest=${ip#*::}
        [[ $rest != *::* ]] || return 1
    elif [[ $ip == :* || $ip == *: ]]; then
        return 1
    fi
    IFS=: read -r -a groups <<< "$ip"
    for part in "${groups[@]}"; do
        [[ -z $part ]] && continue
        [[ ${#part} -le 4 && $part =~ ^[0-9a-fA-F]+$ ]] || return 1
        ((count+=1))
    done
    if [[ $ip == *::* ]]; then (( count < 8 )); else (( count == 8 )); fi
}

valid_ip() { valid_ipv4 "$1" || valid_ipv6 "$1"; }

first_public_ip() {
    local family=$1 line ip
    has_cmd ip || { printf 'Не определён\n'; return; }
    while IFS= read -r line; do
        if [[ $family == 4 ]]; then
            ip=$(awk '{print $4}' <<< "$line"); ip=${ip%%/*}
            valid_ipv4 "$ip" || continue
            case "$ip" in
                0.*|10.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|192.0.0.*|192.0.2.*|198.18.*|198.19.*|198.51.100.*|203.0.113.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|22[4-9].*|2[3-5][0-9].*) continue;;
            esac
        else
            ip=$(awk '{print $4}' <<< "$line"); ip=${ip%%/*}
            [[ $ip == *:* ]] || continue
            case "${ip,,}" in fe80:*|fec*|fc*|fd*|ff*|::|::1|2001:db8:*) continue;; esac
        fi
        printf '%s\n' "$ip"; return
    done < <(ip -o -"$family" addr show scope global 2>/dev/null)
    printf 'Не определён\n'
}

ssh_setting() {
    local key=$1 output
    if ! has_cmd sshd; then printf 'Недоступно\n'; return; fi
    output=$(sshd -T 2>/dev/null) || { printf 'Недоступно\n'; return; }
    awk -v key="$key" '$1 == key {print $2; exit}' <<< "$output"
}

ssh_port() { ssh_setting port; }

service_active() { has_cmd systemctl && systemctl is-active --quiet "$1" 2>/dev/null; }

package_installed() { has_cmd dpkg-query && [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]; }

yes_no() { if "$@"; then printf 'Да\n'; else printf 'Нет\n'; fi; }

uptime_ru() {
    local seconds='' days hours minutes
    if [[ ! -r /proc/uptime ]]; then printf 'Недоступно\n'; return; fi
    read -r seconds _ < /proc/uptime
    seconds=${seconds%%.*}
    [[ $seconds =~ ^[0-9]+$ ]] || { printf 'Недоступно\n'; return; }
    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    minutes=$(((seconds % 3600) / 60))
    printf '%s дн. %s ч. %s мин.\n' "$days" "$hours" "$minutes"
}

apt_diagnostics() {
    awk '
        /Could not get lock|Unable to acquire.*lock|Waiting for cache lock|is another process using it/ {
            if (!locked++) print "[ОШИБКА] apt/dpkg занят другим процессом. Дождитесь его завершения; lock-файлы не удаляйте."
            next
        }
        /Temporary failure resolving|Could not resolve/ {print "[ОШИБКА] Не удалось определить адрес репозитория. Проверьте DNS."; next}
        /Failed to fetch|^Err:/ {print "[ОШИБКА] Не удалось получить данные репозитория. Проверьте доступность источника."; next}
        /Hash Sum mismatch/ {print "[ОШИБКА] Контрольная сумма данных репозитория не совпала."; next}
        /404 Not Found/ {print "[ОШИБКА] Файл пакета не найден в репозитории (404)."; next}
        /^E: Unable to locate package / {
            sub(/^E: Unable to locate package /, "")
            if ($0 ~ /^[a-zA-Z0-9.+_-]+$/) print "[ОШИБКА] Пакет не найден: " $0
            else print "[ОШИБКА] Пакет не найден."
            next
        }
        /^E: Sub-process .* returned an error code/ {print "[ОШИБКА] Подпроцесс apt/dpkg завершился с ошибкой."; next}
        /^dpkg: error processing package / {
            sub(/^dpkg: error processing package /, "")
            split($0, parts, " ")
            print "[ОШИБКА] Ошибка обработки пакета: " parts[1]
            next
        }
        /^E:/ {print "[ОШИБКА] apt сообщил об ошибке. Проверьте репозитории и состояние dpkg."; next}
        /^W:/ {print "[ПРЕДУПРЕЖДЕНИЕ] apt сообщил о проблеме с репозиторием или пакетом."; next}
        /^Fetched/ {print "[ИНФО] Данные репозиториев получены."; next}
    '
}

apt_run() {
    local result
    local -a options=(-y -o DPkg::Lock::Timeout=0 -o Dpkg::Options::=--force-confold)
    if [[ ${1:-} == update ]]; then options+=(-o APT::Update::Error-Mode=any); fi
    DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get "${options[@]}" "$@" 2>&1 | apt_diagnostics
    result=${PIPESTATUS[0]}
    return "$result"
}
