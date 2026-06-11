"""serenityUI — left-panel param sections, preview, and the 3 panels (split from serenity_ui_main.mojo).

Part of the `src` package; see serenity_ui_main.mojo for the app entry point.
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

# ---------------------------------------------------------------------------
# Synthetic gradient preview. Paints horizontal color bands derived from a
# UInt32 seed so each completed generation looks distinct. No image upload —
# pure draw_rect bands, mirroring the spec's "synthetic gradient" placeholder.
# ---------------------------------------------------------------------------


def _draw_synthetic(mut ctx: Context, rect: Rect, color_seed: UInt32):
    var bands: Int32 = 24
    var bh = rect.h / Float32(Int(bands))
    var s = color_seed
    for i in range(Int(bands)):
        # cheap LCG to perturb the band color
        s = s * UInt32(1664525) + UInt32(1013904223)
        var r = UInt8((s >> UInt32(16)) & UInt32(0xFF))
        var g = UInt8((s >> UInt32(8)) & UInt32(0xFF))
        var b = UInt8(s & UInt32(0xFF))
        # blend toward a teal-ish base so it reads as a "render"
        var rr = UInt8((Int(r) + 30) // 2)
        var gg = UInt8((Int(g) + 120) // 2)
        var bb = UInt8((Int(b) + 150) // 2)
        var band = Rect(
            rect.x, rect.y + Float32(i) * bh, rect.w, bh + Float32(1.0)
        )
        ctx.draw_rect(band, Color(rr, gg, bb, UInt8(255)))


def _draw_preview(
    mut ctx: Context,
    rect: Rect,
    s: InferenceState,
    font_id: UInt32,
    texture_id: UInt32,
    ui_scale: Float32,
    font_size_pt: Int32,
):
    """Rounded-rect slot; synthetic gradient when a result is ready, else a
    centered placeholder label."""
    if texture_id != UInt32(0):
        var white = Color(255, 255, 255, 255)
        _ = ctx.commands.emit_image(rect.copy(), texture_id, white.copy())
    elif s.result_ready:
        _draw_synthetic(ctx, rect.copy(), s.history[len(s.history) - 1].color_seed)
    else:
        tess_rounded_rect(
            ctx, rect.copy(), Float32(8.0) * ui_scale, Color(30, 30, 38, 255), 6
        )
        if font_id != 0:
            var msg = String("(generating…)") if s.generating else String("(no image yet)")
            var pos = Vec2(
                rect.x + rect.w * Float32(0.5) - Float32(54.0) * ui_scale,
                rect.y + rect.h * Float32(0.5),
            )
            ctx.draw_text(font_id, font_size_pt, pos, Color(140, 145, 160, 255), msg)


# ---------------------------------------------------------------------------
# Left params panel — collapsing-header sections.
# ---------------------------------------------------------------------------


def _section_model(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Model"), s.sec_model):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Task:"))
        _ = combobox(ctx, String("task"), s.model.task_options,
                     s.model.task_index, s.model.task_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Model:"))
        if combobox(ctx, String("model"), s.model_display,
                    s.store.m_model_index, s.model_combo_open):
            s.store.d_model = True
        ctx.layout_row(_row1(_left_full_w(s)), _px(s, 20))
        if s.models_from_daemon:
            var arch = _selected_arch(s)
            var route = String("route: daemon") if arch == String("zimage") else (
                String("route: CLI (") + _cli_name_for(arch, String("")) + String(")")
            )
            label(ctx, route)
        else:
            label(ctx, String("daemon down — static CLI list"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("VAE:"))
        _ = combobox(ctx, String("vae"), s.model.vae_options,
                     s.model.vae_index, s.model.vae_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Precision:"))
        _ = combobox(ctx, String("precision"), s.model.precision_options,
                     s.model.precision_index, s.model.precision_open)


def _section_resolution(mut s: InferenceUIState) raises:
    """P3: aspect presets + swap + custom W/H (bound to the param store)."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Resolution"), s.sec_resolution):
        var bw = (_left_full_w(s) - _px(s, 12)) / 4
        ctx.layout_row(_row4(bw, bw, bw, bw), _px(s, 26))
        if button(ctx, String("1:1")):
            s.store.m_width = 1024.0
            s.store.m_height = 1024.0
            s.store.d_width = True
            s.store.d_height = True
        if button(ctx, String("3:2")):
            s.store.m_width = 1216.0
            s.store.m_height = 832.0
            s.store.d_width = True
            s.store.d_height = True
        if button(ctx, String("16:9")):
            s.store.m_width = 1344.0
            s.store.m_height = 768.0
            s.store.d_width = True
            s.store.d_height = True
        if button(ctx, String("9:16")):
            s.store.m_width = 768.0
            s.store.m_height = 1344.0
            s.store.d_width = True
            s.store.d_height = True
        ctx.layout_row(_row2(bw * 2 + _px(s, 4), bw * 2), _px(s, 26))
        if button(ctx, String("512 · 1:1")):
            s.store.m_width = 512.0
            s.store.m_height = 512.0
            s.store.d_width = True
            s.store.d_height = True
        if button(ctx, String("Swap W/H")):
            var t = s.store.m_width
            s.store.m_width = s.store.m_height
            s.store.m_height = t
            s.store.d_width = True
            s.store.d_height = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Width:"))
        if drag_value(ctx, s.store.m_width, String("width"), Float32(8.0)):
            s.store.d_width = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Height:"))
        if drag_value(ctx, s.store.m_height, String("height"), Float32(8.0)):
            s.store.d_height = True
        if _selected_arch(s) == String("zimage") and (
            Int(s.store.m_width) != 512 or Int(s.store.m_height) != 512
        ):
            ctx.layout_row(_row1(_left_full_w(s)), _px(s, 20))
            label(ctx, String("daemon: 512 only — this size runs via CLI"))


