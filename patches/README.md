# 补丁目录

把需要应用到 OpenWrt 源码根目录的补丁（统一 diff 格式）放在本目录，文件名以 `.patch` 结尾。`scripts/prepare.sh` 会在 `./scripts/feeds install -a` 之后按文件名顺序执行：

```bash
patch -p1 --forward --batch < patches/xxx.patch
```

已应用的补丁会被 `--forward` 跳过并给出警告，不会中断构建。需要调整补丁层级时，请自行修改脚本中的 `-p1`。

本仓库默认不附带补丁：所用源码 tag `v25.12.6` 已包含 MT7981 闭源 Wi-Fi 驱动、WED/HNAT 硬件加速以及目标机型的 DTS/镜像定义，无需额外打补丁即可编译出题目要求的 `.bin` 固件。
