#!/usr/bin/env bash
# 主构建入口：./scripts/build.sh [选项] [机型...]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

usage() {
    cat <<EOF
用法: $0 [选项] [机型...]

选项:
  -d, --device NAME    指定机型（可重复）；可选值见 .config 的 DEVICES
  -a, --all            编译 .config 中全部机型（默认）
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
    # 公共编译配置来自 .config 的 COMMON_CONFIG（单一配置文件）
    common_config
    # 检测到 ccache 则启用编译缓存（CI 与各人本地均可受益）
    if command -v ccache >/dev/null 2>&1; then
        echo 'CONFIG_CCACHE=y'
    fi
    while IFS= read -r plugin; do
        printf 'CONFIG_PACKAGE_%s=y\n' "$plugin"
    done < <(read_plugins)
    # 插件运行依赖，显式勾选以保证镜像内一定有
    printf 'CONFIG_PACKAGE_luci-lib-taskd=y\n'
    printf 'CONFIG_PACKAGE_appfilter=y\n'
    printf 'CONFIG_PACKAGE_kmod-oaf=y\n'
    # luci-app-store 依赖 tar，而 tar 默认开启 PACKAGE_TAR_XZ，需要 xz-utils
    # 才能满足 store 的 Kconfig depends 条件；否则 defconfig 会把 store 置为 n。
    printf 'CONFIG_PACKAGE_xz-utils=y\n'
    # 新增插件的核心运行包（lucky 用官方源预编译二进制；watchcat 为架构无关工具）
    printf 'CONFIG_PACKAGE_lucky=y\n'
    printf 'CONFIG_PACKAGE_watchcat=y\n'
} > .config

if ! make defconfig >/dev/null; then
    die "make defconfig 失败（常见原因：feed 包 Kconfig 循环依赖）；请检查上方错误后重试"
fi

# 诊断：必选 luci 插件若在 defconfig 后丢失，打印其 Kconfig 依赖状态便于定位
for sym in luci-app-store luci-app-diskman luci-app-oaf luci-theme-argon \
           luci-app-lucky luci-app-wrtbwmon luci-app-watchcat lucky watchcat \
           $(read_custom_plugins); do
    if ! grep -qxF "CONFIG_PACKAGE_${sym}=y" .config; then
        warn "诊断：${sym} 未进入 .config，相关行如下："
        grep -iE "${sym}|luci-lua-runtime|mount-utils" .config | sed 's/^/    /' || true
        if [[ -f tmp/.config-package.in ]]; then
            echo "    --- Kconfig 符号定义（.config-package.in）---"
            grep -n -A12 "config PACKAGE_${sym}$" tmp/.config-package.in | head -16 | sed 's/^/    /' || true
        fi
        dmp="logs/package/feeds/smallpackage/${sym}/dump.txt"
        [[ -f "$dmp" ]] && { echo "    --- $dmp ---"; cat "$dmp" | head -30 | sed 's/^/    /'; } || true
    fi
done

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
    echo "custom_plugins=$(read_custom_plugins | tr '\n' ' ')"
} > "$FIRMWARE_DIR/BUILD_INFO.txt"

log "编译后校验固件与插件清单"
"$REPO_ROOT/scripts/verify.sh"

ok "全部完成，固件目录：$FIRMWARE_DIR"
