# SerenityUI campaign TODO (updated 2026-06-11; gen-screen campaign phases 1-4 COMPLETE — see verdict at bottom)

Goal: SwarmUI-class experience, pure Mojo. Audit: SWARMUI_GAP_AUDIT_2026-06-10.md.
Bridge contract: DAEMON_BRIDGE_SPEC.md. Campaign plan + per-phase gates:
GENSCREEN_PARITY_PLAN.md.

## DONE (verified + pushed)
- **MojoUI text-input fixes landed** (MojoUI `21b771c`, 2026-06-11) — the
  prompt boxes (`text_edit` / `text_area`) had three live bugs, all fixed:
  (1) characters accumulating across focus changes → "extra chars"; fixed by
  draining the C text buffer once per frame in `Context.begin_frame`.
  (2) no key auto-repeat → backspace/arrows worked one-press-at-a-time; fixed
  with a held-frames counter + `InputState.key_repeat()`.
  (3) caret drift with no horizontal scroll; fixed with a caret-following
  `scroll_x` + clip in `text_edit`.
  Headless-verified (new `test_text_edit_repro` 6/6 + input/context/textedit/
  text_edit/text_area suites); on-screen feel (held-repeat, caret tracking)
  still needs a display to confirm.
- MOJO-libs validated under serenitymojo toolchain: json 26/26, sqlite 52/52
  (pure Mojo, NO python/pytorch/FFI), png 18/18, jpeg 5/5, http 77/77.
- MOJO-libs png tEXt chunks (encode+read, PIL-gated) — MOJO-libs `eedfea3`.
- Generation daemon skeleton `serenitymojo/serve/` (mojodiffusion `2889926`):
  localhost:7801, POST /v1/generate, jobs/cancel/health, WS /v1/progress
  (full RFC6455), stub backend, genparams in PNG tEXt, jobs.db via pure-Mojo
  sqlite. All gates re-run by orchestrator (curl e2e, PIL, sqlite dump).
- **Gen-screen parity campaign phases 1-4, all skeptic-FIT** (see "CAMPAIGN
  STATUS" at bottom; serenityUI `7190263`/`9bb7c61`/`0f0179c`/`539b8d2`,
  mojodiffusion `cd185d6`/`adffe5e`/`7fb11c1`/`9f60845`/`0932be8`):
  - Z-Image GenBackend COMPLETE (the former "in flight" item) + model scanner
    + /v1/models + WS preview field (mojodiffusion `cd185d6`).
  - UI daemon bridge w/ CLI fallback, params column P1-P6, presets P8,
    daemon generate + queue rail P11-P12, history/reuse-params/stars P14-P16.
  - img2img (init image + creativity) P7, prompt syntax ((w)/<lora>/<random>)
    P10, batch thumbnails P13.
  - Phase 4: Qwen-Image backend + model-switch dispatch (`0932be8`).
- CLIP + T5 tokenizers parity-verified bit-exact vs HF (2026-06-08; re-verified
  2026-06-10) — see MODEL_WIRING_STATUS.md.

## REMAINING (order)
1. F3 GPU confirm (deferred, one run owed): post-OOM CUDA-context recovery —
   zimage->qwen[FAILED]->zimage = done/FAILED/done. [GPU]
2. Phase 5: process-isolation-per-model in the daemon (the robust 24 GB fix
   for the ~21 GB pool-retention limit; GenBackend seam is fork-ready).
3. Wire verified CLIP/T5 ids into the sidecar/prompt-blind model adapters
   (Chroma/SD3.5/SDXL/Anima/FLUX) → prove one image each on GPU
   (MODEL_WIRING_STATUS.md "Next unlock"); fix umt5 trailing-whitespace 7/8.
4. P1 leftovers: video tab (LTX2 refhq/NAVA backends), inpaint mask, upscaler
   tab, queue reorder; WS live preview content (slot plumbed, empty — needs
   cheap latent preview, measure first).
5. Extend daemon residency/switching to remaining prompt-ready models
   (Klein 9B/4B, ERNIE) per G-PERF1/G-PERF2.

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

F3 — POST-OOM CUDA-CONTEXT RECOVERY: **PASS (measured 2026-06-11, GPU run)**.
  Real dispatch-daemon run, 3 jobs, authoritative /v1/jobs states:
    job-0010 zimage -> DONE    (loaded 11.5 GB DiT, ran 4 steps, decoded)
    job-0011 qwen   -> FAILED  (start() raised under the pinned ~21 GB pool — the
                                documented OOM limit; GPU at 21416 MiB when qwen tried 1024² load)
    job-0012 zimage -> DONE    (freed half-built qwen, rebuilt zimage, loaded, ran -> done)
  => the daemon SURVIVES the failed switch and the NEXT job recovers fully. Process
     exit then released the whole pool: 21416 -> 788 MiB (clean OS reclaim).
  Caveat: did not re-capture the literal CUDA_ERROR_OUT_OF_MEMORY string this run
  (sqlite3 CLI absent; error is in jobs.db + /v1/job error field). The recovery
  CLAIM — next job serves after a failed switch — is what's measured-PASS.
  OBSERVABILITY FIX (serenitymojo, this commit): the start()-failure path marked the
  job failed but never printed to stdout (only step()-failures logged "-> failed").
  This silent path is what made the first F3 run ambiguous. Added a symmetric
  print("job ... -> failed (start): <error>"). Daemon rebuild: see commit.

DOCUMENTED-ACCEPTED limit (-> Phase 5): ~21 GB pool retention between jobs;
  process-isolation-per-model is the robust 24 GB fix (daemon GenBackend seam is fork-ready).

CAMPAIGN STATUS: Phases 1-4 all skeptic-FIT. Pure-Mojo SwarmUI gen-screen clone delivered:
  stub/zimage/qwen backends, model scan + /v1/models, dispatch + job-boundary switching,
  img2img, LoRA stack, history pager + PNG tEXt genparams, presets, prompt syntax
  (weights/<lora>/<random>), daemon HTTP+WS+SQLite (pure Mojo), H1-H4 node-sync hooks baked.
  F3 post-OOM recovery: MEASURED-PASS (above). UI<->daemon e2e (--selftest): ALL PASS
  (CPU, stub daemon — genparams H1 round-trip, H2 observer, cancel, double-cancel->409, preset).
  Remaining: Phase-5 process isolation (future node-graph-backend upgrade) — only open item.
