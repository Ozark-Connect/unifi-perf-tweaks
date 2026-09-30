# kmod-cross: cross-compilation environment for the SGMII+ kernel modules
#
# Prepares a Linux 5.4.213 kernel tree (matching UniFi OS's
# "5.4.213-ui-ipq9574") from CodeLinaro's public IPQ kernel tree, then
# builds modules/force-uniphy{1,2}-sgmiiplus against it using the
# router's own .config.
#
# Kernel source: https://git.codelinaro.org/clo/qsdk/oss/kernel/linux-ipq-5.4
# (Qualcomm's public QSDK kernel tree, hosted on CodeLinaro - the official
# successor to Code Aurora Forum). Tag NHSS.QSDK.12.2.r7 is VERSION=5
# PATCHLEVEL=4 SUBLEVEL=213, confirmed via its Makefile.
#
# This gives correct kernel headers / UAPI / Kconfig plumbing for the exact
# point release UniFi OS ships. It does NOT need to build a bootable image
# or include IPQ9574-specific SoC drivers (clock/pinctrl/ESS/uniphy) - the
# module only links against qca-ssdk.ko's exported symbols and resolves the
# rest via kallsyms at load time, so all `modules_prepare` needs is a
# correctly versioned tree plus the router's real .config.
#
# BUILD:  docker build -t sgmiiplus-kbuild build/kmod-cross
# RUN:    see build/kmod-cross/README.md

FROM debian:11

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        git \
        ca-certificates \
        wget \
        xz-utils \
        rsync \
        python3 \
        cpio \
        kmod \
    && rm -rf /var/lib/apt/lists/*

ARG KERNEL_REPO=https://git.codelinaro.org/clo/qsdk/oss/kernel/linux-ipq-5.4.git
ARG KERNEL_REF=NHSS.QSDK.12.2.r7
ARG KERNEL_VERSION=5.4.213

ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV KDIR=/work/linux

WORKDIR /work

# Shallow-clone just the tagged revision - full history is ~900k commits.
RUN git clone --depth 1 --branch "${KERNEL_REF}" "${KERNEL_REPO}" "${KDIR}" \
    && grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) =' "${KDIR}/Makefile" \
    && v=$(awk '/^VERSION =/{print $3}' "${KDIR}/Makefile") \
    && p=$(awk '/^PATCHLEVEL =/{print $3}' "${KDIR}/Makefile") \
    && s=$(awk '/^SUBLEVEL =/{print $3}' "${KDIR}/Makefile") \
    && echo "Checked out kernel ${v}.${p}.${s}" \
    && [ "${v}.${p}.${s}" = "${KERNEL_VERSION}" ] || \
       (echo "ERROR: checked-out kernel ${v}.${p}.${s} != expected ${KERNEL_VERSION}" && exit 1)

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
