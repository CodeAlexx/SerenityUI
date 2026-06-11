"""MojoUI m8 — interactive text->image generation app.

A real, interactive MojoUI desktop app mirroring the egui `inference_ui`
reference (Image mode only), driven through the MojoUI graph executor. Clicking
Generate snapshots the params into a Comfy-shaped Klein 9B workflow, runs the
existing pure-Mojo Klein sampler path, uploads the completed PNG as a texture,
and pushes history.

Layout (3 columns):
  - LEFT params panel: model · resolution · sampling · seed · lora · batch ·
    advanced (collapsing headers + combobox/slider/drag_value/checkbox).
  - CENTER canvas: task header · prompt + negative text_area · action bar
    (Generate / Cancel / randomize seed) · generated image preview · progress.
  - RIGHT panel: queue list (running + queued w/ per-job progress) · history ·
    perf footer (backend telemetry once the graph runner feeds metrics).

DEFERRED (per M4 scope scope): Video mode (frames/fps), RON persistence
(state is in-memory only), the controlnet panel, egui-dnd LoRA reorder.

Build + run: `pixi run inference`. Build-then-run scaffold (text_area /
combobox / tessellator reach FFI symbols the JIT cannot dlopen); the c50
user_data extension carries persistent state across frames; the post-run
keep-alive print prevents ASAP-destruction from freeing state early.
"""

from std.io.file import open
from std.memory import UnsafePointer
from std.sys import argv
from std.time import sleep
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_RELEASED, OPT_NONE
from mojoui.core.textedit import TextEditState
from mojoui.core.commands import (
    CMD_JUMP, CMD_RECT, CMD_TEXT, CMD_IMAGE, CMD_TRIANGLES,
    CmdTriangles, read_cmd_rect, read_cmd_text, read_cmd_image,
    read_cmd_triangles,
)
from mojoui.core.multiline_edit import MultiLineState
from mojoui.render.backend import Backend
from mojoui.render.command_renderer import render_context_commands
from mojoui.render.ffi import (
    MOJOUI_BTN_RIGHT,
    MOJOUI_KEY_RETURN,
    MOJOUI_KEY_ESCAPE,
)
from mojoui.widgets.basic import button, button_primary, label, separator
from mojoui.widgets.text_area import text_area
from mojoui.widgets.text_edit import text_edit
from mojoui.widgets.combobox import combobox
from mojoui.widgets.slider import slider
from mojoui.widgets.drag_value import drag_value
from mojoui.widgets.checkbox import checkbox
from mojoui.widgets.progress_bar import progress_bar
from mojoui.widgets.collapsing_header import collapsing_header
from mojoui.render.tessellator import tess_rounded_rect
from mojoui.app.state import store_user_state, retrieve_user_state
from mojoui.app.inference_model import (
    InferenceState,
    LoraSlot,
    QueueJob,
)
from mojoui.app.inference_graph_bridge import (
    GraphUiRuntime,
    build_klein9b_inference_graph,
    daemon_cancel_submitted,
    daemon_refresh_health,
    daemon_submit_params,
    dry_run_klein9b_graph,
    graph_has_port_metadata,
    graph_backend_label,
    graph_cancel_all,
    graph_progress_fraction,
    graph_submit_current,
    graph_tick_and_apply,
    merge_saved_node_layout,
    _sys_system,
    _write_text_file,
)
from mojoui.app.genparams import GenLora, GenParams, GenParamStore
from mojoui.app.prompt_syntax import (
    join_notes,
    parse_float_strict,
    resolve_prompt,
    selftest_prompt_syntax,
)
from serenitymojo.serve.image_io import decode_image_any, image_to_rgba_bytes
from image.transform import resize_bilinear
from mojoui.app.daemon_client import (
    DaemonJobInfo,
    DaemonLoraEntry,
    DaemonModelEntry,
    daemon_cancel,
    daemon_jobs,
    daemon_models,
)
from mojoui.app.gen_history import (
    GalleryItem,
    absolutize_output_path,
    list_presets,
    load_gallery_from_db,
    load_preset,
    load_stars,
    read_genparams_from_png,
    sanitize_preset_name,
    save_preset,
    save_stars,
)
from mojoui.nodes.node import FieldValue
from mojoui.nodes.graph import Graph
from mojoui.nodes.registry import NodeRegistry, register_builtins
from mojoui.nodes.canvas_model import (
    CanvasGroup,
    CanvasState,
    canvas_screen_to_world,
)
from mojoui.nodes.canvas import begin_node_canvas, end_node_canvas
from mojoui.nodes.add_menu import AddMenuState, add_menu
from mojoui.nodes.node_menu import (
    node_context_menu,
    NODE_ACTION_DELETE,
    NODE_ACTION_DUPLICATE,
    NODE_ACTION_RENAME,
    NODE_ACTION_COLOR,
)
from mojoui.nodes.progress import ProgressState, draw_progress_overlay
from mojoui.serde.comfy_workflow import parse_comfy_workflow
from mojoui.serde.workflow import emit_workflow, parse_workflow


