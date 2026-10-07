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

test_config=$(mktemp) || fail 'Не удалось создать временный файл теста.'
conflict_file=$(mktemp) || fail 'Не удалось создать файл проверки sysctl.'
fixture_root=$(mktemp -d) || fail 'Не удалось создать временный каталог sysctl.'
trap 'rm -f -- "$test_config" "$conflict_file" "$fixture_root/run/sysctl.d/case.conf" "$fixture_root/usr/local/lib/sysctl.d/case.conf"; rmdir -- "$fixture_root/run/sysctl.d" "$fixture_root/run" "$fixture_root/usr/local/lib/sysctl.d" "$fixture_root/usr/local/lib" "$fixture_root/usr/local" "$fixture_root/usr" "$fixture_root" 2>/dev/null || true' EXIT
BBR_CONFIG=$test_config
bbr_config_content cubic fq_codel > "$BBR_CONFIG"
bbr_file_owned || fail 'Штатный файл BBR не распознан.'
printf '# чужое изменение\n' >> "$BBR_CONFIG"
if bbr_file_owned; then fail 'Изменённый файл BBR принят как штатный.'; fi
rm -f -- "$BBR_CONFIG"

DRY_RUN=1
confirm() { return 0; }
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
sshd() { printf 'port 22\n'; }
ss() { printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'; }
service_active() { return 1; }
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
fail2ban-client() {
    if [[ ${1:-} == get ]]; then
        case ${3:-} in maxretry) printf '5\n';; findtime) printf '600\n';; bantime) printf '3600\n';; esac
    fi
    return 0
}
service_active() { return 0; }
systemctl() { [[ ${1:-} == list-sockets ]] && printf '0.0.0.0:22 ssh.socket ssh@.service\n'; }
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
ss() { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'; }
port_mismatch=$(fail2ban_install_configure) || fail 'Проверка расхождения портов завершилась ошибкой.'
[[ $port_mismatch == *'Фактические порты SSH: 2222'* && $port_mismatch == *'Автоматическая настройка jail отменена'* ]] || fail 'Расхождение sshd -T и ss не остановило настройку.'
ss() { printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'; }
unknown_listener=$(fail2ban_install_configure) || fail 'Проверка неизвестного listener завершилась ошибкой.'
[[ $unknown_listener == *'Фактический TCP listener SSH не определён'* ]] || fail 'Неизвестный listener SSH принят.'
ss() { printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("systemd",pid=1,fd=3))\n'; }
socket_listener=$(fail2ban_install_configure) || fail 'Проверка ssh.socket завершилась ошибкой.'
[[ $socket_listener == *'Порт SSH 22 подтверждён'* ]] || fail 'Активный ssh.socket на порту 22 не распознан.'
ss() { printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'; }
rm -f -- "$F2B_CONFIG"
external_jail=$(fail2ban_install_configure) || fail 'Проверка внешнего jail завершилась ошибкой.'
[[ $external_jail == *'Существующие правила сохранены'* ]] || fail 'Внешний jail был присвоен toolkit.'
fail2ban-client() { return 1; }
service_active() { return 1; }
stopped_service=$(fail2ban_install_configure) || fail 'Проверка остановленного Fail2Ban завершилась ошибкой.'
[[ $stopped_service == *'План:'* ]] || fail 'Остановленный Fail2Ban не предложен к настройке.'
package_installed() { return 1; }
sshd() { printf 'port 2222\n'; }
custom_port=$(fail2ban_install_configure) || fail 'Проверка нестандартного SSH-порта завершилась ошибкой.'
[[ $custom_port == *'Автоматическая настройка jail отменена'* ]] || fail 'Нестандартный SSH-порт не остановил настройку.'
updates_plan=$(updates_available) || fail 'Проверка обновлений в режиме просмотра завершилась ошибкой.'
[[ $updates_plan == *'apt не запускается'* ]] || fail 'Режим просмотра попытался проверить apt.'
apt_plan=$(apt_upgrade_safe) || fail 'Просмотр обновления завершился ошибкой.'
[[ $apt_plan == *'План:'* ]] || fail 'План обновления не показан.'
refresh_plan=$(apt_refresh) || fail 'Просмотр apt update завершился ошибкой.'
[[ $refresh_plan == *'План:'* ]] || fail 'План apt update не показан.'
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
apt-get() {
    if [[ ${1:-} == -s ]]; then printf 'Inst package-a [1] (2 Ubuntu:24.04)\nInst package-b [1] (2 Ubuntu:24.04)\n'; return 0; fi
    printf 'E: Could not get lock /var/lib/dpkg/lock\n'
    return 42
}
apt_preview_upgrade >/dev/null || fail 'Симуляция apt с подменённой командой завершилась ошибкой.'
[[ $APT_PREVIEW_COUNT == 2 ]] || fail 'Число пакетов в плане обновления неверно.'
set +e
apt_diagnostic=$(apt_run upgrade 2>&1)
apt_result=$?
set -e
[[ $apt_result == 42 && $apt_diagnostic == *'apt/dpkg занят'* ]] || fail 'Код ошибки apt или диагностика блокировки потеряны.'
prepare_mutation() { return 0; }
log_action() { return 0; }
set +e
step_diagnostic=$(run_step 'Тестовая команда apt' apt_run upgrade 2>&1)
step_result=$?
set -e
[[ $step_result == 42 && $step_diagnostic == *'Действие не выполнено'* ]] || fail 'Код ошибки apt потерян при выполнении шага.'

printf 'OK: синтаксис, модули, версия, IP, SSH, Fail2Ban, sysctl, apt и режим просмотра проверены.\n'
