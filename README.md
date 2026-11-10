# Xiaomi Mi 10 Ultra (cas) — MIUI kernel

Linux 4.19.325 (CIP `v4.19.325-cip135` / `-st19`) kernel for the **Xiaomi Mi 10
Ultra** (`cas`), built for **MIUI** with **ReSukiSU (BakaSU) + SuSFS** root.

This tree builds exactly one target. Every other device the upstream tree
supported, and the whole Android/GKI build plumbing that this kernel never used,
has been removed — see [What was removed](#what-was-removed).

| | |
|---|---|
| Device | Xiaomi Mi 10 Ultra (`cas`, M2007J1SC) |
| Kernel | 4.19.325, CIP `cip135` / `-st19` base |
| Target OS | MIUI |
| Root | ReSukiSU (BakaSU) with SuSFS |
| Toolchain | zyc-clang 16.0.6 |
| Output | AnyKernel3 flashable zip |

---

## Download

Grab the latest `AnyKernel3_BakaSU_*.zip` from
[Releases](../../releases/latest). It is the flashable package itself — flash it
directly from a custom recovery or a kernel manager, do **not** unzip it first.

The matching `BakaSU_*_arm64-v8a-release.apk` manager is published alongside it.

## Flash

1. Boot into a custom recovery (or use a kernel manager that accepts AnyKernel3).
2. Flash `AnyKernel3_BakaSU_<version>_<kernel-release>.zip`.
3. Reboot. Install the matching BakaSU manager APK to manage root.

The package only replaces the kernel inside `boot`; it does not touch `dtbo`,
`vendor_boot` or user data. To roll back, flash the stock `boot` image you saved
beforehand.

## Build

### GitHub Actions (recommended)

Push to `bakasu-cas`, or run the **`Build MIUI_cas_ReSukiSU-SuSFS`** workflow
manually from the Actions tab. The single job runs:

```sh
./build_kernel.sh cas ksu miui
```

and publishes the resulting AnyKernel3 zip plus the matching BakaSU manager APK
as a Release. ccache is restored and saved between runs, so only the first build
is slow.

### Locally

You need an `aarch64` clang toolchain, `make`, `bc`, `bison`, `flex`, `zip`,
`unzip` and `ccache`.

```sh
# The script expects the toolchain at $HOME/zyc-clang/bin — put yours there,
# or edit TOOLCHAIN_BIN at the top of build_kernel.sh.
mkdir -p $HOME/zyc-clang && cd $HOME/zyc-clang
curl -fLO https://github.com/ZyCromerZ/Clang/releases/download/16.0.6-20260807-release/Clang-16.0.6-20260807.tar.gz
tar -zxf Clang-16.0.6-20260807.tar.gz

cd /path/to/this/repo
./build_kernel.sh cas ksu miui
```

The zip lands in the repository root; the build tree goes to `out_miui/` (or
`out_aosp/`, one per target).

#### Arguments

```
./build_kernel.sh <device> [ksu] [miui|aosp]
```

`<device>` must be `cas` — it selects `arch/arm64/configs/cas_defconfig`, and
that is the only defconfig left in the tree. `ksu` enables ReSukiSU + SuSFS;
omitting it produces a kernel with no root. For the target OS, `miui` and `aosp`
select one; giving neither builds both, one after the other. CI always passes
`miui`.

## Configuration

`arch/arm64/configs/cas_defconfig` is the base config. `build_kernel.sh`
layers on top of it before compiling:

- **Always** — Baseband-guard (`BBG`), and the optimization level pinned to
  `-O2` so a future fragment cannot silently drop the kernel to `-Os`.
- **With `ksu`** — `KSU`, `THREAD_INFO_IN_TASK`, `KSU_SUSFS`. The hook variant
  is a Kconfig `choice`, so `KSU_TRACEPOINT_HOOK` and `KSU_MANUAL_HOOK` are
  switched off first; this 4.19 tree uses the SuSFS inline-hook variant.
- **With `miui`** — `STATIC_USERMODEHELPER_PATH=/system/bin/micd`, `XIAOMI_MIUI`,
  `MIGT`, `MIHW`, `MILLET_*`, `MIUI_ZRAM_MEMORY_TRACKING`, `BINDER_OPT`,
  `PERF_*`, `RTMM`, `BOOTUP_RECLAIM`, `MI_RECLAIM`, `OVERLAY_FS`,
  `PACKAGE_RUNTIME_INFO`, `KPERFEVENTS`, `TASK_DELAY_ACCT`, `LTO_NONE`
  (clang LTO off), `SHADOW_CALL_STACK` off, `REKERNEL` off.

The MIUI build also patches a handful of DSI panel timing tables in
`arch/arm64/boot/dts/vendor/qcom/` before compiling and restores them from a
backup afterwards, so the working tree is left clean.

## What was removed

The tree used to carry twelve Xiaomi sm8250 devices plus the full Qualcomm
reference set, and the Android/GKI build system (`AndroidKernel.mk`,
`Android.bp`, `build.config.*`, `android/`, and so on) that `build_kernel.sh`
never invoked. None of it was reachable from the `cas` build graph, so all of it
is gone:

- **Device trees** — a closure over `#include` from the four roots the build
  actually uses (`kona.dts`, `kona-v2.dts`, `kona-v2.1.dts`,
  `cas-sm8250-overlay.dts`) leaves 107 of the 1055 files under
  `arch/arm64/boot/dts/vendor/qcom`. The other 948, the 27 generic SoC trees
  under `arch/arm64/boot/dts/` that the Makefile never descends into, the stale
  `vendor/xiaomi/` duplicate, and `vendor/bindings/` (every include resolves
  through `<dt-bindings/...>` instead) are removed.
- **Configs** — only `cas_defconfig`, `cas_stock-defconfig` and the generic
  `defconfig` fallback remain. The other devices' defconfigs, `AOSP_defconfig/`
  and `configs/vendor/` were referenced only by `kernel/Makefile`'s per-device
  `config_data.gz` rules, by a python2 `scripts/build-all.py` nothing calls, and
  by `scripts/update_defconfig` pointing at a directory that did not exist.
- **Build system** — everything Android/GKI, plus `buildall.sh` (a thirteen
  device loop; CI has always called `build_kernel.sh cas ksu miui` directly).

The three Makefiles were reduced to match: `vendor/qcom/Makefile` keeps only the
`cas` stanza (`kona.dtb`, `kona-v2.dtb` and `kona-v2.1.dtb` are still produced
through their `dtbo-base` dependency), `arch/arm64/boot/dts/Makefile` drops the
now-empty SoC list, and `kernel/Makefile` embeds `cas_stock-defconfig`
unconditionally for MIUI.

## Kernel changes on top of CIP

Two rounds of work sit on top of the upstream 4.19.325 tree.

**Ported from `PORTING_GUIDE.md`** — an Android-relevant lockdown pass:
adreno ioctl size check, qrtr overflow, binder transaction use-after-free,
audit/selinux/f2fs/netfilter/net-sched fixes, audio compress locking, USB OTG
null deref, cpufreq hotplug race, sdcardfs negative dentry, camera request
manager UAF / CCI out-of-bounds / JPEG bounds, and per-domain GIDs for
`Android/data` and `Android/obb`.

**Backported from `v4.19.325-cip136`** (`-st20`) — 25 further fixes, each
verified reachable against the actual compiled configuration rather than the
defconfig:

- out-of-bounds and info-leak fixes: rndis query, net1080 pad byte,
  `nf_conntrack_irc` DCC parsing, ebtables match names, uvc SEND_RESPONSE
  length, igmp multicast hash teardown, `af_packet` ring restart, evdev
  `input_event` padding, evdev `array_index_nospec`
- reference-counting and validation: qrtr `init_net` restriction, xt_nat family
  check, nf_log MAC header, IPv6 MLD timer UAF, IPv6 FIB dump cursor, cls_bpf
  rollback recursion, xt_hashlimit rate-match, f_fs read buffer lifetime
- SCTP: `auth_hmacs` sizing, embedded address parameter length, stale-cookie
  error cause, stream reset counts, expired cookie vtag match, auth chunk
  capacity

Plus two USB fixes: `msm-ssusb-qmp` no longer touches the DP-combo PHY's
registers on the USB3-only PHY (which exposes only `0x1000` bytes and oopses),
and `xhci-plat` skips port accesses across a runtime-suspended system PM.

Everything was validated by a full CI build; no runtime testing was done for
the individual patches.

## Credits

- [CIP](https://gitlab.com/cip-project/cip-kernel/linux-cip) — `4.19.325-cip135`
  / `-st19` base and the fixes backported from `cip136`.
- [ReSukiSU / BakaSU](https://github.com/Baka-SU/BakaSU) — KernelSU fork and the
  manager APK.
- [ApartTUSITU](https://github.com/ApartTUSITU) — the multi-device sm8250 tree
  this one was pruned from.
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) — the flashable zip
  template.
- [ZyCromerZ](https://github.com/ZyCromerZ/Clang) — clang 16 toolchain.

## License

GPL-2.0, as the kernel itself. See [COPYING](COPYING).
