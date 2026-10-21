# Changelog

## 1.1.1

Two independent faults that both leave the link at Gen1 after a reboot. Found on a
live two-card host that had been unlocked successfully before it rebooted.

- **Removed `RMPcieLinkSpeed=0x1` from the shipped `modprobe.d` drop-in.** It is a
  driver-wide cap, not a per-card one: with it loaded, `/proc/driver/nvidia/params`
  shows `RegistryDwords: "RMPcieLinkSpeed=0x1"` and every nvidia GPU on the host is
  pinned at 2.5 GT/s, CMP or not. The Gen3 path needs no registry dword.
- **The boot unit now wins the race for the GPUs.** `Before=` gained
  `systemd-user-sessions.service` and `user@1000.service`, so the systemd *user*
  manager that starts an inference stack (llama-server, reflex, embed) cannot open
  `/dev/nvidia*` first. Before this, the unit died with "GPU/DRM device nodes are
  open" on every boot and the cards came up locked and at Gen1.
- **`assert_quiescent` no longer refuses on a non-target DRM node.** It resolved
  every `/dev/dri/card*` to its PCI BDF and only blocks when the holder owns a
  *target* card. On a mixed host the boot splash (`plymouthd`) holds the desktop
  GPU's node, which is not our client; that alone made boot-time unlock impossible.
  An unresolvable node still refuses, and `/dev/nvidia*` holders always block.
- The display-manager check now only applies when a target card actually has a DRM
  node (i.e. `nvidia_drm` is attached to it).
- Measured on the regression host: H2D 0.202/0.194 GB/s (Gen1) before, tensor
  `0x00000999`; after the fix the link trains Gen3 and tensor reads `0x00000888`.
- 22 mocked tests (4 new: foreign DRM holder, target DRM holder, unresolvable node,
  nvidia node).

## 1.1.0

- PCIe Gen3 x1 is the default. Pre-POST clear of the CYA speed clamp in
  `NV_XVE_PRIV_MISC_1` (0x8841C) after a secondary bus reset, then retrain from the
  upstream port. Mechanism credit: duggasco/CMP100-210.
- Measured 0.806 / 0.845 GB/s H2D / D2H per card (4.1x Gen1, 2.1x Gen2).
- Gen2 signed-write path kept as `--gen2` fallback and used automatically if a card
  loses Gen3 during the Tensor stage.
- `CMP100_PCIE=3|2|0` config knob; `CMP100_GEN2=0` still accepted.
- Refuses the Gen3 path on cards with `OPT_PCIE_BOOT_GEN23/GEN3_DISABLE` fused.
- On failure the `driver_override` hold is released so a manual nvidia bind works.
- New `cmp100-pcie-bw` bandwidth tool; `status` flags the nvidia-smi gen readout.
- 18 mocked tests.

## 1.0.0

- Tensor unlock (0x409664 = 0x888) via signed ACR chain through nouveau, plus PCIe
  Gen2 via two signed writes and an upstream retrain with retries.
- Single `install.sh`, hash-locked payload build from stock firmware, systemd oneshot,
  boot-id crash marker, `cmp100.skip` kernel cmdline, 14 mocked tests.
