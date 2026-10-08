#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install.sh"
fail() { printf 'ОШИБКА: %s\n' "$1" >&2; exit 1; }

fixture=$(mktemp -d) || fail 'Не удалось создать временный каталог.'
trap 'rm -f -- "$fixture"/*; rmdir -- "$fixture" 2>/dev/null || true' EXIT
F2B_CONFIG=$fixture/jail.local
F2B_GLOBAL_CONFIG=$fixture/global.local
foreign=$fixture/foreign.local

apt-get() { fail 'Тест политики вызвал реальный apt-get.'; }
dpkg() { fail 'Тест политики вызвал реальный dpkg.'; }
dpkg-query() { fail 'Тест политики вызвал реальный dpkg-query.'; }
package_installed() { return 0; }
fail2ban_ssh_port_safe() { say_info 'Тестовый порт SSH 22 подтверждён.'; }
fail2ban_existing_custom() { [[ ${MOCK_FOREIGN_JAIL:-0} == 1 ]]; }
fail2ban_foreign_db_files() { [[ ! -f $foreign ]] || printf '%s\n' "$foreign"; }
confirm_yes_no() { return 0; }
prepare_mutation() { return 0; }
log_action() { return 0; }
journalctl() { printf 'Тестовое событие Fail2Ban\n'; }
service_active() { [[ ${1:-} == fail2ban && ${MOCK_ACTIVE:-1} == 1 ]]; }
sleep() { printf '%s\n' "$(( $(< "$fixture/sleeps") + 1 ))" > "$fixture/sleeps"; }
backup_file() {
    local number
    number=$(< "$fixture/backups")
    number=$((number + 1))
    printf '%s\n' "$number" > "$fixture/backups"
    BACKUP_LAST=$fixture/backup.$number
    cp -a -- "$1" "$BACKUP_LAST"
}
systemctl() {
    local number
    [[ ${2:-} == fail2ban ]] || fail 'Неожиданный сервис в тесте политики.'
    number=$(< "$fixture/restarts")
    case ${1:-} in
        restart) printf '%s\n' "$((number + 1))" > "$fixture/restarts";;
        is-active)
            if [[ ${MOCK_FAILURE:-} == start && $number == 1 ]]; then printf 'failed\n'; return 3; fi
            printf 'active\n';;
        stop) MOCK_ACTIVE=0;;
        *) fail 'Неожиданный вызов systemctl в тесте политики.';;
    esac
}
fail2ban-client() {
    local value
    case ${1:-} in
        -t) [[ ${MOCK_FAILURE:-} != config ]];;
        -d) fail 'Дамп конфигурации не должен подтверждать runtime-политику.';;
        ping) printf 'Server replied: pong\n';;
        status) [[ ${2:-} == sshd ]] || fail 'Неожиданный jail в тесте политики.'
            [[ ${MOCK_JAIL_ACTIVE:-1} == 1 ]];;
        get)
            if [[ ${2:-} == dbpurgeage ]]; then
                if [[ -n ${MOCK_DBPURGE_OUTPUT:-} ]]; then printf '%s\n' "$MOCK_DBPURGE_OUTPUT"; return; fi
                if [[ -f $F2B_GLOBAL_CONFIG ]]; then value=$(sed -n 's/^dbpurgeage = //p' "$F2B_GLOBAL_CONFIG")
                elif [[ -f $foreign ]]; then value=$(sed -n 's/^dbpurgeage = //p' "$foreign")
                else value=86400; fi
                value=$(fail2ban_duration_seconds "$value") || return 1
                printf 'Current database purge age is:\n`- %sseconds\n' "$value"
            elif [[ ${2:-} == dbfile ]]; then
                if [[ -n ${MOCK_DBFILE_OUTPUT:-} ]]; then printf '%s\n' "$MOCK_DBFILE_OUTPUT"
                elif [[ ${MOCK_DBFILE_NONE:-0} == 1 ]]; then printf 'Database currently disabled\n'
                else printf 'Current database file is:\n`- /var/lib/fail2ban/fail2ban.sqlite3\n'; fi
            else
                [[ ${2:-} == sshd ]] || fail 'Неожиданный запрос к Fail2Ban.'
                case ${3:-} in maxretry) printf '%s\n' "${MOCK_RUNTIME_RETRY:-5}";; findtime) printf '600\n';; bantime) printf '3600\n';;
                    bantime.increment)
                        if [[ -n ${MOCK_RUNTIME_INCREMENT:-} ]]; then printf '%s\n' "$MOCK_RUNTIME_INCREMENT"
                        elif grep -Eq '^bantime.increment = true$' "$F2B_CONFIG"; then printf 'True\n'
                        elif grep -Eq '^bantime.increment = false$' "$F2B_CONFIG"; then printf 'False\n'
                        else printf 'None\n'; fi;;
                    bantime.factor)
                        value=$(sed -n 's/^bantime.factor = //p' "$F2B_CONFIG")
                        printf '%s\n' "${MOCK_RUNTIME_FACTOR:-${value:-None}}";;
                    bantime.maxtime)
                        [[ ${MOCK_UNSUPPORTED_GET:-0} != 1 ]] || return 1
                        value=$(sed -n 's/^bantime.maxtime = //p' "$F2B_CONFIG")
                        if [[ -n $value ]]; then value=$(fail2ban_duration_seconds "$value") || return 1
                        else value=None; fi
                        printf '%s\n' "${MOCK_RUNTIME_MAX:-$value}";;
                    *) fail 'Неожиданный параметр Fail2Ban.';; esac
            fi;;
        *) fail 'Неожиданный вызов fail2ban-client в тесте политики.';;
    esac
}

