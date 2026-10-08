#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install.sh"

fail() { printf 'ОШИБКА: %s\n' "$1" >&2; exit 1; }

while IFS= read -r -d '' file; do
    bash -n "$file" || fail "Ошибка синтаксиса: $file"
done < <(find "$ROOT_DIR" -type f -name '*.sh' -print0)

[[ $(read_version) == 0.1.0 ]] || fail 'Версия определена неверно.'
declare -F audit_server update_menu fail2ban_menu bbr_menu system_info backup_file log_action >/dev/null || fail 'Не все модули загружены.'
source "$ROOT_DIR/install.sh"
declare -F audit_server update_menu fail2ban_menu bbr_menu >/dev/null || fail 'Повторная загрузка модулей не удалась.'
os_field() { case "$1" in ID) printf 'ubuntu\n';; VERSION_ID) printf '24.04\n';; esac; }
check_platform || fail 'Ubuntu 24.04 должна поддерживаться.'
os_field() { case "$1" in ID) printf 'debian\n';; VERSION_ID) printf '12\n';; esac; }
if check_platform; then fail 'Неподдерживаемая ОС принята.'; fi
[[ $(fail2ban_desired_config | grep -c '^maxretry = 5$') == 1 ]] || fail 'Параметры Fail2Ban неверны.'
[[ $(fail2ban_desired_config | grep -c '^port = 22$') == 1 ]] || fail 'Порт Fail2Ban не закреплён.'
[[ $(bbr_config_content cubic fq_codel | grep -c '^net.ipv4.tcp_congestion_control=bbr$') == 1 ]] || fail 'Параметры BBR неверны.'
[[ $(bbr_config_content cubic fq_codel | grep -c '^# previous_cc=cubic$') == 1 ]] || fail 'Предыдущее значение BBR не сохраняется.'
for address in 127.0.0.1 255.255.255.255 2001:db8::1 ::1 ::ffff:192.0.2.1 1:2:3:4:5:6:7:8; do
    valid_ip "$address" || fail "Правильный IP отклонён: $address"
done
for address in '1.2.3.4; rm -rf /' 999.1.1.1 001.2.3.4 1.2.3 1.2.3.4: 1:::2 1:2:3:4:5:6:7:8:9; do
    if valid_ip "$address"; then fail "Неправильный IP принят: $address"; fi
done
for answer in y Y; do
    confirmation=$(printf '%s\n' "$answer" | confirm_yes_no 'Тестовое подтверждение?') || fail "Ответ $answer не принят как подтверждение."
    [[ $confirmation == *'[y/N]:'* ]] || fail 'Формат приглашения подтверждения неверен.'
done
for answer in n N '' да yes неверно; do
    if confirmation=$(printf '%s\n' "$answer" | confirm_yes_no 'Тестовое подтверждение?'); then
        fail "Ответ ${answer:-Enter} ошибочно принят как подтверждение."
    fi
    [[ $confirmation == *'[y/N]:'* ]] || fail 'Формат приглашения подтверждения неверен.'
done
if confirm_yes_no 'Тестовое подтверждение?' </dev/null >/dev/null; then
    fail 'Конец ввода ошибочно принят как подтверждение.'
fi

test_config=$(mktemp) || fail 'Не удалось создать временный файл теста.'
conflict_file=$(mktemp) || fail 'Не удалось создать файл проверки sysctl.'
fixture_root=$(mktemp -d) || fail 'Не удалось создать временный каталог sysctl.'
readiness_dir=$(mktemp -d) || fail 'Не удалось создать временный каталог Fail2Ban.'
trap 'rm -f -- "$test_config" "$conflict_file" "$fixture_root/run/sysctl.d/case.conf" "$fixture_root/usr/local/lib/sysctl.d/case.conf" "$readiness_dir/restarts" "$readiness_dir/jail-checks" "$readiness_dir/sleeps"; rmdir -- "$readiness_dir" "$fixture_root/run/sysctl.d" "$fixture_root/run" "$fixture_root/usr/local/lib/sysctl.d" "$fixture_root/usr/local/lib" "$fixture_root/usr/local" "$fixture_root/usr" "$fixture_root" 2>/dev/null || true' EXIT
BBR_CONFIG=$test_config
bbr_config_content cubic fq_codel > "$BBR_CONFIG"
bbr_file_owned || fail 'Штатный файл BBR не распознан.'
printf '# чужое изменение\n' >> "$BBR_CONFIG"
if bbr_file_owned; then fail 'Изменённый файл BBR принят как штатный.'; fi
rm -f -- "$BBR_CONFIG"

