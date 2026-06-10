# SerenityUI campaign TODO (paused 2026-06-10, "stop all")

Goal: SwarmUI-class experience, pure Mojo. Audit: SWARMUI_GAP_AUDIT_2026-06-10.md.
Bridge contract: DAEMON_BRIDGE_SPEC.md. Everything below CPU-buildable except
where marked GPU.

## DONE (verified + pushed)
- MOJO-libs validated under serenitymojo toolchain: json 26/26, sqlite 52/52
  (pure Mojo, NO python/pytorch/FFI), png 18/18, jpeg 5/5, http 77/77.
- MOJO-libs png tEXt chunks (encode+read, PIL-gated) — MOJO-libs `eedfea3`.
- Generation daemon skeleton `serenitymojo/serve/` (mojodiffusion `2889926`):
  localhost:7801, POST /v1/generate, jobs/cancel/health, WS /v1/progress
  (full RFC6455), stub backend, genparams in PNG tEXt, jobs.db via pure-Mojo
  sqlite. All gates re-run by orchestrator (curl e2e, PIL, sqlite dump).

## IN FLIGHT (stopped mid-gate by "stop all")
1. **Z-Image GenBackend** — `serenitymojo/serve/zimage_backend.mojo` WRITTEN,
   UNCOMMITTED. Agent killed during its first e2e: denoise 20/20 done, stopped
   in VAE decode right after applying a DiT-release-before-decode fix.
   RESUME: relaunch builder against existing file; remaining gates = e2e two
   different prompts → visibly different images + per-step progress + cancel
   mid-denoise + job-2 latency (resident-weights win) + tEXt params. [GPU]

## NEXT (order)
2. UI bridge switch (per DAEMON_BRIDGE_SPEC.md): inference_graph_bridge.mojo
   gains daemon client (MOJO-libs http client) w/ health-check + CLI fallback;
   poll /v1/jobs for progress; cancel; queue rail from daemon. Add
   -I /home/alex/MOJO-libs to serenityUI build.
3. P0.2 model/LoRA disk scanner (+ /v1/models endpoint) → replaces fixed
   12-entry dropdown; multi-LoRA stack w/ weights (runtime-add only).
4. P0.3 gallery tab: jobs.db + output-dir browse, thumbnails (MOJO-libs image
   resize), "reuse params" from PNG tEXt, stars.
5. P0.4 presets save/load + UI state persistence.
6. P1: img2img/inpaint (init image via MOJO-libs jpeg/png decode + creativity
   slider + minimal mask), video tab (LTX2 refhq/NAVA backends), aspect
   presets, (text:weight)/<lora:> prompt syntax, upscaler tab, queue reorder.
7. Daemon hardening: /v1/models, WS preview slot (needs cheap latent preview),
   multi-model backend registry (one resident model at a time, swap on demand).

## Parallel campaigns parked elsewhere
- LTX2: serenitymojo/docs/LTX2_TODO.md (quality arms + trainer stages 2+).
- Z-Image/L2P training prepare: 51 samples staged, task #7.

## Phase 4 VRAM work (skeptic F2/F3 vs serve/ daemon @ cd185d6 — deferred by order, 2026-06-10)
Both findings are REAL VRAM engineering, explicitly out of Phase-1 bugfix
scope. Mitigation shipped instead: `ZImageBackend.start()` now rejects every
size except 512x512 with a clear "pending VRAM work (Phase 4)" error (no false
advertising), so neither path is reachable from /v1/generate.
- F2 CRITICAL — 1024x1024 zimage job OOMs at decode: the whole-frame 128-grid
  VAE decode peaks ~23.6 GiB beside the resident DiT (13.2 GiB) on the 24 GB
  GPU → CUDA OOM. The cd185d6 workaround released the resident DiT before the
  128-grid decode (next job reloads), which sacrifices the resident-weights
  win [G-PERF1]. Real fix: tiled/chunked 1024 decode (FLUX 3x3 overlap-blend
  precedent) or decode-time activation budget so the DiT stays resident.
- F3 MAJOR — ~8 GB device-pool retention after a job completes: per-job
  tensors are freed to the DeviceContext pool but the pool does not return
  the VRAM between jobs (nvidia-smi stays high while idle). Real fix: pool
  trim/release-to-OS hook between jobs, or per-job sub-pool with reset.
