#!/usr/bin/env bash
# 主构建入口：./scripts/build.sh [选项] [机型...]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

usage() {
    cat <<EOF
用法: $0 [选项] [机型...]

选项:
  -d, --device NAME    指定机型（可重复）；可选值见 devices.conf
  -a, --all            编译 devices.conf 中全部 4 个机型（默认）
      --jobs N         并行编译线程数（默认 ${JOBS}）
      --ip ADDR        LAN 口默认地址（默认 ${LAN_IP}）
      --tag TAG        源码 tag（默认 ${SOURCE_TAG}）
      --author NAME    固件署名（默认 ${AUTHOR}）
      --source-dir DIR 源码目录（默认 ${SOURCE_DIR}）
      --skip-prepare   跳过拉源码/feeds/补丁，仅重新生成配置并编译
      --skip-download  跳过 make download
  -h, --help           显示帮助

示例:
  ./scripts/build.sh --all
  ./scripts/build.sh cmcc_rax3000m-emcc
  ./scripts/build.sh -d cmcc_rax3000m-nand -d cmcc_xr30-emmc --jobs 8
EOF
}

DEVICES=()
SKIP_PREPARE=0
SKIP_DOWNLOAD=0

while (( $# > 0 )); do
    case "$1" in
        -d|--device) shift; DEVICES+=("${1:?--device 缺少机型名称}") ;;
        -a|--all) DEVICES=() ;;
        --jobs) shift; JOBS="${1:?--jobs 缺少数值}" ;;
        --ip) shift; LAN_IP="${1:?--ip 缺少地址}" ;;
        --tag) shift; SOURCE_TAG="${1:?--tag 缺少 tag}" ;;
        --author) shift; AUTHOR="${1:?--author 缺少名称}" ;;
        --source-dir) shift; SOURCE_DIR="${1:?--source-dir 缺少路径}" ;;
        --skip-prepare) SKIP_PREPARE=1 ;;
        --skip-download) SKIP_DOWNLOAD=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "未知选项：$1（使用 --help 查看用法）" ;;
        *) DEVICES+=("$1") ;;
    esac
    shift
done

valid_ip "$LAN_IP" || die "非法 LAN 地址：$LAN_IP"
if (( ${#DEVICES[@]} == 0 )); then
    mapfile -t DEVICES < <(all_devices)
fi
for dev in "${DEVICES[@]}"; do
    device_exists "$dev" || die "未知机型：$dev。可选值：$(all_devices | tr '\n' ' ')"
done

export SOURCE_DIR SOURCE_TAG LAN_IP AUTHOR JOBS

log "目标机型：${DEVICES[*]}"
log "源码版本：$SOURCE_TAG"
log "源码目录：$SOURCE_DIR"
log "LAN 地址：$LAN_IP"

if (( SKIP_PREPARE == 0 )); then
    "$REPO_ROOT/scripts/prepare.sh"
else
    [[ -d "$SOURCE_DIR/.git" ]] || die "--skip-prepare 要求源码目录已存在：$SOURCE_DIR"
    log "跳过环境准备"
fi

cd "$SOURCE_DIR"

# ---------------------------------------------------------------- 生成 .config
log "生成 .config"
{
    echo 'CONFIG_TARGET_mediatek=y'
    echo 'CONFIG_TARGET_mediatek_filogic=y'
    for dev in "${DEVICES[@]}"; do
        sym="$(device_symbol "$dev")" || die "未找到 $dev 的 Kconfig 符号"
        printf '%s=y\n' "$sym"
    done
    cat "$COMMON_CONF"
    while IFS= read -r plugin; do
        printf 'CONFIG_PACKAGE_%s=y\n' "$plugin"
    done < <(read_plugins)
    # 插件运行依赖，显式勾选以保证镜像内一定有
    printf 'CONFIG_PACKAGE_luci-lib-taskd=y\n'
    printf 'CONFIG_PACKAGE_appfilter=y\n'
    printf 'CONFIG_PACKAGE_kmod-oaf=y\n'
} > .config

make defconfig >/dev/null

log "编译前校验配置"
"$REPO_ROOT/scripts/verify.sh" --config-only

# ---------------------------------------------------------------- 下载与编译
if (( SKIP_DOWNLOAD == 0 )); then
    log "下载源码包"
    make download -j"$JOBS" || make download -j1
else
    log "跳过 make download"
fi

log "开始编译（并发 $JOBS）"
if ! make -j"$JOBS"; then
    warn "并行编译失败，尝试单线程定位问题"
    make -j1 || make -j1 V=s
fi

# ---------------------------------------------------------------- 收集产物
mkdir -p "$FIRMWARE_DIR"
log "收集固件到 $FIRMWARE_DIR"
for dev in "${DEVICES[@]}"; do
    outdir="$FIRMWARE_DIR/$dev"
    mkdir -p "$outdir"
    shopt -s nullglob
    bins=("$SOURCE_DIR/$TARGET_DIR"/openwrt-mediatek-filogic-"$dev"*-squashfs-sysupgrade.bin)
    manifests=("$SOURCE_DIR/$TARGET_DIR"/openwrt-mediatek-filogic-"$dev"*.manifest)
    shopt -u nullglob
    (( ${#bins[@]} > 0 )) || die "$dev 未生成 sysupgrade .bin，请检查编译日志"
    cp -f "${bins[@]}" "$outdir/"
    if (( ${#manifests[@]} > 0 )); then
        cp -f "${manifests[@]}" "$outdir/"
    else
        warn "$dev 未找到 .manifest，跳过镜像内包清单校验"
    fi
    ok "$dev: $(basename "${bins[0]}")"
done

(
    cd "$FIRMWARE_DIR"
    find . -type f -name '*.bin' -exec sha256sum {} + | sort -k2 > SHA256SUMS
)

{
    echo "build_date=$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "source_repo=$SOURCE_REPO"
    echo "source_tag=$SOURCE_TAG"
    echo "devices=${DEVICES[*]}"
    echo "lan_ip=$LAN_IP"
    echo "author=$AUTHOR"
    echo "plugins=$(read_plugins | tr '\n' ' ')"
} > "$FIRMWARE_DIR/BUILD_INFO.txt"

log "编译后校验固件与插件清单"
"$REPO_ROOT/scripts/verify.sh"

ok "全部完成，固件目录：$FIRMWARE_DIR"
