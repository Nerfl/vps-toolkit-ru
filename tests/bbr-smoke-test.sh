#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install.sh"
fail() { printf 'ОШИБКА: %s\n' "$1" >&2; exit 1; }

fixture=$(mktemp -d) || fail 'Не удалось создать временный каталог BBR.'
alias_root=$(mktemp -d) || fail 'Не удалось создать временный каталог для ссылок sysctl.'
trap 'rm -f -- "$fixture/etc/sysctl.d/"* "$fixture/etc/sysctl.conf" "$fixture/etc/middle.conf" "$fixture/external.conf" "$fixture/usr/lib/sysctl.d/"*.conf "$fixture/current-cc" "$fixture/current-qdisc" "$fixture/fail-once" "$alias_root/lib/sysctl.d" "$alias_root/usr/lib/sysctl.d/"*.conf "$alias_root/external.conf"; rmdir -- "$fixture/usr/lib/sysctl.d" "$fixture/usr/lib" "$fixture/usr" "$fixture/etc/sysctl.d" "$fixture/etc" "$fixture" "$alias_root/elsewhere" "$alias_root/usr/lib/sysctl.d" "$alias_root/usr/lib" "$alias_root/usr" "$alias_root/lib" "$alias_root" 2>/dev/null || true' EXIT
mkdir -p -- "$fixture/etc/sysctl.d" || fail 'Не удалось создать тестовую структуру sysctl.'
BBR_CONFIG=$fixture/etc/sysctl.d/99-vps-toolkit-bbr.conf
earlier=$fixture/etc/sysctl.d/10-bufferbloat.conf
printf '%s\n' '-net.core.default_qdisc = fq_codel' > "$earlier"

mkdir -p -- "$alias_root/usr/lib/sysctl.d" "$alias_root/lib" || fail 'Не удалось создать каталог проверки symlink.'
printf '%s\n' 'net.core.default_qdisc = fq_codel' > "$alias_root/usr/lib/sysctl.d/10-alias.conf"
ln -s ../usr/lib/sysctl.d "$alias_root/lib/sysctl.d" || fail 'Не удалось создать штатный symlink каталога.'
alias_files=$(bbr_sysctl_files "$alias_root") || fail 'Штатный alias /lib/sysctl.d ошибочно отклонён.'
[[ $alias_files == "$alias_root/usr/lib/sysctl.d/10-alias.conf" ]] || fail 'Canonical alias прочитан повторно или неверно.'
printf 'OK: /lib/sysctl.d → /usr/lib/sysctl.d распознан один раз.\n'
rm -f -- "$alias_root/lib/sysctl.d"
mkdir -p -- "$alias_root/elsewhere" || fail 'Не удалось создать необычный каталог sysctl.'
ln -s ../elsewhere "$alias_root/lib/sysctl.d" || fail 'Не удалось создать необычный symlink каталога.'
if bbr_sysctl_files "$alias_root" >/dev/null; then fail 'Неожиданный symlink каталога принят.'; fi
rm -f -- "$alias_root/lib/sysctl.d"
printf '%s\n' 'net.core.default_qdisc=fq' > "$alias_root/external.conf"
ln -s ../../../external.conf "$alias_root/usr/lib/sysctl.d/20-link.conf" || fail 'Не удалось создать symlink файла.'
if bbr_sysctl_files "$alias_root" >/dev/null; then fail 'Symlink файла конфигурации принят.'; fi
rm -f -- "$alias_root/usr/lib/sysctl.d/20-link.conf"
printf 'OK: неожиданный symlink каталога и symlink файла блокируются.\n'

earlier_report=$(bbr_sysctl_conflicts "$fixture") || fail 'Более ранняя настройка qdisc ошибочно заблокировала BBR.'
[[ $earlier_report == *"$earlier = fq_codel"* && $earlier_report == *'ведущий «-»'* ]] || fail 'Ранняя настройка и смысл ведущего «-» не показаны.'
printf 'OK: 10-bufferbloat.conf с -net.core.default_qdisc=fq_codel безопасно переопределяется.\n'

printf '%s\n' 'net.core.default_qdisc = fq_codel' > "$fixture/etc/sysctl.d/99-z.conf"
if late_report=$(bbr_sysctl_conflicts "$fixture"); then fail 'Поздний файл sysctl не заблокировал BBR.'; fi
[[ $late_report == *'99-z.conf'* && $late_report == *'после файла toolkit'* ]] || fail 'Поздний конфликт не объяснён.'
rm -f -- "$fixture/etc/sysctl.d/99-z.conf"

