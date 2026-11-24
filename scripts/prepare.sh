#!/usr/bin/env bash
# 准备 OpenWrt 编译环境：拉取固定-tag 源码、追加插件源、安装 feeds、应用补丁。
# 用法：./scripts/prepare.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

cd "$REPO_ROOT"

valid_ip "$LAN_IP" || die "LAN_IP 不是合法 IPv4 地址：$LAN_IP"

# ---------------------------------------------------------------- 源码
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    log "克隆 OpenWrt 源码：$SOURCE_REPO (tag: $SOURCE_TAG)"
    git clone --depth 1 --branch "$SOURCE_TAG" "$SOURCE_REPO" "$SOURCE_DIR"
else
    log "复用已有源码目录：$SOURCE_DIR"
    if ! git -C "$SOURCE_DIR" rev-parse -q --verify "refs/tags/$SOURCE_TAG" >/dev/null; then
        log "拉取 tag $SOURCE_TAG"
        git -C "$SOURCE_DIR" fetch --depth 1 origin "tag" "$SOURCE_TAG"
    fi
    current="$(git -C "$SOURCE_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
    if [[ "$current" != "$SOURCE_TAG" ]]; then
        git -C "$SOURCE_DIR" checkout --detach "$SOURCE_TAG"
    fi
fi
ok "源码版本：$(git -C "$SOURCE_DIR" describe --tags --exact-match HEAD 2>/dev/null || git -C "$SOURCE_DIR" rev-parse --short HEAD)"

cd "$SOURCE_DIR"

# ---------------------------------------------------------------- feeds
# feeds.conf 优先于 feeds.conf.default；每次重新生成，保证可重复。
log "写入 feeds.conf（官方源 + .config 中定义的自定义源）"
cp feeds.conf.default feeds.conf
while IFS='|' read -r alias url; do
    [[ -n "$alias" && -n "$url" ]] || continue
    printf 'src-git %s %s\n' "$alias" "$url" >> feeds.conf
done < <(read_custom_feeds)

log "更新 feeds"
./scripts/feeds update -a

# small-package 提供维护版 luci-app-diskman；移除官方同名包避免重复定义。
if [[ -d feeds/luci/applications/luci-app-diskman ]]; then
    rm -rf feeds/luci/applications/luci-app-diskman
    log "已移除官方 feeds 中的 luci-app-diskman，避免与插件源冲突"
fi

# 官方 luci feed 的 luci-app-weechat 与 packages feed 的 weechat-full/minimal
# 存在 Kconfig 循环依赖（weechat-minimal is selected by luci-app-weechat，
# 而 weechat-full 又 depends on weechat-minimal），会导致 make defconfig 报
# "recursive dependency detected" 并中止。本仓库不需要 weechat，直接移除。
if [[ -d feeds/luci/applications/luci-app-weechat ]]; then
    rm -rf feeds/luci/applications/luci-app-weechat
    log "已移除官方 feeds 中的 luci-app-weechat，避免 Kconfig 循环依赖"
fi

# luci-app-store 的上游 Makefile 依赖 +mount-utils 与 +libuci-lua，但本源码树
# （25.12 / apk 体系）中这两个包都不存在：libuci-lua 会再依赖已移除的 liblua，
# mount-utils 从未提供。任一无法满足都会让 defconfig 把 luci-app-store 置为 n。
# store 本体是 prebuilt 前端 UI，运行时用 busybox 的 mount，去掉这两个失效依赖。
STORE_MK="feeds/smallpackage/luci-app-store/Makefile"
if [[ -f "$STORE_MK" ]]; then
    sed -i \
        -e 's/ +mount-utils//' \
        -e 's/ +libuci-lua//' \
        -e '/^LUCI_EXTRA_DEPENDS:/d' \
        "$STORE_MK"
    log "已清理 luci-app-store 的失效依赖（mount-utils/libuci-lua/EXTRA_DEPENDS）"
fi