DRY_RUN=1
confirm_yes_no() { return 0; }
bbr_current() { printf 'cubic\n'; }
bbr_qdisc() { printf 'fq_codel\n'; }
bbr_supported() { return 0; }
bbr_sysctl_files() { [[ -n ${MOCK_SYSCTL_FILE:-} ]] && printf '%s\n' "$MOCK_SYSCTL_FILE"; return 0; }
sysctl() { fail 'В режиме просмотра вызван sysctl.'; }
apt-get() { fail 'В режиме просмотра вызван apt-get.'; }
apt() { fail 'В режиме просмотра вызван apt.'; }
backup_file() { fail 'В режиме просмотра создана резервная копия.'; }
systemctl() { fail 'В режиме просмотра вызван systemctl.'; }
log_action() { fail 'В режиме просмотра выполнена запись в журнал.'; }
prepare_mutation >/dev/null || fail 'Режим просмотра потребовал системный журнал.'
enable_plan=$(bbr_enable) || fail 'Просмотр включения BBR завершился ошибкой.'
[[ $enable_plan == *'План:'* ]] || fail 'План включения BBR не показан.'
printf 'net.ipv4.tcp_congestion_control = cubic\nnet.core.default_qdisc = fq_codel\n' > "$conflict_file"
MOCK_SYSCTL_FILE=$conflict_file
conflict_result=$(bbr_enable) || fail 'Проверка конфликта sysctl завершилась ошибкой.'
[[ $conflict_result == *"$conflict_file"* && $conflict_result == *'cubic'* && $conflict_result == *'fq_codel'* && $conflict_result == *'Включение BBR отменено'* ]] || fail 'Конфликты sysctl не показаны.'
mkdir -p -- "$fixture_root/run/sysctl.d" "$fixture_root/usr/local/lib/sysctl.d" || fail 'Не удалось создать тестовую структуру sysctl.'
printf '%s\n' '-net.ipv4.tcp_congestion_control = cubic' > "$fixture_root/run/sysctl.d/case.conf"
printf '%s\n' '-net.core.default_qdisc = fq_codel' > "$fixture_root/usr/local/lib/sysctl.d/case.conf"
fixture_conflicts=$( (source "$ROOT_DIR/modules/bbr.sh"; bbr_sysctl_conflicts "$fixture_root") ) || fail 'Поиск конфликтов во временных каталогах завершился ошибкой.'
[[ $fixture_conflicts == *"$fixture_root/run/sysctl.d/case.conf: net.ipv4.tcp_congestion_control = cubic"* ]] || fail 'Конфликт из /run/sysctl.d с ведущим дефисом не найден.'
[[ $fixture_conflicts == *"$fixture_root/usr/local/lib/sysctl.d/case.conf: net.core.default_qdisc = fq_codel"* ]] || fail 'Конфликт из /usr/local/lib/sysctl.d с ведущим дефисом не найден.'
printf '%s\n' '-net.ipv4.tcp_congestion_control' > "$fixture_root/run/sysctl.d/case.conf"
printf '%s\n' '-net.core.default_qdisc' > "$fixture_root/usr/local/lib/sysctl.d/case.conf"
standalone_result=$( (source "$ROOT_DIR/modules/bbr.sh"; bbr_sysctl_conflicts "$fixture_root") ) || fail 'Строка исключения без значения вызвала ошибку.'
[[ -z $standalone_result ]] || fail 'Строка исключения без «=» ошибочно принята за конфликт.'
printf '%s\n' '-net.ipv4.tcp_congestion_control = cubic=неоднозначно' > "$fixture_root/run/sysctl.d/case.conf"
if ambiguous_result=$( (source "$ROOT_DIR/modules/bbr.sh"; bbr_sysctl_conflicts "$fixture_root") ); then
    fail 'Неоднозначное значение sysctl было принято.'
