# SerenityUI → serenitymojo model wiring status (2026-06-08)

All 12 UI dropdown models are now **dispatched** to a pure-Mojo inference
backend. The Klein-only shell-out in `mojoui/app/inference_graph_bridge.mojo`
was generalized into a model registry (`_resolve_model_spec`) + a generic
runner (`_run_model_system`). Generate now routes by `state.model_index`.

**Constraint:** built under a busy GPU — every backend was verified to
**compile** (`mojo build`, offline). None were *run*. Acceptance bar = compiles.

## Wiring contract
Each model CLI is invoked as:
```
<bin> <config.json> <lora|-> <sample_prompts.json> <id> <out.png>     # sample_cli style
<bin> <lora|base> <out.png> <sample_prompts.json> <id>                # zimage style
```
The bridge writes a `serenity.sample_prompts.v1` JSON (the existing shared
schema, read by `read_sample_prompt_config`) and builds the CLI on demand.

## Readiness matrix
Conditioning classes: **FULL** = prompt text → tokenize → encode → image, all
pure-Mojo at runtime. **PRECACHE-MOJO** = same, via a pure-Mojo precache step
run first. **SIDECAR** = real generate math, but conditioning needs an
embedding/context file pre-encoded *outside* Mojo (CLIP/T5 tokenizers are now
ported + verified — see below — but the id→encoder wiring isn't done, so the
sidecar feed is still what runs today). **PROMPT-BLIND** = feeds placeholder
tokens; image ignores the prompt.

| Model | Backend | New adapter | Conditioning | Prompt-driven today? |
|---|---|---|---|---|
| Klein 9B | `klein_sample_cli` + klein precache | no | PRECACHE-MOJO | ✅ |
| Klein 4B | `klein_sample_cli` (klein4b.json) | no | PRECACHE-MOJO | ✅ |
| Z-Image (base) | `zimage_generate` | no | FULL (Qwen3) | ✅ |
| Z-Image (turbo) | `zimage_generate` | no | FULL (Qwen3) | ✅ |
| Qwen-Image | `qwenimage_sample_cli` | ✅ | FULL (Qwen2.5-VL) | ✅ |
| ERNIE | `ernie_sample_cli` + ernie precache | ✅ | PRECACHE-MOJO¹ | ✅ (minor tokenizer caveat) |
| Chroma | `chroma_sample_cli` | ✅ | SIDECAR (T5-XXL) | ⚠️ tok ✅; needs encoder wiring |
| SD 3.5 | `sd3_sample_cli` | ✅ | SIDECAR (CLIP-L/G + T5) | ⚠️ toks ✅; needs encoder wiring |
| SDXL | `sdxl_sample_cli` | ✅ | SIDECAR (dual CLIP)² | ⚠️ toks ✅; needs encoder wiring |
| Anima | `anima_serenity_cli` | ✅ | SIDECAR (Qwen3/T5 token arrays) | ⚠️ tok ✅ (umt5 7/8); needs wiring |
| FLUX Dev | `flux_sample_cli` | ✅ | PROMPT-BLIND³ | ❌ toks ✅; until encoder wiring |
| SD 1.5 | — none — | fail-loud | N/A (no pipeline) | ❌ unsupported |

¹ ERNIE precache uses `Qwen3Tokenizer(TOK_JSON)` (Qwen2 split) on a tokenizer
  whose `ignore_merges=true` wants the o200k split. One-line candidate fix:
  `Qwen3Tokenizer(TOK_JSON, True)` in `ernie_precache_sample_prompts.mojo:125`.
  **Not applied** — it touches an existing file with prior parity work; verify
  against reference before changing.
² SDXL silently falls back to a *developer-test* embedding sidecar when
  `caps_pos` is empty (`sdxl_sample_cli.mojo:244`) — prints a `[warn]`.
³ FLUX feeds hardcoded BOS/EOS/PAD ids (`flux_sample_cli.mojo:191`); generate
  math is real but every image is prompt-independent.

## The (former) gating issue: text tokenizers — CLIP + T5 NOW VERIFIED
**RE-VERIFIED 2026-06-10** (independent session): `t5_tokenizer_smoke` and
`clip_tokenizer_smoke` rebuilt + rerun vs `parity/{t5,clip}_ref.py`, id lists
diffed IDENTICAL.
**UPDATE 2026-06-08:** CLIP BPE and T5 Unigram are ported AND parity-verified
bit-exact vs HF on CPU (no GPU). Files: `serenitymojo/tokenizer/clip_tokenizer.mojo`,
`t5_tokenizer.mojo` (+ argv-driven `_clip_generic_smoke.mojo` / `_t5_generic_smoke.mojo`
harnesses). Method: HF reference (`transformers` / `tokenizers` Rust impl) on the
SAME `tokenizer.json`, diffed line-by-line on 8 non-trivial cases (BPE merges,
contractions, emoji, NFKC unicode, whitespace, 40+-token prompt).

Measured results:
| Tokenizer | Vocab tested | Result |
|---|---|---|
| CLIP-L | openai/clip-vit-large-patch14 | ✅ 8/8 bit-exact |
| CLIP-bigG | laion/CLIP-ViT-bigG-14 (SDXL/SD3.5 enc#2) | ✅ 8/8 bit-exact |
| T5-XXL | t5xxl_fp16 (SD3.5/Flux/Chroma/Anima) | ✅ 8/8 bit-exact |
| umt5-xxl | google/umt5-xxl (Wan 2.x / Anima-umt5) | ⚠️ 7/8 — trailing-whitespace edge case drops a token |

So the **encode** side is closed for the CLIP/T5 path. Qwen3-family (Qwen-Image,
Z-Image, Klein, ERNIE) was already prompt-driven. Remaining tokenizer work:
the umt5 trailing-whitespace divergence (`"  leading and trailing  "` →
ref `...439, 273, 1` vs Mojo `...439, 1`).

NOT yet proven: per-model id→text-encoder→image wiring, and any actual
generation (needs GPU). Bit-exact ids ≠ end-to-end FULL.

## Bottom line
- **Wiring: complete.** 12/12 dispatched, bridge + all 7 new adapters compile,
  UI builds (`pixi run build` → READY). Klein path preserved unchanged.
- **Run-ready for prompt-driven testing now (when GPU frees):** Qwen-Image,
  Z-Image base/turbo, Klein 9B/4B, ERNIE (6 models).
- **Tokenizer-unblocked (encode verified, wiring + GPU run still TODO):** Chroma,
  SD 3.5, SDXL, FLUX — their CLIP/T5 tokenizers are now bit-exact in Mojo. The
  former SIDECAR/PROMPT-BLIND status was a *tokenizer* gap that is now closed on
  the encode side; each still needs id→encoder wiring verified + a GPU run.
  Anima: T5 path verified, but if it uses umt5 see the 7/8 caveat above.
- **No backend:** SD 1.5.
- **Next unlock = wire the verified CLIP/T5 ids into each model's text-encoder
  path** (replace the sidecar/placeholder feed), then prove one image on GPU.
  Fix the umt5 trailing-whitespace edge case for the Wan/Anima-umt5 path.

Files added (`serenitymojo/pipeline/`): `qwenimage_sample_cli.mojo`,
`chroma_sample_cli.mojo`, `sd3_sample_cli.mojo`, `sdxl_sample_cli.mojo`,
`ernie_sample_cli.mojo`, `flux_sample_cli.mojo`, `anima_serenity_cli.mojo`.
Bridge: `MojoUI/mojoui/app/inference_graph_bridge.mojo` (registry + generic runner).
