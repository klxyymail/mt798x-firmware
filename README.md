# MT798X 闭源驱动固件编译仓库

一个可直接编译以下 4 个中国移动光猫路由机型固件的仓库，产物为 `*.bin`（`sysupgrade.bin`），**内置 MediaTek 闭源 Wi-Fi 驱动**以及题目要求的全部 LuCI 插件。

实现思路参考 [shiyu1314/openwrt-rax3000m](https://github.com/shiyu1314/openwrt-rax3000m)：固定版本 OpenWrt 源码 + 自定义 feed + 构建脚本 + GitHub Actions 矩阵编译 + 产物整理。本仓库把机型、插件、校验逻辑拆成可维护的配置，而不是把全部逻辑写在 workflow 里。

---

## 1. 支持机型与产物

| 机型 key | 设备 | 闪存 | 产物文件名 |
|---|---|---|---|
| `cmcc_rax3000m-256m-nand` | CMCC RAX3000M 256M NAND 版 | 256MB NAND | `openwrt-mediatek-filogic-cmcc_rax3000m-256m-nand-squashfs-sysupgrade.bin` |
| `cmcc_rax3000m-emmc` | CMCC RAX3000M eMMC 版 | eMMC | `openwrt-mediatek-filogic-cmcc_rax3000m-emmc-squashfs-sysupgrade.bin` |
| `cmcc_rax3000m-nand` | CMCC RAX3000M NAND 版 | NAND | `openwrt-mediatek-filogic-cmcc_rax3000m-nand-squashfs-sysupgrade.bin` |
| `cmcc_xr30-emmc` | CMCC XR30 eMMC 版 | eMMC | `openwrt-mediatek-filogic-cmcc_xr30-emmc-squashfs-sysupgrade.bin` |

4 个机型的设备定义均来自固定源码 tag `v25.12.6` 的 `target/linux/mediatek/image/filogic.mk`，镜像命令为 `sysupgrade-tar | append-metadata`，因此产物后缀统一为 `-squashfs-sysupgrade.bin`。

> ⚠️ 这 4 个镜像**不能互换**：eMMC 版与 NAND 版分区布局不同；256M NAND 与普通 NAND 的 DTS/容量不同。刷错会变砖。

---

## 2. 插件

| 插件 | 来源 feed |
|---|---|
| `luci-app-store` | `kenzok8/small-package.git^main`（1708 星，含 `luci-lib-taskd` / `luci-lib-xterm` / `taskd`） |
| `luci-app-eqos-mtk` | 源码内置 `package/mtk/applications` |
| `luci-app-mtwifi-cfg` | 源码内置 `package/mtk/applications` |
| `luci-app-turboacc-mtk` | 源码内置 `package/mtk/applications` |
| `luci-app-ttyd` | OpenWrt 官方 luci feed |
| `luci-app-upnp` | OpenWrt 官方 luci feed |
| `luci-app-diskman` | `kenzok8/small-package.git^main` |
| `luci-theme-argon` | `kenzok8/small-package.git^main` |
| `luci-app-oaf` | `kenzok8/small-package.git^main` |
| `luci-app-ssr-plus` | `kenzok8/small-package.git^main` |
| `luci-app-passwall` | `kenzok8/small-package.git^main` |
| `luci-i18n-oaf-zh-cn` | 由 `luci-app-oaf/po/zh_Hans` 经 `luci.mk` 自动生成（`zh_Hans` → `zh-cn`） |
| `luci-app-lucky` | 官方 [`gdy666/luci-app-lucky.git^main`](https://github.com/gdy666/luci-app-lucky)（核心包 `lucky` 按架构下载预编译二进制） |
| `luci-i18n-lucky-zh-cn` | 由官方 lucky 源 `po/zh_Hans` 经 `luci.mk` 自动生成 |
| `luci-app-wrtbwmon` | `kenzok8/small-package.git^main`（依赖官方 `luci-app-nlbwmon`） |
| `luci-app-watchcat` | OpenWrt 官方 luci feed（核心包 `watchcat` 来自官方 packages feed） |
| `luci-i18n-watchcat-zh-cn` | 由官方 luci 源 `po/zh_Hans` 经 `luci.mk` 自动生成 |

## 3. 闭源驱动说明

源码 tag `v25.12.6` 自带联发科闭源 Wi-Fi 方案，关键配置位于唯一配置文件 [`.config`](.config) 的 `COMMON_CONFIG` 段：

- `CONFIG_MTK_WIFI_DRIVER=y` + `CONFIG_MTK_MT_WIFI_DRIVER_VERSION_7673=y`（mt_wifi 7.6.7.3）
- `CONFIG_MTK_MT_WIFI_FIRMWARE_PATH_MT7981="mt7981-fw-20260601"`
- `CONFIG_PACKAGE_kmod-mt_wifi=y`、`CONFIG_PACKAGE_kmod-conninfra=y`
- `CONFIG_MTK_WHNAT_SUPPORT=m`、`CONFIG_PACKAGE_kmod-mediatek_hnat=y`
- `CONFIG_WED_HW_RRO_SUPPORT=y`、`CONFIG_PACKAGE_kmod-warp=y`、`CONFIG_WARP_CHIPSET="mt7981"`
- 配套应用：`mtwifi-cfg`、`mtwifi-cfg-ucode`、`mtkhqos_util`、`wifi-dats`、`datconf`

闭源驱动意味着 Wi-Fi 部分不是主线 mac80211/cfg80211 方案，配置入口是 `luci-app-mtwifi-cfg`，硬件加速入口是 `luci-app-turboacc-mtk`。**使用、再分发闭源二进制文件前请自行确认上游许可与当地法律要求**；本仓库只负责自动化构建流程，不提供任何驱动二进制。

---

## 4. 本地编译

### 4.1 环境

推荐 Ubuntu 24.04 x86_64，至少 4GB 内存（建议 8GB+），至少 40GB 可用磁盘，需要能访问 GitHub。

```bash
sudo apt-get update
sudo apt-get install -y build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
  python3-setuptools rsync swig unzip zlib1g-dev file wget \
  libelf-dev qemu-utils ccache
```

### 4.2 一键编译全部 4 个机型

```bash
git clone <你的仓库地址> mt798x-firmware
cd mt798x-firmware
chmod +x scripts/*.sh
./scripts/build.sh --all
```

脚本会自动：拉取固定 tag 源码 → 追加 2 个插件 feed（kenzok8/small-package + gdy666/lucky） → 安装依赖包 → 写入默认 IP/署名 → 生成 `.config` → `make defconfig` → 编译前校验 → 下载源码包 → 编译 → 收集 `.bin` → 编译后校验。

### 4.3 常用变体

```bash
# 只编一个机型
./scripts/build.sh cmcc_rax3000m-emcc

# 编两个机型，限制并发，自定义 LAN 地址
./scripts/build.sh -d cmcc_rax3000m-nand -d cmcc_xr30-emmc \
  --jobs 4 --ip 192.168.5.1 --author MyName

# 源码已就绪，只重新生成配置并编译
./scripts/build.sh --all --skip-prepare --skip-download

# 只校验，不编译
./scripts/verify.sh
```

也可以通过 `Makefile` 调用：`make prepare`、`make build`、`make build DEVICES="cmcc_rax3000m-emcc"`、`make verify`。

### 4.4 产物

```
firmware/
├── BUILD_INFO.txt
├── SHA256SUMS
├── cmcc_rax3000m-256m-nand/
│   ├── openwrt-mediatek-filogic-cmcc_rax3000m-256m-nand-squashfs-sysupgrade.bin
│   └── *.manifest
├── cmcc_rax3000m-emmc/
├── cmcc_rax3000m-nand/
└── cmcc_xr30-emmc/
```

`verify.sh` 会读取每个机型的 `.manifest`，逐个确认根目录配置文件 `.config` 中全部 15 个必装插件确实被打包进镜像，而不只是写进 OpenWrt 源码目录生成的编译配置里。（注：25.12 的 apk 固件不生成传统 `.manifest`，此时脚本会给出 warn 并跳过镜像内清单核对，但编译配置校验仍强制执行。）

---

## 5. GitHub Actions 云端编译

在仓库 **Actions → Build MT798X Closed-Driver Firmware → Run workflow**：

- `device`：选 `all` 或某个机型
- `ip`：LAN 默认地址，默认 `192.168.6.1`
- `author`：固件署名
- `jobs`：并发数，默认 `4`
- `release`：勾选后把固件发布到 Release（tag 形如 `v25.12.6-20261124-2100-r5`，含日期、时分和 GitHub 运行序号，每次编译独立保留、不覆盖历史固件），默认勾选
- `custom_plugins`：**自定义插件**，多个用空格分隔，留空则不添加。例：`luci-app-zerotier luci-app-socat`。构建时会自动从所有已添加的 feed 中安装这些包及其依赖；找不到（拼错或源里没有）的包会告警并跳过，不中断编译。运行结果写入各机型 `BUILD_INFO.txt` 的 `custom_plugins` 字段。

每个机型一个独立 job，编译完成后上传 artifact（含 `SHA256SUMS` 与 `BUILD_INFO.txt`）。全部机型编译成功后，由一个独立的 `release` job 统一下载 artifact、生成总 `SHA256SUMS` 和一个 Release（4 个机型的 `.bin` 在同一页），避免多 job 并发写同一 tag 造成互相覆盖。Release tag 由「日期-时分-运行序号」组成，每次运行都是新 tag，因此**历史编译的固件都会保留**，不会被后续编译覆盖（在 Releases 页面可查看/下载历次版本）。也支持 `repository_dispatch` 的 `build` 事件触发。

---

## 6. 目录结构

```
.
├── .config                       # ★ 唯一配置文件：源码/feed/机型/插件/公共Kconfig
├── .github/workflows/op.yml      # GitHub Actions 矩阵编译（读取 .config）
├── scripts/
│   ├── env.sh                    # 加载 .config + 路径/解析函数
│   ├── prepare.sh                # 拉源码、配 feed、打补丁、默认设置
│   ├── build.sh                  # 主入口
│   └── verify.sh                 # 配置 + 产物 + 镜像内插件校验
├── Makefile
└── README.md
```

> 配置集中化（参照 [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) 的单文件思路）：以前分散在 `devices.conf`、`plugins.conf`、`config/common.config`、`env.sh` 中的可变配置，现已全部合并到根目录的 [`.config`](.config) 一个文件。改机型、加常驻插件、换源码版本/源地址、调公共编译选项，只需编辑这一处；脚本与 workflow 都会自动读取。运行期的临时参数（IP、署名、机型选择、自定义插件）仍通过 Actions 菜单或命令行传入，优先级高于文件内的默认值。

源码 tag `v25.12.6` 已包含闭源驱动和 4 个机型的定义，默认无需打补丁。如需自定义补丁，自行创建 `patches/` 目录并放入 `.patch` 文件，`scripts/prepare.sh` 会自动按文件名顺序应用。

---

## 7. 刷机与排错提示

- 刷机前备份 `factory` 分区中的校准数据（EEPROM/calibration），闭源驱动依赖它；不同机型的校准数据不可混用。
- 从原厂系统刷入前通常需要先替换/改造 U-Boot，可参考 [bl-mt798x-dhcpd](https://github.com/Yuzhii0718/bl-mt798x-dhcpd) 与参考仓库的说明。
- 首次启动请耐心等待 2–3 分钟再访问管理页；默认 LAN 地址见 `BUILD_INFO.txt`（默认 `192.168.6.1`）。
- `make defconfig` 后插件符号消失：通常是 feed 未安装成功，执行 `./scripts/prepare.sh` 后重试。
- 编译 OOM 或卡死：把 `--jobs` 降到 `2`，并在 Actions 里用 `4` 线程。
- 下载失败可直接重跑 `./scripts/build.sh --skip-prepare`，`make download` 会续传。

---

## 8. 上游来源

- 实际编译源码：`https://github.com/shiyu1314/openwrt-source.git`，tag `v25.12.6`（三个 workflow 均 clone 此仓库并 checkout 最新 `v25.*` tag；其 README 指向联发科 `mtk-openwrt-feeds`，闭源驱动即来自这里）
- 参考实现：`https://github.com/shiyu1314/openwrt-rax3000m`
- 上游核心源码（README 致谢）：`https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git`，分支 `25.12`（306 星；`ImmortalWrt with MTK OpenWrt Feeds patches imported`）
- 插件源：`https://github.com/kenzok8/small-package.git`，分支 `main`（1708 星）；Lucky 用官方源 `https://github.com/gdy666/luci-app-lucky.git`，分支 `main`；watchcat 用 OpenWrt 官方 luci/packages feed
- U-Boot：`https://github.com/Yuzhii0718/bl-mt798x-dhcpd`