fi
[[ $ambiguous_result == *'Неоднозначное определение sysctl'* ]] || fail 'Неоднозначное значение sysctl не объяснено.'
MOCK_SYSCTL_FILE=''
bbr_current() { printf 'bbr\n'; }
external_bbr=$(bbr_enable) || fail 'Проверка внешней настройки BBR завершилась ошибкой.'
[[ $external_bbr == *'вне toolkit'* ]] || fail 'Внешняя настройка BBR была присвоена toolkit.'
bbr_current() { printf 'cubic\n'; }
fail2ban_existing_custom() { return 1; }
package_installed() { return 1; }
MOCK_SSHD_CONFIG='port 22'
MOCK_SS_OUTPUT='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))'
MOCK_MAIN_PID=123
MOCK_SOCKET_LISTEN='22 (Stream)'
MOCK_SSH_SERVICE_ACTIVE=1
MOCK_SSH_SOCKET_ACTIVE=0
MOCK_F2B_ACTIVE=0
sshd() { printf '%s\n' "$MOCK_SSHD_CONFIG"; }
ss() { printf '%s\n' "$MOCK_SS_OUTPUT"; }
service_active() {
    case "$1" in
        ssh.service) (( MOCK_SSH_SERVICE_ACTIVE ));;
        ssh.socket) (( MOCK_SSH_SOCKET_ACTIVE ));;
        fail2ban) (( MOCK_F2B_ACTIVE ));;
        *) return 1;;
    esac
}
systemctl() {
    [[ ${1:-} == show && ${2:-} == -p && ${4:-} == --value ]] || fail 'Неожиданный вызов systemctl в smoke-тесте.'
    case "${3:-}:${5:-}" in
        MainPID:ssh.service) printf '%s\n' "$MOCK_MAIN_PID";;
        Listen:ssh.socket) printf '%s\n' "$MOCK_SOCKET_LISTEN";;
        *) fail 'Неожиданный запрос к systemctl в smoke-тесте.';;
    esac
}
F2B_CONFIG=$test_config
f2b_plan=$(fail2ban_install_configure) || fail 'Просмотр настройки Fail2Ban завершился ошибкой.'
[[ $f2b_plan == *'План:'* ]] || fail 'План настройки Fail2Ban не показан.'
fail2ban_desired_config > "$F2B_CONFIG"
fail2ban_config_managed || fail 'Штатный файл Fail2Ban не распознан.'
fail2ban_legacy_config > "$F2B_CONFIG"
fail2ban_config_managed || fail 'Файл Fail2Ban прежней версии не распознан.'
printf '# ручное изменение\n' >> "$F2B_CONFIG"
if fail2ban_config_managed; then fail 'Изменённый файл Fail2Ban принят как штатный.'; fi
rm -f -- "$F2B_CONFIG"
fail2ban_existing_custom() { return 0; }
custom_jail=$(fail2ban_install_configure) || fail 'Проверка пользовательского jail завершилась ошибкой.'
[[ $custom_jail == *'сохранена без изменений'* ]] || fail 'Пользовательская настройка Fail2Ban не защищена.'
fail2ban_existing_custom() { return 1; }
package_installed() { return 0; }
MOCK_F2B_ACTIVE=1
fail2ban-client() {
    if [[ ${1:-} == get ]]; then
        case ${3:-} in maxretry) printf '5\n';; findtime) printf '600\n';; bantime) printf '3600\n';; esac
    fi
    return 0
}
fail2ban_desired_config > "$F2B_CONFIG"
fail2ban_existing_custom() { return 0; }
override_result=$(fail2ban_install_configure) || fail 'Проверка переопределения jail завершилась ошибкой.'
[[ $override_result == *'пользовательская настройка'* && $override_result == *'Действующее значение maxretry: 5'* && $override_result != *'уже настроены'* ]] || fail 'Переопределение jail скрыто сообщением об идемпотентности.'
fail2ban_existing_custom() { return 1; }
repeat_setup=$(fail2ban_install_configure) || fail 'Повторный запуск Fail2Ban завершился ошибкой.'
[[ $repeat_setup == *'уже настроены'* ]] || fail 'Повторный запуск Fail2Ban не идемпотентен.'
fail2ban-client() {
    if [[ ${1:-} == get ]]; then
        case ${3:-} in maxretry) printf '3\n';; findtime) printf '600\n';; bantime) printf '3600\n';; esac
    fi
    return 0
}
effective_override=$(fail2ban_install_configure) || fail 'Проверка действующего переопределения jail завершилась ошибкой.'
[[ $effective_override == *'Действующее значение maxretry: 3'* && $effective_override != *'уже настроены'* ]] || fail 'Расхождение действующих параметров jail не обнаружено.'
fail2ban-client() {
    if [[ ${1:-} == get ]]; then
        case ${3:-} in maxretry) printf '5\n';; findtime) printf '600\n';; bantime) printf '3600\n';; esac
    fi
    return 0
}
MOCK_SS_OUTPUT=$(printf '%s\n' \
    'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))' \
    'LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=123,fd=4))')
