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
# Reproducible build metadata
# ----------------------------------------------------
# scripts/mkcompile_h bakes `date` into include/generated/compile.h, which
# every object that includes <generated/compile.h> picks up.  Pinning the
# timestamp and identity keeps that header byte-identical between runs so
# ccache can serve those objects from cache instead of rebuilding them.
# An explicitly provided value also makes the build reproducible.
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Thu Jan  1 00:00:00 UTC 2026}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-builder}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-ci}"

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"

# ==========================================
# DTS backup / restore
# ==========================================
# build_target() rewrites the MIUI display panel dtsi files in place and then
# puts the tree back.  That restore used to be plain sequential code after
# `make`, so any build failure (set -e exits immediately) left
# arch/arm64/boot/dts/vendor/qcom/ rewritten and .dts.bak.<os>/ behind.  The
# next run then did `cp -a vendor/qcom .dts.bak.miui`, which nests the source
# inside the existing backup (bak/qcom/...) and the restore promoted that
# nested tree to be the real dts directory.  Track the backup explicitly and
# restore from an EXIT trap so it also runs on failure.
DTS_BACKUP_ACTIVE=0
DTS_SOURCE_PATH=""
DTS_BACKUP_PATH=""

restore_dts_backup() {
    if [ "${DTS_BACKUP_ACTIVE}" -eq 1 ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE_PATH}"
        mv "${DTS_BACKUP_PATH}" "${DTS_SOURCE_PATH}"
        DTS_BACKUP_ACTIVE=0
    fi
}
trap restore_dts_backup EXIT

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
# BakaSU version code
# ==========================================
# kernel/Kbuild bakes `30000 + <commits in the BakaSU checkout> + 700` into the
# module as KSU_VERSION and also prints it as "-- BakaSU version code: <n>".
# Read back the value the build actually used so the package name can never
# drift from the kernel it ships.
detect_baksu_version_code() {
    local OUT_DIR="$1"
    local CODE=""
    local COUNT=""

    # 1) Preferred: the -DKSU_VERSION=... flag recorded on the compiler command
    #    line that produced drivers/kernelsu objects.
    CODE=$(grep -rhoE -- '-DKSU_VERSION=[0-9]+' "${OUT_DIR}/drivers/kernelsu" 2>/dev/null | head -n 1 | cut -d= -f2 || true)
    if [ -z "${CODE}" ]; then
        # Object dir layout is not guaranteed (symlinked drivers/kernelsu), so
        # fall back to the whole build tree before giving up.
        CODE=$(grep -rhoE -- '-DKSU_VERSION=[0-9]+' "${OUT_DIR}" 2>/dev/null | head -n 1 | cut -d= -f2 || true)
    fi

    # 2) Fallback: recompute it the way kernel/Kbuild does.
    if [ -z "${CODE}" ] && [ -d "${KERNEL_DIR}/KernelSU/.git" ]; then
        COUNT=$(git -C "${KERNEL_DIR}/KernelSU" rev-list --count HEAD 2>/dev/null || true)
        if [ -n "${COUNT}" ]; then
            CODE=$((30000 + COUNT + 700))
        fi
    fi

    # 3) KernelSU was not requested: keep the mandatory prefix and say so.
    if [ -z "${CODE}" ]; then
        CODE="NoKernelSU"
    fi

    printf '%s' "${CODE}"
}

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
        # cp -a into an existing directory nests the source inside it, so a
        # leftover backup from an earlier failed run has to go first.
        rm -rf "${DTS_BACKUP}"
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        DTS_SOURCE_PATH="${KERNEL_DIR}/${DTS_SOURCE}"
        DTS_BACKUP_PATH="${KERNEL_DIR}/${DTS_BACKUP}"
        DTS_BACKUP_ACTIVE=1
        
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

    # Restore DTS backup for MIUI (also runs from the EXIT trap on failure)
    restore_dts_backup

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
        
        # ------------------------------------------------------------
        # Package name
        # ------------------------------------------------------------
        # Everything under anykernel/ (META-INF/, anykernel.sh, tools/,
        # kernels/, ramdisk/, ...) already is the complete AnyKernel3
        # installer, so the single zip built below is the flashable package
        # itself: copy it to the phone and flash it, nothing gets wrapped
        # around it and no second packaging pass runs afterwards.
        #
        #   AnyKernel3_BakaSU_<version code>_<kernel release>.zip
        #     <version code>   numeric BakaSU version code, without the "v"
        #     <kernel release> include/config/kernel.release, verbatim
        local KSU_VERSION_CODE
        KSU_VERSION_CODE=$(detect_baksu_version_code "${OUT_DIR}")
        # The requested name carries a bare number.  A KernelSU build that
        # cannot report one means the detection above broke, and shipping a
        # wrongly named package would be worse than failing loudly.
        if [ -z "${KSU_VERSION_CODE}" ]; then
            echo "[-] Could not determine the BakaSU version code; refusing to name the package."
            exit 1
        fi
        if [ "$ENABLE_KSU" -eq 1 ] && ! echo "${KSU_VERSION_CODE}" | grep -qE '^[0-9]+$'; then
            echo "[-] BakaSU version code '${KSU_VERSION_CODE}' is not numeric; refusing to name the package."
            exit 1
        fi

        local KERNEL_RELEASE_FILE="${OUT_DIR}/include/config/kernel.release"
        if [ ! -f "${KERNEL_RELEASE_FILE}" ]; then
            echo "[-] ${KERNEL_RELEASE_FILE} is missing; cannot name the package."
            exit 1
        fi
        local KERNEL_RELEASE
        KERNEL_RELEASE=$(sed -n 1p "${KERNEL_RELEASE_FILE}" | tr -d '\r')
        if [ -z "${KERNEL_RELEASE}" ]; then
            echo "[-] ${KERNEL_RELEASE_FILE} is empty; cannot name the package."
            exit 1
        fi
        # Spaces, slashes and anything else a file name cannot carry.
        local KERNEL_RELEASE_SAFE="${KERNEL_RELEASE//[^A-Za-z0-9._+-]/_}"

        local ZIP_FILENAME="AnyKernel3_BakaSU_${KSU_VERSION_CODE}_${KERNEL_RELEASE_SAFE}.zip"

        # A `both` build compiles two targets from the same tree, so the name
        # above can repeat.  Keep the requested name for the first target and
        # disambiguate the second one instead of silently overwriting it.
        if [ -e "${ZIP_FILENAME}" ]; then
            echo "[!] ${ZIP_FILENAME} already exists, appending the target name."
            ZIP_FILENAME="AnyKernel3_BakaSU_${KSU_VERSION_CODE}_${KERNEL_RELEASE_SAFE}-${OS_TYPE}.zip"
        fi

        echo "[*] Packaging ${OS_TYPE} into ${ZIP_FILENAME} ..."
        pushd anykernel > /dev/null
        zip -r9 "${ZIP_FILENAME}" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "${ZIP_FILENAME}" ../
        popd > /dev/null

        # The zip is the deliverable, so prove it really is a flashable
        # AnyKernel3 package and not a folder of files that still needs
        # repacking.
        local ENTRY
        for ENTRY in META-INF/com/google/android/update-binary anykernel.sh tools/ak3-core.sh kernels/Image; do
            if ! unzip -Z1 "${ZIP_FILENAME}" | grep -qxF "${ENTRY}"; then
                echo "[-] ${ZIP_FILENAME} is not flashable: missing ${ENTRY}."
                exit 1
            fi
        done

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
