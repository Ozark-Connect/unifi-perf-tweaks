#!/bin/bash
# build.sh: build pppoe_gro.ko for the UCG-Fiber vendor kernel 5.4.213-ui-ipq9574.
#
# Run from the repository root in a pinned debian:trixie container (cross gcc
# 14.2.0-19 = the vendor compiler). The repository is mounted read-only; the
# kernel checkout and build stay inside the container, only the result is
# written to the directory that holds the config:
#   mkdir -p ~/pppoe-gro-build
#   ssh root@<gateway-ip> 'zcat /proc/config.gz' > ~/pppoe-gro-build/config
#   docker run --rm -v "$PWD":/repo:ro -v ~/pppoe-gro-build:/out \
#     debian@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308 \
#     bash /repo/modules/pppoe-gro/build.sh /out/config
# Output: ~/pppoe-gro-build/pppoe_gro.ko and pppoe_gro.ko.sha256.
#
# The kernel tree is CodeLinaro qsdk_oss_kernel_linux-ipq-5.4 at a pinned commit
# (NHSS.QSDK.12.4.r1, 5.4.213). Ubiquiti's sk_buff carries two private fields
# that the public tree lacks; skbuff-layout-pad.patch adds placeholders so the
# struct offsets match the vendor kernel. With the same inputs (image, commit,
# config) the build is byte-for-byte reproducible.
set -euo pipefail

CONFIG="${1:?usage: build.sh CONFIG (kernel config of the gateway)}"
RESULT_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
QSDK_REPO="https://github.com/CodeLinaro-mirror/qsdk_oss_kernel_linux-ipq-5.4.git"
QSDK_COMMIT="8a567f8188c2174fec2ec9a2993fe30e5b50c61c"   # NHSS.QSDK.12.4.r1
EXPECTED_GCC="14.2.0-19"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="/work"   # inside the container; fixed so debug paths and the hash stay the same
SRC="$WORK/qsdk-5.4"
OUT="$WORK/out"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    git make gcc libc6-dev gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    bc bison flex patch libssl-dev libelf-dev python3 kmod ca-certificates >/dev/null

gcc_pkg=$(dpkg-query -W -f='${Version}' gcc-14-aarch64-linux-gnu 2>/dev/null || true)
echo "cross gcc package: ${gcc_pkg:-unknown} (vendor kernel: ${EXPECTED_GCC})"
case "$gcc_pkg" in
    "$EXPECTED_GCC"*) ;;
    *) echo "WARNING: compiler differs from the vendor build; the module may still work but will not be byte-identical." ;;
esac

if [ ! -d "$SRC/.git" ]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$QSDK_REPO"
fi
git -C "$SRC" fetch -q --depth 1 origin "$QSDK_COMMIT"
git -C "$SRC" checkout -q --force FETCH_HEAD
git -C "$SRC" clean -qfdx

cd "$SRC"
patch -p1 < "$HERE/skbuff-layout-pad.patch"
cp "$CONFIG" .config
: > .scmversion                       # no "+" suffix in the kernel release
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-ui-ipq9574"/' .config
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make -s olddefconfig
make -s -j"$(nproc)" modules_prepare
echo "kernel release: $(make -s kernelrelease)"

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$HERE/pppoe_gro.c" "$HERE/Makefile" "$OUT/"
make -s -C "$SRC" M="$OUT" modules

modinfo -F vermagic "$OUT/pppoe_gro.ko"
cp "$OUT/pppoe_gro.ko" "$RESULT_DIR/pppoe_gro.ko"
(cd "$RESULT_DIR" && sha256sum pppoe_gro.ko | tee pppoe_gro.ko.sha256)
echo "Undefined symbols (must all exist in the running kernel):"
aarch64-linux-gnu-nm -u "$OUT/pppoe_gro.ko" | awk '{print "  " $2}'