dual_stack=$(fail2ban_ssh_port_safe) || fail 'Два адреса SSH-порта 22 не распознаны.'
[[ $dual_stack == *'Порт SSH 22 подтверждён'* && $dual_stack != *'22 22'* ]] || fail 'IPv4 и IPv6 одного SSH-порта не объединены.'
MOCK_SS_OUTPUT=$(printf '%s\n' \
    'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))' \
    'LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=123,fd=4))' \
    'LISTEN 0 128 127.0.0.1:6010 0.0.0.0:* users:(("sshd",pid=456,fd=5))' \
    'LISTEN 0 128 [::1]:6010 [::]:* users:(("sshd",pid=456,fd=6))')
x11_listener=$(fail2ban_ssh_port_safe) || fail 'X11 forwarding ошибочно принят за серверный SSH-порт.'
[[ $x11_listener == *'Порт SSH 22 подтверждён'* && $x11_listener != *6010* ]] || fail 'Дочерний SSH/X11 listener не исключён.'
MOCK_SS_OUTPUT='LISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))'
loopback_server=$(fail2ban_ssh_port_safe) || fail 'Настоящий SSH listener на loopback ошибочно отклонён.'
[[ $loopback_server == *'Порт SSH 22 подтверждён'* ]] || fail 'SSH listener на loopback не подтверждён.'
MOCK_SS_OUTPUT='LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=123,fd=3))'
port_mismatch=$(fail2ban_install_configure) || fail 'Проверка расхождения портов завершилась ошибкой.'
[[ $port_mismatch == *'Фактические порты SSH: 2222'* && $port_mismatch == *'Автоматическая настройка jail отменена'* ]] || fail 'Расхождение sshd -T и ss не остановило настройку.'
MOCK_SS_OUTPUT='LISTEN 0 128 0.0.0.0:22 0.0.0.0:*'
unknown_listener=$(fail2ban_install_configure) || fail 'Проверка неизвестного listener завершилась ошибкой.'
[[ $unknown_listener == *'Фактический TCP listener SSH не определён'* ]] || fail 'Неизвестный listener SSH принят.'
MOCK_SSH_SERVICE_ACTIVE=0
MOCK_SSH_SOCKET_ACTIVE=1
MOCK_SOCKET_LISTEN='ListenStream=22'
MOCK_SS_OUTPUT='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("systemd",pid=1,fd=3))'
socket_listener=$(fail2ban_install_configure) || fail 'Проверка ssh.socket завершилась ошибкой.'
[[ $socket_listener == *'Порт SSH 22 подтверждён'* ]] || fail 'Активный ssh.socket на порту 22 не распознан.'
MOCK_SOCKET_LISTEN=$(printf '%s\n' 'Listen=0.0.0.0:22 (Stream)' 'Listen=[::]:22 (Stream)')
socket_dual_stack=$(fail2ban_ssh_port_safe) || fail 'Два ListenStream ssh.socket на порту 22 не распознаны.'
[[ $socket_dual_stack == *'Порт SSH 22 подтверждён'* ]] || fail 'IPv4 и IPv6 ssh.socket не объединены.'
MOCK_SOCKET_LISTEN=$(printf '%s\n' 'Listen=0.0.0.0:22 (Stream)' 'Listen=[::]:2222 (Stream)')
socket_multiple=$(fail2ban_install_configure) || fail 'Проверка нескольких ListenStream завершилась ошибкой.'
[[ $socket_multiple == *'Порты ssh.socket: 22 2222'* && $socket_multiple == *'Автоматическая настройка jail отменена'* ]] || fail 'Несколько портов ssh.socket не остановили настройку.'
MOCK_SSH_SERVICE_ACTIVE=1
MOCK_SSH_SOCKET_ACTIVE=0
MOCK_SS_OUTPUT=$(printf '%s\n' \
    'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))' \
    'LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=123,fd=4))' \
    'LISTEN 0 128 127.0.0.1:2222 0.0.0.0:* users:(("sshd",pid=123,fd=5))')