printf '%s\n' 'net.ipv4.tcp_congestion_control = cubic' > "$fixture/etc/sysctl.conf"
if global_report=$(bbr_sysctl_conflicts "$fixture"); then fail 'Конфликтующий /etc/sysctl.conf не заблокировал BBR.'; fi
[[ $global_report == *'Позднее определение'* && $global_report == *'cubic'* ]] || fail 'Конфликт в /etc/sysctl.conf не объяснён.'
rm -f -- "$fixture/etc/sysctl.conf"

printf '%s\n' '-net.core.default_qdisc = fq_codel' 'net.core.default_qdisc = fq' > "$earlier"
if ambiguous_report=$(bbr_sysctl_conflicts "$fixture"); then fail 'Противоречивые определения в одном файле приняты.'; fi
[[ $ambiguous_report == *'Противоречивые определения'* ]] || fail 'Противоречие в файле не объяснено.'
printf '%s\n' '-net.core.default_qdisc = fq_codel' > "$earlier"

printf '%s\n' 'net .core.default_qdisc = fq_codel' > "$earlier"
if malformed_report=$(bbr_sysctl_conflicts "$fixture"); then fail 'Неоднозначный ключ sysctl был принят.'; fi
[[ $malformed_report == *'Неоднозначное определение sysctl'* ]] || fail 'Неоднозначный ключ не объяснён.'
printf '%s\n' '-net.core.default_qdisc = fq_codel' > "$earlier"

printf '%s\n' cubic > "$fixture/current-cc"
printf '%s\n' fq_codel > "$fixture/current-qdisc"
bbr_current() { cat -- "$fixture/current-cc"; }
bbr_qdisc() { cat -- "$fixture/current-qdisc"; }
bbr_available() { printf 'reno cubic\n'; }
modinfo() { [[ ${1:-} == tcp_bbr ]]; }
confirm_yes_no() { return 0; }
prepare_mutation() { return 0; }
log_action() { return 0; }
backup_file() { fail 'Неожиданное резервное копирование в тесте BBR.'; }
modprobe() { fail 'Тест вызвал modprobe.'; }
lsmod() { printf 'tcp_bbr 0 0\n'; }
sysctl() { fail 'В dry-run вызван sysctl.'; }

DRY_RUN=1
printf '%s\n' '# Чистая Ubuntu: интересующих параметров нет.' > "$fixture/etc/sysctl.conf"
ln -s ../sysctl.conf "$fixture/etc/sysctl.d/99-sysctl.conf" || fail 'Не удалось создать штатный alias sysctl.conf.'
clean_files=$(bbr_sysctl_files "$fixture") || fail 'Штатный 99-sysctl.conf ошибочно отклонён.'
[[ $(printf '%s\n' "$clean_files" | grep -Fxc "$fixture/etc/sysctl.conf") == 1 \
    && $clean_files != *'/etc/sysctl.d/99-sysctl.conf'* ]] || fail '/etc/sysctl.conf прочитан более одного раза.'
clean_report=$(bbr_sysctl_conflicts "$fixture") || fail 'Чистая Ubuntu с 99-sysctl.conf ошибочно заблокирована.'
[[ $clean_report == *"$earlier = fq_codel"* ]] || fail '10-bufferbloat.conf не распознан при штатном alias.'
clean_dry=$(bbr_enable "$fixture") || fail 'Чистый Ubuntu dry-run завершился ошибкой.'
[[ $clean_dry == *'Текущий алгоритм TCP: cubic; текущий qdisc: fq_codel'* \
    && $clean_dry == *'алгоритм TCP bbr; очередь по умолчанию fq'* \
    && $clean_dry == *'План:'* ]] || fail 'Чистый Ubuntu dry-run не показал план cubic/fq_codel → bbr/fq.'
[[ ! -e $BBR_CONFIG && $(< "$fixture/current-cc") == cubic && $(< "$fixture/current-qdisc") == fq_codel \
    && $(bbr_available) == 'reno cubic' && $(< "$earlier") == '-net.core.default_qdisc = fq_codel' ]] || fail 'Чистый Ubuntu dry-run изменил файл, runtime или доступность BBR.'
printf 'OK: чистая Ubuntu с 99-sysctl.conf разрешает dry-run cubic/fq_codel → bbr/fq без изменений.\n'

rm -f -- "$fixture/etc/sysctl.d/99-sysctl.conf"
ln -s "$fixture/etc/sysctl.conf" "$fixture/etc/sysctl.d/99-sysctl.conf" || fail 'Не удалось создать абсолютный alias sysctl.conf.'
absolute_files=$(bbr_sysctl_files "$fixture") || fail 'Прямой абсолютный alias sysctl.conf ошибочно отклонён.'
[[ $(printf '%s\n' "$absolute_files" | grep -Fxc "$fixture/etc/sysctl.conf") == 1 ]] || fail 'Абсолютный alias вызвал двойное чтение sysctl.conf.'
rm -f -- "$fixture/etc/sysctl.d/99-sysctl.conf"

