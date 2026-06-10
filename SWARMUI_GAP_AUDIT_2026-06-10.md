# SerenityUI vs SwarmUI — gap audit (2026-06-10)

Source: full SwarmUI 0.9.8 feature sweep (C# ASP.NET + JS web UI + ComfyUI
backends) vs SerenityUI today (pure-Mojo native desktop, MojoUI renderer,
in-process/CLI serenitymojo backends, single user). Filter applied per the
standing rule: FUNCTION over parity — web-server concerns that don't fit a
native single-user app are explicitly skipped, not deferred.

## SerenityUI today (baseline)
3-column Image/Video/Nodes UI; params (model/res/sampling/seed/lora/batch/
advanced), prompt+negative, Generate/Cancel, queue list, in-memory history,
perf footer; 12 models dispatched to serenitymojo CLIs (6 prompt-driven-ready;
CLIP/T5 tokenizers bit-exact); SerenityFlow node-workflow presets. Deferred in
tree: video params, persistence, ControlNet panel, LoRA reorder.

## P0 — the four gaps that define the SwarmUI experience for us
1. **Resident generation daemon + progress streaming + cancel.**
   SwarmUI's core UX is a backend POOL that keeps models loaded and streams
   progress/previews over WebSocket. SerenityUI shells a fresh CLI per
   Generate → full checkpoint reload every image (minutes) vs seconds.
   Build: a per-model resident server process (the ideogram4/LTX2 resident-fp8
   patterns make weights-stay-loaded natural) speaking the SAME decoupled
   protocol the trainer UI already uses (JSONL command file + progress-line
   file + pidfile + kill-TERM cancel). This one item is most of the perceived
   "SwarmUI-ness" (fast iteration loop).
2. **Model & LoRA browser from disk.** SwarmUI scans Models/{diffusion_models,
   loras,embeddings,controlnet} with metadata + thumbnails + search. SerenityUI
   has a fixed 12-entry dropdown and a single LoRA path. Build: scan
   /home/alex/.serenity/models/** (+ loras dir), card list w/ thumbnail +
   arch tag, multi-LoRA stack with per-LoRA weight sliders (runtime-add only,
   per the LoRA-never-fused rule).
3. **Persistent gallery + PNG metadata + "reuse params".** SwarmUI embeds the
   full param JSON in PNG headers and rebuilds the UI state from any image.
   serenitymojo's png.mojo is ours — add a tEXt/iTXt chunk with a
   serenity.genparams.v1 JSON on save; gallery tab = browse output dirs
   (thumbnails, click → load params, star/favorite flag in a sidecar index).
4. **Presets + state persistence.** Save/load named param sets (JSON on disk)
   + persist last UI state across launches (the RON-persistence deferral).

## P1 — next ring (each is a real SwarmUI pillar, applicable to us)
5. img2img/inpaint: init-image picker + creativity (denoise-strength) slider;
   minimal mask editor (brush/eraser/invert, single mask layer) — the full
   layer editor is P2. Backends: VAE encoders exist per model.
6. Video tab wiring: LTX2 refhq + NAVA backends are real now — frames/fps/res
   params, MP4 output cell, audio toggle (LTX2 A/V), progress per stage.
7. Aspect-ratio presets, variation seed + strength, batch-count semantics
   matching SwarmUI (Images count vs batch size).
8. Prompt syntax basics: (text:weight) weighting + <lora:name:weight> (maps to
   the runtime LoRA stack) + <random:a,b>. Wildcards files = P2.
9. Upscaler utility tab: LTX2 spatial upsampler + the flux tile pipeline as
   post-process actions on any gallery image.
10. Queue upgrades: per-job param snapshot, reorder/remove queued jobs,
    interrupt-current (pattern from trainer bridge).

## P2 — later
Grid generator (multi-axis sweep; high value, contained); wildcards dirs;
full layer-mask image editor; live mid-generation preview (needs cheap latent
preview decode per N steps — the tiny-VAE/taesd-class approach must be ported
first); ControlNet/IP-Adapter (needs the model ports first); autocomplete;
themes beyond current; UI sounds; segment/regional prompting.

## SKIP (web-server concerns, wrong fit for native single-user)
Multi-user accounts/roles/API tokens, REST/WebSocket public API, webhooks,
extensions marketplace, Swarm-to-Swarm distributed serving, mobile/browser
sharing, in-UI model downloader (user manages files locally), Simple tab.

## Suggested build order (function-first)
P0.1 resident daemon for ONE model (Z-Image: smallest FULL-conditioning model)
→ P0.3 PNG metadata+gallery (immediately useful for all testing) → P0.2 model/
LoRA browser → P0.4 presets/persistence → P1.5 img2img → P1.6 video tab.
Every step shippable alone; no step blocks generation via the existing CLIs.

## MOJO-libs reuse map (/home/alex/MOJO-libs — same toolchain, Mojo 1.0.0b1/MAX 26.3)
Direct hits on the gap list; integration = cross-repo `-I` include, the
established pattern:

| MOJO-libs | Gap it closes | Notes |
|---|---|---|
| `image/` (PNG/JPEG/WebP DECODE+encode, resize, EXIF) | P1.5 init-image loading (img2img/inpaint), gallery THUMBNAILS (resize), P0.3 metadata embed | ALSO unblocks serenitymojo's "no image decode" gap — the Z-Image/L2P Prepare path can drop python staging entirely (dataset images decoded in-Mojo) |
| `http/` + `net/` (HTTP/1.1+2, router, **websocket.mojo**, staticfiles) + `async/` | **P0.1 resident daemon** as a real localhost HTTP+WS server: POST /generate, WS progress/preview stream, DELETE /job cancel — SwarmUI's exact architecture, pure Mojo, replaces file-polling | Daemon becomes browser-reachable for free later (staticfiles) |
| `json/` (RFC 8259 tree + tape parser) | P0.3 genparams metadata, P0.4 presets, daemon protocol bodies | Replaces ALL hand-rolled string-concat JSON in the bridges (UI config writer, sample-prompts schema) |
| `sqlite/` (pure-Mojo DB engine) | P0.3 gallery index: stars, history, job log, model metadata cache | The SwarmUI-style persistent state store without FFI |
| `graphics/` (canvas, charts, 5x7 text) | Perf footer charts, queue graphs; canvas as the mask-editor backing store (P1.5) | Pixel-verified per its own gates |
| `mem/` (arena/pool/slab/ring) | Daemon allocators | As needed |
| `pdf/` | — not applicable now | (report export, someday) |

CAVEAT (measure before depending): the libs' own test suites exist
(image/tests, http/tests, sqlite/tests) — run them under THIS pixi env before
first integration; JPEG-decode coverage on real dataset files is the one to
verify first (it gates both init-image and the Prepare unlock).

Revised P0.1 shape: the generation daemon = MOJO-libs http router + websocket
+ json, wrapping a resident serenitymojo model (Z-Image first). SerenityUI
talks HTTP/WS to localhost instead of spawning CLIs; the CLI path stays as
fallback.
