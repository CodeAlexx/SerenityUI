#!/usr/bin/env bash
set -euo pipefail

app_bin=/tmp/serenity_ui
graph_bin=/tmp/mojoui_m6_nodegraph

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

if needs_rebuild "$graph_bin" \
    /home/alex/MojoUI/examples/m6_nodegraph.mojo \
    /home/alex/MojoUI/mojoui/core \
    /home/alex/MojoUI/mojoui/render \
    /home/alex/MojoUI/mojoui/widgets \
    /home/alex/MojoUI/mojoui/nodes \
    /home/alex/MojoUI/mojoui/serde \
    /home/alex/MojoUI/mojoui/app/state.mojo; then
    (
        cd /home/alex/MojoUI
        mojo build \
            -I . \
            -Xlinker -L. \
            -Xlinker -lmojoui_floor \
            -Xlinker -lm \
            examples/m6_nodegraph.mojo \
            -o "${graph_bin}.next"
    )
    mv "${graph_bin}.next" "$graph_bin"
fi

echo "READY $app_bin $graph_bin"
