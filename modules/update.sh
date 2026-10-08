#!/usr/bin/env bash

updates_available() {
    local count output
    if (( DRY_RUN )); then
        say_info 'Режим просмотра: apt не запускается. Для проверки обновлений выйдите из режима просмотра.'
        return 0
    fi
    if ! has_cmd apt-get; then say_error 'Команда apt-get недоступна.'; return 1; fi
    say_info 'Проверка выполняется по локальным спискам пакетов. Для свежих данных сначала выполните apt update.'
    if ! output=$(apt list --upgradable 2>/dev/null); then
        say_error 'Не удалось прочитать список доступных обновлений.'
        return 1
    fi
    count=$(sed '1d' <<< "$output" | awk 'NF {count++} END {print count+0}')
    printf 'Доступно обновлений пакетов: %s\n' "$count"
}

apt_refresh() {
    if ! confirm_yes_no 'Будет выполнено apt-get update. Продолжить?'; then say_info 'Действие отменено.'; return; fi
    require_commands apt-get || return 1
    run_step 'Обновление списков пакетов: apt-get update' apt_run update || return $?
    if (( ! DRY_RUN )); then log_action INFO 'Обновлены списки пакетов apt' || return 1; say_ok 'Списки пакетов обновлены.'; fi
}

apt_preview_upgrade() {
    local output result packages count
    if output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>&1); then :
    else
        result=$?
        say_error 'Не удалось подготовить план обновления пакетов. apt-get upgrade отменён.'
        apt_show_failure "$result" "$output"
        return "$result"
    fi
    packages=$(awk '$1 == "Inst" {print $2}' <<< "$output")
    count=$(awk 'NF {count++} END {print count+0}' <<< "$packages")
    APT_PREVIEW_COUNT=$count
    printf 'Запланировано к обновлению пакетов: %s\n' "$count"
    if (( count > 0 )); then
        printf 'Пакеты:\n%s\n' "$packages"
    fi
    return 0
}

apt_upgrade_safe() {
    printf '\nБудет выполнено: apt-get update, затем apt-get upgrade.\n'
    printf 'Автоматическое удаление пакетов и перезагрузка не выполняются.\n'
    say_warn 'Не прерывайте apt во время изменения пакетов; при прерывании проверьте состояние dpkg вручную.'
    if ! confirm_yes_no 'Продолжить обновление системы?'; then say_info 'Действие отменено.'; return; fi
    require_commands apt-get || return 1
    if (( DRY_RUN )); then
        say_info 'План: выполнить apt-get update; после него показать расчёт обновления и запросить отдельное подтверждение apt-get upgrade.'
        say_info 'В режиме просмотра apt и симуляция apt не запускаются.'
        return 0
    fi
    run_step 'Обновление списков пакетов: apt-get update' apt_run update || return $?
    apt_preview_upgrade || return $?
    if (( APT_PREVIEW_COUNT == 0 )); then say_info 'Обновлять нечего; apt-get upgrade не запускается.'; return 0; fi
    say_warn 'При обновлении пакетов службы могут быть перезапущены, включая службы, влияющие на удалённое подключение.'
    if ! confirm_yes_no 'Сейчас выполнить apt-get upgrade для перечисленных пакетов?'; then say_info 'Обновление пакетов отменено.'; return 0; fi
    run_step 'Обновление пакетов: apt-get upgrade' apt_run upgrade || return $?
    log_action INFO 'Выполнены apt-get update и apt-get upgrade' || return 1
    say_ok 'Обновление завершено.'
    if [[ -e /var/run/reboot-required ]]; then
        say_warn 'Для применения обновлений требуется перезагрузка сервера.'
        if confirm_yes_no 'Перезагрузить сервер сейчас?'; then
            if confirm_yes_no 'Подтвердите перезагрузку удалённого сервера?'; then
                log_action WARN 'Пользователь подтвердил перезагрузку сервера' || return 1
                if ! systemctl reboot >/dev/null 2>&1; then
                    say_error 'Не удалось запустить перезагрузку.'
                    log_action ERROR 'Не удалось запустить перезагрузку' || true
                    return 1
                fi
            fi
        fi
    fi
}

update_menu() {
    local choice
    while true; do
        printf '\n════════ ОБНОВЛЕНИЕ СИСТЕМЫ ════════\n1. Проверить наличие обновлений\n2. apt update\n3. apt update && apt upgrade\n4. Назад\nВыберите пункт: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) updates_available; pause_menu;;
            2) apt_refresh; pause_menu;;
            3) apt_upgrade_safe; pause_menu;;
            4) return;;
            *) say_warn 'Неизвестный пункт меню.';;
        esac
    done
}