reset_counts() {
    printf '0\n' > "$fixture/restarts"
    printf '0\n' > "$fixture/sleeps"
    printf '0\n' > "$fixture/backups"
    MOCK_FAILURE='' MOCK_FOREIGN_JAIL=0 MOCK_DBFILE_NONE=0 MOCK_ACTIVE=1 MOCK_JAIL_ACTIVE=1 DRY_RUN=0
    MOCK_DBPURGE_OUTPUT='' MOCK_DBFILE_OUTPUT='' MOCK_RUNTIME_INCREMENT='' MOCK_RUNTIME_FACTOR='' MOCK_RUNTIME_MAX='' MOCK_RUNTIME_RETRY=''
    MOCK_UNSUPPORTED_GET=0
}
set_policy() {
    rm -f -- "$F2B_CONFIG" "$F2B_GLOBAL_CONFIG" "$foreign"
    fail2ban_policy_jail_config "$1" > "$F2B_CONFIG"
    [[ $1 == normal ]] || fail2ban_policy_global_config "$1" > "$F2B_GLOBAL_CONFIG"
    reset_counts
}
set_pre_policy() {
    rm -f -- "$F2B_CONFIG" "$F2B_GLOBAL_CONFIG" "$foreign"
    fail2ban_pre_policy_config > "$F2B_CONFIG"
    reset_counts
}

set_policy normal
[[ $(fail2ban-client get sshd bantime.increment) == False \
    && $(fail2ban-client get sshd bantime.factor) == None \
    && $(fail2ban-client get sshd bantime.maxtime) == None ]] || fail 'Mock обычной политики не имитирует unset bantime-параметры.'
[[ $(fail2ban_policy_detect) == normal ]] || fail 'Обычная политика не определена.'
[[ $(fail2ban_policy_status) == *'Максимальный бан: 1 час'* ]] || fail 'Состояние обычной политики неверно.'
[[ $(fail2ban_policy_jail_config normal) == *'bantime.increment = false'* ]] || fail 'Обычная политика не отключает увеличение.'
printf 'OK: Normal при increment=False, factor=None, maxtime=None.\n'
MOCK_DBFILE_NONE=1
[[ $(fail2ban_policy_detect) == normal ]] || fail 'Обычная политика ошибочно отвергнута при отключённой базе.'
[[ $(fail2ban_policy_status) == *'История банов: база отключена'* ]] || fail 'Отключённая база не показана в состоянии обычной политики.'
printf 'OK: Normal при Database currently disabled.\n'
MOCK_DBFILE_NONE=0
MOCK_DBPURGE_OUTPUT=$'Current database purge age is:\n`- неизвестно'
[[ $(fail2ban_policy_detect) == normal ]] || fail 'Обычная политика ошибочно зависит от dbpurgeage.'
[[ $(fail2ban_policy_status) == *'История банов: не подтверждена'* ]] || fail 'Недоступная история базы неверно показана.'
MOCK_DBPURGE_OUTPUT=''