from src.app_core import (
    _WIN_W,
    _WIN_H,
    _LEFT_W,
    _RIGHT_W,
    _GUTTER,
    _CENTER_W,
    _TITLE_H,
    _MENU_H,
    _STATUS_H,
    _NODE_PERSIST_DIR,
    _NODE_PERSIST_WORKFLOW,
    InferenceUIState,
    _row1,
    _row2,
    _row3,
    _row4,
    _populate_model_catalog,
    _seed_initial_params,
    _cli_name_for,
    _selected_arch,
    _sync_lora_open,
    _refresh_store,
    _commit_store,
    _resolve_prompt_syntax,
    _clear_init_thumb,
    _validate_init_image,
    _reset_batch_strip,
    _batch_select,
    _batch_reuse_selected,
    _drain_daemon_done,
    _reuse_params_from_item,
    _toggle_star,
    _do_save_preset,
    _do_load_preset,
    _sync_params_to_state,
    _submit_generate,
    _cancel_generate,
    _add_node_workflow_preset,
    _populate_node_workflow_presets,
    _clamp_scale,
    _scale_for,
    _gb_text,
    _refresh_perf_telemetry,
    _px_scale,
    _px,
    _fpx,
    _font_body,
    _left_w,
    _right_w,
    _gutter,
    _title_h,
    _menu_h,
    _status_h,
    _top_chrome,
    _accent,
    _apply_serenity_palette,
    _center_w,
    _left_label_w,
    _left_field_w,
    _left_full_w,
    _right_x,
    _initial_window_size,
    _node_display_job,
    _build_fresh_klein9b_node_graph,
    _build_serenity_node_graph,
    _build_serenity_node_canvas,
    _autosave_node_workflow,
    _sync_window_metrics,
)
from src.sections import (
    _draw_synthetic,
    _draw_preview,
    _section_model,
    _section_resolution,
    _section_sampling,
    _section_seed,
    _section_lora,
    _section_batch,
    _section_init_image,
    PRESET_PAGE,
    _preset_page_count,
    _section_presets,
    _section_advanced,
    _left_panel,
    _center_panel,
    _QUEUE_PAGE,
    _HIST_PAGE,
    _right_panel,
)
from src.chrome_frame import (
    _chrome_text_w,
    _title_bar,
    _menu_bar,
    _status_bar,
    _draw_backgrounds,
    _node_add_demo_image,
    _node_load_fresh_klein_graph,
    _node_import_comfy_json_path,
    _node_load_selected_workflow,
    _nodes_panel,
    _ui,
    _dispatch_triangles,
    _sync_result_texture,
    _render_command_buffer,
)
from src.selftest import (
    _selftest_wait_terminal,
    _selftest_daemon_e2e,
    _selftest_cancel,
    _selftest_preset,
    _selftest_p3_stub,
    _diff_genparams,
    _selftest_mirrors,
    _graph_seam_selfcheck,
)

