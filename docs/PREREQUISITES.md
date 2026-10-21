# Prerequisites and tested specification

Everything below is what the unlock was developed and verified on. Deviate at your
own risk; the installer hard-fails on the firmware hashes and the device IDs, and
soft-warns on the rest.

## Hardware (tested)

| item | value |
|---|---|
| GPU | NVIDIA CMP 100-210, PCI `10de:1df4` rev a1, subsystem `10de:12b8`, 2 cards |
| VBIOS | **88.00.51.00.04, a Tesla V100 VBIOS; the cards were bought already flashed by the seller** (subsystem `10de:12b8`). Stock CMP 100-210 ships 88.00.9D.00.00 and identifies as "CMP 100-210"; these cards identify as `Tesla V100-PCIE-12GB` even while locked (tensor=0x999, Gen1) |
| HBM2 | 16 GiB physical (`nvidia-smi` shows 16384 MiB) |
| Board | ASUS TUF GAMING B650E-PLUS WIFI, AMI BIOS 3886 (2026-06-24) |
| CPU / RAM | AMD Ryzen 9 9950X, 32 GB |
| Card 1 slot | CPU root port `0000:00:01.1` (AMD 1022:14db), x1 riser, BIOS targets Gen1 by default (the script raises it to Gen3) |
| Card 2 slot | behind chipset PCIe switch `0000:04:00.0` (AMD 1022:43f5), x1 riser, target Gen4 |
| PCIe fuses | `OPT_PCIE_BOOT_GEN23_DISABLE` (0x2157c) = 0, `OPT_PCIE_BOOT_GEN3_DISABLE` (0x21580) = 0 on both cards (required for the Gen3 stage) |
| Secure Boot | disabled (`mokutil --sb-state`) |
| Display | headless; GDM and switcheroo-control masked, default target multi-user |

### VBIOS note

The two test cards were purchased second-hand already flashed with a Tesla V100
VBIOS (88.00.51.00.04, subsystem 10de:12b8). Sellers do this to lift what the VBIOS
controls: the card enumerates as `Tesla V100-PCIE-12GB`, exposes the full 16 GiB HBM2,
and the driver treats it as a V100. Measured on these cards, that flash does **not**
touch the two things this project unlocks: at boot they still read Tensor gate
0x409664=0x999 and train at PCIe Gen1; the pre-POST clamp clear and the signed-ACR
pass here are what lift them. Both layers together give the numbers in RESULTS.md. So:

- the V100 VBIOS alone does **not** unlock Tensor or PCIe Gen2/Gen3 on `10de:1df4`;
- upstream CmpUnlocker validated the same unlock on the stock CMP VBIOS
  (88.00.9D.00.00, `10de:1d84`), so a VBIOS flash is not believed to be required;
- but our only verified configuration is the V100 VBIOS. If you are on stock CMP
  VBIOS and it fails, report the `vbios_version` and `pci.sub_device_id` from
  `nvidia-smi --query-gpu=vbios_version,pci.sub_device_id --format=csv`.

This project does not flash anything. Flashing a VBIOS is a separate, non-volatile,
card-bricking-capable step outside its scope.

Also accepted by the code: `10de:1d84` (the SKU upstream CmpUnlocker validated). The
hook and script refuse every other device ID.

## Software (tested)

