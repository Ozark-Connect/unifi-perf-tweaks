#!/bin/sh
# sfp-link-check.sh - Read-only SFP+ port status for UCG-Fiber / UXG-Fiber.
#
# Reports the uniphy SerDes mode and clock rate for both SFP+ ports.
# All checks are non-destructive register reads and debugfs reads.
#
# Usage:
#   ssh root@<gateway-ip> 'sh -s' < scripts/diagnostics/sfp-link-check.sh

set -u

# Uniphy base address and stride (confirmed on UCG-Fiber / UXG-Fiber, IPQ9574)
UNIPHY_BASE=0x07A00000
UNIPHY_STRIDE=0x10000
REG_SERDES_MODE=0x218

read_reg() {
    busybox devmem $(printf '0x%08X' $(( $1 + $2 ))) 32 2>/dev/null
}

decode_serdes() {
    case "$1" in
        0x00000030) echo "SGMII (1G)" ;;
        0x00000050) echo "SGMII+ (2.5G)" ;;
        0x00000070) echo "USXGMII / 10G-R" ;;
        *)          echo "unknown ($1)" ;;
    esac
}

decode_clock() {
    case "$1" in
        125000000)  echo "125 MHz (1G)" ;;
        312500000)  echo "312.5 MHz (2.5G/10G)" ;;
        *)          echo "$1 Hz" ;;
    esac
}

check_port() {
    _idx=$1
    _iface=$2
    _port=$3
    _phy_offset=$(( UNIPHY_STRIDE * _idx ))

    _reg=$(read_reg $UNIPHY_BASE $(( _phy_offset + REG_SERDES_MODE )))
    _tx_clk=$(cat /sys/kernel/debug/clk/uniphy${_idx}_gcc_tx_clk/clk_rate 2>/dev/null)
    _rx_clk=$(cat /sys/kernel/debug/clk/uniphy${_idx}_gcc_rx_clk/clk_rate 2>/dev/null)
    _link=$(ip link show "$_iface" 2>/dev/null | head -1)

    _state="DOWN"
    echo "$_link" | grep -q "state UP" && _state="UP"
    echo "$_link" | grep -q "NO-CARRIER" && _state="NO-CARRIER"

    echo "  Interface:     $_iface ($_port)"
    echo "  Link state:    $_state"
    if [ -n "$_reg" ]; then
        echo "  SerDes mode:   $(decode_serdes "$_reg")"
    else
        echo "  SerDes mode:   (devmem not available)"
    fi
    if [ -n "$_tx_clk" ]; then
        echo "  TX clock:      $(decode_clock "$_tx_clk")"
        echo "  RX clock:      $(decode_clock "$_rx_clk")"
    else
        echo "  Clock:         (debugfs not available)"
    fi
}

# Check if SGMII+ module is loaded
MODULE_STATUS="not loaded"
lsmod 2>/dev/null | grep -q force_uniphy1_sgmiiplus && MODULE_STATUS="loaded"

echo "=== SFP+ Port Status ==="
echo "  SGMII+ module: $MODULE_STATUS"
echo ""
echo "--- uniphy0 (SFP+ Port 1) ---"
check_port 0 eth5 "Port 6"
echo ""
echo "--- uniphy1 (SFP+ Port 2) ---"
check_port 1 eth6 "Port 7"
