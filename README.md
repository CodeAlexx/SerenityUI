# serenityUI

Pure-Mojo text→image / video **inference desktop app**. Reproduces the Flame
v0.4.2 reference UI (the egui app at `EriDiffusion/inference-flame/inference_ui`)
in Mojo only — no Rust.

- **Front-end:** [MojoUI](https://github.com/CodeAlexx/MojoUi) (imported, not vendored).
- **Inference:** serenitymojo (imported, not vendored) — wired model-by-model.

This is a **standalone** repo (Option B): it owns all app code and has its own
pixi env, but imports `mojoui` and `serenitymojo` from where they live so lib
fixes flow in. It vendors neither.

## Layout

```
serenityUI/
  pixi.toml              # own env; include paths to MojoUI + serenitymojo
  src/serenity_ui_main.mojo   # the app (seeded from MojoUI m8, extended)
```

## Build / run

```bash
pixi run build   # compile to /tmp/serenity_ui (CPU-only)
pixi run run     # build + open the window (needs a display)
```

Build links MojoUI's prebuilt C floor (`libmojoui_floor.so`); `run` sets
`LD_LIBRARY_PATH` so the loader finds it.

## Status — phased toward the screenshot

- **P1 — chrome & layout:** title bar (icon · name · version · window controls),
  menu bar (File/Edit/View/Models/Queue/Help + Image|Video tabs + theme toggle),
  status bar; 3 panels offset between menu and status bars; serenity dark palette
  with orange accent. *(in progress — compiles; visual confirm pending)*
- **P2 — canvas:** checkerboard, Fit/zoom toolbar, lightbox, readout strip,
  T2I badge + Enhance/Template, char counter.
- **P3 — right panel:** queue thumbnails + metadata, history grid, telemetry footer.
- **P4 — params depth + persistence:** LoRA stack, model/VAE pickers from a real
  weights dir, model status line, advanced parity, disk persistence.
- **P5 — real serenitymojo backends (GPU):** replace the stub worker model-by-model
  (qwen-image first, then Z-Image), each gated on actually producing an image.
- **P6 — video mode.**

Backend defaults to the deterministic CPU **stub** so the whole app builds and
runs end-to-end without a GPU.