def _frame() -> None:
    var sp = retrieve_user_state[InferenceUIState]()
    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
    _sync_window_metrics(sp[])

    # Advance graph-runtime state before building the UI so completed-result
    # textures are current this frame.
    graph_tick_and_apply(sp[].model, sp[].zrt)
    _drain_daemon_done(sp[])
    # F3: a lost/finished run must not leave a stale "generating" status
    if not sp[].model.generating and sp[].menu_status == String("daemon: generating"):
        sp[].menu_status = sp[].zrt.last_status.copy()
    # H2 subscriber re-read: external store.set() (preset load / reuse-params)
    # lands in the widget mirrors before the widgets draw.
    _refresh_store(sp[])
    _refresh_perf_telemetry(sp[])
    _sync_result_texture(sp[])

    # TEMPORARY scripted-gate driver (--selftest-ui / --selftest-ui-cancel):
    # triggers the SAME functions the Generate/Cancel buttons call.
    sp[].frame_no += 1
    if sp[].autogen_mode == 1 or sp[].autogen_mode == 2:
        if sp[].frame_no == 150:
            _submit_generate(sp[])
        if (
            sp[].autogen_mode == 2 and sp[].model.generating
            and Int(sp[].model.current_step) >= 5
        ):
            # cancel once the job is visibly mid-denoise (step-aware: frame
            # timing varies with redraw cost)
            _cancel_generate(sp[])
            sp[].autogen_mode = 4  # cancelled; don't repeat
    elif sp[].autogen_mode == 3 and sp[].frame_no == 150:
        # reuse-params from the newest history item — the SAME function a
        # history-row click calls (G2c evidence)
        sp[].model.queue_tab = 1
        _reuse_params_from_item(sp[], len(sp[].gallery) - 1)
    elif sp[].autogen_mode == 5:
        # preset round-trip (G2d): save -> scramble -> load, via the SAME
        # functions the Save/Load buttons call
        if sp[].frame_no == 150:
            sp[].preset_name_buf = String("uigate-roundtrip")
            _do_save_preset(sp[])
        elif sp[].frame_no == 250:
            # scramble through the widget mirrors + dirty flags (the exact
            # state a user edit leaves behind — see F2 dirty-commit)
            sp[].store.m_prompt = String("scrambled: totally different prompt")
            sp[].prompt_edit.set_text(sp[].store.m_prompt)
            sp[].store.d_prompt = True
            sp[].store.m_steps = 77.0
            sp[].store.d_steps = True
            sp[].store.m_cfg = 9.9
            sp[].store.d_cfg = True
            sp[].store.m_seed_text = String("1")
            sp[].store.d_seed = True
            sp[].store.m_width = 1344.0
            sp[].store.d_width = True
            sp[].store.m_height = 768.0
            sp[].store.d_height = True
        elif sp[].frame_no == 1500:
            for i in range(len(sp[].presets)):
                if sp[].presets[i] == String("uigate-roundtrip"):
                    sp[].preset_index = Int32(i)
            _do_load_preset(sp[])
    elif sp[].autogen_mode == 6:
        # P13 batch gate (G3d): submit a 3-image batch; once all 3 thumbs are
        # in the strip, wait ~4 s (screenshot window), then select the MIDDLE
        # thumb via the SAME function the [2] button calls (preview swap).
        if sp[].frame_no == 150:
            _submit_generate(sp[])
        if len(sp[].batch_paths) >= 3 and sp[].autogen_stamp == 0:
            sp[].autogen_stamp = sp[].frame_no
            print("[ui-gate] batch strip full at frame", sp[].frame_no)
        if sp[].autogen_stamp > 0 and sp[].frame_no >= sp[].autogen_stamp + 240:
            _batch_select(sp[], 1)
            print("[ui-gate] selected middle batch thumb -> preview swap")
            sp[].autogen_mode = 62  # done
    elif sp[].autogen_mode == 7:
        # P7 img2img gate (G3c UI evidence): read init path (+ optional
        # creativity) from /tmp/serenityui_init_path.txt, validate (thumbnail
        # upload — the SAME function the Validate button calls), then submit.
        if sp[].frame_no == 60:
            try:
                with open(String("/tmp/serenityui_init_path.txt"), String("r")) as f:
                    var lines = f.read().split(String("\n"))
                    if len(lines) > 0:
                        # the text_edit widget binds m_init_image directly
                        # (TextEditState only tracks cursor/selection)
                        sp[].store.m_init_image = String(lines[0])
                        sp[].store.d_init_image = True
                    if len(lines) > 1 and String(lines[1]).byte_length() > 0:
                        var cok = False
                        var c = parse_float_strict(String(lines[1]), cok)
                        if cok:
                            sp[].store.m_creativity = Float32(c)
                            sp[].store.d_creativity = True
                _validate_init_image(sp[])
                print("[ui-gate] init image set:", sp[].store.m_init_image,
                      "creativity", sp[].store.m_creativity,
                      "status:", sp[].init_status)
            except e:
                print("[ui-gate] init path file read failed:", String(e))
        if sp[].frame_no == 150:
            _submit_generate(sp[])

    sp[].ctx.begin_frame(Vec2(sp[].win_w, sp[].win_h))
    Backend.frame_begin(Color(18, 18, 22, 255))
    try:
        _ui(sp[])
    except e:
        print("MojoUI m8 UI error:", String(e))
    sp[].ctx.end_frame()
    # H2 commit: widget-mirror edits flow through store.set() exactly once
    # per frame (no param state lives outside the store across frames).
    _commit_store(sp[])
    try:
        _render_command_buffer(sp[].ctx)
    except e:
        print("MojoUI m8 walker error:", String(e))
    Backend.frame_end()



