#!/usr/bin/env bash

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
    C_RESET=$'\033[0m'
else
    C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_RESET=''
fi

say_ok()       { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
say_warn()     { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
say_error()    { printf '%s[ОШИБКА]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
say_critical() { printf '%s[CRITICAL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
say_info()     { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
