#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
systemctl disable --now cmp100-unlock.service 2>/dev/null || true
rm -f /etc/systemd/system/cmp100-unlock.service /usr/local/sbin/cmp100-unlock /usr/local/bin/cmp100-bench /usr/local/bin/cmp100-pcie-bw /usr/local/bin/cmp100-memclk /etc/modprobe.d/cmp100-unlock.conf
systemctl daemon-reload
S=/var/lib/cmp100-unlock
if [[ -f $S/stock/ucode_load.bin ]]; then
    # Put stock firmware back in case an interrupted run left a payload active.
    cp -f $S/stock/fecs_sig.bin "$(readlink -f /lib/firmware/nvidia/gv100/gr/fecs_sig.bin)"
    cp -f $S/stock/bl.bin "$(readlink -f /lib/firmware/nvidia/gv100/acr/bl.bin)"
    cp -f $S/stock/ucode_load.bin "$(readlink -f /lib/firmware/nvidia/gv100/acr/ucode_load.bin)"
fi
rm -rf /usr/lib/cmp100-unlock
[[ ${1:-} == --purge ]] && rm -rf "$S" /etc/cmp100-unlock.conf /var/log/cmp100-unlock
echo 'cmp100-unlock removed. Cards return to stock on next reboot.'
