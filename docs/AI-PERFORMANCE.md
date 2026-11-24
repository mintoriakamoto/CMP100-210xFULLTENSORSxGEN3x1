# Getting AI throughput out of a CMP 100-210 (and notes for 170HX)

This card's compute is not the bottleneck. Once Tensor is unlocked a CMP 100-210
does ~87 TFLOP/s FP16 (see `RESULTS.md`), and its HBM2 already runs at 90-99% of
theoretical bandwidth. The thing that actually caps real AI workloads is the
**PCIe x1 link** (no NVLink, no working P2P), and the usual mistake is running a
parallelism strategy the link cannot carry.

Everything here is a **reversible, software / build-time / NVML lever** — no
firmware writes, nothing that can brick a card. Numbers are tagged
**[measured-here]** (reproduced on this project's own 100-210 cards),
**[community]** (reported upstream with a reproducible recipe, not yet
re-measured here), or **[spec]** (a hardware/instruction fact). Treat
[community] numbers as directional until you reproduce them on your box.

> This file is guidance, not code the unlock tool runs. The unlock tool only
> lifts the Tensor/PCIe/HBM gates; the levers below live in your inference
> stack and your launch flags.

---

## TL;DR — the levers that move the needle

| Lever | Card | Win | Risk | Tag |
|---|---|---|---|---|
| **`GGML_CUDA_FORCE_MMQ=ON`** (llama.cpp build) | 100-210 | **pp ~3x** on dense (kills the ubatch cliff) | none | [community] |
| **Pipeline-parallel, not tensor-parallel** | both | **4-6.6x** multi-card vs TP | none | [community] |
| **Pick MoE / sparse-active models** | both | makes "too big" models usable | none | [community] |
| **int8/int4 KV cache** (Volta) · **fp8 KV** (170HX only) | both | more context fits + faster decode | none | [community] |
| HBM VF offset `CMP100_HBM=877` | 100-210 | ~+8% mem bandwidth | none | [community] |
| Gen3 link (this project) | 100-210 | **model load ~4.5x**; *not* decode | none | [measured-here] |

The single biggest **unshipped** win for the 100-210 is a one-line build flag:
`GGML_CUDA_FORCE_MMQ=ON`.

---

## 1. The real bottleneck: interconnect, not compute

A CMP 100-210 is PCIe **Gen1 x1** stock (this project lifts it to Gen3 x1, ~1 GB/s),
with no NVLink and no working peer-to-peer. That link is a **model-load and
tensor-parallel-collective cost — not a steady-state serving cost.**

Proof from this project's own data [measured-here] (`RESULTS.md`, 2x 100-210):

- Gen1 -> Gen3 x1 cut a 5.3 GB model load **34.3 s -> 7.7 s (4.5x)**.
- In the same runs, prefill (~2200 tok/s) and decode (61-65 tok/s @196k ctx) were
  **identical before and after.**

So: raise the link for faster *loading*, but do **not** expect the link to change
per-token rates once weights and KV are resident. For decode, spend your effort on
parallelism strategy and bytes-moved, not GT/s.

---

## 2. Build-time levers (llama.cpp / ggml-cuda)

### `GGML_CUDA_FORCE_MMQ=ON` — the big one (100-210)
These cards suffer a "ubatch cliff": prompt processing collapses at `ubatch >= 64`
because ggml's auto-dispatch falls off the integer MMQ path onto cuBLAS. Forcing
MMQ removes the cliff, and `ubatch 512` becomes the *fastest* config.

```
cmake -B build -DGGML_CUDA=ON -DGGML_CUDA_FORCE_MMQ=ON \
      -DCMAKE_CUDA_ARCHITECTURES=70 -DCMAKE_BUILD_TYPE=Release
```
`[community]` Stock 100-210, dense Qwen 27B Q4_K_M, 8192-token prompt:
**pp8192 148.6 -> 441.5 tok/s (~3.0x)**; the 330->92 ubatch-64 cliff disappears.
(Source: ggml-org/llama.cpp#25139, #26810.) Use arch `80` for a 170HX, `86` for
90HX/70HX.

An older fix (llama.cpp#25139) hard-caps dense matmuls to 56-token chunks on CMP
devices only (+57% dense in a hybrid rig). `FORCE_MMQ` supersedes it (cleaner, and
it also helps MoE); keep the chunker only where you cannot rebuild with FORCE_MMQ.

### 170HX-only instruction levers — do NOT use on the 100-210
The Ampere CMP 170HX throttles fused FP32 FMA and native `__dp4a` specifically.
`[community]` `-DDISABLE_DP4A` (emulate dp4a as 2xPRMT + dp2a) and
`nvcc --fmad=false` together give **2.0-2.33x** decode on a 170HX. These target
the *170HX's* nerfed instructions; the Volta 100-210 does not share that throttle,
so the flags buy it nothing and `--fmad=false` can cost it. Gate by arch.

---

## 3. Parallelism strategy — the part people get wrong

### Pipeline-parallel (PP) >> tensor-parallel (TP) on an x1/x4 fabric
TP does a per-layer all-reduce (~86 collectives per forward pass); the slow link
cannot carry them, so TP throughput goes **flat** regardless of context. PP passes
one hidden-state tensor between adjacent stages (a few hops total) and survives.

`[community]` PP8 vs TP8 decode **30.2 vs 3.4 tok/s**; PP ~4-6.6x TP on prefill
(allover326/deepseek-v4-cmp170hx; developer-forum "1T VRAM" thread). In vLLM prefer
`--pipeline-parallel-size` over `--tensor-parallel-size` on these clusters.

### Data-parallel when the model fits on one card
With no P2P, `TP=2` is often **slower than a single card**. If the model fits,
run one engine per card (DP): `[community]` DP2 ~1.92x a single card
(syv-ai/HyperQwen multi-gpu notes).

### Choose MoE / sparse-active models
Only *active* parameters hit the link and the compute each step, so a sparse model
is itself the workload-shaping lever. `[community]` GLM-5.2 744B/**40B-active**:
30 tok/s decode, 2675 prefill tok/s @131k on 8x 170HX (PP8, W4A16).

### Two more decode levers (PP rigs)
- **Speculative decoding under PP** `[community]` ~1.93x single-stream decode
  (50.8 -> 98.1 tok/s). Needs small vLLM patches (upstream refuses spec+PP in a few
  places). On *TP* speculation goes negative past ~8 concurrent — another reason to
  prefer PP.
- **Pinned-host activation bridge + prefill pipelining** `[community]` hides the x1
  latency behind compute via double-buffered host-staged handoff (no P2P). On a
  *100-210* (sm_70, Gen1 x1): 9B 18K prefill **259 -> 720 tok/s (2.78x)**, output
  bit-equivalent (Haru-neo/qengine).

---

## 4. Memory: capacity and bandwidth

- **HBM clock**: `CMP100_HBM=877` (this project's `cmp100-memclk`, +138 NVML VF
  offset) raises 810 -> 877 MHz, ~+8% bandwidth `[community]`. That is near the
  *whole* remaining envelope — these cards already hit 90-99% of theoretical HBM
  bandwidth, so there is no "double the bandwidth" lever hiding here.
- **Move fewer bytes instead**: quantize the KV cache. Volta (100-210, cc 7.0) has
  no fp8 — use **int8/int4 KV**. Only the 170HX (cc 8.0) can do **fp8 KV**:
  `[community]` +27% decode @100k ctx and a larger KV pool, quality-neutral
  (syv-ai/HyperQwen #153).

---

## 5. What NOT to chase (debunked here so you don't waste a weekend)

- **"ECC off frees ~6% VRAM"** — false on these cards. `[spec]` HBM2/HBM2e uses
  native side-band ECC (~0% capacity/bandwidth cost), unlike GDDR5/Kepler inline
  ECC where the 6% comes from. And these CMP cards ship **ECC already off**. Action
  is only to *confirm*: `nvidia-smi -q -d ECC`.
- **SM/graphics-clock VF offset** — not worth a lever. `[community]` SM offset +200
  measured "within noise", and on some 170HX VBIOSes the NVML range reads `[0..0]`
  (no headroom exposed). This project deliberately ships no SM-clock lever.
- **Chasing link speed for decode** — see section 1; it only helps load time.
- **`NVreg_RegistryDwords="RMPcieLinkSpeed=0x1"`** — a footgun: it is a
  *driver-wide* cap that pins **every** nvidia GPU on the host to 2.5 GT/s and is
  re-applied on each driver load. This project dropped it in 1.1.1; keep your
  `modprobe.d` clean (`grep RegistryDwords /proc/driver/nvidia/params` should print
  nothing).

---

## 6. Notes for the CMP 170HX (GA100 / A100-class) — out of this repo's scope

The 170HX is a much bigger AI card (sm_80, A100 silicon). Its headline unlocks —
memory-geometry (10->40 / 8->64 GB) and compute-throttle removal (community reports
up to ~193 TFLOP/s tensor) — are done by a **firmware/BootROM exploit**, which this
project does not implement or reproduce; see the upstream tools
(amoghmunikote/cmpunlocker, Consensus-Protocol/cmp170hx, adam-s-tech) and weigh the
brick risk yourself. What *is* safe, reversible software, if you run 170HX cards:

- **PP-over-TP, MoE models, spec-decode, int8/fp8 KV** — all of sections 2-4 apply,
  with fp8 KV available (cc 8.0).
- **`RmForceEnableGen2=1`** keeps a 170HX at Gen2 x16 across driver reloads (this is
  the *correct* dword for that board — never the `RMPcieLinkSpeed` footgun above).
- **ACS redirect disable** on PLX switch ports: `[community]` 1.20 -> 1.68 GB/s
  same-switch (`pci=disable_acs_redir`, or live via `setpci ... ECAP_ACS+6.w=0`).
- **BAR1 P2P / NCCL-over-SHM**: real peer DMA needs open-kernel-module patches
  (needs the hardware to validate); without it, NCCL falls back to host-staged SHM
  and TP/PP still work (`[community]` ~6.2 GB/s host-staged, ~94% of link).
  Benchmarks show forcing BAR1 P2P can be *slower* than SHM for TP4 on some
  PLX/Broadwell hosts — measure, don't assume.

---

## Sources

- This project: `docs/RESULTS.md` (Gen1->Gen3 load-vs-serving, HBM), `tools/cmp100-memclk.c`.
- llama.cpp: ggml-org/llama.cpp#25139 (ubatch cliff, 56-token chunker, FORCE_MMQ),
  #26810 (70HX sniffer, FORCE_MMQ), #24616 / PR #25834 (dp2a, `--fmad=false`).
- Multi-GPU recipes: allover326/deepseek-v4-cmp170hx, Haru-neo/qengine,
  syv-ai/HyperQwen, PixelML/club-170hx, bayley/cmpunlocker.
- 170HX empirical review: niconiconi.neocities.org CMP 170HX notes; arXiv 2505.03782.

All third-party numbers are community-reported unless this repo re-measured them.