| item | version |
|---|---|
| OS | Ubuntu 22.04.5 LTS |
| Kernel | 6.8.0-138-generic (HWE), headers `linux-headers-6.8.0-138-generic 6.8.0-138.138~22.04.1` |
| Compiler | gcc-12 12.3.0 (must match the kernel's compiler major; Ubuntu 22.04 HWE 6.8 needs gcc-12, not the default gcc-11) |
| NVIDIA driver | 550.163.01 proprietary (`nvidia-driver-550` / DKMS). Not `nvidia-open`: Volta is unsupported there |
| linux-firmware | 20220329.git681281e4-0ubuntu3.42 |
| Python | 3.10 (installer/tests use only stdlib; anything >= 3.8 works) |
| busybox | 1.30.1 (`devmem` applet) |
| pciutils | 3.7.0 (`setpci`, `lspci`) |
| psmisc | 23.4 (`fuser`) |
| zstd | 1.4.8 (only needed on distros shipping `.zst` firmware) |
| dkms | 2.8.7 (for the NVIDIA driver, not for the hook) |

Upstream CmpUnlocker validated Debian 13 with the same driver and reports users
succeeding on newer 5xx drivers. The Gen3 stage needs nothing from the driver (it runs
with the card unbound); the Gen2 fallback uses `RMPcieLinkSpeed=0x1` via
`NVreg_RegistryDwords`, which exists in every 5xx driver.

## Firmware baseline (hard requirement)

`tools/build_payloads.py` derives the payloads from these exact files and refuses
anything else. They are the stock `linux-firmware` GV100 blobs:

| file | size | SHA-256 |
|---|---|---|
| `nvidia/gv100/gr/fecs_sig.bin` | 192 | `8b636da582662995aa5ed3b8f530299a8aca801934657c85e6a031fb8fd1eab1` |
| `nvidia/gv100/acr/bl.bin` (symlink to `gp102/acr/bl.bin`) | 1280 | `01326cc997716bebb0eab9fe1f463fffa0ee586079e4ca0e5bb096ab6fcfedab` |
| `nvidia/gv100/acr/ucode_load.bin` | 18688 | `b349f0355548716770531eb9082544bb84de059f17bbf3952fb09dd27d8673d4` |

Derived payloads (what the installer must produce; the unlock script re-checks them
every run from `/var/lib/cmp100-unlock/manifest.env`):

| payload | SHA-256 |
|---|---|
| `fecs_sig.candidate-c-504.bin` | `0c6916d57cd46780261bdf4e9dd5c81691f3c1685d1b1e5ea8b266e14d2ea95e` |
| `bl.load-candidate-c.bin` | `7ede4b56759a5e4276604c7bd7e7d6c82016192c019d6d9244e6b2002dbcaa9c` |
| `ucode_load.tensor-success-lsb-restore.bin` | `5bb3828d1b3e8782749b3a9bfcbfc746e88f4ff3ca041c87eea8b4a1eb003b33` |
| `ucode_load.pcie-policy-88610-1.bin` | `f5827fe768a62289fc8080877eb01eacb271b030dbf15c1b43e702f17dacf524` |
| `ucode_load.pcie-vector-8872c-6.bin` | `4c658410b734a022d603e766429b1779647850dbd04e9fde3963e378e024d4e2` |

`bl.bin` is a symlink into `gp102/`; the script writes through `readlink -f` so the
shared gp102 file is temporarily replaced and restored. Nothing else on the system
uses it during the run.

## What the installer does to the system

- apt-installs any missing: `build-essential linux-headers-$(uname -r) busybox pciutils psmisc zstd python3`
- `/var/lib/cmp100-unlock/stock/` snapshot of the three firmware files, `manifest.env` (0600) with all hashes + hook kernel version
- `/usr/lib/cmp100-unlock/` payloads, `gv100_nouveau_acr_hook.ko`, `src/` (rebuilt on `install.sh` after a kernel upgrade)
- `/usr/local/sbin/cmp100-unlock`, `/usr/local/bin/cmp100-bench`, `/usr/local/bin/cmp100-pcie-bw`
- `/usr/local/bin/cmp100-memclk` **only if** `libnvidia-ml.so.1` is present at install time (it ships with the proprietary driver). This is the optional HBM memory-clock helper for `CMP100_HBM=877`; it links against the driver's NVML directly, so no `-dev` headers package is needed. If NVML is absent the installer logs a note and skips it, and the `CMP100_HBM` lever simply stays unavailable.
- `/etc/systemd/system/cmp100-unlock.service` (enabled unless `--no-enable`)
- `/etc/modprobe.d/cmp100-unlock.conf`: blacklist `nouveau` and `nvidia_drm`, `options nvidia NVreg_RegistryDwords="RMPcieLinkSpeed=0x1"`
- `/etc/cmp100-unlock.conf` (only if absent)
- disables (does not remove) legacy `cmp100-tensor-unlock`, `cmp100-pcie-gen2`, `cmp100-firmware-prepare` units from upstream CmpUnlocker

Blacklisting `nvidia_drm` means no DRM/KMS on these cards. CUDA, NVML, `nvidia-smi`,
llama.cpp, PyTorch do not need it. If you want a desktop on a CMP card, this is the
wrong project.

## Hook module facts

- `vermagic` must equal `uname -r` exactly; the script refuses otherwise
- parameters used: `bus=<decimal PCI bus> armed=1 replace_on_return=2 load_test_size=0x5d00`
- kprobes are global: one card at a time, `drivers_autoprobe=0` for the duration
- nouveau is loaded as `modprobe --config /dev/null nouveau modeset=2 noaccel=1 runpm=0` (bypasses the blacklist; `noaccel=1` avoids the `nouveau_ttm_fini -> nve0_bo_move_copy` Oops on unbind)

## Timing (measured, two cards)

| stage | per card |
|---|---|
| Gen3 (unbind, secondary bus reset, clamp clear, retrain, rebind) | ~4 s, 1 retrain attempt on both slots |
| Tensor (unbind, ACR boot, unbind, rebind, nvidia-smi ready) | ~2 s |
| whole run from locked state, Gen3 + Tensor | 18 s for two cards |
| unattended reboot: unit done, both cards Gen3 + 0x888 | 24 s after boot |
| Gen2 fallback: signed writes (two ACR boots) | ~1 s + 5 s nvidia-smi wait |
| Gen2 fallback: retrain cycle | ~6 s each, 1-2 cycles (1.0.0 boot run with Gen2: ~40 s) |
| re-run when already unlocked | ~3 s, no mutation |

PCIe bandwidth per lane (`cmp100-pcie-bw`, 256 MiB pinned, best of 5): Gen1 0.194 / 0.214
GB/s H2D / D2H, Gen2 0.386 / 0.427, Gen3 0.806 / 0.845 (card 1) and 0.794 / 0.845 (card 2).

## Known limits

- Volatile. Reboot, power loss, `nvidia-smi -r`, or a driver-initiated GPU reset re-locks the card until the unit runs again (the unit only runs at boot; re-run it by hand after a reset).
- PCIe Gen3: **yes** on `10de:1df4`. The Gen1 cap is a soft clamp (`NV_XVE_PRIV_MISC_1`, 0x8841c), not a fuse; the fuse words 0x2157c / 0x21580 read 0 here. It only clears pre-POST (after a secondary bus reset, before any driver binds), which is why the unit does it first. On a card where those fuses are non-zero the script refuses and the signed-write Gen2 path (`--gen2`) is the ceiling.
- PCIe Gen4: **no**. With the clamp cleared `LnkCap2` advertises 2.5/5/8 GT/s only; GV100 is PCIe 3.0 silicon.
- x16: **no**. The lane count comes from the IFR at flash offset 0x214, non-volatile; changing it means flashing, which this project does not do.
- After a Gen3 run `nvidia-smi` reports `pcie.link.gen.current` 2 and `lspci` says `8GT/s (strange)`: the driver re-clamps the advertised cap but not the live link. Use `lspci` LnkSta, sysfs `current_link_speed` or `cmp100-pcie-bw` for the truth.
- HBM memory clock (`CMP100_HBM=877`): optional, off by default, and **not yet validated on these cards.** The +138 NVML VF offset -> 877 MHz path is reported by upstream on `10de:1d84` (see RESULTS.md); ours are `10de:1df4` and unmeasured. It uses a supported NVML API (`nvmlDeviceSetMemClkVfOffset`), so it is reversible and resets on power loss, and a failure never disturbs the Tensor/PCIe unlock. Needs `cmp100-memclk` (built only when NVML is present).
- The signed-ACR payloads only exist for the firmware revision above. A `linux-firmware` update that changes those three files stops the installer until the builder is re-derived.
- Not tested: Proxmox passthrough (upstream did), Secure Boot with a MOK-signed hook, drivers other than 550.163.01, `10de:1d84`.