multiple_server_ports=$(fail2ban_install_configure) || fail 'Проверка нескольких портов основного sshd завершилась ошибкой.'
[[ $multiple_server_ports == *'Фактические порты SSH: 22 2222'* && $multiple_server_ports == *'Автоматическая настройка jail отменена'* ]] || fail 'Несколько реальных SSH-портов не остановили настройку.'
MOCK_SS_OUTPUT='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))'
MOCK_MAIN_PID=0
unknown_main_pid=$(fail2ban_install_configure) || fail 'Проверка неизвестного MainPID завершилась ошибкой.'
[[ $unknown_main_pid == *'MainPID службы ssh.service не определён'* && $unknown_main_pid == *'Автоматическая настройка jail отменена'* ]] || fail 'Неизвестный MainPID не остановил настройку.'
MOCK_MAIN_PID=123
rm -f -- "$F2B_CONFIG"
external_jail=$(fail2ban_install_configure) || fail 'Проверка внешнего jail завершилась ошибкой.'
[[ $external_jail == *'Существующие правила сохранены'* ]] || fail 'Внешний jail был присвоен toolkit.'
fail2ban-client() { return 1; }
MOCK_F2B_ACTIVE=0
stopped_service=$(fail2ban_install_configure) || fail 'Проверка остановленного Fail2Ban завершилась ошибкой.'
[[ $stopped_service == *'План:'* ]] || fail 'Остановленный Fail2Ban не предложен к настройке.'
package_installed() { return 1; }
MOCK_SSHD_CONFIG='port 2222'
custom_port=$(fail2ban_install_configure) || fail 'Проверка нестандартного SSH-порта завершилась ошибкой.'
[[ $custom_port == *'Автоматическая настройка jail отменена'* ]] || fail 'Нестандартный SSH-порт не остановил настройку.'
updates_plan=$(updates_available) || fail 'Проверка обновлений в режиме просмотра завершилась ошибкой.'
[[ $updates_plan == *'apt не запускается'* ]] || fail 'Режим просмотра попытался проверить apt.'
apt_plan=$(apt_upgrade_safe) || fail 'Просмотр обновления завершился ошибкой.'
[[ $apt_plan == *'План:'* ]] || fail 'План обновления не показан.'
refresh_plan=$(apt_refresh) || fail 'Просмотр apt update завершился ошибкой.'
[[ $refresh_plan == *'План:'* ]] || fail 'План apt update не показан.'
dpkg() { fail 'В режиме просмотра вызван dpkg.'; }
dry_apt=$(apt_run install fail2ban) || fail 'Режим просмотра apt завершился ошибкой.'
[[ $dry_apt == *'apt-get не запускается'* ]] || fail 'Режим просмотра не сообщил об отмене apt-get.'
update_menu </dev/null >/dev/null || fail 'EOF в меню обновлений обработан неверно.'
invalid_menu=$(printf 'неверно\n4\n' | update_menu) || fail 'Неправильный ввод в меню обработан неверно.'
[[ $invalid_menu == *'Неизвестный пункт меню'* ]] || fail 'Меню не предупредило о неправильном вводе.'