printf '%s\n' 'net.core.default_qdisc=fq' > "$fixture/external.conf"
ln -s "$fixture/external.conf" "$fixture/etc/sysctl.d/99-test.conf" || fail 'Не удалось создать внешнюю ссылку.'
if bbr_sysctl_files "$fixture" >/dev/null; then fail 'Ссылка на внешний конфиг принята.'; fi
rm -f -- "$fixture/etc/sysctl.d/99-test.conf"
ln -s ../missing.conf "$fixture/etc/sysctl.d/99-test.conf" || fail 'Не удалось создать broken symlink.'
if bbr_sysctl_files "$fixture" >/dev/null; then fail 'Broken symlink принят.'; fi
rm -f -- "$fixture/etc/sysctl.d/99-test.conf"
ln -s sysctl.conf "$fixture/etc/middle.conf" || fail 'Не удалось создать промежуточную ссылку.'
ln -s ../middle.conf "$fixture/etc/sysctl.d/99-sysctl.conf" || fail 'Не удалось создать цепочку ссылок.'
if bbr_sysctl_files "$fixture" >/dev/null; then fail 'Цепочка symlink до sysctl.conf принята.'; fi
rm -f -- "$fixture/etc/sysctl.d/99-sysctl.conf" "$fixture/etc/middle.conf"
printf 'OK: прямой alias учитывается один раз; внешняя, broken и цепная ссылки блокируются.\n'

mkdir -p -- "$fixture/usr/lib/sysctl.d" || fail 'Не удалось создать каталог проверки mask.'
printf '%s\n' 'net.core.default_qdisc=fq_codel' > "$fixture/usr/lib/sysctl.d/99-z.conf"
ln -s /dev/null "$fixture/etc/sysctl.d/99-z.conf" || fail 'Не удалось создать mask /dev/null.'
masked_files=$(bbr_sysctl_files "$fixture") || fail 'Штатная mask /dev/null ошибочно отклонена.'
[[ $masked_files != *'99-z.conf'* ]] || fail 'Маскированный нижестоящий config участвует в анализе.'
bbr_sysctl_conflicts "$fixture" >/dev/null || fail 'Маскированный поздний config ошибочно блокирует BBR.'
rm -f -- "$fixture/etc/sysctl.d/99-z.conf" "$fixture/usr/lib/sysctl.d/99-z.conf"
printf 'OK: mask /dev/null исключает одноимённый нижестоящий sysctl-файл.\n'

bbr_available() { printf 'cubic reno bbr\n'; }
bbr_sysctl_files() {
    local file
    (( ${MOCK_BAD_SCAN:-0} == 0 )) || return 1
    for file in "$fixture/etc/sysctl.conf" "$fixture/etc/sysctl.d/"*.conf; do
        [[ -e $file && $file != "$BBR_CONFIG" ]] && printf '%s\n' "$file"
    done
    return 0
}
printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr' > "$fixture/etc/sysctl.d/99-remnawave-bbr.conf"
printf '%s\n' bbr > "$fixture/current-cc"
printf '%s\n' fq > "$fixture/current-qdisc"
external_output=$(bbr_enable) || fail 'Работающий внешний BBR вызвал ошибку.'
[[ $external_output == *'BBR уже активен: bbr / fq'* && $external_output == *'Настройка выполнена вне VPS Toolkit RU'* \
    && $external_output == *'Существующие настройки сохранены без изменений'* && ! -e $BBR_CONFIG ]] || fail 'Работающий внешний BBR не распознан.'
MOCK_BAD_SCAN=1
external_bad_scan=$(bbr_enable) || fail 'Сбой внешней диагностики изменил результат для работающего BBR.'
[[ $external_bad_scan == *'BBR уже активен: bbr / fq'* && ! -e $BBR_CONFIG ]] || fail 'Работающий BBR ошибочно зависит от разбора чужой конфигурации.'
printf '%s\n' fq_codel > "$fixture/current-qdisc"
partial_output=$(bbr_enable) || fail 'Неполное внешнее состояние BBR вызвало непредвиденную ошибку.'
[[ $partial_output == *'BBR активен, но текущий qdisc — fq_codel'* && ! -e $BBR_CONFIG ]] || fail 'BBR с qdisc, отличным от fq, ошибочно принят как управляемый.'
MOCK_BAD_SCAN=0
[[ $(< "$fixture/etc/sysctl.d/99-remnawave-bbr.conf") == *'net.ipv4.tcp_congestion_control = bbr'* ]] || fail 'Внешний BBR-файл изменён.'
rm -f -- "$fixture/etc/sysctl.d/99-remnawave-bbr.conf"
printf '%s\n' cubic > "$fixture/current-cc"
printf 'OK: внешний bbr/fq сохранён при штатной и ошибочной диагностике; bbr/fq_codel не присваивается toolkit.\n'

