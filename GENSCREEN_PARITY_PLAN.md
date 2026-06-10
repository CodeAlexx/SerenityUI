# Main gen-screen parity campaign — SerenityUI vs SwarmUI (2026-06-10)

Scope: ONLY the main generation screen experience. Team = builder → skeptic →
bug-fixer per phase; the ORCHESTRATOR re-runs every gate (agent reports are
never the gate). One mojo build at a time globally → agents run sequentially.
Function over parity (standing rule): behavior first, pixel-look second.

## The parity checklist (derived from SwarmUI's gen tab; skeptic audits against this)
Params column:
 [P1] model selector backed by DISK SCAN (not hardcoded list)
 [P2] multi-LoRA stack: add/remove + per-LoRA weight slider
 [P3] resolution w/ aspect-ratio presets (1:1, 3:2, 16:9, 9:16, custom) + swap
 [P4] steps, CFG, sampler/scheduler selectors
 [P5] seed + randomize + variation seed + variation strength
 [P6] images-count (batch) semantics
 [P7] init image (img2img): file picker + creativity/denoise slider
 [P8] presets: save/load named param sets (persisted JSON)
Prompt area:
 [P9] prompt + negative editors
 [P10] syntax basics: (text:weight), <lora:name:weight>, <random:a|b>
Generate/output:
 [P11] Generate → resident DAEMON (live per-step progress, cancel) w/ CLI fallback
 [P12] queue rail driven by daemon /v1/jobs
 [P13] output preview pane updates on completion; batch thumbnails
History:
 [P14] persistent history (jobs.db + output dir), survives restart
 [P15] "reuse params" from PNG tEXt (serenity.genparams.v1)
 [P16] star/favorite toggle (persisted)

## Phases (each: builder → skeptic → bugfix → orchestrator gate)
Phase 1 — backend completion [GPU]:
  finish Z-Image GenBackend (WIP serve/zimage_backend.mojo: denoise 20/20 ran,
  decode fix untested) through its full gates; + model/LoRA disk scanner +
  GET /v1/models; + WS preview field plumbed (empty ok).
Phase 2 — UI core (P1-P6, P8, P11, P12, P14-P16):
  daemon client in inference_graph_bridge.mojo per DAEMON_BRIDGE_SPEC.md
  (health, submit, poll, cancel, fallback) + params-column upgrades +
  presets + persistent history + reuse-params + stars.
Phase 3 — gen-screen extras (P7, P9-P10, P13 polish):
  init image + creativity; prompt syntax parsing (weight/<lora:>/<random:>);
  batch thumbnails.

## Gates (orchestrator-run per phase)
G1: daemon zimage e2e — two prompts → two valid, visibly-different,
    prompt-matched images; per-step progress; cancel mid-denoise; job-2
    latency << job-1 (resident win); tEXt params PIL-readable; /v1/models
    lists real disk models.
G2: UI build + scripted run: launch UI, screenshot (DISPLAY=:1), submit via
    daemon, progress visible, cancel works, restart UI → history persists,
    reuse-params restores fields, preset round-trip. Visual check by
    orchestrator on screenshots; final visual sign-off = maintainer.
G3: img2img produces an init-image-conditioned output; syntax parser unit
    gates ((w), <lora>, <random> → JobParams), batch view shows N thumbs.

## Skeptic charter
Attack: every checklist item claimed done (drive the running artifact, not
the code); protocol abuse (bad JSON, double-cancel, dead daemon fallback);
state bugs (restart persistence, queue ordering); visual sanity vs SwarmUI's
layout intent (params left / output center / history right). File findings
as a numbered list with repro commands.

## Generation performance IS in scope (maintainer 2026-06-10)
Parity includes the generation experience, not just controls:
 [G-PERF1] resident-weights iteration: job-N latency seconds-class after the
   first job (no checkpoint reload per generate) — Z-Image first, then the
   other prompt-ready models (Klein 9B/4B, Qwen-Image, ERNIE).
 [G-PERF2] daemon model SWITCHING: selecting a different model loads/swaps the
   resident backend on demand (one resident at a time on 24GB; report swap time).
 [G-PERF3] per-step progress smooth (step()-bounded ticks; UI never freezes).
 [G-PERF4] live preview when cheap (latent->small RGB preview slot; only if a
   bounded-cost path exists — measure, don't force).
INTERNAL CHANGES AUTHORIZED to hit these: resident/fp8 paths (reuse
ideogram4_resident / ltx2 fp8_gemm patterns), loader/dequant restructuring,
new kernels — under the standing constraints: shared ops/* semantics must not
break (other models depend on them), every change parity-gated (cos bars as
established), flame-core SPEED_CONTRACT clauses apply (no per-step host
stalls, no re-upload churn, bench new kernels vs torch at matched shape).
Phase 4 (added): extend the daemon backend registry to the remaining
prompt-ready models with per-model residency + the switch protocol.
