#!/usr/bin/env bash
# 公共环境变量与辅助函数。所有脚本通过 source 引入本文件。
# 所有可变配置集中在仓库根目录的 .config（P3TERX 风格的单文件配置）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONF="${REPO_ROOT}/.config"

[[ -f "$BUILD_CONF" ]] || { printf '[FAIL] 找不到配置文件：%s\n' "$BUILD_CONF" >&2; exit 1; }
# shellcheck disable=SC1090
source "$BUILD_CONF"

# 运行期路径 / 目标目录约定（非用户配置，一般无需改动）
SOURCE_DIR="${SOURCE_DIR:-${REPO_ROOT}/source}"
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

# ---------------------------------------------------------------- 配置读取
# 机型：原样输出 .config 中 DEVICES 数组元素（key|符号|说明|闪存）
read_devices() {
    printf '%s\n' "${DEVICES[@]}"
}

# 自定义插件：CUSTOM_PLUGINS 环境变量（空格分隔），规范化为一行一个包名。
# 兼容三种写法：luci-app-xxx / CONFIG_PACKAGE_luci-app-xxx=y / CONFIG_PACKAGE_luci-app-xxx
normalize_plugin() {
    local p="$1"
    p="${p#CONFIG_PACKAGE_}"
    p="${p%=y}"
    printf '%s' "$p"
}

read_custom_plugins() {
    [[ -n "${CUSTOM_PLUGINS:-}" ]] || return 0
    local p
    for p in $CUSTOM_PLUGINS; do
        p="$(normalize_plugin "$p")"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done
}

# 必装插件 = .config 固定清单 + 运行期自定义插件
read_plugins() {
    printf '%s\n' "${PLUGINS[@]}"
    read_custom_plugins
}

# 自定义 feed 源：输出 feed别名|URL
read_custom_feeds() {
    printf '%s\n' "${CUSTOM_FEEDS[@]}"
}

# 公共编译配置（CONFIG_* 行）
common_config() {
    printf '%s\n' "$COMMON_CONFIG"
}

# ---------------------------------------------------------------- 机型辅助
device_symbol() {
    local key="$1" k sym desc flash
    while IFS='|' read -r k sym desc flash; do
        [[ "$k" == "$key" ]] && { printf '%s' "$sym"; return 0; }
    done < <(read_devices)
    return 1
}

device_desc() {
    local key="$1" k sym desc flash
    while IFS='|' read -r k sym desc flash; do
        [[ "$k" == "$key" ]] && { printf '%s' "$desc"; return 0; }
    done < <(read_devices)
    return 1
}

device_exists() {
    local key="$1" k sym desc flash
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