set_pre_policy
[[ $(fail2ban-client get sshd bantime.increment) == None ]] || fail 'Mock прежнего файла не возвращает increment=None.'
fail2ban_config_managed || fail 'Точный pre-policy файл toolkit не признан управляемым.'
[[ $(fail2ban_policy_detect) == normal && $(fail2ban_policy_status) == *'Политика: Обычная'* ]] || fail 'Точный pre-policy файл с increment=None не определён как Normal.'
printf 'OK: точный pre-policy файл с increment=None определяется как Normal.\n'
MOCK_DBFILE_NONE=1
[[ $(fail2ban_policy_detect) == normal ]] || fail 'Pre-policy Normal ошибочно зависит от включённой базы.'
MOCK_DBFILE_NONE=0

cp -a -- "$F2B_CONFIG" "$fixture/old-pre-policy"
DRY_RUN=1
pre_dry_output=$(fail2ban_policy_select adaptive) || fail 'Просмотр миграции pre-policy → Adaptive завершился ошибкой.'
[[ $pre_dry_output == *'Текущая политика: Обычная'* && $pre_dry_output == *'прежняя обычная политика → Адаптивная'* \
    && $pre_dry_output == *"$F2B_CONFIG"* && $pre_dry_output == *"$F2B_GLOBAL_CONFIG"* \
    && $pre_dry_output == *'Режим просмотра: файлы, база и сервис не изменены.'* ]] || fail 'План миграции pre-policy показан неполно.'
cmp -s "$F2B_CONFIG" "$fixture/old-pre-policy" || fail 'Dry-run изменил pre-policy файл.'
[[ ! -e $F2B_GLOBAL_CONFIG && $(< "$fixture/restarts") == 0 && $(< "$fixture/backups") == 0 ]] || fail 'Dry-run изменил состояние при миграции pre-policy.'
printf 'OK: pre-policy → Adaptive dry-run без изменений.\n'
DRY_RUN=0

fail2ban_policy_select adaptive >/dev/null || fail 'Миграция pre-policy → Adaptive не удалась.'
[[ $(fail2ban_policy_detect) == adaptive && $(< "$fixture/restarts") == 1 && $(< "$fixture/backups") == 1 ]] || fail 'Adaptive после миграции не подтверждена.'
cmp -s "$fixture/backup.1" "$fixture/old-pre-policy" || fail 'Резервная копия pre-policy файла не совпадает с оригиналом.'
diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config adaptive) >/dev/null || fail 'Adaptive jail после миграции неверен.'
diff -q "$F2B_GLOBAL_CONFIG" <(fail2ban_policy_global_config adaptive) >/dev/null || fail 'Global dbpurgeage после миграции неверен.'

set_pre_policy
cp -a -- "$F2B_CONFIG" "$fixture/old-pre-policy"
MOCK_FAILURE=config
if fail2ban_policy_select adaptive >/dev/null 2>&1; then fail 'Ошибка после записи Adaptive не вызвала откат.'; fi
cmp -s "$F2B_CONFIG" "$fixture/old-pre-policy" || fail 'Откат не восстановил точно старый pre-policy файл.'
[[ ! -e $F2B_GLOBAL_CONFIG && $(< "$fixture/restarts") == 1 ]] || fail 'Откат не восстановил прежнее состояние Fail2Ban.'
MOCK_FAILURE=''
[[ $(fail2ban_policy_detect) == normal ]] || fail 'После отката pre-policy не определяется как Normal.'
printf 'OK: pre-policy → Adaptive с ошибкой и точным откатом.\n'