def _section_sampling(mut s: InferenceUIState) raises:
    """P4: steps / CFG / sampler / scheduler (store-bound; static lists)."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Sampling"), s.sec_sampling):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Sampler:"))
        if combobox(ctx, String("sampler"), s.model.sampler_options,
                    s.store.m_sampler_index, s.model.sampler_open):
            s.store.d_sampler = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Scheduler:"))
        if combobox(ctx, String("scheduler"), s.model.scheduler_options,
                    s.store.m_scheduler_index, s.model.scheduler_open):
            s.store.d_scheduler = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Steps:"))
        if slider(ctx, s.store.m_steps, Float32(1.0), Float32(100.0), String("steps")):
            s.store.d_steps = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("CFG:"))
        if drag_value(ctx, s.store.m_cfg, String("cfg"), Float32(0.1)):
            s.store.d_cfg = True


def _section_seed(mut s: InferenceUIState) raises:
    """P5: seed + randomize + variation seed + variation strength."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Seed"), s.sec_seed):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Seed:"))
        # F1: TEXT mirror — integer end-to-end (a Float32 drag corrupts
        # seeds > 2^24, e.g. 123456789 -> 123456792)
        if text_edit(ctx, String("seed"), s.store.m_seed_text, s.seed_edit):
            s.store.d_seed = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String(""))
        if button(ctx, String("Randomize")):
            s.pseudo_rng = s.pseudo_rng * UInt32(1664525) + UInt32(1013904223)
            s.store.m_seed_text = String(Int(s.pseudo_rng % UInt32(1000000)))
            s.store.d_seed = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Var seed:"))
        if drag_value(ctx, s.store.m_variation_seed, String("var_seed"), Float32(1.0)):
            s.store.d_variation_seed = True
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Var strength:"))
        if drag_value(
            ctx, s.store.m_variation_strength, String("var_strength"), Float32(0.01)
        ):
            s.store.d_variation_strength = True
            if s.store.m_variation_strength < 0.0:
                s.store.m_variation_strength = 0.0
            if s.store.m_variation_strength > 1.0:
                s.store.m_variation_strength = 1.0


