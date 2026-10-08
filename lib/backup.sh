#!/usr/bin/env bash

backup_error() {
    say_error "$1"
    log_action ERROR "$1" || true
    return 1
}

backup_directory_safe() {
    local path=$1 private=${2:-0} metadata owner mode
    [[ -d $path && ! -L $path ]] || return 1
    metadata=$(stat -c '%u %a' -- "$path" 2>/dev/null) || return 1
    read -r owner mode <<< "$metadata"
    [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
    if (( private )); then (( (8#$mode & 0077) == 0 ))
    else (( (8#$mode & 0022) == 0 )); fi
}

backup_file() {
    local source=$1 target suffix index=1 source_meta target_meta session session_name
    [[ -e $source ]] || return 0
    if (( DRY_RUN )); then say_info "План: резервная копия $source"; return 0; fi
    if [[ ! -e $TOOL_BACKUPS && ! -L $TOOL_BACKUPS ]]; then
        mkdir -m 0700 -- "$TOOL_BACKUPS" 2>/dev/null || { backup_error 'Не удалось создать каталог резервных копий.'; return 1; }
    fi
    backup_directory_safe "$TOOL_BACKUPS" || {
        backup_error 'Каталог резервных копий имеет небезопасного владельца, права или тип.'; return 1;
    }
    if [[ -z ${BACKUP_SESSION:-} ]]; then
        session="$TOOL_BACKUPS/$(date +%Y%m%d-%H%M%S)"
        if [[ ! -e $session && ! -L $session ]]; then
            mkdir -m 0700 -- "$session" 2>/dev/null || { backup_error 'Не удалось создать каталог резервной копии.'; return 1; }
        fi
        backup_directory_safe "$session" 1 || { backup_error 'Каталог сеанса backup имеет небезопасного владельца, права или тип.'; return 1; }
        BACKUP_SESSION=$session
    fi
    session_name=${BACKUP_SESSION##*/}
    if [[ $BACKUP_SESSION != "$TOOL_BACKUPS/$session_name" || ! $session_name =~ ^[0-9]{8}-[0-9]{6}$ ]] \
        || ! backup_directory_safe "$BACKUP_SESSION" 1; then
        backup_error 'Каталог сеанса backup имеет небезопасный путь, владельца или права.'; return 1
    fi
    target="$BACKUP_SESSION/${source#/}"
    if [[ -e $target ]]; then
        source_meta=$(stat -c '%a:%u:%g' -- "$source" 2>/dev/null) || source_meta=''
        target_meta=$(stat -c '%a:%u:%g' -- "$target" 2>/dev/null) || target_meta=''
        if [[ -n $source_meta && $source_meta == "$target_meta" ]] && cmp -s -- "$source" "$target"; then
            BACKUP_LAST=$target; return 0
        fi
        suffix="$target.$(date +%H%M%S)-$$"
        target=$suffix
        while [[ -e $target ]]; do target="$suffix.$index"; ((index+=1)); done
    fi
    mkdir -p -m 0700 -- "${target%/*}" 2>/dev/null || { backup_error 'Не удалось подготовить путь резервной копии.'; return 1; }
    cp -a -- "$source" "$target" 2>/dev/null || { backup_error 'Не удалось сохранить резервную копию.'; return 1; }
    BACKUP_LAST=$target
    say_info "Создана резервная копия: $target"
    log_action INFO "Создана резервная копия: $target" || return 1
}
