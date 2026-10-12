#!/usr/bin/env python3
"""Hardware-free tests for sbin/cmp100-unlock.

Every command that touches drivers, firmware or MMIO is replaced by a bash
function; sysfs/proc/firmware paths are redirected into a temp tree. The mock
models control flow only: tensor 0x999 -> 0x888 after a nouveau bind with the
hook armed and the tensor payload staged, link Gen1 -> Gen2 after CHANGE_SPEED.
Run: python3 -m unittest -v tests/test_unlock_flow.py
"""
import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / 'sbin' / 'cmp100-unlock').read_text()
MOCKS = (ROOT / 'tests' / 'mocks.sh').read_text()


class Flow(unittest.TestCase):
    def run_script(self, args=(), pre=None, env_extra=None):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)

            def put(rel, txt):
                f = p / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(txt)

            for bdf, bar in [('0000:01:00.0', '0x10000000'), ('0000:05:00.0', '0x20000000')]:
                put(f'sys/bus/pci/devices/{bdf}/vendor', '0x10de')
                put(f'sys/bus/pci/devices/{bdf}/device', '0x1df4')
                put(f'sys/bus/pci/devices/{bdf}/resource', f'{bar} 0 0\n')
                (p / f'sys/bus/pci/devices/{bdf}/driver').symlink_to('../../drivers/nvidia')
                put(f'regs/{bdf}/tensor', '0x00000999')
                put(f'regs/{bdf}/status', '0x10110142')
                put(f'regs/{bdf}/lnksta', '1')
                put(f'regs/{bdf}/xp', '0x08785800')
                put(f'regs/{bdf}/upstream', 'devices')  # parent_port() of a flat sandbox path
                put(f'sys/bus/pci/devices/{bdf}/reset', '')
            put('sys/bus/pci/drivers_autoprobe', '1')
            put('proc/modules', 'nvidia_uvm 1 0\nnvidia 1 0\n')
            put('proc/cmdline', 'quiet\n')
            put('proc/sys/kernel/random/boot_id', 'boot-1')
            put('dmesg', '')
            (p / 'run/lock').mkdir(parents=True)
            (p / 'sys/module').mkdir(parents=True)
            put('lib/firmware/nvidia/gv100/gr/fecs_sig.bin', 'STOCKFECS')
            put('lib/firmware/nvidia/gv100/acr/bl.bin', 'STOCKBL')
            put('lib/firmware/nvidia/gv100/acr/ucode_load.bin', 'STOCKUCODE')
            names = {
                'STOCK_FECS': ('var/lib/cmp100-unlock/stock/fecs_sig.bin', 'STOCKFECS'),
                'STOCK_BL': ('var/lib/cmp100-unlock/stock/bl.bin', 'STOCKBL'),
                'STOCK_UCODE': ('var/lib/cmp100-unlock/stock/ucode_load.bin', 'STOCKUCODE'),
                'CUSTOM_FECS': ('usr/lib/cmp100-unlock/payloads/fecs_sig.candidate-c-504.bin', 'CFECS'),
                'CUSTOM_BL': ('usr/lib/cmp100-unlock/payloads/bl.load-candidate-c.bin', 'CBL'),
                'CUSTOM_UCODE': ('usr/lib/cmp100-unlock/payloads/ucode_load.tensor-success-lsb-restore.bin', 'TENSORUCODE'),
                'PCIE_POLICY_UCODE': ('usr/lib/cmp100-unlock/payloads/ucode_load.pcie-policy-88610-1.bin', 'POLICYUCODE'),
                'PCIE_VECTOR_UCODE': ('usr/lib/cmp100-unlock/payloads/ucode_load.pcie-vector-8872c-6.bin', 'VECTORUCODE'),
                'HOOK': ('usr/lib/cmp100-unlock/gv100_nouveau_acr_hook.ko', 'HOOKKO'),
            }
            manifest = []
            for key, (rel, value) in names.items():
                put(rel, value)
                manifest.append(f'{key}_SHA={hashlib.sha256(value.encode()).hexdigest()}')
            put('var/lib/cmp100-unlock/manifest.env', '\n'.join(manifest) + '\n')
            if pre:
                pre(p, put)
            s = SCRIPT
            for prefix in ['/sys/', '/proc/', '/dev/dri/', '/dev/nvidia', '/lib/firmware/', '/var/lib/',
                           '/usr/lib/', '/var/log/', '/run/lock/', '/etc/cmp100']:
                s = s.replace(prefix, td + prefix)
            marker = "[[ $EUID -eq 0 ]] || die 'run as root'"
            assert marker in s
            s = s.replace(marker, MOCKS)
            put('script.sh', s)
            env = {k: v for k, v in os.environ.items() if not k.startswith('CMP100_')}
            env.update(SANDBOX=td, CMP100_BOOT_ID_FILE=td + '/proc/sys/kernel/random/boot_id',
                       TENSOR_SHA=hashlib.sha256(b'TENSORUCODE').hexdigest(),
                       POLICY_SHA=hashlib.sha256(b'POLICYUCODE').hexdigest(),
                       VECTOR_SHA=hashlib.sha256(b'VECTORUCODE').hexdigest())
            env.update(env_extra or {})
            r = subprocess.run(['bash', str(p / 'script.sh'), *args], env=env,
                               capture_output=True, text=True, timeout=30)
            events = (p / 'events').read_text() if (p / 'events').exists() else ''
            regs = {b: (p / f'regs/{b}/tensor').read_text() for b in ['0000:01:00.0', '0000:05:00.0']}
            fw = (p / 'lib/firmware/nvidia/gv100/acr/ucode_load.bin').read_text()
            autoprobe = (p / 'sys/bus/pci/drivers_autoprobe').read_text()
            marker_left = (p / 'var/lib/cmp100-unlock/in-progress').exists()
            return dict(rc=r.returncode, out=r.stdout + r.stderr, ev=events, regs=regs,
                        fw=fw, autoprobe=autoprobe, marker=marker_left)

    def test_full_unlock_two_cards(self):
        x = self.run_script()
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertEqual(x['regs']['0000:01:00.0'], '0x00000888')
        self.assertEqual(x['regs']['0000:05:00.0'], '0x00000888')
        self.assertEqual(x['fw'], 'STOCKUCODE', 'stock firmware must be restored')
        self.assertEqual(x['autoprobe'], '1')
        self.assertFalse(x['marker'])
        self.assertIn('modprobe --config /dev/null nouveau modeset=2 noaccel=1 runpm=0', x['ev'])
        self.assertEqual(x['ev'].count('insmod '), 2, 'tensor only; Gen3 needs no signed write')
        self.assertIn('Gen3 stage PASS', x['out'])
        self.assertIn('Gen3 held through Tensor stage', x['out'])
        self.assertEqual(x['ev'].count('/reset'), 2, 'one SBR per card')
        self.assertIn('misc1_write 0000:01:00.0 0x00340500', x['ev'])
        self.assertNotIn('xp_write', x['ev'], 'no Gen2 fallback when Gen3 trained')
        self.assertIn('PASS; log', x['out'])
        # ordering: SBR + clamp clear before any nouveau bind on the same card
        ev = x['ev']
        self.assertLess(ev.index('misc1_write 0000:01:00.0'), ev.index('write 0000:01:00.0 /sys/bus/pci/drivers/nouveau/bind'))
        self.assertLess(ev.index('write 0000:01:00.0 /sys/bus/pci/drivers/nvidia/bind'),
                        ev.index('write 0000:05:00.0 /sys/bus/pci/drivers/nvidia/unbind'),
                        'card 2 must not start before card 1 is back on nvidia')

    def test_gen2_path_explicit(self):
        x = self.run_script(['--gen2'])
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertEqual(x['ev'].count('insmod '), 6, 'tensor+policy+vector per card')
        self.assertIn('Gen2 stage PASS', x['out'])
        self.assertNotIn('/reset', x['ev'])

    def test_gen3_fused_card_refused(self):
        x = self.run_script(env_extra={'MOCK_FUSED': '0x00000001'})
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('fused', x['out'])
        self.assertNotIn('/reset', x['ev'], 'no SBR on a card the clamp clear cannot help')

    def test_gen3_train_failure_falls_to_error_and_releases_override(self):
        x = self.run_script(env_extra={'MOCK_NO_GEN3': '1', 'CMP100_RETRAIN_ATTEMPTS': '2'})
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('did not train to Gen3', x['out'])
        self.assertIn('write  /sys/bus/pci/devices/0000:01:00.0/driver_override', x['ev'],
                      'failure path must drop the test-hold override')

    def test_gen3_already_trained_falls_back_to_gen2_if_lost(self):
        # card 1 at Gen3 already, card 2 loses Gen3 during Tensor (simulate: never trains)
        def pre(p, put):
            put('regs/0000:01:00.0/lnksta', '3')
            put('regs/0000:01:00.0/status', '0x10130143')
        x = self.run_script(pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertIn('0000:01:00.0: already Gen3', x['out'])
        self.assertEqual(x['ev'].count('/reset'), 1)

    def test_already_unlocked_is_noop(self):
        def pre(p, put):
            for b in ['0000:01:00.0', '0000:05:00.0']:
                put(f'regs/{b}/tensor', '0x00000888')
                put(f'regs/{b}/lnksta', '3')
                put(f'regs/{b}/status', '0x10130143')
        x = self.run_script(pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertIn('already unlocked; nothing to do', x['out'])
        # a Gen2-unlocked box is done when the user only asked for Gen2
        def pre2(p, put):
            for b in ['0000:01:00.0', '0000:05:00.0']:
                put(f'regs/{b}/tensor', '0x00000888')
                put(f'regs/{b}/lnksta', '2')
        x = self.run_script(['--gen2'], pre=pre2)
        self.assertIn('already unlocked; nothing to do', x['out'])
        for forbidden in ['unbind', 'insmod', 'modprobe', 'rmmod']:
            self.assertNotIn(forbidden, x['ev'])

    def test_mixed_state_touches_only_locked_card(self):
        def pre(p, put):
            put('regs/0000:01:00.0/tensor', '0x00000888')
            put('regs/0000:01:00.0/lnksta', '2')
            put('regs/0000:01:00.0/status', '0x10120142')
        x = self.run_script(['--gen2'], pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertIn('0000:01:00.0: Tensor already unlocked', x['out'])
        self.assertIn('0000:01:00.0: already Gen2', x['out'])
        self.assertEqual(x['ev'].count('insmod '), 3)

    def test_tensor_done_gen2_pending(self):
        def pre(p, put):
            for b in ['0000:01:00.0', '0000:05:00.0']:
                put(f'regs/{b}/tensor', '0x00000888')
        x = self.run_script(['--gen2'], pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertEqual(x['ev'].count('insmod '), 4, 'only policy+vector per card')

    def test_status_is_readonly(self):
        x = self.run_script(['status'])
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertIn('[locked]', x['out'])
        self.assertNotIn('write', x['ev'])

    def test_tensor_only(self):
        x = self.run_script(['--no-gen2'])
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertEqual(x['ev'].count('insmod '), 2)
        self.assertNotIn('retrain', x['out'])
        self.assertNotIn('/reset', x['ev'])

    def test_marker_from_other_boot_blocks_until_force(self):
        def pre(p, put):
            put('var/lib/cmp100-unlock/in-progress', 'boot-0')
        x = self.run_script(pre=pre)
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('previous run did not finish', x['out'])
        self.assertNotIn('unbind', x['ev'])
        x = self.run_script(['--force'], pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])

    def test_interrupted_run_firmware_restored_first(self):
        def pre(p, put):
            put('lib/firmware/nvidia/gv100/acr/ucode_load.bin', 'POLICYUCODE')
        x = self.run_script(pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertIn('interrupted run', x['out'])
        self.assertEqual(x['fw'], 'STOCKUCODE')

    def test_unknown_firmware_refused(self):
        def pre(p, put):
            put('lib/firmware/nvidia/gv100/acr/ucode_load.bin', 'DISTRO-UPDATE')
        x = self.run_script(pre=pre)
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('neither stock nor a known payload', x['out'])
        self.assertNotIn('unbind', x['ev'])

    def test_failed_unbind_stops_without_recovery(self):
        x = self.run_script(env_extra={'MOCK_STICKY_UNBIND': '0000:05:00.0'})
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('remains bound', x['out'])
        self.assertEqual(x['fw'], 'STOCKUCODE')
        self.assertTrue(x['marker'], 'marker must survive a failure')
        tail = x['ev'][x['ev'].rfind('/unbind'):]
        self.assertNotIn('/bind', tail, 'no rebind attempt after a failed unbind')
        self.assertIn('Gen3 stage PASS', x['out'], 'card 1 Gen3 finished before card 2 failed')
        # with --gen2 the Tensor stage runs first, so card 1's unlock must survive card 2's failure
        x = self.run_script(['--gen2'], env_extra={'MOCK_STICKY_UNBIND': '0000:05:00.0'})
        self.assertNotEqual(x['rc'], 0)
        self.assertEqual(x['regs']['0000:01:00.0'], '0x00000888', 'card 1 unlock stays')

    def test_gen2_retry_then_fail_keeps_tensor(self):
        x = self.run_script(['--gen2'], env_extra={'MOCK_NO_GEN2': '1', 'CMP100_RETRAIN_ATTEMPTS': '2'})
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('did not reach Gen2 after 2 attempts', x['out'])
        self.assertEqual(x['out'].count('retrain attempt'), 2)
        self.assertEqual(x['regs']['0000:01:00.0'], '0x00000888')
        self.assertEqual(x['fw'], 'STOCKUCODE')

    def test_bad_bdf_list_rejected(self):
        for bad in ['01:00.0', '0000:01:00.0 0000:01:00.0', '0000:01:00.1']:
            x = self.run_script(env_extra={'CMP100_BDFS': bad})
            self.assertNotEqual(x['rc'], 0, bad)
            self.assertNotIn('write', x['ev'])

    def test_waits_for_late_nvidia_bind(self):
        def pre(p, put):
            (p / 'sys/bus/pci/devices/0000:05:00.0/driver').unlink()
            (p / 'sys/bus/pci/drivers/nvidia').mkdir(parents=True, exist_ok=True)
        x = self.run_script(pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertIn('0000:05:00.0: binding nvidia', x['out'])
        self.assertEqual(x['regs']['0000:05:00.0'], '0x00000888')

    def test_kernel_cmdline_skip(self):
        def pre(p, put):
            put('proc/cmdline', 'quiet cmp100.skip\n')
        x = self.run_script(pre=pre)
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertNotIn('unbind', x['ev'])

    def _held_drm_node(self, p, node_bdf, node='card1'):
        """Create a DRM node in the sandbox owned by `node_bdf`, plus its globe."""
        (p / 'dev/dri').mkdir(parents=True, exist_ok=True)
        (p / 'dev/dri' / node).touch()
        dev = p / 'sys/bus/pci/devices' / node_bdf
        dev.mkdir(parents=True, exist_ok=True)
        (dev / 'vendor').write_text('0x1002' if node_bdf.endswith('0c:00.0') else '0x10de')
        cls = p / 'sys/class/drm' / node
        cls.mkdir(parents=True, exist_ok=True)
        (cls / 'device').symlink_to(p / 'sys/bus/pci/devices' / node_bdf)
        return cls

    def test_foreign_drm_holder_does_not_block_the_run(self):
        """A DRM client on a NON-target GPU (boot splash, desktop) must not stop us.

        Measured on zues: plymouthd holds /dev/dri/card1, which maps to the AMD GPU
        at 0c:00.0, so the boot unit failed every reboot and the cards stayed Gen1.
        """
        def pre(p, put):
            self._held_drm_node(p, '0000:0c:00.0')
        x = self.run_script(pre=pre, env_extra={'MOCK_HELD_NODES': 'card1'})
        self.assertEqual(x['rc'], 0, x['out'])
        self.assertIn('ignoring DRM holders on non-target devices', x['out'])
        self.assertEqual(x['regs']['0000:01:00.0'], '0x00000888')

    def test_target_drm_holder_still_blocks(self):
        """A DRM client on the target card is fatal and must still stop the run."""
        def pre(p, put):
            self._held_drm_node(p, '0000:01:00.0')
        x = self.run_script(pre=pre, env_extra={'MOCK_HELD_NODES': 'card1'})
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('on a target card is open', x['out'])
        self.assertNotIn('unbind', x['ev'])

    def test_unresolvable_drm_holder_blocks(self):
        """If the node cannot be mapped to a card, stay conservative and refuse."""
        def pre(p, put):
            (p / 'dev/dri').mkdir(parents=True, exist_ok=True)
            (p / 'dev/dri/card7').touch()
        x = self.run_script(pre=pre, env_extra={'MOCK_HELD_NODES': 'card7'})
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('on a target card is open', x['out'])

    def test_nvidia_node_holder_blocks_even_when_targets_are_scoped(self):
        """A CUDA client is always our client, regardless of CMP100_BDFS scoping."""
        def pre(p, put):
            (p / 'dev').mkdir(parents=True, exist_ok=True)
            (p / 'dev/nvidia0').touch()
        x = self.run_script(pre=pre, env_extra={'MOCK_HELD_NODES': 'nvidia0'})
        self.assertNotEqual(x['rc'], 0)
        self.assertIn('on a target card is open', x['out'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
