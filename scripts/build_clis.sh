#!/usr/bin/env bash
# Prebuild the CLI-fallback backends serenityUI spawns (F4: the UI itself
# NEVER runs `mojo build` and never blocks on a build).
#
# Usage: scripts/build_clis.sh [slug ...]
#   default: zimage (covers the "Z-Image (base/turbo)" dropdown entries)
#   known slugs: zimage klein9b klein4b qwenimage chroma sd35 sdxl ernie
#                flux anima
#
# One mojo build at a time (global rule) — builds run sequentially.
set -euo pipefail

ROOT=/home/alex/mojodiffusion
BIN="$ROOT/output/bin"
PIXI=/home/alex/.pixi/bin/pixi
mkdir -p "$BIN"
cd "$ROOT"

build() { # build <src.mojo> <out-bin>
    local src=$1 out=$2
    if [[ -x "$out" && -z $(find "$src" -newer "$out" 2>/dev/null) ]]; then
        echo "OK (cached) $out"
        return 0
    fi
    echo "BUILD $out  <-  $src"
    "$PIXI" run mojo build -I . -Xlinker -lm -Xlinker -lcuda "$src" -o "$out.next"
    mv "$out.next" "$out"
    echo "OK $out"
}

do_slug() {
    case "$1" in
    zimage)
        # zimage_generate serves both dropdown entries (base + turbo slugs)
        build serenitymojo/pipeline/zimage_generate.mojo "$BIN/zimage_base_serenity_cli"
        cp -f "$BIN/zimage_base_serenity_cli" "$BIN/zimage_turbo_serenity_cli"
        echo "OK $BIN/zimage_turbo_serenity_cli (copy)"
        ;;
    klein9b)
        build serenitymojo/pipeline/klein9b_precache_sample_prompts.mojo "$BIN/klein9b_precache"
        build serenitymojo/sampling/klein_sample_cli.mojo "$BIN/klein9b_serenity_cli"
        ;;
    klein4b)
        build serenitymojo/pipeline/klein9b_precache_sample_prompts.mojo "$BIN/klein4b_precache"
        build serenitymojo/sampling/klein_sample_cli.mojo "$BIN/klein4b_serenity_cli"
        ;;
    qwenimage) build serenitymojo/pipeline/qwenimage_sample_cli.mojo "$BIN/qwenimage_serenity_cli" ;;
    chroma)    build serenitymojo/pipeline/chroma_sample_cli.mojo "$BIN/chroma_serenity_cli" ;;
    sd35)      build serenitymojo/pipeline/sd3_sample_cli.mojo "$BIN/sd35_serenity_cli" ;;
    sdxl)      build serenitymojo/pipeline/sdxl_sample_cli.mojo "$BIN/sdxl_serenity_cli" ;;
    ernie)
        build serenitymojo/pipeline/ernie_precache_sample_prompts.mojo "$BIN/ernie_precache"
        build serenitymojo/pipeline/ernie_sample_cli.mojo "$BIN/ernie_serenity_cli"
        ;;
    flux)      build serenitymojo/pipeline/flux_sample_cli.mojo "$BIN/flux_serenity_cli" ;;
    anima)     build serenitymojo/pipeline/anima_serenity_cli.mojo "$BIN/anima_serenity_cli" ;;
    *) echo "unknown slug: $1" >&2; exit 1 ;;
    esac
}

slugs=("$@")
[[ ${#slugs[@]} -eq 0 ]] && slugs=(zimage)
for s in "${slugs[@]}"; do
    do_slug "$s"
done
echo "ALL DONE"
