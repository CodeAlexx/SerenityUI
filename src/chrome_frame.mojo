"""serenityUI — title/menu/status chrome, node panel, _ui frame orchestration (split from serenity_ui_main.mojo).

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

# ---------------------------------------------------------------------------
# Window chrome — title bar, menu bar, status bar. Drawn with primitives so we
# control vertical placement (MojoUI's menubar widget hard-anchors at y=0).
# ---------------------------------------------------------------------------


def _chrome_text_w(s: InferenceUIState, text: String, fs: Int32) -> Float32:
    """Crude width estimate for chrome label spacing (no measure_text yet)."""
    return Float32(text.byte_length()) * Float32(fs) * 0.58


def _title_bar(mut s: InferenceUIState):
    ref ctx = s.ctx
    var h = Float32(Int(_title_h(s)))
    var w = s.win_w
    ctx.draw_rect(Rect(0.0, 0.0, w, h), Color(28, 28, 34, 255))
    ctx.draw_rect(Rect(0.0, h - 1.0, w, 1.0), ctx.theme.border.copy())
    var pad = _fpx(s, 12.0)
    var icon = _fpx(s, 13.0)
    ctx.draw_rect(Rect(pad, (h - icon) * 0.5, icon, icon), _accent())
    if s.font_id == 0:
        return
    var fs = _font_body(s)
    var ty = (h + Float32(fs) * 0.7) * 0.5
    var name_x = pad + icon + _fpx(s, 10.0)
    ctx.draw_text(s.font_id, fs, Vec2(name_x, ty), ctx.theme.text.copy(),
                  String("serenityUI"))
    var ver_x = name_x + _chrome_text_w(s, String("serenityUI"), fs) + _fpx(s, 10.0)
    ctx.draw_text(s.font_id, fs, Vec2(ver_x, ty), Color(140, 140, 155, 255),
                  String("v0.1.0"))
    # window-control placeholders (cosmetic in P1; native vs custom decoration
    # is a platform detail to resolve when run on the target box).
    var bw = _fpx(s, 30.0)
    var ch = _fpx(s, 12.0)
    var cy = (h - ch) * 0.5
    var gx = w - bw * 3.0
    for k in range(3):
        ctx.draw_rect(
            Rect(gx + Float32(k) * bw + _fpx(s, 9.0), cy, _fpx(s, 12.0), ch),
            Color(60, 60, 72, 255),
        )


def _menu_bar(mut s: InferenceUIState):
    ref ctx = s.ctx
    var top: Float32 = 0.0   # OS owns the title bar; menu bar is our top row
    var h = Float32(Int(_menu_h(s)))
    var w = s.win_w
    ctx.draw_rect(Rect(0.0, top, w, h), Color(26, 26, 32, 255))
    ctx.draw_rect(Rect(0.0, top + h - 1.0, w, 1.0), ctx.theme.border.copy())
    if s.font_id == 0:
        return
    var fs = _font_body(s)
    var ty = top + (h + Float32(fs) * 0.7) * 0.5

    # top-level menu labels (dropdowns wired in a later slice)
    var menus = List[String]()
    menus.append(String("File"))
    menus.append(String("Nodes"))
    menus.append(String("Edit"))
    menus.append(String("View"))
    menus.append(String("Models"))
    menus.append(String("Queue"))
    menus.append(String("Help"))
    var x = _fpx(s, 10.0)
    for i in range(len(menus)):
        var lbl = menus[i]
        var bw = _chrome_text_w(s, lbl, fs) + _fpx(s, 16.0)
        var brect = Rect(x, top + _fpx(s, 4.0), bw, h - _fpx(s, 8.0))
        var mid = ctx.get_id(String("menu_") + lbl)
        var flags = ctx.update_control(mid, brect.copy(), OPT_NONE)
        if (flags & CTRL_RELEASED) != 0:
            if lbl == String("Nodes"):
                s.tab = Int32(2)
                s.menu_status = String("nodes graph view")
        if (flags & CTRL_HOVERED) != 0:
            ctx.draw_rect(brect.copy(), ctx.theme.hover_bg.copy())
        ctx.draw_text(s.font_id, fs, Vec2(x + _fpx(s, 8.0), ty),
                      Color(190, 190, 205, 255), lbl)
        x = x + bw

    # separator before mode tabs
    x = x + _fpx(s, 8.0)
    ctx.draw_rect(Rect(x, top + _fpx(s, 8.0), 1.0, h - _fpx(s, 16.0)),
                  ctx.theme.border.copy())
    x = x + _fpx(s, 12.0)

    # Image | Video tabs
    var tabs = List[String]()
    tabs.append(String("Image"))
    tabs.append(String("Video"))
    tabs.append(String("Nodes"))
    for i in range(len(tabs)):
        var lbl = tabs[i]
        var bw = _chrome_text_w(s, lbl, fs) + _fpx(s, 20.0)
        var brect = Rect(x, top + _fpx(s, 4.0), bw, h - _fpx(s, 8.0))
        var tid = ctx.get_id(String("tab_") + lbl)
        var flags = ctx.update_control(tid, brect.copy(), OPT_NONE)
        var active = s.tab == Int32(i)
        if (flags & CTRL_RELEASED) != 0:
            s.tab = Int32(i)
        if (flags & CTRL_HOVERED) != 0 and not active:
            ctx.draw_rect(brect.copy(), ctx.theme.hover_bg.copy())
        var col = _accent() if active else Color(170, 170, 185, 255)
        ctx.draw_text(s.font_id, fs, Vec2(x + _fpx(s, 10.0), ty), col^, lbl)
        if active:
            ctx.draw_rect(
                Rect(x + _fpx(s, 6.0), top + h - 2.0, bw - _fpx(s, 12.0), 2.0),
                _accent(),
            )
        x = x + bw

    # theme toggle pinned far right
    var tw = _fpx(s, 26.0)
    var trect = Rect(w - tw - _fpx(s, 10.0), top + _fpx(s, 5.0), tw, h - _fpx(s, 10.0))
    var ttid = ctx.get_id(String("theme_toggle"))
    var tflags = ctx.update_control(ttid, trect.copy(), OPT_NONE)
    if (tflags & CTRL_RELEASED) != 0:
        s.theme_dark = not s.theme_dark
        _apply_serenity_palette(ctx, s.theme_dark)
    if (tflags & CTRL_HOVERED) != 0:
        ctx.draw_rect(trect.copy(), ctx.theme.hover_bg.copy())
    var dot = _fpx(s, 10.0)
    ctx.draw_rect(
        Rect(trect.x + (trect.w - dot) * 0.5, trect.y + (trect.h - dot) * 0.5, dot, dot),
        _accent(),
    )


def _status_bar(mut s: InferenceUIState):
    ref ctx = s.ctx
    var h = Float32(Int(_status_h(s)))
    var y = s.win_h - h
    var w = s.win_w
    ctx.draw_rect(Rect(0.0, y, w, h), Color(28, 28, 34, 255))
    ctx.draw_rect(Rect(0.0, y, w, 1.0), ctx.theme.border.copy())
    if s.font_id == 0:
        return
    var fs = _font_body(s)
    var ty = y + (h + Float32(fs) * 0.7) * 0.5
    var dot = _fpx(s, 7.0)
    # F5: the dot reflects ACTUAL health (dedicated ~2 s probe): green ok /
    # red down / yellow degraded (up but recent probe/poll failures).
    var dot_color = Color(220, 70, 70, 255)        # red: down
    var daemon_lbl = String("daemon DOWN -> CLI")
    if s.zrt.daemon_ok:
        if s.zrt.health_fail_streak > 0 or s.zrt.daemon_fail_streak > 0:
            dot_color = Color(225, 190, 60, 255)   # yellow: degraded
            daemon_lbl = String("daemon degraded (") + s.zrt.daemon_backend + String(")")
        else:
            dot_color = Color(90, 200, 120, 255)   # green: healthy
            daemon_lbl = String("daemon ok (") + s.zrt.daemon_backend + String(")")
    ctx.draw_rect(Rect(_fpx(s, 10.0), y + (h - dot) * 0.5, dot, dot),
                  dot_color^)
    ctx.draw_text(s.font_id, fs, Vec2(_fpx(s, 24.0), ty), Color(150, 150, 165, 255),
                  daemon_lbl
                  + String("  ·  ")
                  + graph_backend_label(s.zrt)
                  + String("  ·  ")
                  + s.menu_status)


def _draw_backgrounds(mut s: InferenceUIState):
    ref ctx = s.ctx
    var right_x = _right_x(s)
    ctx.draw_rect(Rect(0.0, 0.0, s.win_w, s.win_h), Color(22, 22, 28, 255))
    ctx.draw_rect(Rect(0.0, 0.0, Float32(Int(_left_w(s))) + _fpx(s, 8.0), s.win_h),
                  Color(28, 28, 36, 255))
    ctx.draw_rect(Rect(right_x, 0.0, Float32(Int(_right_w(s))) + _fpx(s, 16.0), s.win_h),
                  Color(28, 28, 36, 255))


def _node_add_demo_image(mut s: InferenceUIState) raises:
    var node_id = s.node_graph.id_alloc.alloc()
    var pos = s.node_canvas.action_anchor_world.copy()
    var node = s.node_registry.make_node(String("core/load_image"), pos.copy(), node_id)
    node.title = String("Image Node")
    node.size = Vec2(360.0, 360.0)
    node.fields[String("path")] = FieldValue.string(
        String("/home/alex/Downloads/image (17).webp")
    )
    node.fields[String("upload_label")] = FieldValue.string(
        String("SerenityUI reference image")
    )
    s.node_graph.nodes.append(node^)
    s.menu_status = String("added image node")


def _node_load_fresh_klein_graph(mut s: InferenceUIState) raises:
    s.node_graph = _build_fresh_klein9b_node_graph(s.model)
    s.node_canvas = _build_serenity_node_canvas(s.node_graph)
    s.node_canvas.show_minimap = True
    s.node_canvas.snap_to_grid = True
    s.node_progress.reset()
    s.menu_status = String("loaded main Klein 9B node graph")


def _node_import_comfy_json_path(
    mut s: InferenceUIState,
    path: String,
    label_text: String,
) raises:
    var file = open(path, String("r"))
    var imported = parse_comfy_workflow(file.read())
    s.node_graph = imported.take_graph()
    s.node_canvas = imported.take_canvas()
    s.node_canvas.show_minimap = True
    s.node_canvas.snap_to_grid = True
    s.node_progress.reset()
    s.menu_status = String("loaded ") + label_text


def _node_load_selected_workflow(mut s: InferenceUIState) raises:
    var idx = Int(s.node_workflow_index)
    if idx < 0 or idx >= len(s.node_workflow_paths):
        s.menu_status = String("workflow preset index out of range")
        return
    var path = s.node_workflow_paths[idx].copy()
    var label_text = s.node_workflow_options[idx].copy()
    if path == String("builtin:klein"):
        _node_load_fresh_klein_graph(s)
    else:
        _node_import_comfy_json_path(s, path, label_text)


def _nodes_panel(mut s: InferenceUIState, body_h: Float32) raises:
    ref ctx = s.ctx
    var renaming = s.node_canvas.renaming_node != UInt64(0)
    var changed = False
    var used_h = Int32(0)

    var load_w = _px(s, 110)
    var main_w = _px(s, 150)
    var preset_w = Int32(Int(s.win_w)) - load_w - main_w - _px(s, 38)
    if preset_w < _px(s, 360):
        preset_w = _px(s, 360)
    ctx.layout_row(_row3(preset_w, load_w, main_w), _px(s, 34))
    if combobox(
        ctx,
        String("node_workflow_preset"),
        s.node_workflow_options,
        s.node_workflow_index,
        s.node_workflow_open,
    ):
        s.menu_status = String("selected workflow preset")
    if button_primary(ctx, String("Load")):
        _node_load_selected_workflow(s)
        changed = True
    if button(ctx, String("Main Graph")):
        s.node_workflow_index = 0
        _node_load_selected_workflow(s)
        changed = True
    used_h = used_h + _px(s, 38)

    if renaming:
        var rw = List[Int32]()
        rw.append(Int32(Int(s.win_w)))
        ctx.layout_row(rw^, _px(s, 38))
        _ = text_edit(ctx, String("node_rename_field"), s.node_rename_buffer, s.node_rename_state)
        used_h = _px(s, 38)

    var cw = List[Int32]()
    cw.append(Int32(Int(s.win_w)))
    var canvas_h = Int32(Int(body_h)) - used_h
    if canvas_h < _px(s, 120):
        canvas_h = _px(s, 120)
    ctx.layout_row(cw^, canvas_h)
    if begin_node_canvas(ctx, String("serenity_nodes"), s.node_canvas, s.node_graph):
        changed = True
    end_node_canvas(ctx)

    if s.node_canvas.generate_requested:
        graph_submit_current(s.model, s.zrt)
        s.menu_status = String("running Klein 9B graph from Nodes")
    if s.node_canvas.add_image_requested:
        _node_add_demo_image(s)
        changed = True
    if s.node_canvas.import_json_requested:
        _node_import_comfy_json_path(
            s,
            String("/home/alex/Downloads/image_ideogram4_t2i.json"),
            String("Downloads / Ideogram image test"),
        )
        changed = True

    if ctx.input.mouse_pressed(MOJOUI_BTN_RIGHT) and not s.node_canvas.ctx_menu_open:
        var mp = ctx.control.mouse_pos.copy()
        if mp.y > Float32(Int(_top_chrome(s))):
            var world = canvas_screen_to_world(s.node_canvas, mp.copy())
            s.node_addmenu.show_at(mp.copy(), world)
    if s.node_canvas.ctx_menu_open:
        s.node_addmenu.hide()

    var act = node_context_menu(ctx, String("serenity_node_ctx"), s.node_canvas, s.node_graph)
    if act == NODE_ACTION_DELETE:
        s.menu_status = String("deleted node")
        changed = True
    elif act == NODE_ACTION_DUPLICATE:
        s.menu_status = String("duplicated node")
        changed = True
    elif act == NODE_ACTION_RENAME:
        var idx = s.node_graph.find_node(s.node_canvas.renaming_node)
        if idx >= 0:
            s.node_rename_buffer = s.node_graph.nodes[idx].title.copy()
            s.node_rename_state = TextEditState(single_line=True)
        s.menu_status = String("renaming node")
    elif act == NODE_ACTION_COLOR:
        s.menu_status = String("selected node color")
        changed = True

    if add_menu(ctx, String("serenity_add_menu"), s.node_addmenu, s.node_registry, s.node_graph):
        s.menu_status = String("added node")
        changed = True

    if renaming:
        if ctx.input.key_pressed(MOJOUI_KEY_RETURN):
            var idx = s.node_graph.find_node(s.node_canvas.renaming_node)
            if idx >= 0:
                s.node_graph.nodes[idx].title = s.node_rename_buffer.copy()
            s.node_canvas.renaming_node = UInt64(0)
            s.menu_status = String("renamed node")
            changed = True
        elif ctx.input.key_pressed(MOJOUI_KEY_ESCAPE):
            s.node_canvas.renaming_node = UInt64(0)
            s.menu_status = String("rename cancelled")

    _ = draw_progress_overlay(ctx, s.node_canvas, s.node_graph, s.node_progress)
    if changed:
        _autosave_node_workflow(s)


def _ui(mut s: InferenceUIState) raises:
    if s.tab != Int32(2):
        _draw_backgrounds(s)
    else:
        s.ctx.draw_rect(Rect(0.0, 0.0, s.win_w, s.win_h), Color(22, 22, 28, 255))
    var left_w = Float32(Int(_left_w(s)))
    var center_x = left_w + _fpx(s, 16.0)
    var center_w = Float32(Int(_center_w(s)))
    var right_x = _right_x(s)
    var top_y = Float32(Int(_top_chrome(s)))
    var body_h = s.win_h - top_y - Float32(Int(_status_h(s)))

    if s.tab == Int32(2):
        s.ctx.begin_panel(Rect(0.0, top_y, s.win_w, body_h))
        _nodes_panel(s, body_h)
        s.ctx.end_panel()
    else:
        s.ctx.begin_panel(Rect(0.0, top_y, left_w, body_h))
        _left_panel(s)
        s.ctx.end_panel()

        s.ctx.begin_panel(Rect(center_x, top_y, center_w, body_h))
        _center_panel(s, center_x + _fpx(s, 8.0))
        s.ctx.end_panel()

        s.ctx.begin_panel(Rect(right_x, top_y, Float32(Int(_right_w(s))), body_h))
        _right_panel(s, right_x + _fpx(s, 12.0))
        s.ctx.end_panel()

    # Chrome drawn last so it sits above panel backgrounds + content.
    # (Title bar is the native OS bar — see _top_chrome. _title_bar() is kept
    # defined for when MojoUI gains borderless/custom-chrome support.)
    _menu_bar(s)
    _status_bar(s)


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    _ = Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _sync_result_texture(mut s: InferenceUIState):
    """Upload the latest completed graph result once the GL context is live."""
    if s.zrt.result_job_id == UInt64(0):
        return
    if s.zrt.result_job_id == s.zrt.uploaded_job_id:
        return
    if s.zrt.result_width <= 0 or s.zrt.result_height <= 0:
        return
    if s.zrt.texture_id != UInt32(0):
        Backend.destroy_texture(s.zrt.texture_id)
        s.zrt.texture_id = UInt32(0)
    if s.zrt.result_path.byte_length() > 0:
        var loaded = Backend.load_texture_file_info(
            s.zrt.result_path,
            Int32(s.zrt.result_width),
            Int32(s.zrt.result_height),
        )
        s.zrt.texture_id = loaded.texture_id
    elif len(s.zrt.result_pixels) > 0:
        s.zrt.texture_id = Backend.make_texture_rgba(
            Int32(s.zrt.result_width),
            Int32(s.zrt.result_height),
            s.zrt.result_pixels,
        )
    if s.zrt.texture_id != UInt32(0):
        s.zrt.uploaded_job_id = s.zrt.result_job_id


def _render_command_buffer(mut ctx: Context) raises:
    """Render through the shared live command-buffer adapter."""
    _ = render_context_commands(ctx, String("MojoUI m8"))