def main() raises:
    # TEMPORARY scripted-gate argv paths (clearly marked; see selftests above)
    var run_mode = String("")
    var args = argv()
    for i in range(1, len(args)):
        var a = String(args[i])
        if (
            a == String("--selftest") or a == String("--selftest-cancel")
            or a == String("--selftest-preset") or a == String("--selftest-ui")
            or a == String("--selftest-ui-cancel")
            or a == String("--selftest-ui-reuse")
            or a == String("--selftest-ui-preset")
            or a == String("--selftest-ui-gpu")
            or a == String("--selftest-mirrors")
            or a == String("--selftest-syntax")
            or a == String("--selftest-p3")
            or a == String("--selftest-ui-batch")
            or a == String("--selftest-ui-img2img")
        ):
            run_mode = a^
    if run_mode == String("--selftest-mirrors"):
        _selftest_mirrors()
        return
    if run_mode == String("--selftest-syntax"):
        # G3a: the prompt-syntax parser unit gate (10+ cases)
        selftest_prompt_syntax()
        return
    if run_mode == String("--selftest-p3"):
        # G3b: stub e2e — syntax resolution + lora merge + img2img params
        selftest_prompt_syntax()
        _selftest_p3_stub()
        return
    if run_mode == String("--selftest"):
        _selftest_daemon_e2e()
        _selftest_cancel()
        _selftest_preset()
        print("[selftest] ALL PASS")
        return
    if run_mode == String("--selftest-cancel"):
        _selftest_cancel()
        return
    if run_mode == String("--selftest-preset"):
        _selftest_preset()
        return

    _graph_seam_selfcheck()
    var state = InferenceUIState()
    if run_mode == String("--selftest-ui"):
        state.autogen_mode = 1
        # distinctive params + a 2-row LoRA stack (G2a/G2b evidence); flows
        # through the same H2 dispatch a preset-load would use
        var p = state.store.params.copy()
        p.prompt = String("ui-gate: crystal lighthouse at dawn, oil painting")
        p.steps = 12
        p.seed = 31337
        p.images = 2   # P6: two queued daemon jobs from one Generate
        p.variation_seed = 999
        p.variation_strength = 0.35
        if len(state.lora_names) > 0:
            p.loras.append(GenLora(state.lora_names[0].copy(), 0.8))
        if len(state.lora_names) > 1:
            p.loras.append(GenLora(state.lora_names[1].copy(), 1.35))
        state.store.set(p^)
    elif run_mode == String("--selftest-ui-cancel"):
        state.autogen_mode = 2
        # a 50-step job so the auto-cancel lands mid-denoise
        var p = state.store.params.copy()
        p.steps = 50
        state.store.set(p^)
    elif run_mode == String("--selftest-ui-batch"):
        # G3d: 3-image stub batch -> thumbnail strip -> middle-click swap
        state.autogen_mode = 6
        var p = state.store.params.copy()
        p.prompt = String("batch-gate: paper lantern on a pier")
        p.steps = 6
        p.seed = 5150   # 3 jobs at seeds 5150/5151/5152 -> distinct gradients
        p.images = 3
        state.store.set(p^)
    elif run_mode == String("--selftest-ui-img2img"):
        # G3c UI evidence: init image (path read from
        # /tmp/serenityui_init_path.txt) + creativity + thumbnail + submit.
        state.autogen_mode = 7
        # collapse the upper sections so the Init-image section (thumbnail)
        # is on-screen for the gate screenshot
        state.sec_sampling = False
        state.sec_seed = False
        state.sec_lora = False
        var p = state.store.params.copy()
        p.prompt = String("the same scene but everything is deep red, "
                          "crimson tones, photo")
        p.steps = 20
        p.seed = 777
        p.images = 1
        state.store.set(p^)
    elif run_mode == String("--selftest-ui-reuse"):
        state.autogen_mode = 3
    elif run_mode == String("--selftest-ui-gpu"):
        # G2e: one real zimage generation driven entirely from the UI —
        # plain auto-generate with zimage-safe params (no LoRA, 1 image)
        state.autogen_mode = 1
        var p = state.store.params.copy()
        p.prompt = String("a red bicycle leaning against a blue brick wall, "
                          "golden hour, photo")
        p.steps = 20
        p.seed = 12345
        p.images = 1
        state.store.set(p^)
    elif run_mode == String("--selftest-ui-preset"):
        state.autogen_mode = 5
        # distinctive baseline so the round-trip is visible
        var p = state.store.params.copy()
        p.prompt = String("preset-gate: amber forest, volumetric fog")
        p.steps = 33
        p.cfg = 6.5
        p.seed = 2026
        p.variation_seed = 55
        p.variation_strength = 0.2
        if len(state.lora_names) > 0:
            p.loras.append(GenLora(state.lora_names[0].copy(), 1.25))
        state.store.set(p^)
    var sp = UnsafePointer(to=state)
    store_user_state(sp)

    var initial_size = _initial_window_size()
    state.win_w = initial_size.x
    state.win_h = initial_size.y
    state.scale = _scale_for(initial_size.x, initial_size.y)

    var rc = Backend.init(
        Int32(Int(initial_size.x)), Int32(Int(initial_size.y)),
        String("serenityUI"),
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print(
        "Opening inference UI (graph executor + Klein 9B",
        ", scale=", state.scale,
        ", window=", Int(state.win_w), "x", Int(state.win_h),
        "). Click Generate to run."
    )
    Backend.run_blocking(_frame)
    # Keep-alive: reference state AFTER run_blocking so ASAP destruction does
    # not free the struct (and the callback's pointer) early.
    if state.zrt.texture_id != UInt32(0):
        Backend.destroy_texture(state.zrt.texture_id)
    print("PASS: m8 inference UI exited. history=", len(state.model.history))
