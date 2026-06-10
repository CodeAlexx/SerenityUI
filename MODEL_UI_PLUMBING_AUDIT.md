# Model → UI plumbing audit (Ideogram4 as the reference) — 2026-06-09

**Goal:** for every UI dropdown model, what plumbing is still needed to reach the
**Ideogram4 bar** = a single pure-Mojo runtime path `prompt string → image PNG`,
no Python/Rust sidecar, no precache, no placeholder tokens.

**Audit only — nothing implemented here.** Status of each layer is from reading
the CLI headers, the component inventory, and `MODEL_WIRING_STATUS.md`. Caveat
(measured): every backend is **compile-verified, none RUN** (built under a busy
GPU). "Works" below means *the plumbing exists*, not *a generation was produced*.

---

## The Ideogram4 reference: the 10 plumbing layers (the bar)

From `serenitymojo/pipeline/ideogram4_generate.mojo` (e2e, image matches torch
PSNR 29.7 dB), a UI-complete model needs ALL of these as pure-Mojo runtime:

| # | Layer | Ideogram4 component | Notes |
|---|---|---|---|
| 1 | **CLI entry / contract** | (demo hardcodes prompt) | UI contract = `<bin> <config.json> <lora\|-> <sample_prompts.json> <id> <out.png>` |
| 2 | **Tokenizer** (text→ids, runtime) | Qwen3 tok | the long-time gate; CLIP/T5/umt5 now ported |
| 3 | **Text encoder** (ids→emb, load→encode→FREE) | `ideogram_qwen3vl` | frees the 17GB encoder before the DiT loads |
| 4 | **Input/noise build** | `build_inputs` | packed latents + randn |
| 5 | **RoPE / positional** | `build_ideogram4_mrope` | |
| 6 | **DiT weights load** | `Ideogram4Weights.load` (cond+uncond) | resident fp8; CFG needs both |
| 7 | **Schedule + denoise loop (CFG)** | `ideogram4_schedule` | |
| 8 | **VAE decode** (latent→image) | `load_ideogram4_vae_decoder` | |
| 9 | **PNG save** | `save_png` | shared |
| 10 | **LoRA overlay variant** | `ideogram4_generate_lora.mojo` | additive, runtime |

**Key reference move (layer 3):** Ideogram4's `encode_prompt(ctx)` does
tokenize → load encoder → encode → **free encoder** in one runtime call. The
missing piece for most other models is exactly this fused `*_encode_runtime`.

---

## Shared infra that already exists (reusable across models)

- **Tokenizers (ported):** CLIP-L, CLIP-bigG, T5-XXL — *bit-exact vs HF* (8/8);
  umt5-xxl 7/8 (trailing-whitespace edge). Qwen3 / Qwen2.5-VL already runtime.
  (`serenitymojo/tokenizer/{clip,t5,...}_tokenizer.mojo`)
- **Text encoders (present):** `clip_encoder`, `t5_encoder`, `umt5_encoder`,
  `qwen3_encoder`, `qwen25vl_encoder`, `ideogram_qwen3vl`, `mistral3b`, `gpt_oss`.
- **VAE decoders (present):** ldm (flux/ideogram), klein, qwenimage, zimage,
  decoder2d/sdxl, wan22, ltx2, acestep.
- **Samplers/schedules (present):** per-model (`sd3_flow_match`, `flux1_dev`,
  `flux2_klein`, `sdxl_euler`, `qwenimage_sampling`, `chroma1_hd`, `ernie_sampling`,
  `anima_sampling`, `ideogram4_schedule`, …).
- **Bridge:** `inference_graph_bridge` registry + generic runner; 12/12 dispatched.

**Implication:** for most models the DiT/VAE/sampler/PNG layers (4–9) already
exist and compile. The remaining work concentrates in **layer 2–3 (runtime
tokenize+encode)** and **per-model RUN verification**.

---

## Per-model audit (gap to the Ideogram4 bar)

Legend — Conditioning today: **FULL** (runtime tokenize+encode, pure-Mojo),
**PRECACHE** (pure-Mojo precache step first), **SIDECAR** (needs external
pre-encoded embedding file), **BLIND** (placeholder tokens, prompt ignored).

