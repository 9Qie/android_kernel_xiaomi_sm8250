# 小米 10 至尊纪念版 (cas) — MIUI 内核

基于 Linux 4.19.325（CIP `v4.19.325-cip135` / `-st19`）的 **小米 10 至尊纪念版**
（`cas`）内核，面向 **MIUI** 构建，集成 **ReSukiSU (BakaSU) + SuSFS** root。

本仓库只构建一个目标。上游原本支持的其他机型，以及这套内核从未用到的整套
Android/GKI 构建体系，都已移除 —— 见 [移除内容](#移除内容)。

| | |
|---|---|
| 机型 | 小米 10 至尊纪念版（`cas`，M2007J1SC） |
| 内核 | 4.19.325，CIP `cip135` / `-st19` 基线 |
| 目标系统 | MIUI |
| Root | ReSukiSU (BakaSU) + SuSFS |
| 工具链 | zyc-clang 16.0.6 |
| 产物 | AnyKernel3 刷机包 |

---

## 下载

到 [Releases](../../releases/latest) 取最新的 `AnyKernel3_BakaSU_*.zip`。它本身就是
刷机包 —— 直接在第三方 recovery 或内核管理器中刷入，**不要先解压**。

配套的 `BakaSU_*_arm64-v8a-release.apk` 管理器会一并发布。

## 刷入

1. 进入第三方 recovery（或使用支持 AnyKernel3 的内核管理器）。
2. 刷入 `AnyKernel3_BakaSU_<版本号>_<内核release>.zip`。
3. 重启。安装配套的 BakaSU 管理器 APK 以管理 root。

刷机包只替换 `boot` 里的内核，不碰 `dtbo`、`vendor_boot` 和用户数据。若要回退，
刷回事先备份的原厂 `boot` 镜像即可。

## 构建

### GitHub Actions（推荐）

向 `bakasu-cas` 分支推送，或在 Actions 页面手动运行
**`Build MIUI_cas_ReSukiSU-SuSFS`** 工作流。这个唯一的 job 执行：

```sh
./build_kernel.sh cas ksu miui
```

并把产出的 AnyKernel3 刷机包和配套的 BakaSU 管理器 APK 发布为 Release。
ccache 在两次运行之间会恢复和保存，所以只有首次构建慢。

### 本地构建

需要 aarch64 clang 工具链，以及 `make`、`bc`、`bison`、`flex`、`zip`、`unzip`、
`ccache`。

```sh
# 脚本默认从 $HOME/zyc-clang/bin 找工具链 —— 把你的放那里，
# 或者改 build_kernel.sh 顶部的 TOOLCHAIN_BIN。
mkdir -p $HOME/zyc-clang && cd $HOME/zyc-clang
curl -fLO https://github.com/ZyCromerZ/Clang/releases/download/16.0.6-20260807-release/Clang-16.0.6-20260807.tar.gz
tar -zxf Clang-16.0.6-20260807.tar.gz

cd /path/to/this/repo
./build_kernel.sh cas ksu miui
```

刷机包落在仓库根目录；构建目录为 `out_miui/`（或 `out_aosp/`，每个目标一个）。

#### 参数

```
./build_kernel.sh <device> [ksu] [miui|aosp]
```

`<device>` 必须是 `cas` —— 它决定使用 `arch/arm64/configs/cas_defconfig`，
而这是树里唯一保留的 defconfig。`ksu` 启用 ReSukiSU + SuSFS；不写则产出无 root
的内核。目标系统方面，`miui` 和 `aosp` 二选一；两个都不写则依次都编。
CI 固定传 `miui`。

## 配置

基础配置是 `arch/arm64/configs/cas_defconfig`，`build_kernel.sh` 在编译前逐层叠加：

- **始终启用** —— Baseband-guard（`BBG`），并把优化级别钉死在 `-O2`，
  防止将来某个配置片段悄悄把内核降到 `-Os`。
- **带 `ksu` 时** —— `KSU`、`THREAD_INFO_IN_TASK`、`KSU_SUSFS`。钩子变体是
  一个 Kconfig `choice`，所以先关掉 `KSU_TRACEPOINT_HOOK` 和
  `KSU_MANUAL_HOOK`；这棵 4.19 树用的是 SuSFS inline-hook 变体。
- **带 `miui` 时** —— `STATIC_USERMODEHELPER_PATH=/system/bin/micd`、
  `XIAOMI_MIUI`、`MIGT`、`MIHW`、`MILLET_*`、`MIUI_ZRAM_MEMORY_TRACKING`、
  `BINDER_OPT`、`PERF_*`、`RTMM`、`BOOTUP_RECLAIM`、`MI_RECLAIM`、`OVERLAY_FS`、
  `PACKAGE_RUNTIME_INFO`、`KPERFEVENTS`、`TASK_DELAY_ACCT`、`LTO_NONE`
  （关闭 clang LTO）、关闭 `SHADOW_CALL_STACK`、关闭 `REKERNEL`。

MIUI 构建还会在编译前对 `arch/arm64/boot/dts/vendor/qcom/` 下若干 DSI 面板时序表
做补丁，之后从备份还原，因此工作区不会留下改动。

## 移除内容

这棵树原本带着 12 台小米 sm8250 机型连同全套高通参考板，还有一整套
`build_kernel.sh` 从不调用的 Android/GKI 构建体系（`AndroidKernel.mk`、
`Android.bp`、`build.config.*`、`android/` 等）。这些都不在 `cas` 的构建图里，
已全部移除：

- **设备树** —— 从构建实际使用的 4 个根（`kona.dts`、`kona-v2.dts`、
  `kona-v2.1.dts`、`cas-sm8250-overlay.dts`）递归求 `#include` 闭包，
  `arch/arm64/boot/dts/vendor/qcom` 下 1055 个文件里只剩 107 个是活的。其余 948 个、
  `arch/arm64/boot/dts/` 下 Makefile 根本不会下探的 27 个通用 SoC 目录、
  陈旧的 `vendor/xiaomi/` 副本、以及 `vendor/bindings/`（所有 include 都经
  `<dt-bindings/...>` 解析）一并删除。
- **配置** —— 只留 `cas_defconfig`、`cas_stock-defconfig` 和兜底的通用
  `defconfig`。其他机型的 defconfig、`AOSP_defconfig/`、`configs/vendor/` 的
  可达性仅来自 `kernel/Makefile` 按机型分支的 `config_data.gz` 规则、无人调用的
  python2 `scripts/build-all.py`、以及指向不存在目录的 `scripts/update_defconfig`。
- **构建体系** —— 全部 Android/GKI 相关，加上 `buildall.sh`（一个 13 机型的循环；
  CI 一直直接调用 `build_kernel.sh cas ksu miui`）。

三个 Makefile 同步裁剪：`vendor/qcom/Makefile` 只留 `cas` 段
（`kona.dtb`、`kona-v2.dtb`、`kona-v2.1.dtb` 仍通过各自的 `dtbo-base` 依赖编出），
`arch/arm64/boot/dts/Makefile` 去掉已空的 SoC 列表，`kernel/Makefile` 在 MIUI 下
无条件嵌入 `cas_stock-defconfig`。

## 相对 CIP 的内核改动

在上游 4.19.325 之上有两批工作。

**按 `PORTING_GUIDE.md` 移植** —— 一轮面向 Android 的加固：adreno ioctl 长度检查、
qrtr 溢出、binder transaction use-after-free、audit/selinux/f2fs/netfilter/net-sched
修复、audio compress 加锁、USB OTG 空指针、cpufreq 热插拔竞态、sdcardfs 负 dentry、
camera request manager UAF / CCI 越界 / JPEG 边界，以及 `Android/data` 与
`Android/obb` 的按域 GID 隔离。

**从 `v4.19.325-cip136`（`-st20`）回移** —— 另外 25 条修复，每条都对着**实际编译出的
配置**（而非 defconfig）核实过可达性：

- 越界读与信息泄漏：rndis query、net1080 pad byte、`nf_conntrack_irc` DCC 解析、
  ebtables match 名、uvc SEND_RESPONSE 长度、igmp 组播哈希表清理、`af_packet`
  环形缓冲区重启、evdev `input_event` 填充、evdev `array_index_nospec`
- 引用计数与校验：qrtr `init_net` 限制、xt_nat family 校验、nf_log MAC 头、
  IPv6 MLD 定时器 UAF、IPv6 FIB dump 游标、cls_bpf 回滚递归、xt_hashlimit
  rate-match、f_fs read buffer 生命周期
- SCTP：`auth_hmacs` 尺寸、嵌入地址参数长度、stale-cookie 错误原因、
  stream reset 计数、过期 cookie 的 vtag 匹配、auth chunk 容量

另有两处 USB 修复：`msm-ssusb-qmp` 不再在仅支持 USB3 的 PHY 上访问 DP-combo PHY
的寄存器（那个窗口只有 `0x1000` 字节，会 oops）；`xhci-plat` 在系统 PM 遇到
runtime-suspended 时跳过端口访问。

这些改动只经过完整 CI 构建验证，未对单条补丁做运行时测试。

## 致谢

- [CIP](https://gitlab.com/cip-project/cip-kernel/linux-cip) —— `4.19.325-cip135`
  / `-st19` 基线，以及从 `cip136` 回移的修复。
- [ReSukiSU / BakaSU](https://github.com/Baka-SU/BakaSU) —— KernelSU 分支与管理器 APK。
- [ApartTUSITU](https://github.com/ApartTUSITU) —— 本树精简自的多机型 sm8250 树。
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) —— 刷机包模板。
- [ZyCromerZ](https://github.com/ZyCromerZ/Clang) —— clang 16 工具链。

## 许可

GPL-2.0，与内核本身一致。见 [COPYING](COPYING)。