def _section_lora(mut s: InferenceUIState) raises:
    """P2: multi-LoRA stack — add/remove rows backed by the daemon's
    /v1/models lora scan + per-row weight slider 0..2."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("LoRA"), s.sec_lora):
        _sync_lora_open(s)
        var remove_at = -1
        for i in range(len(s.store.m_lora_indices)):
            ctx.layout_row(
                _row3(_px(s, 168), _px(s, 142), _px(s, 30)), _px(s, 26)
            )
            var open_flag = s.lora_row_open[i]
            if combobox(ctx, String("lora_sel_") + String(i), s.lora_names,
                        s.store.m_lora_indices[i], open_flag):
                s.store.d_loras = True
            s.lora_row_open[i] = open_flag
            if slider(ctx, s.store.m_lora_weights[i], Float32(0.0),
                      Float32(2.0), String("lora_w_") + String(i)):
                s.store.d_loras = True
            # NOTE: button ids hash the label — keep per-row labels unique
            if button(ctx, String("x") + String(i + 1)):
                remove_at = i
        if remove_at >= 0:
            var keep_idx = List[Int32]()
            var keep_w = List[Float32]()
            var keep_open = List[Bool]()
            for j in range(len(s.store.m_lora_indices)):
                if j == remove_at:
                    continue
                keep_idx.append(s.store.m_lora_indices[j])
                keep_w.append(s.store.m_lora_weights[j])
                keep_open.append(s.lora_row_open[j])
            s.store.m_lora_indices = keep_idx^
            s.store.m_lora_weights = keep_w^
            s.lora_row_open = keep_open^
            s.store.d_loras = True
        ctx.layout_row(_row1(_px(s, 180)), _px(s, 28))
        if button(ctx, String("+ Add LoRA")):
            if len(s.lora_names) > 0:
                s.store.m_lora_indices.append(Int32(0))
                s.store.m_lora_weights.append(Float32(1.0))
                s.lora_row_open.append(False)
                s.store.d_loras = True


def _section_batch(mut s: InferenceUIState) raises:
    """P6: images-count (each image = one queued daemon job)."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Images"), s.sec_batch):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Count: ") + String(Int(s.store.m_images)))
        if slider(ctx, s.store.m_images, Float32(1.0), Float32(8.0), String("images")):
            s.store.d_images = True


