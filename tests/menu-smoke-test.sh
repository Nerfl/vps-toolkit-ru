#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install.sh"
fail() { printf 'ОШИБКА: %s\n' "$1" >&2; exit 1; }

toolkit_is_root() { return 0; }
check_platform() { return 0; }
os_field() { printf 'Ubuntu 24.04 LTS\n'; }
first_public_ip() { printf 'Недоступно\n'; }
uptime_ru() { printf 'Тестовый запуск\n'; }
fail2ban_status() { printf 'Тестовый статус Fail2Ban\n'; }
fail2ban_policy_detect() { printf 'normal\n'; }
bbr_status() { printf 'Тестовый статус BBR\n'; }

main_exit=$(printf '0\n' | main --dry-run) || fail '0 не завершил главное меню.'
[[ $main_exit == *'0. Выход'* && $main_exit == *'Работа завершена'* && $main_exit != *'7. Выход'* ]] || fail 'Главное меню не использует 0 для выхода.'

f2b_back=$(printf '3\n0\n0\n' | main --dry-run) || fail '0 не вернул из Fail2Ban в главное меню.'
[[ $f2b_back == *'0. Назад'* && $(grep -c 'VPS TOOLKIT RU' <<< "$f2b_back") == 2 ]] || fail 'Возврат из Fail2Ban в главное меню не подтверждён.'

policy_back=$(printf '3\n7\n0\n0\n0\n' | main --dry-run) || fail '0 не вернул из меню политики в Fail2Ban.'
[[ $policy_back == *'ПОЛИТИКА БЛОКИРОВОК'* && $(grep -c 'FAIL2BAN / ЗАЩИТА SSH' <<< "$policy_back") == 2 ]] || fail 'Возврат из политики в Fail2Ban не подтверждён.'

bbr_back=$(printf '4\n0\n0\n' | main --dry-run) || fail '0 не вернул из BBR в главное меню.'
[[ $bbr_back == *'0. Назад'* && $(grep -c 'VPS TOOLKIT RU' <<< "$bbr_back") == 2 ]] || fail 'Возврат из BBR в главное меню не подтверждён.'

update_back=$(printf '2\n0\n0\n' | main --dry-run) || fail '0 не вернул из обновления в главное меню.'
[[ $update_back == *'0. Назад'* && $(grep -c 'VPS TOOLKIT RU' <<< "$update_back") == 2 ]] || fail 'Возврат из обновления в главное меню не подтверждён.'

old_main=$(printf '7\n0\n' | main --dry-run) || fail 'Старый номер выхода вызвал ошибку.'
[[ $old_main == *'Неизвестный пункт меню'* && $(grep -c 'VPS TOOLKIT RU' <<< "$old_main") == 2 ]] || fail 'Старый номер 7 всё ещё завершает главное меню.'

old_f2b=$(printf '3\n8\n0\n0\n' | main --dry-run) || fail 'Старый номер возврата Fail2Ban вызвал ошибку.'
[[ $old_f2b == *'Неизвестный пункт меню'* && $(grep -c 'FAIL2BAN / ЗАЩИТА SSH' <<< "$old_f2b") == 2 ]] || fail 'Старый номер 8 всё ещё возвращает из Fail2Ban.'

old_bbr=$(printf '4\n5\n0\n0\n' | main --dry-run) || fail 'Старый номер возврата BBR вызвал ошибку.'
[[ $old_bbr == *'Неизвестный пункт меню'* && $(grep -c '════════ BBR' <<< "$old_bbr") == 2 ]] || fail 'Старый номер 5 всё ещё возвращает из BBR.'

old_update=$(printf '2\n4\n0\n0\n' | main --dry-run) || fail 'Старый номер возврата обновления вызвал ошибку.'
[[ $old_update == *'Неизвестный пункт меню'* && $(grep -c 'ОБНОВЛЕНИЕ СИСТЕМЫ' <<< "$old_update") == 2 ]] || fail 'Старый номер 4 всё ещё возвращает из обновления.'

printf 'OK: 0 завершает главное меню и возвращает из Fail2Ban, политики, BBR и обновления; старые номера не возвращают.\n'