printf '%s\n' 'net.core.default_qdisc = fq_codel' > "$fixture/etc/sysctl.d/99-z.conf"
late_enable=$(bbr_enable) || fail 'Поздний конфликт вызвал непредвиденную ошибку.'
[[ $late_enable == *'Включение BBR отменено'* && ! -e $BBR_CONFIG ]] || fail 'Поздний sysctl-файл не отменил включение BBR.'
rm -f -- "$fixture/etc/sysctl.d/99-z.conf"

printf '%s\n' 'net.ipv4.tcp_congestion_control = cubic' > "$fixture/etc/sysctl.conf"
global_enable=$(bbr_enable) || fail 'Конфликт /etc/sysctl.conf вызвал непредвиденную ошибку.'
[[ $global_enable == *'Включение BBR отменено'* && ! -e $BBR_CONFIG ]] || fail '/etc/sysctl.conf не отменил включение BBR.'
rm -f -- "$fixture/etc/sysctl.conf"

dry_output=$(bbr_enable) || fail 'BBR dry-run завершился ошибкой.'
[[ $dry_output == *'Текущий алгоритм TCP: cubic; текущий qdisc: fq_codel'* \
    && $dry_output == *'алгоритм TCP bbr; очередь по умолчанию fq'* \
    && $dry_output == *'Исходные файлы изменяться не будут'* && $dry_output == *'План:'* ]] || fail 'Dry-run не показал полный план переопределения.'
[[ ! -e $BBR_CONFIG && $(< "$earlier") == '-net.core.default_qdisc = fq_codel' ]] || fail 'Dry-run изменил sysctl-файлы.'
printf 'OK: BBR dry-run показывает cubic/fq_codel → bbr/fq без изменений.\n'

sysctl() {
    [[ ${1:-} == -w ]] || fail 'Тест вызвал неожиданный sysctl.'
    case ${2:-} in
        net.core.default_qdisc=*) printf '%s\n' "${2#*=}" > "$fixture/current-qdisc";;
        net.ipv4.tcp_congestion_control=*)
            if [[ ${2#*=} == bbr && -f $fixture/fail-once ]]; then rm -f -- "$fixture/fail-once"; return 1; fi
            printf '%s\n' "${2#*=}" > "$fixture/current-cc";;
        *) fail 'Тест вызвал неожиданный ключ sysctl.';;
    esac
}

DRY_RUN=0
enable_output=$(bbr_enable) || fail 'Mock-включение BBR завершилось ошибкой.'
[[ $(< "$fixture/current-cc") == bbr && $(< "$fixture/current-qdisc") == fq ]] || fail 'Mock-включение не применило bbr/fq.'
[[ $(< "$BBR_CONFIG") == *'# previous_cc=cubic'* && $(< "$BBR_CONFIG") == *'# previous_qdisc=fq_codel'* ]] || fail 'Предыдущие cubic/fq_codel не сохранены.'
[[ $(< "$earlier") == '-net.core.default_qdisc = fq_codel' ]] || fail 'Чужой файл был изменён при включении.'
[[ $enable_output == *'BBR включён и проверен'* ]] || fail 'Успех BBR не показан.'
printf 'OK: mock-enable сохранил previous_cc=cubic и previous_qdisc=fq_codel.\n'

rm -f -- "$BBR_CONFIG"
printf '%s\n' cubic > "$fixture/current-cc"
printf '%s\n' fq_codel > "$fixture/current-qdisc"
: > "$fixture/fail-once"
if bbr_enable >/dev/null 2>&1; then fail 'Ошибка применения BBR не вызвала откат.'; fi
[[ ! -e $BBR_CONFIG && $(< "$fixture/current-cc") == cubic && $(< "$fixture/current-qdisc") == fq_codel ]] || fail 'Откат не восстановил cubic/fq_codel.'
[[ $(< "$earlier") == '-net.core.default_qdisc = fq_codel' ]] || fail 'Откат изменил чужой файл.'
printf 'OK: после ошибки rollback восстановил cubic/fq_codel и сохранил чужой файл.\n'

bbr_sysctl_files() { printf '%s\n' "$fixture/etc/sysctl.d/missing.conf"; }
if missing_report=$(bbr_sysctl_conflicts); then fail 'Недоступный sysctl config не заблокировал BBR.'; fi
[[ $missing_report == *'Недоступен или необычен источник sysctl'* ]] || fail 'Недоступный sysctl config не объяснён.'
printf 'OK: поздние, неоднозначные и недоступные sysctl-конфиги блокируются.\n'