# kenzok8/small-package 打包缺陷：appfilter(目录 open-app-filter) 与 luci-app-oaf
# 都把各自的 ACL 安装为 /usr/share/rpcd/acl.d/luci-app-oaf.json，但两份内容不同
# （appfilter 授予 oaf / fwx 的 ubus 权限；luci-app-oaf 授予 appfilter 的 uci 权限）。
# 25.12 使用 apk，禁止包间覆盖同一路径，package/install 会报
# "trying to overwrite ... owned by appfilter" 并让整个 world 构建失败。
# 把 appfilter 侧的 ACL 改名为 oaf.json（与其权限名一致），两份 ACL 都保留。
APPFILTER_MK="feeds/smallpackage/open-app-filter/Makefile"
if [[ -f "$APPFILTER_MK" ]]; then
    sed -i 's#$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/#$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/oaf.json#' "$APPFILTER_MK"
    log "已修复 appfilter 与 luci-app-oaf 的 ACL 文件名冲突（appfilter 侧改名 oaf.json）"
fi

# 官方 feed 全量安装；第三方大仓只安装需要的包，避免其 base-files/firewall 等
# 同名包覆盖 OpenWrt 核心包。
log "安装官方 feeds 中的软件包"
while IFS= read -r feed; do
    [[ -n "$feed" ]] && ./scripts/feeds install -a -p "$feed" >/dev/null
done < <(awk '$1 ~ /^src-/ && NF >= 2 {print $2}' feeds.conf.default)

log "从 small-package 安装所需插件及依赖"
./scripts/feeds install -p smallpackage \
    luci-app-store luci-lib-taskd luci-lib-xterm taskd \
    luci-app-diskman luci-theme-argon \
    luci-app-oaf open-app-filter oaf \
    luci-app-wrtbwmon >/dev/null

# Lucky 用官方源 gdy666/luci-app-lucky（兼容 25.12 apk，核心程序按架构下载
# 预编译包，不依赖老式 Lua 编译）。luci-i18n-lucky-zh-cn 由该 Makefile 内的
# LuciTranslation 自动生成，装了界面包即会出现，无需单独 install。
log "从 gdy666/luci-app-lucky 安装 lucky 核心包与界面包"
./scripts/feeds install -p lucky lucky luci-app-lucky >/dev/null

# watchcat / luci-app-watchcat / luci-i18n-watchcat-zh-cn 均来自官方 feed
# （packages feed 提供 watchcat 核心；luci feed 提供界面+zh_Hans 语言包），
# 上面 `feeds install -a -p <官方feed>` 已全量安装，无需额外处理。

# 运行时自定义插件（CUSTOM_PLUGINS，空格分隔）：在所有 feed 里去安装这些包，
# feeds install 会自动递归装上其依赖；找不到的包给出告警而不中断（defconfig
# 会自然忽略未安装的包，避免用户填错一个名字导致整个固件编译失败）。
if [[ -n "${CUSTOM_PLUGINS:-}" ]]; then
    log "安装运行时自定义插件：${CUSTOM_PLUGINS}"
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        if ./scripts/feeds install "$pkg" >/dev/null 2>&1; then
            ok "自定义插件已安装：$pkg"
        else
            warn "自定义插件未找到（将不会打进固件）：$pkg"
        fi
    done < <(read_custom_plugins)
fi

# ---------------------------------------------------------------- 补丁
shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob
if (( ${#patches[@]} > 0 )); then
    for p in "${patches[@]}"; do
        log "应用补丁：$(basename "$p")"
        patch -p1 --forward --batch < "$p" || warn "补丁 $(basename "$p") 未干净应用，请人工确认"
    done
else
    log "没有待应用的补丁，跳过"
fi

# ---------------------------------------------------------------- 默认设置
mkdir -p files/etc
{
    printf ' _______ ________ __\n'
    printf ' |     |.-----.-----.-----.|  |  |  |.----.|  |_\n'
    printf ' |   - ||  _  |  -__|     ||  |  |  ||   _||   _|\n'
    printf ' |_______||   __|_____|__|__||________||__|  |____|\n'
    printf ' |__|\n'
    printf ' -----------------------------------------------------\n'
    printf ' %%D by %s\n' "$AUTHOR"
    printf ' -----------------------------------------------------\n'
} > files/etc/banner

if [[ -f package/base-files/files/bin/config_generate ]]; then
    sed -i "s/192\.168\.1\.1/${LAN_IP}/g" package/base-files/files/bin/config_generate
    ok "LAN 默认地址已设置为 $LAN_IP"
fi

ok "编译环境准备完成：$SOURCE_DIR"