bbr_config_content cubic fq_codel > "$BBR_CONFIG"
bbr_current() { printf 'bbr\n'; }
bbr_qdisc() { printf 'fq\n'; }
bbr_available() { printf 'cubic bbr\n'; }
disable_plan=$(bbr_disable) || fail 'Просмотр отключения BBR завершился ошибкой.'
[[ $disable_plan == *'План:'* ]] || fail 'План отключения BBR не показан.'
[[ -f $BBR_CONFIG ]] || fail 'Режим просмотра удалил файл BBR.'
bbr_config_content bbr fq_codel > "$BBR_CONFIG"
fallback_plan=$(bbr_disable) || fail 'Просмотр запасного алгоритма завершился ошибкой.'
[[ $fallback_plan == *'cubic'* && $fallback_plan == *'План:'* ]] || fail 'Запасной алгоритм cubic не предложен.'
printf '# ручное изменение\n' >> "$BBR_CONFIG"
modified_file=$(bbr_disable) || fail 'Проверка изменённого файла BBR завершилась ошибкой.'
[[ $modified_file == *'удаление отменено'* ]] || fail 'Изменённый файл BBR не был защищён.'

DRY_RUN=0
MOCK_DPKG_AUDIT=''
dpkg() {
    [[ ${1:-} == --audit ]] || fail 'В тесте dpkg вызван с неожиданным аргументом.'
    printf '%s' "$MOCK_DPKG_AUDIT"
}
health_output=$(dpkg_health audit) || fail 'Пустой dpkg --audit ошибочно заблокировал операции apt.'
[[ $health_output == *'Состояние dpkg: нормально'* ]] || fail 'Аудит не показал нормальное состояние dpkg.'
for fixture in \
    'The following packages have been unpacked but not yet configured: fail2ban' \
    'The following packages are only half configured: fail2ban' \
    'The following packages have been triggered, but the trigger processing has not yet been done: libc-bin'; do
    MOCK_DPKG_AUDIT=$fixture
    if health_output=$(dpkg_health preflight); then fail 'Незавершённое состояние dpkg пропущено.'; fi
    [[ $health_output == *'[CRITICAL] Пакетная система dpkg находится в незавершённом состоянии.'* && $health_output == *"$fixture"* ]] || fail 'Причина блокировки dpkg не показана.'
    if health_output=$(dpkg_health audit); then fail 'Аудит пропустил незавершённое состояние dpkg.'; fi
    [[ $health_output == *'[CRITICAL] Обнаружены незавершённые операции dpkg.'* ]] || fail 'Аудит не отметил критическое состояние dpkg.'