set_pre_policy
cp -a -- "$F2B_CONFIG" "$fixture/old-pre-policy"
fail2ban_policy_select normal >/dev/null || fail 'Миграция pre-policy → Normal не удалась.'
diff -q "$F2B_CONFIG" <(fail2ban_policy_jail_config normal) >/dev/null || fail 'В Normal не добавлен bantime.increment=false.'
cmp -s "$fixture/backup.1" "$fixture/old-pre-policy" || fail 'При миграции в Normal отсутствует точная копия старого файла.'
[[ $(fail2ban_policy_detect) == normal ]] || fail 'Normal после миграции не подтверждён.'

set_pre_policy
printf 'maxretry = 4\n' >> "$F2B_CONFIG"
if fail2ban_config_managed; then fail 'Pre-policy файл с лишней строкой принят как управляемый.'; fi
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Pre-policy файл с лишней строкой ошибочно определён как Normal.'
foreign_output=$(fail2ban_policy_select adaptive) || fail 'Чужой файл вызвал непредвиденную ошибку.'
[[ $foreign_output == *'автоматическое изменение отменено'* && $(< "$fixture/restarts") == 0 ]] || fail 'Изменённый pre-policy файл не заблокировал миграцию.'

set_pre_policy
sed -i 's/^port = 22$/port = 2222/' "$F2B_CONFIG"
if fail2ban_config_managed; then fail 'Pre-policy файл с другим портом принят как управляемый.'; fi
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Pre-policy файл с другим портом ошибочно определён как Normal.'

set_pre_policy
sed -i 's/^maxretry = 5$/maxretry = 4/' "$F2B_CONFIG"
if fail2ban_config_managed; then fail 'Pre-policy файл с другим maxretry принят как управляемый.'; fi
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Pre-policy файл с другим maxretry ошибочно определён как Normal.'

set_pre_policy
sed -i '1d' "$F2B_CONFIG"
if fail2ban_config_managed; then fail 'Pre-policy файл без заголовка принят как управляемый.'; fi
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Pre-policy файл без заголовка ошибочно определён как Normal.'

set_pre_policy
fail2ban_previous_config > "$F2B_CONFIG"
[[ $(fail2ban_policy_detect) == custom ]] || fail 'increment=None с другим прежним форматом ошибочно определён как Normal.'
printf 'OK: неизвестный файл с increment=None остаётся Custom.\n'

set_pre_policy
MOCK_RUNTIME_RETRY=4
[[ $(fail2ban_policy_detect) == custom ]] || fail 'increment=None с другим runtime maxretry ошибочно определён как Normal.'

set_pre_policy
MOCK_FOREIGN_JAIL=1
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Чужая jail-конфигурация не остановила legacy Normal.'
foreign_output=$(fail2ban_policy_select adaptive) || fail 'Чужая jail-конфигурация вызвала непредвиденную ошибку.'
[[ $foreign_output == *'автоматическое изменение отменено'* && $(< "$fixture/restarts") == 0 ]] || fail 'Чужая jail-конфигурация не запретила миграцию.'

set_pre_policy
MOCK_JAIL_ACTIVE=0
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Неактивный jail ошибочно подтвердил legacy Normal.'

