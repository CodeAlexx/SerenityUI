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
