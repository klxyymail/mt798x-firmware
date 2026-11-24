#!/usr/bin/env bash
# 公共环境变量与辅助函数。所有脚本通过 source 引入本文件。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOURCE_REPO="${SOURCE_REPO:-https://github.com/shiyu1314/openwrt-source.git}"
SOURCE_TAG="${SOURCE_TAG:-v25.12.6}"
SOURCE_DIR="${SOURCE_DIR:-${REPO_ROOT}/source}"

LAN_IP="${LAN_IP:-192.168.2.1}"
AUTHOR="${AUTHOR:-WorkBuddy}"
JOBS="${JOBS:-$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) )}"

DEVICE_CONF="${REPO_ROOT}/devices.conf"
PLUGIN_CONF="${REPO_ROOT}/plugins.conf"
COMMON_CONF="${REPO_ROOT}/config/common.config"
PATCH_DIR="${REPO_ROOT}/patches"
FIRMWARE_DIR="${REPO_ROOT}/firmware"
TARGET_DIR="bin/targets/mediatek/filogic"

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_RESET='\033[0m'

log()  { printf '%b[INFO]%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# 输出格式：key|Kconfig 符号|说明|闪存
read_devices() {
    grep -vE '^[[:space:]]*(#|$)' "$DEVICE_CONF"
}

# 输出格式：包名
read_plugins() {
    grep -vE '^[[:space:]]*(#|$)' "$PLUGIN_CONF" | tr -d '\r'
}

device_symbol() {
    local key="$1" line
    while IFS='|' read -r k sym desc flash; do
        [[ "$k" == "$key" ]] && { printf '%s' "$sym"; return 0; }
    done < <(read_devices)
    return 1
}

device_desc() {
    local key="$1" line
    while IFS='|' read -r k sym desc flash; do
        [[ "$k" == "$key" ]] && { printf '%s' "$desc"; return 0; }
    done < <(read_devices)
    return 1
}

device_exists() {
    local key="$1"
    while IFS='|' read -r k sym desc flash; do
        [[ "$k" == "$key" ]] && return 0
    done < <(read_devices)
    return 1
}

all_devices() {
    read_devices | cut -d'|' -f1
}

# 校验 IP 格式（仅用于生成 LAN 口默认地址）
valid_ip() {
    local ip="$1" IFS=.
    read -r a b c d <<<"$ip"
    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for n in "$a" "$b" "$c" "$d"; do
        [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 0 && n <= 255 )) || return 1
    done
    return 0
}