done
fuser() { [[ ${MOCK_LOCK_OWNER:-} == yes ]] && printf '1234\n' || return 1; }
MOCK_LOCK_OWNER=yes
if lock_output=$(apt_lock_preflight "$test_config"); then fail 'Занятый lock-файл не обнаружен.'; fi
[[ $lock_output == *'PID 1234'* ]] || fail 'Владелец lock-файла не показан.'
MOCK_LOCK_OWNER=no
apt_lock_preflight "$test_config" >/dev/null || fail 'Свободный lock-файл ошибочно заблокирован.'
apt_lock_preflight() { return 0; }
apt-get() {
    if [[ ${1:-} == -s ]]; then
        if [[ ${MOCK_APT_SIM_FAIL:-} == yes ]]; then printf 'E: План обновления недоступен\n'; return 100; fi
        printf 'Inst package-a [1] (2 Ubuntu:24.04)\nInst package-b [1] (2 Ubuntu:24.04)\n'
        return 0
    fi
    printf 'dpkg: error processing package fail2ban (--configure):\nE: Sub-process /usr/bin/dpkg returned an error code (1)\n'
    return 100
}
apt_preview_upgrade >/dev/null || fail 'Симуляция apt с подменённой командой завершилась ошибкой.'
[[ $APT_PREVIEW_COUNT == 2 ]] || fail 'Число пакетов в плане обновления неверно.'
MOCK_APT_SIM_FAIL=yes
if preview_diagnostic=$(apt_preview_upgrade 2>&1); then fail 'Ошибка симуляции apt ошибочно принята за успех.'; else preview_result=$?; fi
[[ $preview_result == 100 && $preview_diagnostic == *'кодом 100'* && $preview_diagnostic == *'План обновления недоступен'* ]] || fail 'Диагностика ошибки симуляции apt потеряна.'
MOCK_APT_SIM_FAIL=no
for fixture in \
    'The following packages have been unpacked but not yet configured: fail2ban' \
    'The following packages are only half configured: fail2ban' \
    'The following packages have been triggered, but the trigger processing has not yet been done: libc-bin'; do
    MOCK_DPKG_AUDIT=$fixture
    if apt_diagnostic=$(apt_run install fail2ban 2>&1); then fail 'apt был разрешён при незавершённом dpkg.'; fi
    [[ $apt_diagnostic == *'[CRITICAL] Пакетная система dpkg находится в незавершённом состоянии.'* && $apt_diagnostic != *'apt-get завершился'* ]] || fail 'apt не был остановлен до запуска.'
done
MOCK_DPKG_AUDIT=''
if apt_diagnostic=$(apt_run upgrade 2>&1); then fail 'Ошибка apt ошибочно принята за успех.'; else apt_result=$?; fi
[[ $apt_result == 100 && $apt_diagnostic == *'кодом 100'* && $apt_diagnostic == *'dpkg: error processing package'* && $apt_diagnostic == *'E: Sub-process'* ]] || fail 'Код ошибки apt или исходная диагностика потеряны.'
prepare_mutation() { return 0; }
log_action() { return 0; }
if step_diagnostic=$(run_step 'Тестовая команда apt' apt_run upgrade 2>&1); then fail 'Ошибка шага apt ошибочно принята за успех.'; else step_result=$?; fi
[[ $step_result == 100 && $step_diagnostic == *'Действие не выполнено'* ]] || fail 'Код ошибки apt потерян при выполнении шага.'

