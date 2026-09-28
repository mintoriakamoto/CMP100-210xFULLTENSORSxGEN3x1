#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# cmp100-unlock installer: builds the hook for the running kernel, derives the
# signed-ACR payloads from your stock firmware (verified by hash), installs the
# unlock script + systemd unit, and (optionally) enables it at boot.
#
#   sudo ./install.sh              install + enable boot unit
#   sudo ./install.sh --no-enable  install only
#   sudo ./install.sh --run        install, enable, and unlock right now
#   ./install.sh --help            show this text
set -Eeuo pipefail
for a in "$@"; do case $a in -h|--help) sed -n '3,10p' "$0"; exit 0;; esac; done

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=/var/lib/cmp100-unlock
LIB_DIR=/usr/lib/cmp100-unlock
CONF=/etc/cmp100-unlock.conf
FW_DIR=/lib/firmware/nvidia/gv100
FW_FECS=$FW_DIR/gr/fecs_sig.bin
FW_BL=$FW_DIR/acr/bl.bin
FW_UCODE=$FW_DIR/acr/ucode_load.bin
ENABLE=1; RUN=0
for a in "$@"; do case $a in --no-enable) ENABLE=0;; --run) RUN=1;; *) echo "unknown arg $a" >&2; exit 2;; esac; done

TMP=$(mktemp -d); trap 'rm -rf -- "$TMP"' EXIT
log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die 'run as root'
KVER=$(uname -r)

# ---- packages ----
missing=()
command -v make >/dev/null && command -v gcc >/dev/null || missing+=(build-essential)
[[ -d /lib/modules/$KVER/build ]] || missing+=("linux-headers-$KVER")
command -v busybox >/dev/null || missing+=(busybox)
command -v setpci >/dev/null || missing+=(pciutils)
command -v fuser >/dev/null || missing+=(psmisc)
command -v zstd >/dev/null || missing+=(zstd)
command -v python3 >/dev/null || missing+=(python3)
command -v nvidia-smi >/dev/null || die 'nvidia-smi not found: install the proprietary NVIDIA driver first (550.x tested)'
if [[ -r /proc/driver/nvidia/version ]]; then
    grep -q 'Open Kernel Module' /proc/driver/nvidia/version && die 'nvidia open kernel module detected: Volta needs the proprietary flavour (nvidia-driver-5xx, not -open)'
    log "nvidia: $(head -1 /proc/driver/nvidia/version | awk '{print $8}') (tested: 550.163.01)"
fi
if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
    log 'WARNING: Secure Boot is enabled; the unsigned hook will not load unless you sign it with your MOK'
fi
KGCC=$(grep -oE 'gcc-[0-9]+|gcc \(.*\) [0-9]+' /proc/version | grep -oE '[0-9]+' | head -1 || true)
if [[ -n $KGCC ]] && command -v "gcc-$KGCC" >/dev/null && [[ $(gcc -dumpversion | cut -d. -f1) != "$KGCC" ]]; then
    export CC=gcc-$KGCC; log "kernel built with gcc-$KGCC; using CC=$CC for the hook"