set_policy adaptive
[[ $(fail2ban_policy_detect) == adaptive ]] || fail 'Адаптивная политика не определена.'
[[ $(fail2ban_policy_status) == *'История банов: 30 суток'* && $(fail2ban_policy_status) == *'Первичный бан: 1 час'* ]] || fail 'Состояние адаптивной политики показано неверно.'
[[ $(fail2ban_policy_jail_config adaptive) == *'bantime.factor = 1'* && $(fail2ban_policy_jail_config adaptive) == *'bantime.maxtime = 7d'* ]] || fail 'Параметры адаптивной политики неверны.'
[[ $(fail2ban_policy_global_config adaptive) == *'dbpurgeage = 30d'* ]] || fail 'История адаптивной политики неверна.'
MOCK_RUNTIME_MAX=604800.0
[[ $(fail2ban_policy_detect) == adaptive ]] || fail 'Числовое представление runtime bantime.maxtime не распознано.'
MOCK_RUNTIME_MAX=''
MOCK_DBFILE_NONE=1
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Адаптивная политика без базы ошибочно подтверждена.'
MOCK_DBFILE_NONE=0
MOCK_RUNTIME_FACTOR=None
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Адаптивная политика с factor=None ошибочно подтверждена.'
MOCK_RUNTIME_FACTOR=''
MOCK_RUNTIME_MAX=None
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Адаптивная политика с maxtime=None ошибочно подтверждена.'
MOCK_RUNTIME_MAX=''
MOCK_DBPURGE_OUTPUT=$'Current database purge age is:\n`- неверно 2592000seconds'
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Некорректный runtime dbpurgeage ошибочно принят.'
MOCK_DBPURGE_OUTPUT=''
MOCK_DBFILE_OUTPUT='Неожиданный путь /var/lib/fail2ban/fail2ban.sqlite3'
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Произвольный текст ошибочно принят за dbfile.'
MOCK_DBFILE_OUTPUT=''
MOCK_RUNTIME_MAX='604800 seconds'
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Некорректный runtime bantime.maxtime ошибочно принят.'
MOCK_RUNTIME_MAX=''
MOCK_UNSUPPORTED_GET=1
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Недоступный runtime bantime.maxtime ошибочно принят.'
MOCK_UNSUPPORTED_GET=0
MOCK_RUNTIME_FACTOR=2
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Отличающийся runtime bantime.factor ошибочно принят.'
MOCK_RUNTIME_FACTOR=''
MOCK_RUNTIME_INCREMENT=False
[[ $(fail2ban_policy_detect) == custom ]] || fail 'Файл политики ошибочно признан доказательством вместо runtime.'
MOCK_RUNTIME_INCREMENT=''

set_policy strict
[[ $(fail2ban_policy_detect) == strict ]] || fail 'Строгая политика не определена.'
[[ $(fail2ban_policy_jail_config strict) == *'bantime.maxtime = 30d'* && $(fail2ban_policy_global_config strict) == *'dbpurgeage = 90d'* ]] || fail 'Параметры строгой политики неверны.'

set_policy normal
fail2ban_policy_select adaptive >/dev/null || fail 'Переход Обычная → Адаптивная не удался.'
[[ $(fail2ban_policy_detect) == adaptive && $(< "$fixture/restarts") == 1 ]] || fail 'Адаптивная политика не применена.'
reset_counts
fail2ban_policy_select normal >/dev/null || fail 'Переход Адаптивная → Обычная не удался.'
[[ $(fail2ban_policy_detect) == normal && ! -e $F2B_GLOBAL_CONFIG ]] || fail 'Управляемый dbpurgeage не удалён.'
fail2ban_policy_select adaptive >/dev/null || fail 'Повторный переход к адаптивной политике не удался.'
reset_counts
fail2ban_policy_select strict >/dev/null || fail 'Переход Адаптивная → Строгая не удался.'
[[ $(fail2ban_policy_detect) == strict && $(< "$fixture/restarts") == 1 ]] || fail 'Строгая политика не применена.'

set_policy normal
printf '[Definition]\ndbpurgeage = 90d\n' > "$foreign"
fail2ban_policy_select adaptive >/dev/null || fail 'Достаточное чужое значение dbpurgeage отвергнуто.'
[[ $(fail2ban_policy_detect) == adaptive && ! -e $F2B_GLOBAL_CONFIG && $(< "$foreign") == *'90d'* ]] || fail 'Чужой dbpurgeage не сохранён.'

set_policy adaptive
printf '[Definition]\ndbpurgeage = 90d\n' > "$foreign"
fail2ban_policy_select strict >/dev/null || fail 'Чужое достаточное значение не использовано при переходе к строгой политике.'
[[ $(fail2ban_policy_detect) == strict && ! -e $F2B_GLOBAL_CONFIG && $(< "$foreign") == *'90d'* ]] || fail 'Управляемый файл не убран при достаточной чужой настройке.'

