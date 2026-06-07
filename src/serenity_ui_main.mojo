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


# ---------------------------------------------------------------------------
# Layout constants. Three columns split a 1500-wide window.
# ---------------------------------------------------------------------------

comptime _WIN_W: Float32 = 1500.0
comptime _WIN_H: Float32 = 950.0
comptime _LEFT_W: Int32 = 380
comptime _RIGHT_W: Int32 = 360
comptime _GUTTER: Int32 = 16
# center = win - left - right - 3 gutters
comptime _CENTER_W: Int32 = 1500 - 380 - 360 - 48

# Window chrome heights (unscaled px) — mirror the Flame reference:
# title bar 32 / menu bar 34 / status bar 22.
comptime _TITLE_H: Int32 = 32
comptime _MENU_H: Int32 = 34
comptime _STATUS_H: Int32 = 22
comptime _NODE_PERSIST_DIR = "/home/alex/.cache/serenityui"
comptime _NODE_PERSIST_WORKFLOW = "/home/alex/.cache/serenityui/klein9b_nodegraph.workflow.json"


# ---------------------------------------------------------------------------
# Persistent demo state — wraps the pure InferenceState plus the live-only
# Context + text-edit engines + section open flags + a frame seed.
# ---------------------------------------------------------------------------


struct InferenceUIState(Movable):
    var ctx: Context
    var model: InferenceState
    var zrt: GraphUiRuntime
    var node_registry: NodeRegistry
    var node_graph: Graph
    var node_canvas: CanvasState
    var node_progress: ProgressState
    var node_addmenu: AddMenuState
    var node_rename_buffer: String
    var node_rename_state: TextEditState
    var node_workflow_options: List[String]
    var node_workflow_paths: List[String]
    var node_workflow_index: Int32
    var node_workflow_open: Bool

    var prompt_edit: MultiLineState
    var negative_edit: MultiLineState

    # collapsing-header open flags (left panel)
    var sec_model: Bool
    var sec_resolution: Bool
    var sec_sampling: Bool
    var sec_seed: Bool
    var sec_lora: Bool
    var sec_batch: Bool
    var sec_advanced: Bool

    var pseudo_rng: UInt32   # for the randomize-seed button
    var font_id: UInt32
    var win_w: Float32
    var win_h: Float32
    var scale: Float32
    var perf_refresh_tick: Int32

    # chrome state
    var tab: Int32           # 0 = Image, 1 = Video, 2 = Nodes
    var theme_dark: Bool     # dark/light toggle in the menu bar
    var open_menu: Int32     # menu-bar dropdown open index (-1 = none)
    var menu_status: String

    def __init__(out self) raises:
        self.ctx = Context()
        self.model = InferenceState()
        self.zrt = GraphUiRuntime()
        var registry = NodeRegistry()
        register_builtins(registry)
        self.node_registry = registry^
        self.node_graph = _build_serenity_node_graph(self.model)
        self.node_canvas = _build_serenity_node_canvas(self.node_graph)
        self.node_progress = ProgressState()
        self.node_addmenu = AddMenuState()
        self.node_rename_buffer = String("")
        self.node_rename_state = TextEditState(single_line=True)
        self.node_workflow_options = List[String]()
        self.node_workflow_paths = List[String]()
        _populate_node_workflow_presets(self.node_workflow_options, self.node_workflow_paths)
        self.node_workflow_index = 0
        self.node_workflow_open = False
        self.prompt_edit = MultiLineState()
        self.prompt_edit.set_text(self.model.prompt)
        self.negative_edit = MultiLineState()
        self.negative_edit.set_text(self.model.negative)
        self.sec_model = True
        self.sec_resolution = True
        self.sec_sampling = True
        self.sec_seed = False
        self.sec_lora = False
        self.sec_batch = False
        self.sec_advanced = False
        self.pseudo_rng = 0x9E3779B9
        self.font_id = 0
        self.win_w = _WIN_W
        self.win_h = _WIN_H
        self.scale = 1.0
        self.perf_refresh_tick = 1000
        self.tab = 0
        self.theme_dark = True
        self.open_menu = -1
        self.menu_status = String("ready")
        _apply_serenity_palette(self.ctx, True)


# ---------------------------------------------------------------------------
# Row-width helpers (fresh List[Int32] per call — c13 by-move ownership).
# ---------------------------------------------------------------------------


