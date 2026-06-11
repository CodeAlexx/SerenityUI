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

  PHASE-4 INVESTIGATION (2026-06-10, MEASURED, dispatch daemon @ this build):
  ROOT CAUSE confirmed and the proposed fix DOES NOT REACH the pool —
  documented here so the next attempt doesn't re-walk it.
    * The Mojo GPU runtime's `DeviceContext` (std.gpu.host) is a SINGLETON (ctx.id()==0 for every instance,
      one shared default stream + ONE caching allocator). Dropping a backend
      drops its DeviceBuffers (AsyncRT_DeviceBuffer_release) back to the Mojo runtime's
      caching pool, but the singleton's refcount NEVER hits zero while any
      DeviceContext value lives (the daemon always holds one), so the pool is
      never destroyed → bytes never return to the OS. nvidia-smi stays at the
      HIGH-WATER MARK (measured: zimage job peaks 21.4 GB resident-DiT(13) +
      per-job Qwen3-4B encoder(7.5); pool then pins ~21 GB while idle).
    * cuMemPoolTrimTo HOOK ADDED + WIRED (serenitymojo/offload/vmm_cuda.mojo
      cu_device_get_mempool / cu_mempool_trim_to / cu_mempool_trim_current;
      called from dispatch_backend._free_current + between_jobs_trim + the
      daemon job-boundary). It RECLAIMS 0 MiB — the Mojo runtime's (AsyncRT) allocator does NOT
      allocate from the CUDA *default* stream-ordered mempool, so a
      driver-level cuMemPoolTrimTo on that pool finds nothing of the runtime's to
      free. AsyncRT references cuMemPool* but uses its own pool/strategy; the
      trim is a no-op against it. (The hook is left in place — harmless, and
      correct if a future Mojo-runtime build routes through the default pool.)
    * CONSEQUENCE for switching (G-PERF2): zimage->qwen OOMs. After a zimage
      job the pool is pinned at ~21 GB; the incoming qwen 1024² CFG forward
      activations push past 24 GB (CUDA_ERROR_OUT_OF_MEMORY in the first
      denoise step). The SWITCH MECHANISM is correct (free old backend, build
      new, /v1/health tracks resident); qwen->zimage->qwen (heaviest peak
      FIRST, its pool absorbs the lighter model) round-trips fine. zimage->
      qwen->zimage gives done/FAILED/done.
    * WHAT'S ACTUALLY NEEDED (none available in this build):
      (a) a Mojo-runtime-internal "release cached buffers to OS" API on DeviceContext
          (the docstring says __del__ frees cached buffers at refcount 0 — we
          need that reachable WITHOUT destroying the singleton), or
      (b) the Mojo runtime routing its allocator through the CUDA stream-ordered default
          pool so cuMemPoolTrimTo binds, or
      (c) PROCESS ISOLATION: run each resident model in a child process; a
          model switch = kill child + spawn new (the OS reclaims on exit).
          This is the robust 24 GB answer and is the recommended Phase-5
          change (the daemon already has a clean GenBackend seam to fork on).
    NOT FAKED: 1024 stays gated and the gate reports the OOM honestly.

---

## PHASE 4 — SKEPTIC VERDICT: FIT (2026-06-11)

Builder: Qwen-Image backend + model-switch dispatch + VRAM diagnosis (serenitymojo 0932be8).
Skeptic (ade0e4b76d8bee5b9, CPU+static; GPU work halted mid-run on user OOM/remote-GPU):
verdict = **PHASE 4 FIT — switching is real and honest**.

Defects found + FIXED (serenitymojo 2855587):
  * F1 vmm_cuda.mojo:140 — "MAX's DeviceContext caching allocator" -> "the Mojo
    GPU runtime's (AsyncRT) DeviceContext caching allocator" (comment-only).
  * F2 backend.mojo:138 — "pool-managed-by-MAX" -> "pool-managed-by-the-Mojo-runtime".
  Repo-wide grep after fix: CLEAN, no MAX-engine prose mislabels remain.
  Import-smoke build of both modules: exit 0.

Verified clean (static + CPU compile):
  * tiled decode (zimage_tiled_decode.mojo) compiles + instantiates; honestly
    DEAD CODE (1024 zimage gated at start(), decoder never reached — not falsely advertised).
  * F1 lora clamp: --selftest-syntax 14/14 PASS (out-of-range ->[-10,10] w/ note).
  * Qwen backend is parameter-driven by construction (steps/cfg/seed/negative all wired);
    non-1024/LoRA/img2img rejected at start() with clear errors; cancel-first in step().
  * between_jobs_trim() genuinely called at every terminal job boundary; 0-MiB reclaim
    honestly documented (AsyncRT allocator not bound by cuMemPoolTrimTo).
  * _kind_for_model fail-loud on unknown; free-then-construct at job boundary; residency tracked.

OPEN GAP — F3 (GPU-only, DEFERRED to a GPU-free window):
  Post-OOM CUDA-context recovery for the job AFTER a failed switch is unproven.
  Static path is clean (OOM -> job FAILED + _clear_job, daemon worker survives), but whether
  the CUDA context recovers enough to serve the NEXT job after an in-denoise
  CUDA_ERROR_OUT_OF_MEMORY needs one real GPU run (zimage->qwen[FAILED]->zimage = done/FAILED/done).
  Single confirming run owed when the user clears the GPU. Not a known defect — an unverified claim.

DOCUMENTED-ACCEPTED limit (-> Phase 5): ~21 GB pool retention between jobs;
  process-isolation-per-model is the robust 24 GB fix (daemon GenBackend seam is fork-ready).

CAMPAIGN STATUS: Phases 1-4 all skeptic-FIT. Pure-Mojo SwarmUI gen-screen clone delivered:
  stub/zimage/qwen backends, model scan + /v1/models, dispatch + job-boundary switching,
  img2img, LoRA stack, history pager + PNG tEXt genparams, presets, prompt syntax
  (weights/<lora>/<random>), daemon HTTP+WS+SQLite (pure Mojo), H1-H4 node-sync hooks baked.
  Remaining: F3 GPU confirm (deferred) + Phase-5 process isolation (future upgrade).