set_policy normal
printf '[Definition]\ndbpurgeage = 7d\n' > "$foreign"
low_output=$(fail2ban_policy_select adaptive) || fail 'Недостаточное чужое значение вызвало непредвиденную ошибку.'
[[ $low_output == *'меньше необходимого'* && $(fail2ban_policy_detect) == normal && $(< "$fixture/restarts") == 0 ]] || fail 'Недостаточный dbpurgeage не остановил изменение.'

set_policy normal
printf '[Definition]\ndbpurgeage = неизвестно\n' > "$foreign"
ambiguous_output=$(fail2ban_policy_select adaptive) || fail 'Неоднозначный dbpurgeage вызвал непредвиденную ошибку.'
[[ $ambiguous_output == *'Неоднозначное значение dbpurgeage'* && $(< "$fixture/restarts") == 0 ]] || fail 'Неоднозначный dbpurgeage не остановил изменение.'

set_policy normal
MOCK_FOREIGN_JAIL=1
foreign_output=$(fail2ban_policy_select adaptive) || fail 'Чужой jail вызвал непредвиденную ошибку.'
[[ $foreign_output == *'автоматическое изменение отменено'* && $(fail2ban_policy_detect) == normal && $(< "$fixture/restarts") == 0 ]] || fail 'Чужой jail был изменён.'

set_policy adaptive
cp -a -- "$F2B_CONFIG" "$fixture/old-jail"
cp -a -- "$F2B_GLOBAL_CONFIG" "$fixture/old-global"
MOCK_FAILURE=config
if fail2ban_policy_select strict >/dev/null 2>&1; then fail 'Ошибка проверки конфигурации принята за успех.'; fi
cmp -s "$F2B_CONFIG" "$fixture/old-jail" && cmp -s "$F2B_GLOBAL_CONFIG" "$fixture/old-global" || fail 'После ошибки -t не восстановлены оба файла.'
[[ $(< "$fixture/restarts") == 1 ]] || fail 'После ошибки -t прежний сервис не восстановлен.'

set_policy adaptive
cp -a -- "$F2B_CONFIG" "$fixture/old-jail"
cp -a -- "$F2B_GLOBAL_CONFIG" "$fixture/old-global"
MOCK_FAILURE=start
if fail2ban_policy_select strict >/dev/null 2>&1; then fail 'Ошибка запуска сервиса принята за успех.'; fi
cmp -s "$F2B_CONFIG" "$fixture/old-jail" && cmp -s "$F2B_GLOBAL_CONFIG" "$fixture/old-global" || fail 'После ошибки запуска не восстановлены оба файла.'
[[ $(< "$fixture/restarts") == 2 ]] || fail 'Откат не перезапустил прежний сервис.'

set_policy normal
DRY_RUN=1
dry_output=$(fail2ban_policy_select adaptive) || fail 'Режим просмотра завершился ошибкой.'
[[ $dry_output == *'План:'* && $(fail2ban_policy_detect) == normal && ! -e $F2B_GLOBAL_CONFIG && $(< "$fixture/restarts") == 0 && $(< "$fixture/backups") == 0 ]] || fail 'Режим просмотра изменил состояние.'

set_policy adaptive
repeat_output=$(fail2ban_policy_select adaptive) || fail 'Повторное применение политики завершилось ошибкой.'
[[ $repeat_output == *'уже действует'* && $(< "$fixture/restarts") == 0 && $(< "$fixture/backups") == 0 ]] || fail 'Повторное применение политики не идемпотентно.'

menu_output=$(printf '0\n' | fail2ban_policy_menu) || fail 'Подменю политики не завершилось.'
[[ $menu_output == *'2. Адаптивная [РЕКОМЕНДУЕТСЯ]'* && $menu_output == *'0. Назад'* ]] || fail 'Подменю политики неполное.'
main_menu_output=$(printf '8\n' | fail2ban_menu) || fail 'Меню Fail2Ban не вернулось назад.'
[[ $main_menu_output == *'7. Политика блокировок'* && $main_menu_output == *'8. Назад'* ]] || fail 'Пункты меню Fail2Ban не обновлены.'
printf 'OK: политики Fail2Ban, переходы, чужие настройки, откат, режим просмотра и идемпотентность проверены.\n'
