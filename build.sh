#!/bin/bash
set -euo pipefail

# ============================================================================
# Sheng Kernel Build
# ============================================================================
# Usage: ./build.sh <config-file> [kernel-source-dir]
#
#   config-file       : Path to kernel .config (required)
#   kernel-source-dir : Path to kernel source tree (default: current directory)
#
# Outputs (placed in ./out/):
#   linux-xiaomi-sheng.deb         - Kernel + modules Debian package
#   boot_sheng_dualboot.img        - Boot image (root=PARTLABEL=linux)
#   boot_sheng_singleboot.img      - Boot image (root=PARTLABEL=userdata)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/out"

# ---- Parse arguments -------------------------------------------------------
CONFIG_FILE="${1:?Usage: $0 <config-file> [kernel-source-dir]}"
KERNEL_SRC="${2:-$(pwd)}"

if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "Error: config file not found: $CONFIG_FILE"
	exit 1
fi

if [[ ! -d "$KERNEL_SRC" ]]; then
	echo "Error: kernel source directory not found: $KERNEL_SRC"
	exit 1
fi

CONFIG_FILE="$(realpath "$CONFIG_FILE")"
KERNEL_SRC="$(realpath "$KERNEL_SRC")"

# ---- Locate mkbootimg ------------------------------------------------------
MKBOOTIMG="${SCRIPT_DIR}/mkbootimg"

# ---- Environment: ccache + LLVM --------------------------------------------
if [ -z "${CCACHE_DIR:-}" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi
mkdir -p "$CCACHE_DIR"

export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

# ---- Show build configuration ----------------------------------------------
echo "============================================"
echo " Sheng Kernel Build"
echo "============================================"
echo "Config file : ${CONFIG_FILE}"
echo "Kernel src  : ${KERNEL_SRC}"
echo "mKbootimg   : ${MKBOOTIMG}"
echo "Output dir  : ${OUT_DIR}"
echo "Toolchain   : $(clang --version | head -1)"
echo "ccache      : $(ccache --version | head -1)"
echo "============================================"

# ---- Prepare output directory ----------------------------------------------
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# ---- Build kernel ----------------------------------------------------------
cd "${KERNEL_SRC}"

echo ""
echo "[1/4] Configuring kernel..."
cp "${CONFIG_FILE}" .config

# Ensure ccache knows about this build
ccache -z >/dev/null

echo "[2/4] Building kernel (using $(nproc) jobs)..."
make -j"$(nproc)" ARCH=arm64 CC="ccache clang" LLVM=1

_kernel_version="$(make kernelrelease -s)"
echo "Kernel version: ${_kernel_version}"

# ---- Create Debian package structure ---------------------------------------
echo "[3/4] Packaging kernel modules..."

PKGDIR="${OUT_DIR}/linux-xiaomi-sheng"
mkdir -p "${PKGDIR}/boot"
mkdir -p "${PKGDIR}/DEBIAN"

cat > "${PKGDIR}/DEBIAN/control" << EOF
Package: linux-xiaomi-sheng
Version: ${_kernel_version}
Architecture: arm64
Maintainer: ianchb <i@4t.pw>
Section: kernel
Description: Kernel and Modules for Xiaomi Pad 6s Pro
EOF

# Install kernel images
install -Dm644 arch/arm64/boot/Image.gz \
	"${PKGDIR}/boot/Image.gz"

install -Dm644 arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb \
	"${PKGDIR}/boot/sm8550-xiaomi-sheng.dtb"

install -Dm644 .config \
	"${PKGDIR}/boot/config-${_kernel_version}"

install -Dm644 System.map \
	"${PKGDIR}/boot/System.map-${_kernel_version}"

# Install kernel modules
make -j"$(nproc)" ARCH=arm64 CC="ccache clang" LLVM=1 \
	INSTALL_MOD_PATH="${PKGDIR}" modules_install

# Remove symlinks to build/source trees (not needed on target)
rm -rf "${PKGDIR}/lib/modules/"*"/build" \
       "${PKGDIR}/lib/modules/"*"/source"

# Build .deb package
dpkg-deb --build --root-owner-group "${PKGDIR}" "${OUT_DIR}/linux-xiaomi-sheng.deb"
echo "  -> ${OUT_DIR}/linux-xiaomi-sheng.deb"

# ---- Create boot images ----------------------------------------------------
echo "[4/4] Creating boot images..."

cat arch/arm64/boot/Image.gz \
    arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb \
    > "${OUT_DIR}/Image.gz-dtb_sheng"

install -Dm644 "${OUT_DIR}/Image.gz-dtb_sheng" \
	"${PKGDIR}/boot/Image.gz-dtb_sheng"

# Dual-boot image (root=PARTLABEL=linux)
"${MKBOOTIMG}" \
	--kernel "${OUT_DIR}/Image.gz-dtb_sheng" \
	--cmdline "root=PARTLABEL=linux" \
	--base 0x00000000 \
	--kernel_offset 0x00008000 \
	--tags_offset 0x01e00000 \
	--pagesize 4096 \
	--id \
	-o "${OUT_DIR}/boot_sheng_dualboot.img"
echo "  -> ${OUT_DIR}/boot_sheng_dualboot.img"

# Single-boot image (root=PARTLABEL=userdata)
"${MKBOOTIMG}" \
	--kernel "${OUT_DIR}/Image.gz-dtb_sheng" \
	--cmdline "root=PARTLABEL=userdata" \
	--base 0x00000000 \
	--kernel_offset 0x00008000 \
	--tags_offset 0x01e00000 \
	--pagesize 4096 \
	--id \
	-o "${OUT_DIR}/boot_sheng_singleboot.img"
echo "  -> ${OUT_DIR}/boot_sheng_singleboot.img"

# ---- ccache stats ----------------------------------------------------------
echo ""
echo "ccache statistics:"
ccache -s

# ---- Summary ---------------------------------------------------------------
echo ""
echo "============================================"
echo " Build Complete!"
echo "============================================"
echo "Artifacts:"
echo "  $(du -h "${OUT_DIR}/linux-xiaomi-sheng.deb" | cut -f1)  linux-xiaomi-sheng.deb"
echo "  $(du -h "${OUT_DIR}/boot_sheng_dualboot.img" | cut -f1)  boot_sheng_dualboot.img"
echo "  $(du -h "${OUT_DIR}/boot_sheng_singleboot.img" | cut -f1)  boot_sheng_singleboot.img"
echo "============================================"
