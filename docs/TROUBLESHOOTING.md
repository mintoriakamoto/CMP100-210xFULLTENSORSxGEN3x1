# When it goes wrong

## Rule 1

If the unit failed after "unbind", do not touch bind/unbind by hand. Reboot.
A faulted nouveau teardown leaves the device lock held; a second write hangs in D state
and cannot be killed.

The one exception: a failure in the Gen3 stage (before any nouveau bind) leaves the card
unbound but healthy. Since 1.1.0 the script clears `driver_override` on the way out, so
`echo <bdf> > /sys/bus/pci/drivers/nvidia/bind` is safe there.

## Messages

`journalctl -u cmp100-unlock -b` and `/var/log/cmp100-unlock/run-*.log` have the trace.

| message | cause | fix |
|---|---|---|
| `a previous run did not finish (marker ...)` | last boot's run hung or crashed | read that boot's log, then `cmp100-unlock --force` or `rm /var/lib/cmp100-unlock/in-progress` |
| `must start bound to nvidia (is: '')` | nvidia not loaded/probed yet; the script waits 30 s and tries modprobe/bind itself | if persistent, check `dmesg \| grep NVRM` and Secure Boot |
| `Tensor baseline 0xffffffff` / `BAR0 not decoding after reset` | BAR0 not decoding | bad riser/slot; the script already forces COMMAND mem+master after every unbind and reset |
| `active ... is neither stock nor a known payload` | linux-firmware updated to an untested revision | rerun install.sh; if the hashes in tools/build_payloads.py don't match your files, open an issue with sha256s |
| `hook built for ...` | kernel upgraded | `sudo ./install.sh` |
| `X.service is active; a DRM client...` | desktop up during a manual run | run at boot, or stop the DM |
| `a GPU/DRM device node on a target card is open` | a client holds a target card's `/dev/nvidia*` or its DRM node (the trace names the PIDs) | stop the stack (`CMP100_STOP_SERVICES`, or `systemctl --user stop` your units) and rerun; at boot, see the two caused-below entries |
| `has OPT_PCIE_BOOT_GEN23/GEN3_DISABLE fused` | this card's Gen2/Gen3 disable fuses are blown (both read 0 on our `1df4` cards) | the clamp clear cannot help; `cmp100-unlock --gen2` or `CMP100_PCIE=2` in the config |
| `upstream port ... only supports GenN` | the slot/switch above the card is not Gen3-capable | move the card, or use `--gen2` |
| `did not train to Gen3 (LnkSta GenN)` | clamp cleared and target set, but the link would not retrain at 8 GT/s: Gen2-only riser, BIOS slot speed limit, or a marginal cable | `lspci -vv -s <upstream> \| grep -E 'LnkCap\|LnkCtl2\|LnkSta'`; try another riser; `--gen2` still works. Nothing else was touched: the card is simply rebound |
| `link is GenN after Tensor stage; falling back to signed Gen2 path` | the nouveau/nvidia POST downshifted the link on this slot (not seen here) | not an error; the Gen2 stage runs automatically for that card |
| `did not reach Gen2 after 3 attempts` | root port capped at Gen1 by BIOS, or a Gen1-only riser | `lspci -vv -s <upstream> \| grep -E 'LnkCap\|LnkCtl2'`; Tensor stays unlocked regardless |
| `produced no BOOT_RETURN` | nouveau never reached ACR load | `dmesg \| grep -E 'nouveau\|gv100'` |
| `No such device` on a manual `echo <bdf> > .../drivers/nvidia/bind` | stale `driver_override` from an interrupted run | `echo '' > /sys/bus/pci/devices/<bdf>/driver_override`, then bind again |

## The cards came up locked and at Gen1 after a reboot

Two independent causes, both silent. Check both before touching hardware.

1. **The unlock unit never ran.** Read the failure:

   ```
   systemctl status cmp100-unlock; journalctl -u cmp100-unlock -b | tail -20
   ```

   `... device nodes are open` means something owned the GPUs before the unit did.
   Until 1.1.1 the unit only ordered itself before system services, so startup of a
   systemd *user* stack (llama-server, reflex, embed) won the race. Since 1.1.1 the
   unit is ordered before `user@1000.service` and `systemd-user-sessions.service`
   (adjust the uid in the unit if your stack runs as another user). If the holder is
   instead a DRM client on a *non-target* GPU - the boot splash (`plymouthd`) drawing
   on the desktop card is the usual one - 1.1.1 ignores it, because it resolves each
   `/dev/dri/card*` to its PCI BDF and only blocks on a target card.

2. **A driver-wide Gen1 cap is loaded.** The pre-1.1.1 install shipped
   `options nvidia NVreg_RegistryDwords="RMPcieLinkSpeed=0x1"`. `0x1` is Gen1, and the
   dword applies to *every* nvidia GPU on the host:

   ```
   grep RegistryDwords /proc/driver/nvidia/params
   # RMPcieLinkSpeed=0x1  -> the cap is live; delete it from /etc/modprobe.d/
   # ""                   -> clean
   ```

   The nvidia module is loaded from the initramfs, so removing the line needs
   `sudo update-initramfs -u` (copy `/boot/initrd.img-$(uname -r)` aside first) and a
   reboot, or the next driver load. Rebuild, then confirm the initramfs carries the
   fixed file (`unmkinitramfs /boot/initrd.img-$(uname -r) /tmp/ird` and read
   `/tmp/ird/main/etc/modprobe.d/cmp100-unlock.conf`). Verify in the live host's
   parent port as well: if its `LnkCtl2` target is Gen1 (`cmp100-unlock status` prints
   `target=Gen1 cap=Gen5`), the BIOS trained it low at POST and only a retrain - what
   the Gen3 stage does - lifts it.

   Symptom that separates (1) from (2): after cause 1, Tensor also reads locked
   (`tensor=0x00000999[locked]` in `cmp100-unlock status`). Cause 2 alone leaves
   Tensor at `0x00000888` and only the link at Gen1.

## Readings that look wrong but are not

`nvidia-smi --query-gpu=pcie.link.gen.current` says **2** (or 1) after a Gen3 run, and
`lspci -vv -s <bdf>` says `LnkSta: Speed 8GT/s (strange), Width x1 (ok)`. Both are the
same effect: the NVIDIA driver's devinit re-clamps the *advertised* capability to Gen1/2
but leaves the trained link alone. nvidia-smi reports the cap; lspci reports the link and
flags the mismatch as "strange". Trust `lspci` LnkSta, `cat
/sys/bus/pci/devices/<bdf>/current_link_speed` (`8.0 GT/s PCIe`), `cmp100-unlock status`
(prints both with a note), or `cmp100-pcie-bw` (~0.8 GB/s per direction on x1 Gen3 vs
~0.2 on Gen1). See docs/REGISTERS.md, "The Gen1 clamp".

## Disabling

Disable without uninstalling: add `cmp100.skip` to the kernel command line, or
`systemctl disable cmp100-unlock`. Tensor-only: `CMP100_PCIE=0` in `/etc/cmp100-unlock.conf`
or `cmp100-unlock --no-pcie`.
