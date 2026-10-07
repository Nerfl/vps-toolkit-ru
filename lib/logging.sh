#!/usr/bin/env bash

init_log() {
    (( DRY_RUN )) && return 0
    [[ ! -L $TOOL_LOG ]] || return 1
    if [[ ! -e $TOOL_LOG ]]; then
        install -m 0600 /dev/null "$TOOL_LOG" 2>/dev/null || return 1
    fi
    [[ -f $TOOL_LOG && -w $TOOL_LOG ]] || return 1
    chmod 0600 "$TOOL_LOG" 2>/dev/null || return 1
}

prepare_mutation() {
    (( DRY_RUN )) && return 0
    [[ ${ACTION_LOG_READY:-0} == 1 ]] && return 0
    if ! init_log; then say_error 'Не удалось подготовить журнал действий; изменение отменено.'; return 1; fi
    if ! log_action INFO "Запущен VPS Toolkit RU v${TOOL_VERSION:-0.1.0}"; then
        say_error 'Не удалось записать начало операции в журнал; изменение отменено.'
        return 1
    fi
    ACTION_LOG_READY=1
}

log_action() {
    local level=$1 message=$2
    (( DRY_RUN )) && return 0
    printf '%(%Y-%m-%d %H:%M:%S)T [%s] %s\n' -1 "$level" "$message" >> "$TOOL_LOG"
}
