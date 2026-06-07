#!/usr/bin/env bash
set -euo pipefail

app_bin=/tmp/serenity_ui

needs_rebuild() {
    local bin=$1
    shift
    if [[ ! -x "$bin" ]]; then
        return 0
    fi
    find "$@" -name '*.mojo' -newer "$bin" -print -quit 2>/dev/null | grep -q .
}

if needs_rebuild "$app_bin" \
    src \
    /home/alex/MojoUI/mojoui \
    /home/alex/mojodiffusion/serenitymojo; then
    mojo build \
        -I . \
        -I /home/alex/MojoUI \
        -I /home/alex/mojodiffusion \
        -Xlinker -L/home/alex/MojoUI \
        -Xlinker -lmojoui_floor \
        -Xlinker -lm \
        src/serenity_ui_main.mojo \
        -o "${app_bin}.next"
    mv "${app_bin}.next" "$app_bin"
fi

echo "READY $app_bin"
