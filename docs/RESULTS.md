# Results

Host: Ubuntu 22.04.5 HWE, kernel 6.8.0-138-generic, NVIDIA 550.163.01, two CMP 100-210
(`10de:1df4`, rev a1, V100 VBIOS 88.00.51.00.04). Card 1 on CPU root port 00:01.1 (BIOS
target Gen1), card 2 behind a PCIe switch (04:00.0). Both x1 risers.

## Gen3 run from locked state (journal, cmp100-unlock 1.1.0, abridged)

    cmp100-unlock 1.1.0 targets: 0000:01:00.0 0000:05:00.0 pcie=Gen3
    0000:01:00.0: unbind NVIDIA for pre-POST Gen3 window
    0000:01:00.0: secondary bus reset
    0000:01:00.0: PRIV_MISC_1 0xc0346500 -> 0x00340500 (clear CYA speed override)
    0000:01:00.0: LnkCap now 0x00453c13, LnkCap2 0x0000000e
    0000:01:00.0: raised 0000:00:01.1 target link speed to Gen3
    0000:01:00.0: retrain 1 -> LnkSta Gen3 (upstream Gen3)
    0000:01:00.0: Gen3 stage PASS (LnkSta Gen3; nvidia-smi will keep reporting gen 1, trust lspci)
    0000:05:00.0: ...
    0000:05:00.0: retrain 1 -> LnkSta Gen3 (upstream Gen3)
    0000:05:00.0: Gen3 stage PASS
    0000:01:00.0: Tensor stage PASS
    0000:05:00.0: Tensor stage PASS
    0000:01:00.0: Gen3 held through Tensor stage (LnkSta Gen3)
    0000:05:00.0: Gen3 held through Tensor stage (LnkSta Gen3)
    PASS

18 s for both cards from a locked state: ~4 s per card for Gen3 (unbind, SBR, clamp
clear, one retrain, rebind) and ~2 s per card for Tensor. Both cards trained to Gen3 on
the first retrain. `dmesg` clean: no Oops, no Xid, no AER. Firmware on disk is stock
afterwards (`ucode_load.bin` b349f035...).

Before the clamp clear the endpoint read `LnkCap 0x00453c11` / `LnkCap2 0x2` (2.5 GT/s
only); after it `LnkCap 0x00453c13` / `LnkCap2 0xe` (2.5-8 GT/s). Fuse words
`0x2157c` and `0x21580` read 0 on both cards.

`lspci -vv` afterwards, with the driver bound:

    LnkCap: Port #0, Speed 2.5GT/s, Width x16 ...
    LnkSta: Speed 8GT/s (strange), Width x1 (ok)

The "strange" is lspci noticing the live speed exceeds the (re-clamped) capability.
`nvidia-smi --query-gpu=pcie.link.gen.current` reports 2 permanently for the same reason;
it reads the clamped cap, not the trained link. `/sys/bus/pci/devices/<bdf>/current_link_speed`
says `8.0 GT/s PCIe`.

Attempted first and rejected: clearing the clamp *after* POST (driver bound once). LnkCap2
lifts to 2.5-8 GT/s but every retrain settles at Gen2, hence the secondary bus reset.

## Unattended reboot (1.1.0)

Unit active, both cards `LnkSta Gen3` and Tensor `0x00000888`, 24 s after boot. Status
afterwards:

    0000:01:00.0 driver=nvidia tensor=0x00000888[UNLOCKED] link=Gen3 (mmio Gen3) upstream=0000:00:01.1 target=Gen3 cap=Gen1 nvidia-smi=2
    0000:01:00.0   note: nvidia-smi reports the re-clamped cap (gen 1/2); LnkSta Gen3 is the physical link
    0000:05:00.0 driver=nvidia tensor=0x00000888[UNLOCKED] link=Gen3 (mmio Gen3) upstream=0000:04:00.0 target=Gen3 cap=Gen1 nvidia-smi=2
    0000:05:00.0   note: nvidia-smi reports the re-clamped cap (gen 1/2); LnkSta Gen3 is the physical link

## PCIe bandwidth (`cmp100-pcie-bw`, 256 MiB pinned, best of 5)

