# cmp100-unlock

```
                       .:-=+*##%%%%%%##*+=-:.
                   .-*%%%%%%%%%%%%%%%%%%%%%%%%*-.
                .=%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%=.
              .*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%*.
             +%%%%%%%%%%%%#*+=-::::::-=+*#%%%%%%%%%%%%+
            #%%%%%%%%%#=:.                 .:=#%%%%%%%%%#
           #%%%%%%%%+.    . : . : . : . : .   .+%%%%%%%%#
          =%%%%%%%*.    .--:.        .:--.      .*%%%%%%%=
          %%%%%%%=     :%%%%%-      -%%%%%:       =%%%%%%%
         :%%%%%%#      +% () %+    +% () %+        #%%%%%%:
         -%%%%%%+      .+%%%%+.    .+%%%%+.        +%%%%%%-
         :%%%%%%#          .          .            #%%%%%%:
          %%%%%%%=              /\                =%%%%%%%
          =%%%%%%%*.           /  \              .*%%%%%%%=
           #%%%%%%%%+.       .______.          .+%%%%%%%%#
            #%%%%%%%%%#=:.  \  ____  /      .:=#%%%%%%%%%#
             +%%%%%%%%%%%%#*+ `----' +*#%%%%%%%%%%%%%+
              .*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%*.
                .=%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%=.
                   .-*%%%%%%%%%%%%%%%%%%%%%%%%*-.
                       .:-=+*##%%%%%%##*+=-:.

         tensor gate  0x999 ---------------------> 0x888
         pcie         Gen1  ---------------------> Gen3
         HMMA         ~512 cycles ---------------> 36.8 cycles
         PCIe bw      0.19 GB/s -----------------> 0.81 GB/s
