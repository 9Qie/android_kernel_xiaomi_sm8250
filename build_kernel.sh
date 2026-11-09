#!/bin/bash

# Exit on any error
set -e

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp]"
    echo "Example: $0 lmi"
    echo "         $0 lmi ksu"
    echo "         $0 lmi ksu miui"
    echo "         $0 lmi aosp"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    echo "[!] Please verify the device name and try again."
    exit 1
fi

ENABLE_KSU=0
TARGET_OS="both"

shift
# Parse remaining arguments loosely
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache Setup
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache_mikernel}"
export CCACHE_EXEC=$(command -v ccache)

if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found! Please install ccache first."
    exit 1
fi

# ----------------------------------------------------
# ccache tuning (kernel-aware caching)
# ----------------------------------------------------
# CCACHE_IS_KERNEL_COMPILING switches on the ECS (Effective Configuration
# State) fast path of the ccache-ECS build.  Upstream ccache falls back to
# full preprocessing whenever include/generated/autoconf.h changes, which is
# exactly what happens on nearly every config tweak; ECS records per-source
# header dependencies plus the autoconf snapshot, so an unchanged source still
# hits directly even after unrelated CONFIG_* symbols moved.
export CCACHE_IS_KERNEL_COMPILING=true
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-3G}"
# The compiler binary is byte-identical across runs and we always feed the
# same absolute toolchain path, so hashing it every invocation is pure waste.
export CCACHE_COMPILERCHECK=none
# Every CI checkout lands in the same directory but at a different absolute
# path; without BASEDIR/NOHASHDIR every object would miss.
export CCACHE_NOHASHDIR=true
export CCACHE_BASEDIR="${KERNEL_DIR}"
# A fresh git checkout rewrites every mtime, and __DATE__/__TIME__ bake the
# build moment into a few objects.  Both would invalidate the whole cache on
# each run, so have ccache trust content instead of timestamps here.
export CCACHE_SLOPPINESS="time_macros,include_file_ctime,include_file_mtime,file_stat_matches,system_headers,locale"
# Objects compress well; keeps the cache inside the GitHub cache size budget.
ccache -o compression=true >/dev/null 2>&1 || true
ccache -M "$CCACHE_MAXSIZE" >/dev/null 2>&1 || true

# ----------------------------------------------------
# Compiler optimisation level
# ----------------------------------------------------
# init/Kconfig defaults the "Compiler optimization level" choice to
# CC_OPTIMIZE_FOR_PERFORMANCE, which is what makes the kernel build with -O2
# instead of -Os.  This tree's Makefile gates clang's -O3 branch on cc-name,
# a variable that is never defined on 4.19, so the -O2 branch is also what
# actually applies; pinning both keeps it that way and keeps -O2 last on the
# command line (KCFLAGS is appended after the Makefile's own -O flags).
export KCFLAGS="${KCFLAGS:-} -O2 -pipe"

