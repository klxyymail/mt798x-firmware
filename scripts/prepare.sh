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
log "写入 feeds.conf（官方源 + 自定义插件源）"
cp feeds.conf.default feeds.conf
cat >> feeds.conf <<'EOF'
src-git xd https://github.com/shiyu1314/openwrt-feeds.git^packages
src-git istore https://github.com/istoreos/istore.git^main
EOF

log "更新 feeds"
./scripts/feeds update -a

# xd 源提供维护版 luci-app-diskman；移除官方同名包避免冲突。
if [[ -d feeds/luci/applications/luci-app-diskman ]]; then
    rm -rf feeds/luci/applications/luci-app-diskman
    log "已移除官方 feeds 中的 luci-app-diskman，避免与 xd 源冲突"
fi

log "安装 feeds 中的软件包"
./scripts/feeds install -a >/dev/null

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
    log "patches/ 目录中没有补丁，跳过"
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