def _row1(a: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    return w^


def _row2(a: Int32, b: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    return w^


def _row3(a: Int32, b: Int32, c: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    w.append(c)
    return w^


def _add_node_workflow_preset(
    mut names: List[String],
    mut paths: List[String],
    label: String,
    path: String,
):
    names.append(label.copy())
    paths.append(path.copy())


def _populate_node_workflow_presets(mut names: List[String], mut paths: List[String]):
    _add_node_workflow_preset(
        names, paths,
        String("Main screen / Klein 9B graph"),
        String("builtin:klein"),
    )
    _add_node_workflow_preset(
        names, paths,
        String("Downloads / Ideogram image test"),
        String("/home/alex/Downloads/image_ideogram4_t2i.json"),
    )

    var sf = String("/home/alex/serenityflow-v2/serenityflow/workflows/")
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 1 Dev edit"), sf + String("flux1_dev_edit.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 1 Dev edit LoRA"), sf + String("flux1_dev_edit_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 1 Dev t2i"), sf + String("flux1_dev_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 1 Dev t2i LoRA"), sf + String("flux1_dev_t2i_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 2 Dev edit"), sf + String("flux2_dev_edit.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 2 Dev edit LoRA"), sf + String("flux2_dev_edit_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 2 Dev t2i"), sf + String("flux2_dev_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Flux 2 Dev t2i LoRA"), sf + String("flux2_dev_t2i_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 4B edit"), sf + String("klein4b_edit.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 4B edit LoRA"), sf + String("klein4b_edit_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 4B t2i"), sf + String("klein4b_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 4B t2i LoRA"), sf + String("klein4b_t2i_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 9B edit"), sf + String("klein9b_edit.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 9B edit LoRA"), sf + String("klein9b_edit_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 9B t2i"), sf + String("klein9b_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Klein 9B t2i LoRA"), sf + String("klein9b_t2i_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 a2v"), sf + String("ltx23_a2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 i2v"), sf + String("ltx23_i2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 ia2v"), sf + String("ltx23_ia2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 fp8 a2v"), sf + String("ltx23_serenityfp8_a2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 fp8 i2v"), sf + String("ltx23_serenityfp8_i2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 fp8 ia2v"), sf + String("ltx23_serenityfp8_ia2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 fp8 t2v"), sf + String("ltx23_serenityfp8_t2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / LTX 2.3 t2v"), sf + String("ltx23_t2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Qwen edit"), sf + String("qwen_edit.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Qwen edit LoRA"), sf + String("qwen_edit_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Qwen Image t2i"), sf + String("qwen_image_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Qwen Image t2i LoRA"), sf + String("qwen_image_t2i_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / SD 3.5 Large t2i"), sf + String("sd35_large_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / SDXL t2i"), sf + String("sdxl_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.2 i2v"), sf + String("wan22_i2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.2 i2v LoRA"), sf + String("wan22_i2v_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.2 t2v"), sf + String("wan22_t2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.2 t2v LoRA"), sf + String("wan22_t2v_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.3 i2v"), sf + String("wan23_i2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.3 i2v LoRA"), sf + String("wan23_i2v_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.3 t2v"), sf + String("wan23_t2v.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Wan 2.3 t2v LoRA"), sf + String("wan23_t2v_lora.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Z-Image t2i"), sf + String("zimage_t2i.json"))
    _add_node_workflow_preset(names, paths, String("SerenityFlow / Z-Image t2i LoRA"), sf + String("zimage_t2i_lora.json"))

    var sw = String("/home/alex/SwarmUI/dlbackend/ComfyUI/blueprints/")
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Text to Image"), sw + String("Text to Image.json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Text to Image Qwen"), sw + String("Text to Image (Qwen-Image).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Text to Image Qwen 2512"), sw + String("Text to Image (Qwen-Image 2512).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Text to Image Flux 2 Dev"), sw + String("Text to Image (Flux.2 Dev).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Text to Image Z-Image Turbo"), sw + String("Text to Image (Z-Image-Turbo).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Image Edit Klein 4B"), sw + String("Image Edit (Flux.2 Klein 4B).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Image Edit Qwen 2511"), sw + String("Image Edit (Qwen 2511).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Image to Video Wan 2.2"), sw + String("Image to Video (Wan 2.2).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Text to Video Wan 2.2"), sw + String("Text to Video (Wan 2.2).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / First Last Frame LTX 2.3"), sw + String("First-Last-Frame to Video (LTX-2.3).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Canny to Video LTX 2.0"), sw + String("Canny to Video (LTX 2.0).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / ControlNet Z-Image Turbo"), sw + String("ControlNet (Z-Image-Turbo).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Image Inpainting Qwen"), sw + String("Image Inpainting (Qwen-image).json"))
    _add_node_workflow_preset(names, paths, String("Comfy/Swarm / Prompt Enhance"), sw + String("Prompt Enhance.json"))


def _clamp_scale(v: Float32) -> Float32:
    if v < 1.0:
        return 1.0
    if v > 1.8:
        return 1.8
    return v


def _scale_for(win_w: Float32, win_h: Float32) -> Float32:
    var sx = win_w / _WIN_W
    var sy = win_h / _WIN_H
    var s = sx
    if sy < s:
        s = sy
    return _clamp_scale(s)


def _gb_text(value: Float32) -> String:
    var tenths = Int(value * 10.0 + 0.5)
    var whole = tenths / 10
    var frac = tenths - whole * 10
    return String(whole) + String(".") + String(frac)


def _refresh_perf_telemetry(mut s: InferenceUIState):
    s.perf_refresh_tick = s.perf_refresh_tick + 1
    if s.perf_refresh_tick < 60:
        return
    s.perf_refresh_tick = 0
    var metrics = Backend.system_metrics()
    if metrics.gpu_available:
        s.model.perf.gpu_name = metrics.gpu_name.copy()
        s.model.perf.vram_used_gb = Float32(metrics.gpu_memory_used_mb) / 1024.0
        s.model.perf.vram_total_gb = Float32(metrics.gpu_memory_total_mb) / 1024.0
        s.model.perf.gpu_util_pct = Float32(metrics.gpu_util_percent)
        s.model.perf.temperature_c = Float32(metrics.gpu_temperature_c)
    else:
        s.model.perf.gpu_name = String("GPU telemetry unavailable")
        s.model.perf.vram_used_gb = 0.0
        s.model.perf.vram_total_gb = 0.0
        s.model.perf.gpu_util_pct = 0.0
        s.model.perf.temperature_c = 0.0


def _px_scale(scale: Float32, value: Int32) -> Int32:
    return Int32(Float32(Int(value)) * scale + 0.5)


def _px(s: InferenceUIState, value: Int32) -> Int32:
    return _px_scale(s.scale, value)


def _fpx(s: InferenceUIState, value: Float32) -> Float32:
    return value * s.scale


def _font_body(s: InferenceUIState) -> Int32:
    if s.scale >= 1.45:
        return Int32(24)
    if s.scale >= 1.15:
        return Int32(18)
    return Int32(16)


def _left_w(s: InferenceUIState) -> Int32:
    return _px(s, _LEFT_W)


def _right_w(s: InferenceUIState) -> Int32:
    return _px(s, _RIGHT_W)


def _gutter(s: InferenceUIState) -> Int32:
    return _px(s, _GUTTER)


def _title_h(s: InferenceUIState) -> Int32:
    return _px(s, _TITLE_H)


def _menu_h(s: InferenceUIState) -> Int32:
    return _px(s, _MENU_H)


def _status_h(s: InferenceUIState) -> Int32:
    return _px(s, _STATUS_H)


def _top_chrome(s: InferenceUIState) -> Int32:
    """Height of in-window chrome above the panels. The OS supplies the title
    bar (sokol_app has no borderless mode), so our top chrome is just the menu
    bar; panel content begins right below it."""
    return _menu_h(s)


def _accent() -> Color:
    """serenityUI's orange accent — used ONLY for the chrome bits we draw
    ourselves (icon, active tab, underline, dots). MojoUI conflates control
    fill + accent into theme.primary, so we keep primary a neutral control
    color and never use it as the accent here."""
    return Color(235, 150, 60, 255)


def _apply_serenity_palette(mut ctx: Context, dark: Bool):
    """serenityUI palette. NOTE: MojoUI widgets use theme.primary as their
    RESTING FILL (combobox/button/drag_value) as well as the accent
    (slider/progress fill, focus rings). To avoid an all-orange UI we keep
    primary a neutral dark control color; vivid orange lives in _accent()
    for our own chrome. Splitting control_bg vs accent in MojoUI is the
    proper fix (deferred to theming polish)."""
    if dark:
        ctx.theme.bg = Color(22, 22, 28, 255)
        ctx.theme.fg = Color(225, 225, 235, 255)
        ctx.theme.text = Color(225, 225, 235, 255)
        ctx.theme.primary = Color(235, 150, 60, 255)     # orange accent
        ctx.theme.control_bg = Color(44, 44, 54, 255)    # neutral control fill
        ctx.theme.hover_bg = Color(58, 58, 70, 255)
        ctx.theme.active_bg = Color(74, 74, 88, 255)
        ctx.theme.border = Color(72, 72, 84, 255)
    else:
        ctx.theme.bg = Color(238, 238, 242, 255)
        ctx.theme.fg = Color(30, 30, 38, 255)
        ctx.theme.text = Color(30, 30, 38, 255)
        ctx.theme.primary = Color(210, 120, 30, 255)     # orange accent
        ctx.theme.control_bg = Color(224, 224, 232, 255)  # neutral control fill
        ctx.theme.hover_bg = Color(208, 208, 218, 255)
        ctx.theme.active_bg = Color(190, 190, 202, 255)
        ctx.theme.border = Color(200, 200, 210, 255)


def _center_w(s: InferenceUIState) -> Int32:
    var w = Int32(s.win_w) - _left_w(s) - _right_w(s) - _gutter(s) * 3
    if w < _px(s, _CENTER_W):
        return _px(s, _CENTER_W)
    return w


def _left_label_w(s: InferenceUIState) -> Int32:
    return _px(s, 110)


def _left_field_w(s: InferenceUIState) -> Int32:
    var w = _left_w(s) - _left_label_w(s) - _px(s, 22)
    if w < _px(s, 180):
        return _px(s, 180)
    return w


def _left_full_w(s: InferenceUIState) -> Int32:
    return _left_label_w(s) + _left_field_w(s)


def _right_x(s: InferenceUIState) -> Float32:
    return Float32(Int(_left_w(s) + _center_w(s) + _gutter(s) * 2))


def _initial_window_size() -> Vec2:
    var display = Backend.display_size()
    if display.x <= 0.0 or display.y <= 0.0:
        return Vec2(_WIN_W, _WIN_H)
    var w = display.x * 0.92
    var h = display.y * 0.90
    if w < _WIN_W:
        w = _WIN_W
    if h < _WIN_H:
        h = _WIN_H
    return Vec2(w, h)


def _node_display_job(model: InferenceState) -> QueueJob:
    return QueueJob(
        UInt64(1),
        model.prompt.copy(),
        Int32(Int(model.width)),
        Int32(Int(model.height)),
        Int32(Int(model.steps)),
        model.sampler_label(),
        Int64(-1),
        UInt32(0),
    )


def _build_fresh_klein9b_node_graph(model: InferenceState) raises -> Graph:
    var display = _node_display_job(model)
    return build_klein9b_inference_graph(
        model,
        display,
        String("/home/alex/mojodiffusion/output/serenityui_klein9b_nodes.png"),
        Int32(1024),
        Int32(1024),
    )


def _build_serenity_node_graph(model: InferenceState) raises -> Graph:
    var g = _build_fresh_klein9b_node_graph(model)
    try:
        var file = open(String(_NODE_PERSIST_WORKFLOW), String("r"))
        var saved = parse_workflow(file.read())
        if saved.node_count() > 0:
            if graph_has_port_metadata(saved):
                g = saved^
            else:
                var matched = merge_saved_node_layout(g, saved)
                if matched == saved.node_count():
                    _write_text_file(String(_NODE_PERSIST_WORKFLOW), emit_workflow(g))
    except e:
        pass
    return g^


def _build_serenity_node_canvas(graph: Graph) -> CanvasState:
    var canvas = CanvasState()
    canvas.pan = Vec2(110.0, 115.0)
    canvas.zoom = Float32(1.30)
    canvas.show_minimap = True
    canvas.snap_to_grid = True
    var group = CanvasGroup(
        Int64(1),
        String("SerenityUI Klein 9B Generate Workflow"),
        Rect(20.0, 35.0, 2500.0, 840.0),
        Color(64, 118, 210, 68),
    )
    for i in range(graph.node_count()):
        group.members.append(graph.nodes[i].id)
    canvas.groups.append(group^)
    canvas.next_group_id = Int64(2)
    return canvas^


def _autosave_node_workflow(s: InferenceUIState):
    try:
        _ = _sys_system(String("mkdir -p ") + String(_NODE_PERSIST_DIR))
        _write_text_file(String(_NODE_PERSIST_WORKFLOW), emit_workflow(s.node_graph))
    except e:
        pass


def _sync_window_metrics(mut s: InferenceUIState):
    var win = Backend.window_size()
    if win.x <= 0.0 or win.y <= 0.0:
        win = Vec2(_WIN_W, _WIN_H)
    s.win_w = win.x
    s.win_h = win.y
    s.scale = _scale_for(win.x, win.y)
    s.ctx.theme.font_size_pt = _font_body(s)
    s.ctx.theme.row_height = _px(s, 26)
    s.ctx.theme.padding = _px(s, 6)
    s.ctx.theme.spacing = _px(s, 5)


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
        _ = combobox(ctx, String("model"), s.model.model_options,
                     s.model.model_index, s.model.model_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("VAE:"))
        _ = combobox(ctx, String("vae"), s.model.vae_options,
                     s.model.vae_index, s.model.vae_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Precision:"))
        _ = combobox(ctx, String("precision"), s.model.precision_options,
                     s.model.precision_index, s.model.precision_open)


def _section_resolution(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Resolution"), s.sec_resolution):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Preset:"))
        _ = combobox(ctx, String("respreset"), s.model.resolution_options,
                     s.model.resolution_index, s.model.resolution_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Width:"))
        _ = slider(ctx, s.model.width, Float32(256.0), Float32(2048.0), String("width"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Height:"))
        _ = slider(ctx, s.model.height, Float32(256.0), Float32(2048.0), String("height"))


def _section_sampling(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Sampling"), s.sec_sampling):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Sampler:"))
        _ = combobox(ctx, String("sampler"), s.model.sampler_options,
                     s.model.sampler_index, s.model.sampler_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Scheduler:"))
        _ = combobox(ctx, String("scheduler"), s.model.scheduler_options,
                     s.model.scheduler_index, s.model.scheduler_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Steps:"))
        _ = slider(ctx, s.model.steps, Float32(1.0), Float32(100.0), String("steps"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("CFG:"))
        _ = drag_value(ctx, s.model.cfg, String("cfg"), Float32(0.1))


def _section_seed(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Seed"), s.sec_seed):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Seed:"))
        _ = drag_value(ctx, s.model.seed, String("seed"), Float32(1.0))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Mode:"))
        _ = combobox(ctx, String("seedmode"), s.model.seed_mode_options,
                     s.model.seed_mode_index, s.model.seed_mode_open)
        ctx.layout_row(_row1(_left_full_w(s)), _px(s, 28))
        _ = checkbox(ctx, String("Lock seed"), s.model.seed_locked)


def _section_lora(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("LoRA"), s.sec_lora):
        var n = len(s.model.loras)
        for i in range(n):
            ctx.layout_row(_row3(_px(s, 140), _px(s, 168), _px(s, 50)), _px(s, 26))
            label(ctx, s.model.loras[i].name)
            _ = slider(ctx, s.model.loras[i].strength, Float32(0.0),
                       Float32(2.0), String("lora_str_") + String(i))
            _ = checkbox(ctx, String(""), s.model.loras[i].active)
        ctx.layout_row(_row2(_px(s, 180), _left_full_w(s) - _px(s, 180)), _px(s, 28))
        if button(ctx, String("+ Add LoRA")):
            s.model.loras.append(
                LoraSlot(String("new-lora.safetensors"), Float32(1.0), True)
            )
        if button(ctx, String("- Remove last")):
            if len(s.model.loras) > 0:
                var keep = List[LoraSlot]()
                for j in range(len(s.model.loras) - 1):
                    keep.append(s.model.loras[j].copy())
                s.model.loras = keep^


def _section_batch(mut s: InferenceUIState) raises:
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Batch"), s.sec_batch):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Count:"))
        _ = slider(ctx, s.model.batch_count, Float32(1.0), Float32(16.0), String("bcount"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Size:"))
        _ = slider(ctx, s.model.batch_size, Float32(1.0), Float32(8.0), String("bsize"))


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
    _section_advanced(s)


def _center_panel(mut s: InferenceUIState, col_x: Float32) raises:
    ref ctx = s.ctx
    # task/mode header
    ctx.layout_row(_row1(_center_w(s)), _px(s, 30))
    label(ctx, String("Image  ·  ") + s.model.task_short()
          + String("  ·  ") + s.model.model_label())

    ctx.layout_row(_row1(_center_w(s)), _px(s, 24))
    label(ctx, String("Prompt:"))
    ctx.layout_row(_row1(_center_w(s)), _px(s, 80))
    if text_area(ctx, String("prompt"), s.model.prompt, s.prompt_edit):
        pass

    ctx.layout_row(_row1(_center_w(s)), _px(s, 24))
    label(ctx, String("Negative:"))
    ctx.layout_row(_row1(_center_w(s)), _px(s, 56))
    if text_area(ctx, String("negative"), s.model.negative, s.negative_edit):
        pass

    # action bar
    ctx.layout_row(_row3(_px(s, 196), _px(s, 200), _px(s, 200)), _px(s, 40))
    label(ctx, String(""))
    if s.model.generating:
        if button(ctx, String("Cancel")):
            graph_cancel_all(s.model, s.zrt)
    else:
        if button_primary(ctx, String("Generate")):
            graph_submit_current(s.model, s.zrt)
    if button(ctx, String("Randomize seed")):
        s.pseudo_rng = s.pseudo_rng * UInt32(1664525) + UInt32(1013904223)
        s.model.seed = Float32(Int(s.pseudo_rng % UInt32(1000000)))

    # image preview
    ctx.layout_row(_row1(_center_w(s)), _px(s, 460))
    var slot = ctx.layout_next()
    var side: Float32 = _fpx(s, 440.0)
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

    # progress bar + readout
    ctx.layout_row(_row1(_center_w(s)), _px(s, 18))
    progress_bar(ctx, graph_progress_fraction(s.model))
    if s.font_id != 0:
        var readout = String("step ") + String(s.model.current_step) \
            + String("/") + String(s.model.total_steps)
        ctx.draw_text(s.font_id, _font_body(s),
                      Vec2(col_x, s.win_h - Float32(Int(_status_h(s))) - _fpx(s, 18.0)),
                      Color(150, 200, 160, 255), readout)


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
        if s.model.has_running:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("▶ running #") + String(s.model.running.id))
            ctx.layout_row(_row1(_right_w(s)), _px(s, 16))
            progress_bar(ctx, s.model.running.progress())
        var nq = len(s.model.queued)
        for i in range(nq):
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("· queued #") + String(s.model.queued[i].id)
                  + String("  ") + String(Int(s.model.queued[i].width))
                  + String("x") + String(Int(s.model.queued[i].height)))
        if (not s.model.has_running) and nq == 0:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("(queue empty)"))
    else:
        var nh = len(s.model.history)
        if nh == 0:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("(no history)"))
        for i in range(nh):
            var idx = nh - 1 - i  # newest first
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("✓ #") + String(s.model.history[idx].id)
                  + String("  seed ") + String(s.model.history[idx].seed))

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
    ctx.draw_rect(Rect(_fpx(s, 10.0), y + (h - dot) * 0.5, dot, dot),
                  Color(90, 200, 120, 255))
    ctx.draw_text(s.font_id, fs, Vec2(_fpx(s, 24.0), ty), Color(150, 150, 165, 255),
                  String("backend connected  ·  serenitymojo  ·  ")
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
        s.menu_status = String("cycled node color")
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


def _frame() -> None:
    var sp = retrieve_user_state[InferenceUIState]()
    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
    _sync_window_metrics(sp[])

    # Advance graph-runtime state before building the UI so completed-result
    # textures are current this frame.
    graph_tick_and_apply(sp[].model, sp[].zrt)
    _refresh_perf_telemetry(sp[])
    _sync_result_texture(sp[])

    sp[].ctx.begin_frame(Vec2(sp[].win_w, sp[].win_h))
    Backend.frame_begin(Color(18, 18, 22, 255))
    try:
        _ui(sp[])
    except e:
        print("MojoUI m8 UI error:", String(e))
    sp[].ctx.end_frame()
    try:
        _render_command_buffer(sp[].ctx)
    except e:
        print("MojoUI m8 walker error:", String(e))
    Backend.frame_end()


def _graph_seam_selfcheck():
    """Compile and dry-run the Klein graph once at startup."""
    var state = InferenceState()
    try:
        var ok = dry_run_klein9b_graph(state)
        print("[graph-seam] klein9b_graph_dry=", ok, " model=", state.model_label())
    except e:
        print("[graph-seam] failed:", String(e))


def main() raises:
    _graph_seam_selfcheck()
    var state = InferenceUIState()
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