# ----------------------------------------------------
# Build metadata masquerade
# ----------------------------------------------------
# The kernels shipped from this repo must report, unconditionally,
#
#     uname -r -> 4.19.157-perf-g19050d39787c
#     uname -v -> #1 SMP PREEMPT Wed Jun 5 13:37:11 UTC 2024
#
# while the tree itself keeps building whatever sources it really has.  Both
# strings are pure build metadata, so they are substituted here, at build
# time, and nothing else is touched: no kernel source, no config, no build
# rule is changed beyond what is listed below, and every rewrite is undone
# when this script exits.
#
# `uname -r` comes from include/config/kernel.release, which the top Makefile
# regenerates on every run as
#     $(KERNELVERSION)$(sh scripts/setlocalversion ...)
# i.e. the VERSION/PATCHLEVEL/SUBLEVEL triple from the Makefile plus whatever
# scripts/setlocalversion collects.  Hence four things have to line up:
#   1. the triple is rewritten in place (Makefile is restored on exit);
#   2. CONFIG_LOCALVERSION is emptied per target, which drops the
#      "-aptusitu-perf" suffix that cas_defconfig carries;
#   3. CONFIG_LOCALVERSION_AUTO is turned off, otherwise setlocalversion
#      appends its own `git describe` output after our suffix;
#   4. LOCALVERSION is exported, which setlocalversion appends verbatim and
#      which also suppresses the "+" dirty marker.
# On top of that the stray localversion-* files in the tree root have to be
# hidden for the duration of the build: setlocalversion cats every one of them
# into the release string.  They are moved aside (not deleted) and moved back
# on exit.
#
# `uname -v` comes from scripts/mkcompile_h, which formats
#     "#$KBUILD_BUILD_VERSION $CONFIG_FLAGS $KBUILD_BUILD_TIMESTAMP"
# so pinning the build number and the timestamp is enough -- SMP and PREEMPT
# already come from the arm64 Kconfig defaults and cas_defconfig.
SPOOF_KERNEL_TRIPLE="4.19.157"
SPOOF_LOCAL_VERSION="-perf-g19050d39787c"
SPOOF_KERNEL_RELEASE="${SPOOF_KERNEL_TRIPLE}${SPOOF_LOCAL_VERSION}"
SPOOF_BUILD_NUMBER=1
# mkcompile_h expands this unquoted, so runs of whitespace collapse: passing
# the already-normalised single-space form keeps the assertion below exact.
SPOOF_BUILD_TIMESTAMP="Wed Jun 5 13:37:11 UTC 2024"

export KBUILD_BUILD_VERSION="${SPOOF_BUILD_NUMBER}"
export KBUILD_BUILD_TIMESTAMP="${SPOOF_BUILD_TIMESTAMP}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-builder}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-ci}"

SPOOF_VERSION_MAJOR="${SPOOF_KERNEL_TRIPLE%%.*}"
SPOOF_VERSION_REST="${SPOOF_KERNEL_TRIPLE#*.}"
SPOOF_VERSION_MINOR="${SPOOF_VERSION_REST%%.*}"
SPOOF_VERSION_PATCH="${SPOOF_VERSION_REST#*.}"
SPOOF_BACKUP_DIR=".spoof-backup"

restore_build_metadata() {
    local f
    for f in "${SPOOF_BACKUP_DIR}"/localversion-*; do
        [ -e "$f" ] || continue
        mv -f "$f" "$(basename "$f")"
    done
    if [ -f "${SPOOF_BACKUP_DIR}/Makefile" ]; then
        mv -f "${SPOOF_BACKUP_DIR}/Makefile" Makefile
    fi
    rmdir "${SPOOF_BACKUP_DIR}" 2>/dev/null || true
}
trap restore_build_metadata EXIT

mkdir -p "${SPOOF_BACKUP_DIR}"
cp -a Makefile "${SPOOF_BACKUP_DIR}/Makefile"
sed -i \
    -e "s/^VERSION = .*/VERSION = ${SPOOF_VERSION_MAJOR}/" \
    -e "s/^PATCHLEVEL = .*/PATCHLEVEL = ${SPOOF_VERSION_MINOR}/" \
    -e "s/^SUBLEVEL = .*/SUBLEVEL = ${SPOOF_VERSION_PATCH}/" \
    Makefile
for f in localversion-*; do
    [ -e "$f" ] || continue
    mv -f "$f" "${SPOOF_BACKUP_DIR}/"
done
export LOCALVERSION="${SPOOF_LOCAL_VERSION}"
echo "[*] Build metadata pinned: ${SPOOF_KERNEL_RELEASE} / #${SPOOF_BUILD_NUMBER} ${SPOOF_BUILD_TIMESTAMP}"

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"

