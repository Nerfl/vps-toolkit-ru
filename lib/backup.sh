#!/usr/bin/env bash

backup_error() {
    say_error "$1"
    log_action ERROR "$1" || true
    return 1
}

backup_file() {
    local source=$1 target suffix index=1 source_meta target_meta session
    [[ -e $source ]] || return 0
    if (( DRY_RUN )); then say_info "План: резервная копия $source"; return 0; fi
    if [[ -L $TOOL_BACKUPS ]]; then backup_error 'Каталог резервных копий не должен быть ссылкой.'; return 1; fi
    if [[ -z ${BACKUP_SESSION:-} ]]; then
        session="$TOOL_BACKUPS/$(date +%Y%m%d-%H%M%S)"
        if [[ -L $session ]]; then backup_error 'Каталог текущей резервной копии не должен быть ссылкой.'; return 1; fi
        mkdir -p -m 0700 -- "$session" 2>/dev/null || { backup_error 'Не удалось создать каталог резервной копии.'; return 1; }
        chmod 0700 -- "$session" 2>/dev/null || { backup_error 'Не удалось ограничить доступ к резервной копии.'; return 1; }
        BACKUP_SESSION=$session
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