| Model | Cond. today | DiT/VAE/sampler | Missing to reach Ideogram4 FULL | RUN-verified? |
|---|---|---|---|---|
| **Z-Image** base/turbo | FULL (Qwen3) | present | nothing structural — needs a real GPU gen + image check | ❌ never run |
| **Qwen-Image** | FULL (Qwen2.5-VL) | present | same — GPU gen + check | ❌ |
| **Klein 9B/4B** | PRECACHE (pure-Mojo) | present | fold precache into one runtime call (optional); GPU gen | ❌ |
| **ERNIE** | PRECACHE (pure-Mojo)¹ | present | tokenizer split caveat¹ + fold precache; GPU gen | ❌ |
| **SD 3.5** | SIDECAR (CLIP-L/G + T5) | present (this session: fwd parity cos 0.99999987, medium trains) | **build `sd3_encode_runtime(prompt)`**: 3 tokenizers (verified) → 3 encoders (present) → joint embed + pooled; replace sidecar read. Then GPU gen | ❌ |
| **Chroma** | SIDECAR (T5-XXL) | present | **`chroma_encode_runtime`**: T5 tok (verified) → `t5_encoder` (present); replace sidecar. GPU gen | ❌ |
| **SDXL** | SIDECAR (dual CLIP)² | present | **`sdxl_encode_runtime`**: CLIP-L+bigG tok (verified) → `clip_encoder` ×2 → concat + pooled; replace the dev-test fallback². GPU gen | ❌ |
| **FLUX Dev** | **FULL — DONE 2026-06-09**³ | present | **e2e GENUINELY VERIFIED**: real CLIP+T5 tokenize→encode→DiT→denoise→**3×3 overlap+blend** tiled VAE→PNG at 1024². Real apple image (mean 66, std 49.8, reddish RGB 87/63/48), pixel-checked. ✅ first UI model truly run end-to-end. | ✅ **RUN (1024², pixel-verified)** |
| **Anima** | SIDECAR (Qwen3+T5 id arrays)⁴ | present | **`anima_encode_runtime`**: tokenize qwen+t5 in Mojo → `anima_text_context` (currently wants 3 pre-tokenized int arrays⁴). GPU gen | ❌ |
| **SD 1.5** | — no pipeline — | absent | full pipeline port (DiT/VAE/sampler/encode) or drop from dropdown | N/A |

¹ ERNIE precache uses `Qwen3Tokenizer` (Qwen2 split) on a tokenizer whose
  `ignore_merges=true` wants the o200k split — candidate one-line fix
  `Qwen3Tokenizer(TOK_JSON, True)` (`ernie_precache_sample_prompts.mojo:125`),
  **unverified**, touches prior-parity code.
² SDXL falls back to a *developer-test* embedding sidecar when `caps_pos` empty
  (`sdxl_sample_cli.mojo:244`, prints `[warn]`).
³ FLUX *was* BLIND (hardcoded BOS/EOS/PAD); **wired 2026-06-09** to real
  `ClipTokenizer`+`T5Tokenizer` (`flux_sample_cli.mojo encode_text`).
  **Correction:** an interim claim that FLUX "ran at 512²/1024²" was based on
  BLANK WHITE images (a blank 1024² PNG compresses to identical bytes, which
  masked it). Root cause (measured): `t5xxl_fp16.safetensors` loaded in fp16, and
  T5-XXL's residual stream overflows fp16 (max 65504) — hit ±inf at layer 10 →
  NaN → all-NaN latent → white image. Fix: cast T5 weights to BF16 at load
  (`t5_encoder.mojo load`). After fix: no NaN through 24 layers, real image
  pixel-verified. The 1024² VAE uses a 3×3 overlapping-tile feathered blend
  (fits the post-DiT allocator pool; the 2×2/72² overlap OOM'd, measured).
⁴ `anima_text_context.mojo` requires `qwen_ids`, `qwen_mask`, `t5_ids` arrays
  from a Python sidecar; needs a runtime Mojo tokenize step in front.

---

## The dominant work item (one shape, repeated)

For **SD 3.5, Chroma, SDXL, FLUX, Anima** the gap is the SAME pattern Ideogram4
already solves: a fused **`<model>_encode_runtime(prompt, negative, ctx) → (seq,
pooled)`** that chains the now-verified tokenizer(s) + the existing encoder(s),
load→encode→free, and drop the sidecar/placeholder read in the CLI. The
tokenizers (CLIP/T5) are ported + bit-exact; the encoders exist. This is wiring,
not new math.

Per-model encoder recipe:
- **SDXL** → CLIP-L + CLIP-bigG (concat last_hidden) + bigG pooled.
- **SD 3.5** → CLIP-L + CLIP-bigG + T5-XXL (joint context) + CLIP pooled.
- **Chroma** → T5-XXL only.
- **FLUX** → CLIP-L pooled + T5-XXL sequence.
- **Anima** → Qwen3 + T5 (runtime tokenize in front of `anima_text_context`).

## Cross-cutting gaps (apply to ALL)
1. **Nothing has been RUN** — all compile-only. Each model needs one real GPU
   generation + an eyeball/PSNR check before "UI-ready" is true.
2. **umt5 7/8 tokenizer** — trailing-whitespace edge (affects Anima-umt5 / Wan).
3. **LoRA at inference** — Ideogram4 has a `_lora` variant; confirm each CLI's
   `<lora>` arg actually overlays at runtime (Z-Image/Klein do; others: verify).
4. **Config/path consistency** — each CLI hardcodes model paths via comptime
   constants; the UI passes a `config.json` — confirm every CLI reads paths from
   config, not just comptime (audit per CLI; Ideogram4's generate hardcodes).

## Suggested priority (cheapest → highest-value)
1. **Run the 4 already-FULL/PRECACHE models** (Z-Image, Qwen-Image, Klein, ERNIE)
   on GPU — proves the whole bridge→CLI→image path end-to-end. Lowest effort,
   highest information.
2. **SDXL & Chroma `*_encode_runtime`** — single-encoder (CLIP×2 / T5) wires;
   smallest conditioning lift.
3. **SD 3.5 `*_encode_runtime`** — 3-encoder, but this session's forward is
   parity-verified, so the DiT side is trustworthy.
4. **FLUX, Anima** — multi-encoder + (Anima) tokenize-in-front-of-context.
5. **SD 1.5** — decide: port or drop.