(
    F2B_CONFIG=$test_config
    fail2ban_desired_config > "$F2B_CONFIG"
    package_installed() { return 0; }
    backup_file() { fail 'Тест Fail2Ban попытался создать системную копию.'; }
    mkdir() { [[ "$*" == '-p -m 0755 /etc/fail2ban/jail.d' ]] || fail 'Тест Fail2Ban попытался создать неожиданный каталог.'; }
    service_active() { [[ ${1:-} == fail2ban ]]; }
    journalctl() { printf 'Server ready\n'; }
    sleep() {
        local count
        count=$(< "$readiness_dir/sleeps")
        printf '%s\n' "$((count + 1))" > "$readiness_dir/sleeps"
    }
    systemctl() {
        local count
        [[ ${2:-} == fail2ban ]] || fail 'Неожиданный сервис в тесте Fail2Ban.'
        count=$(< "$readiness_dir/restarts")
        case ${1:-} in
            restart) printf '%s\n' "$((count + 1))" > "$readiness_dir/restarts";;
            is-active)
                if [[ $MOCK_F2B_CASE == failed && $count == 1 ]]; then printf 'failed\n'; return 3; fi
                printf 'active\n';;
            *) fail 'Неожиданный вызов systemctl в тесте Fail2Ban.';;
        esac
    }
    fail2ban-client() {
        local count checks
        case ${1:-} in
            -t) printf "'allowipv6' not defined in 'Definition'. Using default one: 'auto'\n" >&2;;
            ping) printf 'Server replied: pong\n';;
            status)
                [[ ${2:-} == sshd ]] || fail 'Проверен неожиданный jail.'
                count=$(< "$readiness_dir/restarts")
                if (( count == 0 || count == 2 )); then printf 'Status for the jail: sshd\n'; return 0; fi
                checks=$(< "$readiness_dir/jail-checks")
                checks=$((checks + 1))
                printf '%s\n' "$checks" > "$readiness_dir/jail-checks"
                case $MOCK_F2B_CASE in
                    delayed|rollback_delay) (( checks <= 2 )) && return 1;;
                    timeout) return 1;;
                    failed) return 1;;
                esac
                printf 'Status for the jail: sshd\n';;
            get)
                case ${3:-} in maxretry) printf '5\n';; findtime) printf '600\n';; bantime) printf '3600\n';; esac;;
            *) fail 'Неожиданный вызов fail2ban-client в тесте.';;
        esac
    }
    reset_readiness_case() {
        MOCK_F2B_CASE=$1
        printf '0\n' > "$readiness_dir/restarts"
        printf '0\n' > "$readiness_dir/jail-checks"
        printf '0\n' > "$readiness_dir/sleeps"
    }

    reset_readiness_case immediate
    ready_output=$(fail2ban_apply_config) || fail 'Готовый сразу Fail2Ban ошибочно отклонён.'
    [[ $ready_output == *'Сервис Fail2Ban запущен'* && $ready_output == *'jail sshd активен'* && $(< "$readiness_dir/sleeps") == 0 ]] || fail 'Немедленная готовность Fail2Ban не подтверждена.'

    reset_readiness_case delayed
    ready_output=$(fail2ban_apply_config) || fail 'Постепенное появление jail ошибочно отклонено.'
    [[ $(< "$readiness_dir/jail-checks") == 3 && $(< "$readiness_dir/sleeps") == 2 && $(< "$readiness_dir/restarts") == 1 && $ready_output != *'Откат:'* ]] || fail 'Ожидание jail или отсутствие преждевременного отката не подтверждено.'

    reset_readiness_case failed
    if ready_output=$(fail2ban_apply_config 2>&1); then fail 'Упавший сервис ошибочно принят за готовый.'; fi
    [[ $ready_output == *'Сервис Fail2Ban остановился или завершился с ошибкой'* && $ready_output == *'Состояние systemd-сервиса Fail2Ban: failed'* && $ready_output == *'Прежняя конфигурация и состояние Fail2Ban восстановлены'* && $(< "$readiness_dir/restarts") == 2 && $(< "$readiness_dir/sleeps") == 0 ]] || fail 'Падение сервиса не вызвало немедленную ошибку и откат.'

    reset_readiness_case timeout
    if ready_output=$(fail2ban_apply_config 2>&1); then fail 'Отсутствующий jail ошибочно принят за готовый.'; fi
    [[ $F2B_READY_TIMEOUT_SECONDS == 20 && $ready_output == *'Истекло время ожидания'* && $ready_output == *'Последние события Fail2Ban:'* && $ready_output == *'Прежняя конфигурация и состояние Fail2Ban восстановлены'* && $(< "$readiness_dir/restarts") == 2 && $(< "$readiness_dir/sleeps") == 20 ]] || fail 'Таймаут jail не вызвал диагностику и откат через 20 секунд.'

    reset_readiness_case rollback_delay
    F2B_CHANGED=0 F2B_WAS_ACTIVE=1 F2B_JAIL_WAS_ACTIVE=1
    rollback_output=$(fail2ban_restore_config) || fail 'Откат не дождался восстановления jail.'
    [[ $(< "$readiness_dir/jail-checks") == 3 && $(< "$readiness_dir/sleeps") == 2 && $rollback_output == *'jail sshd активен'* ]] || fail 'Откат не проверил готовность через повторные попытки.'

    reset_readiness_case immediate
    warning_output=$(fail2ban_apply_config) || fail 'Предупреждение allowipv6 ошибочно признано ошибкой.'
    [[ $warning_output == *'Конфигурация Fail2Ban прошла проверку'* && $warning_output == *'jail sshd активен'* ]] || fail 'Корректная конфигурация с предупреждением allowipv6 отклонена.'
) || fail 'Проверки ожидания готовности Fail2Ban завершились ошибкой.'

printf 'OK: синтаксис, модули, версия, IP, SSH, Fail2Ban, sysctl, apt и режим просмотра проверены.\n'