# ==========================================
# KernelSU Setup
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing KernelSU (BakaSU) Setup"
    echo "==========================================="
    echo "[*] Downloading and running BakaSU remote setup script..."
    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash
    echo "[+] KernelSU setup finished."
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Downloading and running Baseband-guard remote setup script..."
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel
echo "[+] AnyKernel3 cloned successfully."
echo "[*] Adjusting AnyKernel3..."
sed -i "s/^device\.name1=.*/device.name1=${DEVICE_NAME}/" anykernel/anykernel.sh
# The upstream anykernel.sh only recognises a handful of exact MIUI flavours
# (missi-user, missi_phone_cn-user, qssi-user, ...).  HyperOS and repacked MIUI
# builds ship other flavours, so they fall through to the `*)` branch and the
# installer announces "AOSP ROM detected" on a MIUI device.  This branch is the
# one this repo builds, so make it the fallback and let the miui-* patterns win
# over it explicitly.
sed -i 's|^\([[:space:]]*\)\*) os="aosp"; os_string="AOSP ROM";;|\1missi*) os="miui"; os_string="MIUI ROM";;\n\1*) os="miui"; os_string="MIUI/HyperOS ROM";;|' anykernel/anykernel.sh
grep -n 'os=' anykernel/anykernel.sh | sed -n '1,12p'
echo "[+] AnyKernel3 adjusted successfully."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Starting Kernel Compilation for ${DEVICE_NAME} (Target: $OS_TYPE)"
    echo "==========================================="
    
    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"
    
    local MAKE_OPTS=(
        -j"$(nproc)"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    )

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        
        # Apply MIUI specific sed patches to dts
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true

        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true

        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true

        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # ----------------------------------------------------
    # Configuration tweaks
    # ----------------------------------------------------
    
    # 1. Baseband-guard configuration (Always applied)
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    # 1a. Build metadata masquerade (Always applied)
    # Companion of the "Build metadata masquerade" block near the top of this
    # script: that block pins LOCALVERSION and the Makefile version triple, this
    # one clears the per-target config that would otherwise be appended to the
    # release string by scripts/setlocalversion.
    #   - CONFIG_LOCALVERSION carries "-aptusitu-perf" in cas_defconfig;
    #   - CONFIG_LOCALVERSION_AUTO defaults to y in init/Kconfig and would add
    #     `git describe` output after our suffix.
    echo "[*] Pinning kernel release to ${SPOOF_KERNEL_RELEASE}..."
    scripts/config --file "${OUT_DIR}/.config" --set-str LOCALVERSION ""
    scripts/config --file "${OUT_DIR}/.config" -d LOCALVERSION_AUTO

    # 1b. Compiler optimisation level (Always applied)
    # Pin the "Compiler optimization level" choice to CC_OPTIMIZE_FOR_PERFORMANCE
    # (-O2).  The Kconfig default already is -O2, but pinning it here means a
    # future defconfig or fragment that ships CC_OPTIMIZE_FOR_SIZE cannot
    # silently downgrade the kernel to -Os.
    echo "[*] Pinning compiler optimization level to -O2..."
    scripts/config --file "${OUT_DIR}/.config" \
        -e CC_OPTIMIZE_FOR_PERFORMANCE \
        -d CC_OPTIMIZE_FOR_SIZE

    # 2. KernelSU configurations
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting KernelSU (BakaSU) & SUSFS configurations..."
        # KSU_TRACEPOINT_HOOK / KSU_MANUAL_HOOK / KSU_SUSFS are members of a
        # Kconfig "choice" and are mutually exclusive.  The choice defaults to
        # KSU_TRACEPOINT_HOOK (GKI2 only), so it has to be explicitly disabled
        # before enabling the SUSFS inline-hook variant used on this 4.19 tree.
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e THREAD_INFO_IN_TASK \
            -d KSU_TRACEPOINT_HOOK \
            -d KSU_MANUAL_HOOK \
            -e KSU_SUSFS
    fi

    # 3. MIUI configurations
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -e MILLET_CGROUP \
            -e MILLET_SIG \
            -e MILLET_BINDER \
            -e MILLET_PKG \
            -e MILLET_BINDER_GKI \
            -e MILLET_CORE \
            -e MILLET_HS \
            -e BINDER_PRIO \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    # 4. AOSP configurations
    if [ "$OS_TYPE" == "aosp" ]; then
        echo "[*] Injecting AOSP specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e REKERNEL \
            -e REKERNEL_NETWORK
    fi

    # We always need to re-evaluate dependencies because BBG is injected unconditionally
    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    # ----------------------------------------------------
    # Compilation
    # ----------------------------------------------------
    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}" 

    # ----------------------------------------------------
    # Build metadata verification
    # ----------------------------------------------------
    # Fail loudly here rather than shipping a zip whose uname -r / uname -v
    # differ from the pinned values.  include/generated/utsrelease.h feeds
    # UTS_RELEASE (uname -r), include/generated/compile.h feeds UTS_VERSION
    # (uname -v); both are generated fresh on every build.
    echo "[*] Verifying pinned build metadata..."
    local UTSRELEASE_H="${OUT_DIR}/include/generated/utsrelease.h"
    local COMPILE_H="${OUT_DIR}/include/generated/compile.h"
    local IMAGE_BIN="${OUT_DIR}/arch/arm64/boot/Image"

    if ! grep -qxF "#define UTS_RELEASE \"${SPOOF_KERNEL_RELEASE}\"" "${UTSRELEASE_H}"; then
        echo "[-] UTS_RELEASE mismatch, expected \"${SPOOF_KERNEL_RELEASE}\", got:"
        grep "UTS_RELEASE" "${UTSRELEASE_H}" || true
        exit 1
    fi
    if ! grep -qxF "#define UTS_VERSION \"#${SPOOF_BUILD_NUMBER} SMP PREEMPT ${SPOOF_BUILD_TIMESTAMP}\"" "${COMPILE_H}"; then
        echo "[-] UTS_VERSION mismatch, expected \"#${SPOOF_BUILD_NUMBER} SMP PREEMPT ${SPOOF_BUILD_TIMESTAMP}\", got:"
        grep "UTS_VERSION" "${COMPILE_H}" || true
        exit 1
    fi
    # init/version.c builds linux_banner as
    #   "Linux version " UTS_RELEASE " (" USER "@" HOST ") (" COMPILER ") " UTS_VERSION
    # so both pinned strings have to show up contiguously in the image itself,
    # not merely in the generated headers.
    if ! grep -aqF "Linux version ${SPOOF_KERNEL_RELEASE}" "${IMAGE_BIN}"; then
        echo "[-] ${IMAGE_BIN} does not embed \"Linux version ${SPOOF_KERNEL_RELEASE}\""
        exit 1
    fi
    if ! grep -aqF "#${SPOOF_BUILD_NUMBER} SMP PREEMPT ${SPOOF_BUILD_TIMESTAMP}" "${IMAGE_BIN}"; then
        echo "[-] ${IMAGE_BIN} does not embed \"#${SPOOF_BUILD_NUMBER} SMP PREEMPT ${SPOOF_BUILD_TIMESTAMP}\""
        exit 1
    fi
    echo "[+] Build metadata verified: ${SPOOF_KERNEL_RELEASE} / #${SPOOF_BUILD_NUMBER} SMP PREEMPT ${SPOOF_BUILD_TIMESTAMP}"

    # Restore DTS backup for MIUI
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"

        echo "[*] Packaging to AnyKernel3 ($OS_TYPE)..."
        # AnyKernel3's anykernel.sh does `mv $home/kernels/Image $home/Image`,
        # i.e. it expects the payload directly under kernels/ at the zip root.
        # Nesting it one level deeper (kernels/<os>/Image) made that mv fail
        # silently, and flash_boot() then repacked the *stock* kernel from the
        # boot image, so flashing succeeded but the kernel never changed.
        rm -rf anykernel/kernels/*
        mkdir -p anykernel/kernels

        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/Image"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/dtb"

        if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
            cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/dtbo.img"
        fi
        
        # 确定 ZIP 文件名
        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="ReSukiSU-SuSFS"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
        
        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null
        
        echo "[+] $OS_TYPE kernel binaries successfully packed into: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

# ==========================================
# Execute builds based on target OS
# ==========================================
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi

if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] All requested builds completed!"