```

<p align="center"><b>cmp100-unlock</b> &nbsp;·&nbsp; 86 TFLOP/s of FP16 tensor cores, one <code>install.sh</code> away</p>

---

Boot-time Tensor-core and PCIe Gen3 unlock for the NVIDIA **CMP 100-210**: a locked-down
GV100 that becomes a cheap 16 GB Volta for local LLMs and training once unlocked
(PCI IDs `10de:1d84` and `10de:1df4`, stock proprietary driver). Gen3 is the default
since 1.1.0; the older signed-write Gen2 path is kept as a fallback.

    git clone https://github.com/mintoriakamoto/cmp100-unlock
    cd cmp100-unlock
    sudo ./install.sh --run

That is the whole procedure. One systemd oneshot runs at every boot before anything
touches the GPUs, unlocks each card, and exits. Nothing stays resident. Nothing is
flashed: no VBIOS, no eFuse. Reset or power loss puts the card back to stock.

## What you get

Measured on two `10de:1df4` cards bought already flashed with a Tesla V100 VBIOS (88.00.51.00.04),
driver 550.163.01, Ubuntu 22.04 HWE 6.8:

| | stock | unlocked |
|---|---|---|
| HMMA (`wmma m16n16k16`) dependent latency | ~512 cycles | 36.8 cycles |
| FP16 tensor throughput per card | ~6 TFLOP/s | 86.7 TFLOP/s |
| PCIe link | Gen1 x1 (2.5 GT/s) | Gen3 x1 (8 GT/s); Gen2 fallback |
| PCIe bandwidth H2D / D2H (256 MiB pinned) | 0.194 / 0.214 GB/s | 0.806 / 0.845 GB/s |

Gen3 is 4.1x the Gen1 bandwidth and 2.1x Gen2 (0.386 / 0.427 GB/s), more than the
raw 3.2x rate ratio because Gen3 uses 128b/130b encoding instead of 8b/10b.

Run `cmp100-bench` (HMMA latency / FP16 throughput) and `cmp100-pcie-bw` (host-device
copy bandwidth) after install to see the numbers on your card. Both use libcuda
directly, no CUDA toolkit required.

> **nvidia-smi will always say PCIe gen 2. The link is really Gen3.**
> The NVIDIA driver re-clamps the *capability* register when it loads and
> `nvidia-smi` reads that register, so `pcie.link.gen.current` shows 2 (or 1)
> forever. It never downshifts the trained link. The physical link speed is in
> `lspci -vv` (`LnkSta: Speed 8GT/s (strange)` — "strange" is lspci noticing the
> link is faster than the advertised cap), in
> `/sys/bus/pci/devices/<bdf>/current_link_speed` (`8.0 GT/s PCIe`), and in the
> measured ~0.8 GB/s from `cmp100-pcie-bw`. `cmp100-unlock status` prints the
> real LnkSta and a reminder line for exactly this reason.

## How it works

The card's Tensor gate is a register (`0x409664`) that only the signed ACR firmware
chain can write. `gv100_nouveau_acr_hook.ko` kprobes nouveau's ACR loader and, for
one boot of one card, swaps in a modified `ucode_load.bin` (derived at install time
from *your* stock firmware, hash-checked) that writes `0x888` into that register and
returns cleanly. The script then hands the card back to the NVIDIA driver.

The Gen1 cap on `10de:1df4` is not an eFuse but a soft clamp: four bits
`CYA_GEN2/GEN3_SPEED_OVERRIDE_{EN,VAL}` in `NV_XVE_PRIV_MISC_1` (BAR0 `0x8841c`).
The fuse words that would make the clamp permanent (`0x2157c`, `0x21580`) read 0 on
these cards. devinit latches the clamp, so clearing it only sticks *before* any
driver POSTs the card; once the link has trained at Gen3 in that window the driver
re-clamps the advertised capability but does not downshift the live link.

Stages, in order:

0. **Gen3, per card, pre-POST**: unbind `nvidia`, secondary bus reset via sysfs
   `reset`, re-enable memory decode, clear the four CYA bits in `0x8841c`
   (`0xC0346500 -> 0x00340500`; LnkCap2 goes `0x2 -> 0xE`), set target Gen3 on the
   upstream port and the endpoint (LnkCtl2), retrain from the *upstream* port (the
   endpoint's own retrain bit bounces), verify LnkSta 8 GT/s, bind `nvidia`.
   Refuses with `fused` if either fuse word is non-zero.
1. **Tensor, per card**: unbind `nvidia`, read the Tensor register (skip if already
   `0x888`); arm hook, stage payload, bind `nouveau` with `modeset=2 noaccel=1
   runpm=0`, verify `BOOT_RETURN ... function_rc=0 ... tensor_409664=0x00000888` in
   dmesg; unbind `nouveau`, restore stock firmware, remove hook, rebind `nvidia`.
   The Gen3 link survives this (`Gen3 held through Tensor stage`).
2. **Gen2 fallback**, only for a card that lost Gen3 in stage 1 or when run with
   `--gen2`: two more signed writes (`0x88610=1`, `0x8872c=6`), raise the upstream
   port's target link speed if the BIOS pinned it at Gen1, correct the XP rate field
   at `0x8c040`, pulse CHANGE_SPEED, verify 5 GT/s. Retries the retrain cycle up to
   3 times; some slots only advertise Gen2 after a driver rebind.

After a Gen3 run the NVIDIA driver re-clamps LnkCap, so `lspci` prints
`LnkSta: Speed 8GT/s (strange)` and `nvidia-smi` reports `pcie.link.gen.current` 2
forever. That is cosmetic: trust `lspci` LnkSta, sysfs `current_link_speed`, or
`cmp100-pcie-bw`. `cmp100-unlock status` prints both and says which one is real.

Every step verifies before the next. On any failure the script restores stock
firmware, removes the hook, logs, and stops. It deliberately does **not** try to
re-bind a card after a failed unbind (that wedges the device lock; a reboot is the
only safe recovery). A marker file prevents the next boot from re-running into the
same hang until you clear it or pass `--force`. Kernel cmdline `cmp100.skip`
disables the unit entirely.

The whole pass takes about 4 s per card for Gen3 and 2 s per card for Tensor: 18 s
for two cards from a locked state. On an unattended reboot both cards were Gen3 +
Tensor `0x888` 24 s after boot. The Gen2 fallback, if needed, adds 10-18 s per card.

## Requirements

Full tested spec (board, slots, driver, firmware hashes, timings): [docs/PREREQUISITES.md](docs/PREREQUISITES.md).

- CMP 100-210: `10de:1d84` or `10de:1df4`. Check with `lspci -nn | grep 10de`.
- VBIOS: tested only on cards the seller had flashed with a Tesla V100 VBIOS (88.00.51.00.04),
  which handles identity/memory but leaves Tensor and Gen1 locked, hence this tool;
  upstream validated the same technique on stock CMP VBIOS 88.00.9D.00.00. See
  docs/PREREQUISITES.md, "VBIOS note". This tool never flashes.
- Proprietary NVIDIA driver (550.163.01 tested; users report newer works). **Not**
  the open kernel module flavour: Volta is not supported there.
- `linux-firmware` providing `nvidia/gv100/{gr/fecs_sig.bin,acr/bl.bin,acr/ucode_load.bin}`
  at the tested revision (SHA-256 in `tools/build_payloads.py`). The installer refuses
  to derive payloads from any other version.
- Kernel headers for the running kernel, `build-essential`, `busybox`, `pciutils`,
  `psmisc`, `zstd`, `python3`. The installer apt-installs what is missing.
- Secure Boot off, or a signing setup that lets the unsigned hook load.
- No display manager holding the GPU while it runs. At boot the unit is ordered
  before `display-manager.service`, so a desktop is fine as long as you don't run the
  script by hand with the desktop up. Dedicated compute box: `systemctl set-default multi-user.target`.

Tested here: Ubuntu 22.04 HWE (6.8.0-138), bare metal, x1 risers and a PCIe switch.
The upstream CmpUnlocker project validated Debian 13 and Proxmox passthrough.

## Commands

    sudo ./install.sh [--no-enable|--run]   # --help for usage
    sudo cmp100-verify               # read-only: is this host really unlocked, and if not why
    sudo cmp100-unlock status        # read-only: tensor reg, link speed, driver per card
    sudo systemctl start cmp100-unlock
    journalctl -u cmp100-unlock -b   # or /var/log/cmp100-unlock/run-*.log
    sudo cmp100-unlock --force       # after a failed run on a previous boot
    sudo cmp100-unlock --gen2        # skip the Gen3 stage, use the signed-write Gen2 path
    sudo cmp100-unlock --no-pcie     # tensor only (--no-gen2 is an alias)
    cmp100-bench                     # HMMA latency / FP16 tensor throughput
    cmp100-pcie-bw                   # H2D / D2H copy bandwidth per card
    sudo ./uninstall.sh [--purge]

Start with `cmp100-verify`. `cmp100-unlock status` reports what the cards say; `cmp100-verify`
adds the environment around them, which is where the silent failures live - a driver-wide
`RMPcieLinkSpeed` cap, a boot unit that lost the race for the GPUs, or a DRM client on a
target card - and ends in a PASS/FAIL verdict.

Config in `/etc/cmp100-unlock.conf`: `CMP100_BDFS` (explicit BDF list),
`CMP100_PCIE=3|2|0` (Gen3 pre-POST clamp clear, signed-write Gen2, or Tensor only;
default 3; the pre-1.1 `CMP100_GEN2=0` is still honoured as `CMP100_PCIE=0`),
`CMP100_STOP_SERVICES` (services to stop first), `CMP100_RETRAIN_ATTEMPTS`.

## Troubleshooting

`Tensor baseline 0xffffffff` : BAR0 not decoding. The script sets COMMAND memory+bus-master
after every unbind; if you still see this the slot/riser is flaky.

`X is active; a DRM client on the GPU...` : stop gdm/lightdm/sddm/switcheroo-control, or reboot
and let the unit run before them.

`produced no BOOT_RETURN` : hook loaded but nouveau didn't reach the ACR loader. Check
`dmesg | grep -E 'nouveau|gv100'`. Usually the firmware hash check would have caught this earlier.

`did not train to Gen3 (LnkSta GenN)` : the clamp cleared but the link would not retrain at
8 GT/s. Check the upstream port's LnkCap (`lspci -vv -s <root> | grep -E 'LnkCap|LnkCtl2'`),
the riser (many x1 risers are Gen2-only), and BIOS slot speed settings. `--gen2` still works.

`OPT_PCIE_BOOT_GEN23/GEN3_DISABLE fused` : your card has the Gen2/Gen3 disable fuses blown
(ours read 0). The clamp clear cannot help; run with `--gen2` or set `CMP100_PCIE=2`.

`nvidia-smi` says gen 2 (or 1) after a Gen3 run : expected. The driver re-clamps the
advertised cap but the link stays at 8 GT/s; `lspci -vv -s <bdf> | grep LnkSta` shows
`8GT/s (strange)` and `cmp100-pcie-bw` shows ~0.8 GB/s.

Cards locked **and** at Gen1 after a reboot : two independent causes, both silent - the
boot unit lost the race for the GPUs (a systemd *user* stack holding `/dev/nvidia*`, or a
DRM client on a non-target card), and/or a driver-wide `RMPcieLinkSpeed` dword is loaded.
`sudo cmp100-verify` separates them, and `docs/TROUBLESHOOTING.md` has the full walkthrough
including how to confirm the fixed `modprobe.d` file made it into the initramfs.

`NVIDIA policy did not advertise Gen2` / stuck at Gen1 (Gen2 fallback) : your upstream port
targets Gen1 (`lspci -vv -s <root> | grep LnkCtl2`). The script raises it automatically; if
the BIOS has an explicit "PCIe Gen1" slot setting, change it there.

`No such device` when you `echo <bdf> > /sys/bus/pci/drivers/nvidia/bind` by hand : a stale
`driver_override` from an interrupted run. The script clears it on failure since 1.1.0; if
you still hit it, `echo '' > /sys/bus/pci/devices/<bdf>/driver_override` then bind.

Kernel upgrade: `sudo ./install.sh` again rebuilds the hook. The unit refuses to run with a
hook built for another kernel.

Card in a bad state after a failure: **reboot**. Do not poke sysfs bind/unbind by hand.

## Layout

    install.sh / uninstall.sh
    cmp100-unlock.conf            default config, installed to /etc/cmp100-unlock.conf if absent
    sbin/cmp100-unlock            the unlock script (bash, ~600 lines, fail-closed)
    src/gv100_nouveau_acr_hook.c  kprobe hook + Makefile, accepts 10de:1d84 and 10de:1df4
    tools/build_payloads.py       derives the 5 payloads from stock firmware, hash-locked
    tools/cmp100-bench            HMMA latency / FP16 throughput via PTX JIT
    tools/cmp100-pcie-bw          H2D / D2H copy bandwidth per card via libcuda
    tools/cmp100-verify           whole-host check: link, cap, boot unit, holders, verdict
    systemd/cmp100-unlock.service
    modprobe.d/cmp100-unlock.conf blacklist nouveau + nvidia_drm; no RMPcieLinkSpeed dword
    tests/                        mocked full-flow tests (no hardware)
    docs/PREREQUISITES.md         every tested version, hash and hardware detail
    docs/RESULTS.md               boot journal and benchmark output
    docs/REGISTERS.md             BAR0 register map, the PCIe clamp bits, what is CPU-writable
    docs/TROUBLESHOOTING.md       failure messages and what to do
    CHANGELOG.md                  release notes
    LICENSE                       GPL-2.0

## Credits

The signed-ACR technique, hook, payload builder and register map come from
[Brazzo978/CmpUnlocker-100-210](https://github.com/Brazzo978/CmpUnlocker-100-210) (GPL-2.0).
The Ubuntu 22.04 port work started in [mintoriakamoto/CMP100-210xFULLTENSORSxGEN3x1](https://github.com/mintoriakamoto/CMP100-210xFULLTENSORSxGEN3x1) and grew into this repo.
This repo packages it as a single boot-time installer, adds `10de:1df4` support, the
`noaccel` nouveau workaround for the unbind Oops, the upstream-port target-speed fix and
the retrain retry loop that gets Gen2 on slots where the original script stops.

The PCIe Gen3 mechanism (the `CYA_GEN2/GEN3_SPEED_OVERRIDE` soft clamp in
`NV_XVE_PRIV_MISC_1`, the fuse words to check, and the pre-POST timing) was found and
published by [duggasco/CMP100-210](https://github.com/duggasco/CMP100-210)
(`tools/pcie_retrain_probe.py`, README section "PCIe Gen1 -> Gen3"; PolyForm-Noncommercial
licensed research). We reimplemented the two register writes and the reset/retrain
sequence in bash for this script; no code was copied.

GPL-2.0-only. You are writing to a GPU's firmware loader as root; read the script
before running it.