| link | H2D GB/s | D2H GB/s | vs Gen1 |
|---|---|---|---|
| Gen1 x1 (locked) | 0.194 | 0.214 | 1.0x |
| Gen2 x1 (signed-write path, 1.0.0) | 0.386 | 0.427 | 2.0x |
| Gen3 x1, card 1 (0000:01:00.0) | 0.806 | 0.845 | 4.1x |
| Gen3 x1, card 2 (0000:05:00.0) | 0.794 | 0.845 | 4.1x |

Gen3 is 2.1x Gen2 rather than the 1.6x the raw rates suggest because 8 GT/s uses 128b/130b
encoding while 2.5/5 GT/s use 8b/10b. All numbers are a single x1 lane; the lane count is
set by the IFR at flash offset 0x214 and is out of scope.

## Gen2 signed-write path (1.0.0, kept as fallback)

    20:38:07  cmp100-unlock 1.0.0 targets: 0000:01:00.0 0000:05:00.0 gen2=1
    20:38:14  0000:01:00.0: Tensor stage PASS
    20:38:16  0000:05:00.0: Tensor stage PASS
    20:38:34  0000:01:00.0: Gen2 stage PASS (attempt 2)
    20:38:44  0000:05:00.0: Gen2 stage PASS (attempt 1)
    20:38:47  PASS

40 s from unit start. Card 1 needed the second retrain cycle: after the signed writes
NVIDIA reports `gen 1/max 1`; the first CHANGE_SPEED plus root-port retrain leaves Gen1
but the rebind makes NVIDIA advertise `max 2`; the second CHANGE_SPEED then trains to
5 GT/s directly. The upstream CmpUnlocker script dies at the "did not advertise Gen2"
check before that second cycle. This path is now only used with `--gen2` /
`CMP100_PCIE=2`, or automatically for a card whose Gen3 link did not survive the Tensor
stage.

## cmp100-bench (after the Gen3 boot above)

    GPU0 0000:01:00.0 SMs=80 clk=1147MHz  HMMA dependent latency=36.8 cycles  FP16 tensor throughput=87.0 TFLOP/s
    GPU1 0000:05:00.0 SMs=80 clk=1147MHz  HMMA dependent latency=36.8 cycles  FP16 tensor throughput=86.6 TFLOP/s

Unchanged from the Gen2 runs (86.9 / 86.6): the Tensor unlock is independent of the link.
Locked reference on the same cards: ~512 cycles per dependent HMMA.
Upstream published: 36.4 cycles, 74-75 TFLOP/s on an 8192^3 GEMM (a different metric).

## HBM memory clock (`CMP100_HBM=877`, opt-in — not yet run on these cards)

The optional HBM stage applies an NVML memory-clock VF offset of `+138`, taking HBM
from 810 MHz to 877 MHz (~+8% device bandwidth), via the supported
`nvmlDeviceSetMemClkVfOffset` API. It is reversible (resets on power loss, or
`cmp100-memclk reset <bdf>`), off by default, and never affects the Tensor/PCIe
unlock — a failed offset is rolled back and logged as a warning.

Status on this host: **not yet measured.** The lever is ported from the upstream
projects that report it on `10de:1d84`:

| source | card | stock | offset | result |
|---|---|---|---|---|
| Brazzo978/CmpUnlocker-100-210 | 10de:1d84 | 810 MHz | +138 | 877 MHz (HBM 877 profile) |
| duggasco/CMP100-210 | 10de:1d84 | 810 MHz | +138 | 877.5 MHz, +8.4% bandwidth reported |

Our cards are `10de:1df4`; we have not confirmed the offset takes or the clock
reaches 877 MHz on them, which is why the stage stays opt-in. When run, the helper
verifies the offset read-back and the flow logs `HBM 877 MHz PASS` per card; the
resulting clock is reported for confirmation only (at idle it can read below 877
until a CUDA context loads). To gather a real before/after here, run
`cmp100-memclk read <bdf>`, enable `CMP100_HBM=877`, and compare `cmp100-pcie-bw`
and a memory-bandwidth probe (e.g. a large device-to-device copy) at stock vs 877.

## Idempotence

Second `systemctl start cmp100-unlock` on an unlocked machine:

    all targets already unlocked; nothing to do

No unbind, no reset, no module load, exit 0, ~3 s (the time is nvidia-smi). "Unlocked" is
judged on `LnkSta`, not on `nvidia-smi`, so the re-clamped cap does not trigger a re-run.