def _section_init_image(mut s: InferenceUIState) raises:
    """P7: init image (img2img) — path field + Validate (MOJO-libs decode +
    128px thumbnail) + creativity slider 0..1 + Clear."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Init image"), s.sec_init):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Path:"))
        if text_edit(ctx, String("init_path"), s.store.m_init_image,
                     s.init_path_state):
            s.store.d_init_image = True
        ctx.layout_row(_row2(_px(s, 170), _px(s, 170)), _px(s, 26))
        if button(ctx, String("Validate")):
            s.store.d_init_image = True   # commit the typed path this frame
            _validate_init_image(s)
        if button(ctx, String("Clear init")):
            s.store.m_init_image = String("")
            s.init_path_state = TextEditState(single_line=True)
            s.store.d_init_image = True
            _clear_init_thumb(s)
            s.init_status = String("cleared (txt2img)")
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Creativity: ")
              + String(Float64(Int(s.store.m_creativity * 100.0)) / 100.0))
        if slider(ctx, s.store.m_creativity, Float32(0.0), Float32(1.0),
                  String("creativity")):
            s.store.d_creativity = True
        if s.init_status.byte_length() > 0:
            ctx.layout_row(_row1(_left_full_w(s)), _px(s, 20))
            label(ctx, s.init_status)
        if s.init_thumb_tex != UInt32(0):
            # thumbnail slot (P7): uploaded like the output preview
            var th = Float32(Int(s.init_thumb_h))
            var tw = Float32(Int(s.init_thumb_w))
            ctx.layout_row(_row1(_left_full_w(s)), Int32(Int(th)) + _px(s, 8))
            var slot = ctx.layout_next()
            var rect = Rect(slot.x + _fpx(s, 4.0), slot.y + _fpx(s, 4.0), tw, th)
            _ = ctx.commands.emit_image(
                rect^, s.init_thumb_tex, Color(255, 255, 255, 255)
            )


comptime PRESET_PAGE = 10  # F7: dropdown rows per page (50 entries overflow)


def _preset_page_count(s: InferenceUIState) -> Int:
    var n = len(s.presets)
    if n == 0:
        return 1
    return (n + PRESET_PAGE - 1) // PRESET_PAGE


def _section_presets(mut s: InferenceUIState) raises:
    """P8: named param presets (JSON files under ~/.serenity/ui_presets/).
    F7: the dropdown is PAGED (PRESET_PAGE rows/page) so 50+ presets stay
    reachable, and the preset dir is rescanned every time the dropdown
    OPENs."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Presets"), s.sec_presets):
        var pages = _preset_page_count(s)
        if s.preset_page >= pages:
            s.preset_page = pages - 1
        if s.preset_page < 0:
            s.preset_page = 0
        var lo = s.preset_page * PRESET_PAGE
        var hi = lo + PRESET_PAGE
        if hi > len(s.presets):
            hi = len(s.presets)
        var page_opts = List[String]()
        for i in range(lo, hi):
            page_opts.append(s.presets[i].copy())
        var local_sel = Int32(-1)
        if Int(s.preset_index) >= lo and Int(s.preset_index) < hi:
            local_sel = s.preset_index - Int32(lo)

        var bw = _px(s, 80)
        ctx.layout_row(_row2(_left_full_w(s) - bw - _px(s, 4), bw), _px(s, 28))
        if combobox(ctx, String("preset_sel"), page_opts,
                    local_sel, s.preset_open):
            s.preset_index = Int32(lo) + local_sel
        if s.preset_open and not s.preset_was_open:
            # F7: dropdown just OPENed -> rescan the preset dir (keep the
            # current selection by name when it survives the rescan)
            var sel_name = String("")
            if Int(s.preset_index) >= 0 and Int(s.preset_index) < len(s.presets):
                sel_name = s.presets[Int(s.preset_index)].copy()
            s.presets = list_presets()
            for i in range(len(s.presets)):
                if s.presets[i] == sel_name:
                    s.preset_index = Int32(i)
        s.preset_was_open = s.preset_open
        if button(ctx, String("Load")):
            _do_load_preset(s)
        # pager row (F7)
        var pw = _px(s, 60)
        ctx.layout_row(
            _row3(pw, _left_full_w(s) - pw * 2 - _px(s, 8), pw), _px(s, 24)
        )
        if button(ctx, String("< pg")):
            if s.preset_page > 0:
                s.preset_page -= 1
        label(ctx, String("page ") + String(s.preset_page + 1) + String("/")
              + String(pages) + String(" · ") + String(len(s.presets))
              + String(" presets"))
        if button(ctx, String("pg >")):
            if s.preset_page + 1 < pages:
                s.preset_page += 1
        ctx.layout_row(_row2(_left_full_w(s) - bw - _px(s, 4), bw), _px(s, 28))
        _ = text_edit(ctx, String("preset_name"), s.preset_name_buf,
                      s.preset_name_state)
        if button(ctx, String("Save")):
            _do_save_preset(s)


def _section_advanced(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Advanced"), s.sec_advanced):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Clip skip:"))
        _ = drag_value(ctx, s.model.clip_skip, String("clipskip"), Float32(1.0))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Eta:"))
        _ = drag_value(ctx, s.model.eta, String("eta"), Float32(0.05))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Sigma min:"))
        _ = drag_value(ctx, s.model.sigma_min, String("sigmin"), Float32(0.01))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Sigma max:"))
        _ = drag_value(ctx, s.model.sigma_max, String("sigmax"), Float32(0.1))
        ctx.layout_row(_row1(_left_full_w(s)), _px(s, 28))
        _ = checkbox(ctx, String("Restart sampling"), s.model.restart_sampling)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Attention:"))
        _ = combobox(ctx, String("attn"), s.model.attention_options,
                     s.model.attention_index, s.model.attention_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("CPU offload:"))
        _ = combobox(ctx, String("offload"), s.model.cpu_offload_options,
                     s.model.cpu_offload_index, s.model.cpu_offload_open)


# ---------------------------------------------------------------------------
# UI composition for the three regions. Each pane gets an explicit layout panel
# so its rows start at the pane's own origin instead of being offset with dummy
# spacer cells inside a single root flow.
# ---------------------------------------------------------------------------