fi
if (( ${#missing[@]} )); then
    if command -v apt-get >/dev/null; then
        log "installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
        die "install these packages then rerun: ${missing[*]}"
    fi
fi

# ---- GPUs ----
found=0
for d in /sys/bus/pci/devices/*; do
    [[ $(<"$d/vendor") == 0x10de ]] || continue
    case $(<"$d/device") in 0x1d84|0x1df4) log "found CMP 100-210 $(basename "$d") ($(<"$d/device"))"; found=1;; esac
done
(( found )) || die 'no CMP 100-210 (10de:1d84 / 10de:1df4) on this machine'

# ---- firmware (decompress .zst if needed, snapshot stock) ----
for f in "$FW_FECS" "$FW_BL" "$FW_UCODE"; do
    if [[ ! -e $f && -f $f.zst ]]; then zstd -dcf "$f.zst" > "$f"; chmod 644 "$f"; log "decompressed $f"; fi
    [[ -f $f ]] || die "missing $f (apt install linux-firmware)"
done
install -d -m 0755 "$STATE_DIR/stock" "$LIB_DIR/payloads" "$LIB_DIR/src"
if [[ ! -f $STATE_DIR/stock/ucode_load.bin ]]; then
    install -m 0644 "$(readlink -f "$FW_FECS")" "$STATE_DIR/stock/fecs_sig.bin"
    install -m 0644 "$(readlink -f "$FW_BL")" "$STATE_DIR/stock/bl.bin"
    install -m 0644 "$(readlink -f "$FW_UCODE")" "$STATE_DIR/stock/ucode_load.bin"
    log "saved stock firmware to $STATE_DIR/stock"
fi

# ---- payloads (hash-checked derivation from stock) ----
python3 "$ROOT/tools/build_payloads.py" \
    --fecs "$STATE_DIR/stock/fecs_sig.bin" --bl "$STATE_DIR/stock/bl.bin" \
    --ucode "$STATE_DIR/stock/ucode_load.bin" --output "$TMP/payloads" \
    || die 'payload build failed: your stock firmware is not the tested version (see docs/PREREQUISITES.md, "Firmware baseline")'

# ---- hook ----
log "building gv100_nouveau_acr_hook for $KVER"
cp -r "$ROOT/src/." "$LIB_DIR/src/"
make -C "$LIB_DIR/src" clean >/dev/null
make -C "$LIB_DIR/src" ${CC:+CC=$CC} >/dev/null
[[ $(modinfo -F vermagic "$LIB_DIR/src/gv100_nouveau_acr_hook.ko") == "$KVER "* ]] || die 'built hook vermagic mismatch'

# ---- install ----
install -m 0644 "$TMP"/payloads/*.bin "$LIB_DIR/payloads/"
install -m 0644 "$LIB_DIR/src/gv100_nouveau_acr_hook.ko" "$LIB_DIR/"
install -m 0755 "$ROOT/sbin/cmp100-unlock" /usr/local/sbin/cmp100-unlock
install -m 0755 "$ROOT/tools/cmp100-bench" /usr/local/bin/cmp100-bench
install -m 0755 "$ROOT/tools/cmp100-pcie-bw" /usr/local/bin/cmp100-pcie-bw
install -m 0755 "$ROOT/tools/cmp100-verify" /usr/local/bin/cmp100-verify
install -m 0644 "$ROOT/systemd/cmp100-unlock.service" /etc/systemd/system/
install -m 0644 "$ROOT/modprobe.d/cmp100-unlock.conf" /etc/modprobe.d/cmp100-unlock.conf
[[ -e $CONF ]] || install -m 0644 "$ROOT/cmp100-unlock.conf" "$CONF"
sha() { sha256sum "$1" | awk '{print $1}'; }
cat > "$STATE_DIR/manifest.env" <<EOF
STOCK_FECS_SHA=$(sha "$STATE_DIR/stock/fecs_sig.bin")
STOCK_BL_SHA=$(sha "$STATE_DIR/stock/bl.bin")
STOCK_UCODE_SHA=$(sha "$STATE_DIR/stock/ucode_load.bin")
CUSTOM_FECS_SHA=$(sha "$LIB_DIR/payloads/fecs_sig.candidate-c-504.bin")
CUSTOM_BL_SHA=$(sha "$LIB_DIR/payloads/bl.load-candidate-c.bin")
CUSTOM_UCODE_SHA=$(sha "$LIB_DIR/payloads/ucode_load.tensor-success-lsb-restore.bin")
PCIE_POLICY_UCODE_SHA=$(sha "$LIB_DIR/payloads/ucode_load.pcie-policy-88610-1.bin")
PCIE_VECTOR_UCODE_SHA=$(sha "$LIB_DIR/payloads/ucode_load.pcie-vector-8872c-6.bin")
HOOK_SHA=$(sha "$LIB_DIR/gv100_nouveau_acr_hook.ko")
HOOK_KVER=$KVER
EOF
chmod 0600 "$STATE_DIR/manifest.env"

# ---- disable legacy CmpUnlocker units if present (would double-run) ----
for u in cmp100-tensor-unlock.service cmp100-pcie-gen2.service cmp100-firmware-prepare.service; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
        systemctl disable "$u" >/dev/null 2>&1 || true; log "disabled legacy $u"
    fi
done
# nouveau must never autoload; nvidia_drm must not grab the card before the unit.
systemctl daemon-reload
if (( ENABLE )); then systemctl enable cmp100-unlock.service >/dev/null; log 'enabled cmp100-unlock.service (runs once at boot)'; fi

# ---- warnings ----
if systemctl is-enabled display-manager.service >/dev/null 2>&1 || [[ $(systemctl get-default) == graphical.target ]]; then
    cat <<'EOF'

WARNING: a display manager / graphical.target is enabled. The unlock unit is
ordered before display-manager.service, so boot-time runs are fine, but any
manual run while a desktop holds the GPU will be refused. For a dedicated
compute box: sudo systemctl set-default multi-user.target
EOF
fi
cat <<EOF

Installed. Status (read-only):   sudo cmp100-unlock status
Verify the whole host:           sudo cmp100-verify
Apply now (GPUs must be idle):   sudo systemctl start cmp100-unlock; journalctl -u cmp100-unlock -b
Benchmark tensor cores:          cmp100-bench
PCIe bandwidth (Gen3 ~0.8 GB/s): cmp100-pcie-bw
Logs:                            /var/log/cmp100-unlock/
Config:                          $CONF
EOF
if (( RUN )); then systemctl start cmp100-unlock.service; journalctl -u cmp100-unlock.service -b --no-pager -o cat; fi
