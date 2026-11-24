#!/usr/bin/env bash
# 校验：必选插件是否进入 .config / 固件清单，以及 .bin 是否生成。
# 用法：./scripts/verify.sh [--config-only] [--devices d1 d2 ...]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

CONFIG_ONLY=0
DEVICES=()
while (( $# > 0 )); do
    case "$1" in
        --config-only) CONFIG_ONLY=1 ;;
        --devices)
            shift
            while (( $# > 0 )) && [[ "$1" != -* ]]; do DEVICES+=("$1"); shift; done
            continue
            ;;
        -h|--help) echo "用法: $0 [--config-only] [--devices d1 d2 ...]"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
    shift
done

CONFIG_FILE="$SOURCE_DIR/.config"
[[ -f "$CONFIG_FILE" ]] || die "找不到 $CONFIG_FILE，请先运行 build.sh"

CONFIG_ERRORS=0
check_config_symbol() {
    local sym="$1"
    if grep -qxF "$sym" "$CONFIG_FILE"; then
        return 0
    fi
    printf '%b[FAIL]%b 配置缺失：%s\n' "$C_RED" "$C_RESET" "$sym" >&2
    CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
}

log "校验 .config 中的必选插件"
while IFS= read -r plugin; do
    check_config_symbol "CONFIG_PACKAGE_${plugin}=y"
done < <(read_plugins)

log "校验闭源驱动配置"
for sym in \
    'CONFIG_MTK_WIFI_DRIVER=y' \
    'CONFIG_MTK_MT_WIFI_DRIVER_VERSION_7673=y' \
    'CONFIG_PACKAGE_kmod-mt_wifi=y' \
    'CONFIG_PACKAGE_kmod-conninfra=y' \
    'CONFIG_PACKAGE_kmod-mediatek_hnat=y' \
    'CONFIG_WED_HW_RRO_SUPPORT=y'; do
    check_config_symbol "$sym"
done

(( CONFIG_ERRORS == 0 )) || die "配置校验失败，共 $CONFIG_ERRORS 项缺失"
ok "配置校验通过"

(( CONFIG_ONLY == 0 )) || exit 0

# ---------------------------------------------------------------- 固件产物
if (( ${#DEVICES[@]} == 0 )) && [[ -f "$FIRMWARE_DIR/BUILD_INFO.txt" ]]; then
    line="$(grep '^devices=' "$FIRMWARE_DIR/BUILD_INFO.txt" | head -n1 || true)"
    if [[ -n "$line" ]]; then
        IFS=' ' read -r -a DEVICES <<< "${line#devices=}"
    fi
fi
(( ${#DEVICES[@]} > 0 )) || mapfile -t DEVICES < <(all_devices)

ARTIFACT_ERRORS=0
for dev in "${DEVICES[@]}"; do
    outdir="$FIRMWARE_DIR/$dev"
    shopt -s nullglob
    bins=("$outdir"/*-squashfs-sysupgrade.bin)
    manifests=("$outdir"/*.manifest)
    shopt -u nullglob

    if (( ${#bins[@]} == 0 )); then
        printf '%b[FAIL]%b %s 缺少 sysupgrade .bin\n' "$C_RED" "$C_RESET" "$dev" >&2
        ARTIFACT_ERRORS=$((ARTIFACT_ERRORS + 1))
        continue
    fi
    for bin in "${bins[@]}"; do
        [[ -s "$bin" ]] || {
            printf '%b[FAIL]%b 空文件：%s\n' "$C_RED" "$C_RESET" "$bin" >&2
            ARTIFACT_ERRORS=$((ARTIFACT_ERRORS + 1))
        }
    done
    ok "$dev 固件存在：$(basename "${bins[0]}")"

    if (( ${#manifests[@]} == 0 )); then
        warn "$dev 无 .manifest，无法核对镜像内包"
        continue
    fi
    while IFS= read -r plugin; do
        found=0
        for mf in "${manifests[@]}"; do
            if grep -qE "^${plugin}[[:space:]]" "$mf"; then
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            printf '%b[FAIL]%b %s 镜像内缺少插件：%s\n' "$C_RED" "$C_RESET" "$dev" "$plugin" >&2
            ARTIFACT_ERRORS=$((ARTIFACT_ERRORS + 1))
        fi
    done < <(read_plugins)
    ok "$dev 镜像内插件清单校验完成"
done

(( ARTIFACT_ERRORS == 0 )) || die "固件校验失败，共 $ARTIFACT_ERRORS 项异常"
ok "全部固件校验通过"