def _left_panel(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    # Column header
    ctx.layout_row(_row1(_left_w(s)), _px(s, 30))
    label(ctx, String("Parameters"))
    ctx.layout_row(_row1(_left_w(s)), _px(s, 4))
    separator(ctx)
    _section_model(s)
    _section_resolution(s)
    _section_sampling(s)
    _section_seed(s)
    _section_lora(s)
    _section_batch(s)
    _section_init_image(s)
    _section_presets(s)
    _section_advanced(s)


def _center_panel(mut s: InferenceUIState, col_x: Float32) raises:
    ref ctx = s.ctx
    # task/mode header
    ctx.layout_row(_row1(_center_w(s)), _px(s, 30))
    label(ctx, String("Image  ·  ") + s.model.task_short()
          + String("  ·  ") + s.store.params.model)

    ctx.layout_row(_row1(_center_w(s)), _px(s, 24))
    label(ctx, String("Prompt:"))
    ctx.layout_row(_row1(_center_w(s)), _px(s, 80))
    if text_area(ctx, String("prompt"), s.store.m_prompt, s.prompt_edit):
        s.store.d_prompt = True

    ctx.layout_row(_row1(_center_w(s)), _px(s, 24))
    label(ctx, String("Negative:"))
    ctx.layout_row(_row1(_center_w(s)), _px(s, 56))
    if text_area(ctx, String("negative"), s.store.m_negative, s.negative_edit):
        s.store.d_negative = True

    # action bar
    ctx.layout_row(_row3(_px(s, 196), _px(s, 200), _px(s, 200)), _px(s, 40))
    label(ctx, String(""))
    if s.model.generating:
        if button(ctx, String("Cancel")):
            _cancel_generate(s)
    else:
        if button_primary(ctx, String("Generate")):
            _submit_generate(s)
    if button(ctx, String("Randomize seed")):
        s.pseudo_rng = s.pseudo_rng * UInt32(1664525) + UInt32(1013904223)
        s.store.m_seed_text = String(Int(s.pseudo_rng % UInt32(1000000)))
        s.store.d_seed = True

    # image preview (shorter when the P13 batch strip needs the room below)
    var prev_h: Int32 = 460
    if len(s.batch_paths) >= 2:
        prev_h = 330
    ctx.layout_row(_row1(_center_w(s)), _px(s, prev_h))
    var slot = ctx.layout_next()
    var side: Float32 = _fpx(s, Float32(Int(prev_h)) - 20.0)
    if side > slot.w - _fpx(s, 20.0):
        side = slot.w - _fpx(s, 20.0)
    if side > slot.h - _fpx(s, 20.0):
        side = slot.h - _fpx(s, 20.0)
    var img = Rect(
        slot.x + (slot.w - side) * Float32(0.5),
        slot.y + _fpx(s, 10.0),
        side, side,
    )
    _draw_preview(ctx, img, s.model, s.font_id, s.zrt.texture_id, s.scale, _font_body(s))

    # P13: batch thumbnail strip (this Generate's outputs, images > 1).
    # Thumb textures load lazily; the [n] button under a thumb swaps the
    # full preview to that job; [use params] re-applies its PNG-tEXt params.
    if len(s.batch_paths) >= 2:
        var n = len(s.batch_paths)
        var cell = _px(s, 84)
        var widths = List[Int32]()
        for _ in range(n):
            widths.append(cell)
        ctx.layout_row(widths.copy(), _px(s, 84))
        for i in range(n):
            var slot2 = ctx.layout_next()
            if s.batch_tex[i] == UInt32(0):
                var loaded = Backend.load_texture_file_info(
                    s.batch_paths[i], Int32(96), Int32(96)
                )
                s.batch_tex[i] = loaded.texture_id
            if s.batch_tex[i] != UInt32(0):
                var side2 = slot2.w - _fpx(s, 6.0)
                if side2 > slot2.h - _fpx(s, 4.0):
                    side2 = slot2.h - _fpx(s, 4.0)
                var trect = Rect(
                    slot2.x + _fpx(s, 3.0), slot2.y + _fpx(s, 2.0), side2, side2
                )
                var tint = Color(255, 255, 255, 255)
                if i != s.batch_sel:
                    tint = Color(170, 170, 170, 255)  # selected = full bright
                _ = ctx.commands.emit_image(trect^, s.batch_tex[i], tint^)
        ctx.layout_row(widths^, _px(s, 24))
        for i in range(n):
            var mark = String("[") + String(i + 1) + String("]")
            if i == s.batch_sel:
                mark = String("[*") + String(i + 1) + String("]")
            if button(ctx, mark):
                _batch_select(s, i)
        ctx.layout_row(_row1(_px(s, 240)), _px(s, 24))
        if button(ctx, String("use params of selected")):
            _batch_reuse_selected(s)

    # progress bar + readout
    ctx.layout_row(_row1(_center_w(s)), _px(s, 18))
    progress_bar(ctx, graph_progress_fraction(s.model))
    if s.font_id != 0:
        var readout = String("step ") + String(s.model.current_step) \
            + String("/") + String(s.model.total_steps)
        ctx.draw_text(s.font_id, _font_body(s),
                      Vec2(col_x, s.win_h - Float32(Int(_status_h(s))) - _fpx(s, 18.0)),
                      Color(150, 200, 160, 255), readout)


comptime _QUEUE_PAGE = 10   # F6: queue rows per page
comptime _HIST_PAGE = 12    # F6: history rows per page


def _right_panel(mut s: InferenceUIState, col_x: Float32) raises:
    ref ctx = s.ctx
    # queue / history tab buttons
    ctx.layout_row(_row2(_px(s, 170), _px(s, 170)), _px(s, 30))
    if button(ctx, String("Queue")):
        s.model.queue_tab = 0
    if button(ctx, String("History")):
        s.model.queue_tab = 1
    ctx.layout_row(_row1(_right_w(s)), _px(s, 4))
    separator(ctx)

    if s.model.queue_tab == 0:
        # P12: the queue rail renders the daemon's /v1/jobs directly.
        # F6: paged over the FULL list ([newer]/[older]); F9: ASCII marks;
        # F10: per-job [x] cancel for queued/running rows.
        var jobs = s.zrt.daemon_jobs_cache.copy()
        var nj = len(jobs)
        if s.zrt.daemon_ok and nj > 0:
            var qpages = (nj + _QUEUE_PAGE - 1) // _QUEUE_PAGE
            if s.queue_page >= qpages:
                s.queue_page = qpages - 1
            if s.queue_page < 0:
                s.queue_page = 0
            var start = s.queue_page * _QUEUE_PAGE
            var cancel_id = String("")
            for k in range(_QUEUE_PAGE):
                var i = start + k
                if i >= nj:
                    break
                var idx = nj - 1 - i  # newest first
                var mark = String("- ")
                if jobs[idx].state == String("running"):
                    mark = String("> ")
                elif jobs[idx].state == String("done"):
                    mark = String("ok ")
                var terminal = jobs[idx].is_terminal()
                if terminal:
                    ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
                else:
                    ctx.layout_row(
                        _row2(_right_w(s) - _px(s, 38), _px(s, 30)), _px(s, 22)
                    )
                label(ctx, mark + jobs[idx].id + String("  ")
                      + jobs[idx].state + String("  ")
                      + String(jobs[idx].step) + String("/")
                      + String(jobs[idx].total))
                if not terminal:
                    # F10: per-job cancel -> POST /v1/cancel/<id>
                    if button(ctx, String("x ") + jobs[idx].id):
                        cancel_id = jobs[idx].id.copy()
                if jobs[idx].state == String("running"):
                    ctx.layout_row(_row1(_right_w(s)), _px(s, 14))
                    var frac = Float32(0.0)
                    if jobs[idx].total > 0:
                        frac = Float32(jobs[idx].step) / Float32(jobs[idx].total)
                    progress_bar(ctx, frac)
            if cancel_id.byte_length() > 0:
                try:
                    _ = daemon_cancel(cancel_id)
                    s.menu_status = String("cancel requested: ") + cancel_id
                except e:
                    s.menu_status = String("cancel failed: ") + String(e)
            # pager (F6)
            ctx.layout_row(
                _row3(_px(s, 90), _px(s, 150), _px(s, 90)), _px(s, 24)
            )
            if button(ctx, String("newer")):
                if s.queue_page > 0:
                    s.queue_page -= 1
            label(ctx, String("page ") + String(s.queue_page + 1)
                  + String("/") + String(qpages) + String(" · ")
                  + String(nj) + String(" jobs"))
            if button(ctx, String("older")):
                if s.queue_page + 1 < qpages:
                    s.queue_page += 1
        elif s.model.has_running:
            # CLI fallback path: the in-memory mirror
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("> running #") + String(s.model.running.id))
            ctx.layout_row(_row1(_right_w(s)), _px(s, 16))
            progress_bar(ctx, s.model.running.progress())
        else:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            var msg = String("(queue empty)")
            if not s.zrt.daemon_ok:
                msg = String("(queue empty · daemon down)")
            label(ctx, msg)
    else:
        # P14-P16: persistent history (jobs.db + session) with star + reuse.
        # F6: paged over the FULL gallery + a starred-first toggle.
        var nh = len(s.gallery)
        if nh == 0:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("(no history)"))
        # display order: newest first; starred first when toggled (F6)
        var order = List[Int]()
        if s.starred_first:
            for i in range(nh):
                var idx = nh - 1 - i
                if s.gallery[idx].starred:
                    order.append(idx)
            for i in range(nh):
                var idx = nh - 1 - i
                if not s.gallery[idx].starred:
                    order.append(idx)
        else:
            for i in range(nh):
                order.append(nh - 1 - i)
        var hpages = (nh + _HIST_PAGE - 1) // _HIST_PAGE
        if hpages < 1:
            hpages = 1
        if s.hist_page >= hpages:
            s.hist_page = hpages - 1
        if s.hist_page < 0:
            s.hist_page = 0
        # starred-first toggle (F6) — ASCII only (F9)
        ctx.layout_row(_row1(_px(s, 200)), _px(s, 24))
        var tog = String("[*] starred first: on") if s.starred_first \
            else String("[ ] starred first: off")
        if button(ctx, tog):
            s.starred_first = not s.starred_first
            s.hist_page = 0
        var star_clicked = -1
        var reuse_clicked = -1
        var hstart = s.hist_page * _HIST_PAGE
        for k in range(_HIST_PAGE):
            var oi = hstart + k
            if oi >= len(order):
                break
            var idx = order[oi]
            ctx.layout_row(_row2(_px(s, 40), _px(s, 284)), _px(s, 24))
            # F9: ASCII star (the UI font has no ★ glyph)
            var star_lbl = String("[*]") if s.gallery[idx].starred else String("[ ]")
            # unique per-row labels (button ids hash the label)
            if button(ctx, star_lbl + String(" ") + String(idx)):
                star_clicked = idx
            if button(ctx, s.gallery[idx].job_id + String(" · ")
                      + s.gallery[idx].model):
                reuse_clicked = idx
        # pager (F6)
        ctx.layout_row(_row3(_px(s, 90), _px(s, 150), _px(s, 90)), _px(s, 24))
        if button(ctx, String("newer ")):
            if s.hist_page > 0:
                s.hist_page -= 1
        label(ctx, String("page ") + String(s.hist_page + 1) + String("/")
              + String(hpages) + String(" · ") + String(nh) + String(" items"))
        if button(ctx, String("older ")):
            if s.hist_page + 1 < hpages:
                s.hist_page += 1
        if star_clicked >= 0:
            _toggle_star(s, star_clicked)
        if reuse_clicked >= 0:
            _reuse_params_from_item(s, reuse_clicked)

    # perf footer drawn as absolute text at the bottom of the right column
    if s.font_id != 0:
        var y = s.win_h - Float32(Int(_status_h(s))) - _fpx(s, 86.0)
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y),
                      Color(170, 175, 190, 255), s.model.perf.gpu_name)
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y + _fpx(s, 20.0)),
                      Color(170, 175, 190, 255),
                      String("VRAM ") + _gb_text(s.model.perf.vram_used_gb)
                      + String("/") + _gb_text(s.model.perf.vram_total_gb) + String(" GB"))
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y + _fpx(s, 40.0)),
                      Color(170, 175, 190, 255),
                      String("Util ") + String(Int(s.model.perf.gpu_util_pct)) + String("%"))
        ctx.draw_text(s.font_id, _font_body(s), Vec2(col_x, y + _fpx(s, 60.0)),
                      Color(170, 175, 190, 255),
                      String("Temp ") + String(Int(s.model.perf.temperature_c)) + String("C"))


