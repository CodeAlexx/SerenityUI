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

    # ── gen-screen param state (plan H1/H2) ──
    # `store` is the SINGLE source of truth for generation params; every edit
    # flows through store.set() (the observer dispatch point). The lists below
    # are option catalogs (NOT param state): the daemon's /v1/models scan.
    var store: GenParamStore
    var model_display: List[String]   # combobox labels "arch · name"
    var model_names: List[String]     # canonical genparams.model values
    var model_archs: List[String]
    var model_combo_open: Bool
    var lora_names: List[String]      # /v1/models loras (P2 row options)
    var lora_row_open: List[Bool]     # per-row combobox open flag
    var models_from_daemon: Bool

    # presets (P8)
    var presets: List[String]
    var preset_index: Int32
    var preset_open: Bool
    var preset_name_buf: String
    var preset_name_state: TextEditState

    # persistent history (P14-P16)
    var gallery: List[GalleryItem]
    var starred_ids: List[String]

    # TEMPORARY --selftest-ui driver (scripted gates): 0=off, 1=auto-generate,
    # 2=auto-generate then auto-cancel. Drives the SAME functions the buttons
    # call. Fine to keep; remove when xdotool-driven gates land.
    var autogen_mode: Int
    var frame_no: Int

    # collapsing-header open flags (left panel)
    var sec_model: Bool
    var sec_resolution: Bool
    var sec_sampling: Bool
    var sec_seed: Bool
    var sec_lora: Bool
    var sec_batch: Bool
    var sec_presets: Bool
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
        # ── gen-screen param store (H1) + option catalogs ──
        self.store = GenParamStore()
        self.model_display = List[String]()
        self.model_names = List[String]()
        self.model_archs = List[String]()
        self.model_combo_open = False
        self.lora_names = List[String]()
        self.lora_row_open = List[Bool]()
        self.models_from_daemon = False
        self.presets = list_presets()
        self.preset_index = 0
        self.preset_open = False
        self.preset_name_buf = String("my-preset")
        self.preset_name_state = TextEditState(single_line=True)
        self.starred_ids = load_stars()
        self.gallery = load_gallery_from_db(self.starred_ids)
        self.autogen_mode = 0
        self.frame_no = 0

        self.prompt_edit = MultiLineState()
        self.negative_edit = MultiLineState()
        self.sec_model = True
        self.sec_resolution = True
        self.sec_sampling = True
        self.sec_seed = True
        self.sec_lora = True
        self.sec_batch = True
        self.sec_presets = True
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

        # daemon health + /v1/models population (P1/P2) with CLI fallback,
        # then seed the param store. (Runs LAST: self must be fully
        # initialized before it is passed to helper functions.)
        daemon_refresh_health(self.zrt)
        _populate_model_catalog(self)
        _seed_initial_params(self)
        self.prompt_edit.set_text(self.store.m_prompt)
        self.negative_edit.set_text(self.store.m_negative)


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


def _row4(a: Int32, b: Int32, c: Int32, d: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    w.append(c)
    w.append(d)
    return w^


# ---------------------------------------------------------------------------
# Gen-screen param plumbing (plan H1/H2 + P1-P6/P8/P11/P12/P14-P16).
# ---------------------------------------------------------------------------


def _populate_model_catalog(mut s: InferenceUIState):
    """P1: model selector backed by the daemon's /v1/models disk scan
    (grouped by arch in the labels); P2: LoRA options from the same scan.
    Daemon down -> static CLI-name fallback (arch 'cli')."""
    s.model_display = List[String]()
    s.model_names = List[String]()
    s.model_archs = List[String]()
    s.lora_names = List[String]()
    s.models_from_daemon = False
    if s.zrt.daemon_ok:
        try:
            var models = List[DaemonModelEntry]()
            var loras = List[DaemonLoraEntry]()
            daemon_models(models, loras)
            # group by arch: stable sort by arch label (zimage first since it
            # is the daemon-routable family)
            var order: List[String] = [
                "zimage", "flux-2/klein", "flux", "chroma", "qwen-image",
                "sd3", "sdxl", "anima", "ltx2", "wan", "unknown",
            ]
            for g in range(len(order)):
                for i in range(len(models)):
                    if models[i].arch != order[g]:
                        continue
                    s.model_display.append(
                        models[i].arch + String(" · ") + models[i].name
                    )
                    s.model_names.append(models[i].name.copy())
                    s.model_archs.append(models[i].arch.copy())
            for i in range(len(loras)):
                s.lora_names.append(loras[i].name.copy())
            s.models_from_daemon = True
        except e:
            print("[gen-screen] /v1/models failed:", String(e))
    if len(s.model_names) == 0:
        # static CLI fallback (daemon down): names double as backend names
        var fallback: List[String] = [
            "Z-Image (base)", "Z-Image (turbo)", "Klein 9B", "Klein 4B",
            "Qwen-Image", "FLUX Dev", "Chroma", "SD 3.5", "ERNIE", "Anima",
            "SDXL",
        ]
        for i in range(len(fallback)):
            s.model_display.append(String("cli · ") + fallback[i])
            s.model_names.append(fallback[i].copy())
            s.model_archs.append(String("cli"))
        # demo LoRA names so the stack is editable offline
        s.lora_names = ["detail-tweaker-xl", "film-photography-v2"]


def _seed_initial_params(mut s: InferenceUIState):
    """Initial canonical params through the H2 dispatch point."""
    var p = GenParams()
    p.prompt = String(
        "cinematic portrait, 85mm, warm afternoon light, film grain"
    )
    p.negative = String("ugly, blurry, low quality, watermark")
    p.width = 512
    p.height = 512
    p.steps = 20
    p.cfg = 4.5
    p.seed = 42
    p.images = 1
    # prefer the daemon-routable zimage_base checkpoint when present
    var pick = 0
    for i in range(len(s.model_names)):
        if s.model_archs[i] == String("zimage"):
            pick = i
            break
    if pick < len(s.model_names):
        p.model = s.model_names[pick].copy()
    if len(s.model.sampler_options) > 0:
        p.sampler = s.model.sampler_options[0].copy()
    if len(s.model.scheduler_options) > 0:
        p.scheduler = s.model.scheduler_options[0].copy()
    try:
        s.store.set(p^)
    except e:
        print("[gen-screen] initial store.set failed:", String(e))
    _refresh_store(s)


def _cli_name_for(arch: String, name: String) -> String:
    """Map a daemon-scanned (arch, name) to the CLI backend registry name.
    '' = no CLI backend for this arch."""
    if arch == String("cli"):
        return name.copy()
    if arch == String("zimage"):
        if name.find(String("turbo")) >= 0:
            return String("Z-Image (turbo)")
        return String("Z-Image (base)")
    if arch == String("flux-2/klein"):
        if name.find(String("4b")) >= 0:
            return String("Klein 4B")
        return String("Klein 9B")
    if arch == String("flux"):
        return String("FLUX Dev")
    if arch == String("chroma"):
        return String("Chroma")
    if arch == String("sd3"):
        return String("SD 3.5")
    if arch == String("sdxl"):
        return String("SDXL")
    if arch == String("qwen-image"):
        return String("Qwen-Image")
    if arch == String("anima"):
        return String("Anima")
    return String("")


def _selected_arch(s: InferenceUIState) -> String:
    var i = Int(s.store.m_model_index)
    if i < 0 or i >= len(s.model_archs):
        return String("")
    return s.model_archs[i].copy()


def _sync_lora_open(mut s: InferenceUIState):
    """Keep the per-row combobox open-flag list sized to the store's rows."""
    while len(s.lora_row_open) < len(s.store.m_lora_indices):
        s.lora_row_open.append(False)
    while len(s.lora_row_open) > len(s.store.m_lora_indices):
        _ = s.lora_row_open.pop()


def _refresh_store(mut s: InferenceUIState):
    """Subscriber re-read (H2): rebuild widget mirrors + text engines when
    params changed via set() outside the mirror commit (preset load,
    reuse-params, seed resolution at submit)."""
    var lnames = s.lora_names.copy()
    var refreshed = s.store.refresh_mirrors(
        s.model_names, s.model.sampler_options, s.model.scheduler_options, lnames
    )
    s.lora_names = lnames^
    if refreshed:
        s.prompt_edit.set_text(s.store.m_prompt)
        s.negative_edit.set_text(s.store.m_negative)
    _sync_lora_open(s)


def _commit_store(mut s: InferenceUIState):
    """End-of-frame commit: widget mirrors -> store.set() when changed (the
    single H2 dispatch point — see GenParamStore.commit_mirrors)."""
    try:
        _ = s.store.commit_mirrors(
            s.model_names, s.model.sampler_options,
            s.model.scheduler_options, s.lora_names,
        )
    except e:
        print("[gen-screen] commit failed:", String(e))


def _drain_daemon_done(mut s: InferenceUIState):
    """Move the bridge's terminal-job events into persistent history (P14)."""
    var n = len(s.zrt.daemon_done_events)
    if n == 0:
        return
    for i in range(n):
        var ev = s.zrt.daemon_done_events[i].copy()
        if ev.state != String("done"):
            s.menu_status = ev.id + String(" ") + ev.state
            continue
        var item = GalleryItem()
        item.job_id = ev.id.copy()
        item.created = ev.created.copy()
        item.model = ev.model.copy()
        item.state = ev.state.copy()
        item.output_path = absolutize_output_path(ev.output_path)
        try:
            item.params_json = read_genparams_from_png(item.output_path)
        except:
            item.params_json = s.zrt.last_submit_json.copy()
        for k in range(len(s.starred_ids)):
            if s.starred_ids[k] == item.job_id:
                item.starred = True
                break
        # de-dup (a poll can race a db reload)
        var seen = False
        for k in range(len(s.gallery)):
            if s.gallery[k].job_id == item.job_id:
                seen = True
                break
        if not seen:
            s.gallery.append(item^)
        s.menu_status = ev.id + String(" done")
    s.zrt.daemon_done_events = List[DaemonJobInfo]()


def _reuse_params_from_item(mut s: InferenceUIState, idx: Int):
    """P15: restore ALL params from the output PNG's serenity.genparams.v1
    tEXt chunk through the H2 dispatch (widgets re-read next frame)."""
    if idx < 0 or idx >= len(s.gallery):
        return
    var pj: String
    try:
        pj = read_genparams_from_png(s.gallery[idx].output_path)
    except:
        pj = s.gallery[idx].params_json.copy()  # db fallback (PNG moved?)
    try:
        var p = GenParams.from_json(pj)
        s.store.set(p^)
        s.menu_status = String("params restored from ") + s.gallery[idx].job_id
    except e:
        s.menu_status = String("reuse-params failed: ") + String(e)


def _toggle_star(mut s: InferenceUIState, idx: Int):
    """P16: star/favorite toggle, persisted to ~/.serenity/ui_stars.json."""
    if idx < 0 or idx >= len(s.gallery):
        return
    s.gallery[idx].starred = not s.gallery[idx].starred
    var ids = List[String]()
    for i in range(len(s.gallery)):
        if s.gallery[i].starred:
            ids.append(s.gallery[i].job_id.copy())
    s.starred_ids = ids.copy()
    save_stars(ids)


def _do_save_preset(mut s: InferenceUIState):
    try:
        var name = save_preset(s.preset_name_buf, s.store.params.to_json())
        s.presets = list_presets()
        for i in range(len(s.presets)):
            if s.presets[i] == name:
                s.preset_index = Int32(i)
        s.menu_status = String("preset saved: ") + name
    except e:
        s.menu_status = String("preset save failed: ") + String(e)


def _do_load_preset(mut s: InferenceUIState):
    var idx = Int(s.preset_index)
    if idx < 0 or idx >= len(s.presets):
        s.menu_status = String("no preset selected")
        return
    try:
        var p = GenParams.from_json(load_preset(s.presets[idx]))
        s.store.set(p^)   # H2 dispatch; mirrors refresh next frame
        s.menu_status = String("preset loaded: ") + s.presets[idx]
    except e:
        s.menu_status = String("preset load failed: ") + String(e)


def _sync_params_to_state(mut s: InferenceUIState, p: GenParams, cli_name: String):
    """CLI fallback: project the canonical params onto the legacy
    InferenceState the blocking CLI path consumes."""
    s.model.prompt = p.prompt.copy()
    s.model.negative = p.negative.copy()
    s.model.width = Float32(p.width)
    s.model.height = Float32(p.height)
    s.model.steps = Float32(p.steps)
    s.model.cfg = Float32(p.cfg)
    s.model.seed = Float32(p.seed)
    s.model.cli_model_override = cli_name.copy()
    for i in range(len(s.model.sampler_options)):
        if s.model.sampler_options[i] == p.sampler:
            s.model.sampler_index = Int32(i)
    for i in range(len(s.model.scheduler_options)):
        if s.model.scheduler_options[i] == p.scheduler:
            s.model.scheduler_index = Int32(i)


def _submit_generate(mut s: InferenceUIState):
    """P11: Generate -> daemon (health-checked) with CLI fallback. Routing:
    arch zimage at 512x512 -> daemon; everything else -> CLI spawn."""
    _commit_store(s)
    var p = s.store.params.copy()
    # resolve a random seed request to a concrete seed (reproducible reuse)
    if p.seed < 0:
        s.pseudo_rng = s.pseudo_rng * UInt32(1664525) + UInt32(1013904223)
        p.seed = Int(s.pseudo_rng % UInt32(1000000))
    if not p.same_as(s.store.params):
        try:
            s.store.set(p.copy())  # H2: the submitted seed IS the param state
        except e:
            print("[gen-screen] seed store.set failed:", String(e))
    var arch = _selected_arch(s)
    var route_daemon = (
        arch == String("zimage") and p.width == 512 and p.height == 512
    )
    if route_daemon:
        daemon_refresh_health(s.zrt)  # health-check on Generate (bridge spec)
        route_daemon = s.zrt.daemon_ok
    if route_daemon:
        var all_ok = True
        for k in range(p.images):  # P6: one daemon job per image
            var pk = p.copy()
            pk.seed = p.seed + k
            try:
                if not daemon_submit_params(
                    s.model, s.zrt, pk.to_json(), pk.width, pk.height, pk.steps
                ):
                    all_ok = False
                    break
            except e:
                print("[gen-screen] submit error:", String(e))
                all_ok = False
                break
        if all_ok:
            s.menu_status = String("daemon: generating")
            return
        s.menu_status = String("daemon submit failed -> CLI fallback")
    # CLI fallback (blocking, the proven path)
    var cli_name = _cli_name_for(arch, p.model)
    if cli_name.byte_length() == 0:
        s.menu_status = String("no CLI backend for arch '") + arch + String("'")
        s.zrt.last_error = s.menu_status.copy()
        return
    _sync_params_to_state(s, p, cli_name)
    s.zrt.route_label = String("cli")
    s.menu_status = String("CLI: ") + cli_name
    graph_submit_current(s.model, s.zrt)


def _cancel_generate(mut s: InferenceUIState):
    if len(s.zrt.daemon_submitted) > 0:
        daemon_cancel_submitted(s.model, s.zrt)
    else:
        graph_cancel_all(s.model, s.zrt)


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

    var lp = String("/home/alex/LanPaint/example_workflows/")
    _add_node_workflow_preset(names, paths, String("LanPaint / Qwen Image Inpaint"), lp + String("Qwen_Image_Inpaint.json"))
    _add_node_workflow_preset(names, paths, String("LanPaint / Qwen Image Outpaint"), lp + String("Qwen_Image_Outpaint.json"))
    _add_node_workflow_preset(names, paths, String("LanPaint / Flux 2 Klein Inpainting"), lp + String("Flux2_Klein_inpainting.json"))
    _add_node_workflow_preset(names, paths, String("LanPaint / Z-Image Inpaint"), lp + String("Z_image_Inpaint.json"))
    _add_node_workflow_preset(names, paths, String("LanPaint / Wan 2.2 T2I Inpaint"), lp + String("wan2_2_T2I_Inpaint.json"))
    _add_node_workflow_preset(names, paths, String("LanPaint / SDXL Inpaint"), lp + String("SDXL_Inpaint.json"))

    var vhs = String("/home/alex/ComfyUI-VideoHelperSuite/tests/")
    _add_node_workflow_preset(names, paths, String("VHS / Simple Video"), vhs + String("simple.json"))
    _add_node_workflow_preset(names, paths, String("VHS / Loop Video"), vhs + String("loop.json"))
    _add_node_workflow_preset(names, paths, String("VHS / Audio Video"), vhs + String("audio.json"))
    _add_node_workflow_preset(names, paths, String("VHS / Batch 4x4"), vhs + String("batch4x4.json"))
    _add_node_workflow_preset(names, paths, String("VHS / Converted Input"), vhs + String("converted-input.json"))
    _add_node_workflow_preset(names, paths, String("VHS / Format Input"), vhs + String("converted-format-input.json"))


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
        _ = combobox(ctx, String("model"), s.model_display,
                     s.store.m_model_index, s.model_combo_open)
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
        if button(ctx, String("3:2")):
            s.store.m_width = 1216.0
            s.store.m_height = 832.0
        if button(ctx, String("16:9")):
            s.store.m_width = 1344.0
            s.store.m_height = 768.0
        if button(ctx, String("9:16")):
            s.store.m_width = 768.0
            s.store.m_height = 1344.0
        ctx.layout_row(_row2(bw * 2 + _px(s, 4), bw * 2), _px(s, 26))
        if button(ctx, String("512 · 1:1")):
            s.store.m_width = 512.0
            s.store.m_height = 512.0
        if button(ctx, String("Swap W/H")):
            var t = s.store.m_width
            s.store.m_width = s.store.m_height
            s.store.m_height = t
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Width:"))
        _ = drag_value(ctx, s.store.m_width, String("width"), Float32(8.0))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Height:"))
        _ = drag_value(ctx, s.store.m_height, String("height"), Float32(8.0))
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
        _ = combobox(ctx, String("sampler"), s.model.sampler_options,
                     s.store.m_sampler_index, s.model.sampler_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Scheduler:"))
        _ = combobox(ctx, String("scheduler"), s.model.scheduler_options,
                     s.store.m_scheduler_index, s.model.scheduler_open)
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Steps:"))
        _ = slider(ctx, s.store.m_steps, Float32(1.0), Float32(100.0), String("steps"))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("CFG:"))
        _ = drag_value(ctx, s.store.m_cfg, String("cfg"), Float32(0.1))


def _section_seed(mut s: InferenceUIState) raises:
    """P5: seed + randomize + variation seed + variation strength."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Seed"), s.sec_seed):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Seed:"))
        _ = drag_value(ctx, s.store.m_seed, String("seed"), Float32(1.0))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String(""))
        if button(ctx, String("Randomize")):
            s.pseudo_rng = s.pseudo_rng * UInt32(1664525) + UInt32(1013904223)
            s.store.m_seed = Float32(Int(s.pseudo_rng % UInt32(1000000)))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Var seed:"))
        _ = drag_value(ctx, s.store.m_variation_seed, String("var_seed"), Float32(1.0))
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Var strength:"))
        _ = drag_value(
            ctx, s.store.m_variation_strength, String("var_strength"), Float32(0.01)
        )
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
            _ = combobox(ctx, String("lora_sel_") + String(i), s.lora_names,
                         s.store.m_lora_indices[i], open_flag)
            s.lora_row_open[i] = open_flag
            _ = slider(ctx, s.store.m_lora_weights[i], Float32(0.0),
                       Float32(2.0), String("lora_w_") + String(i))
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
        ctx.layout_row(_row1(_px(s, 180)), _px(s, 28))
        if button(ctx, String("+ Add LoRA")):
            if len(s.lora_names) > 0:
                s.store.m_lora_indices.append(Int32(0))
                s.store.m_lora_weights.append(Float32(1.0))
                s.lora_row_open.append(False)


def _section_batch(mut s: InferenceUIState) raises:
    """P6: images-count (each image = one queued daemon job)."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Images"), s.sec_batch):
        ctx.layout_row(_row2(_left_label_w(s), _left_field_w(s)), _px(s, 28))
        label(ctx, String("Count: ") + String(Int(s.store.m_images)))
        _ = slider(ctx, s.store.m_images, Float32(1.0), Float32(8.0), String("images"))


def _section_presets(mut s: InferenceUIState) raises:
    """P8: named param presets (JSON files under ~/.serenity/ui_presets/)."""
    ref ctx = s.ctx
    if collapsing_header(ctx, String("Presets"), s.sec_presets):
        var bw = _px(s, 80)
        ctx.layout_row(_row2(_left_full_w(s) - bw - _px(s, 4), bw), _px(s, 28))
        _ = combobox(ctx, String("preset_sel"), s.presets,
                     s.preset_index, s.preset_open)
        if button(ctx, String("Load")):
            _do_load_preset(s)
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
        pass

    ctx.layout_row(_row1(_center_w(s)), _px(s, 24))
    label(ctx, String("Negative:"))
    ctx.layout_row(_row1(_center_w(s)), _px(s, 56))
    if text_area(ctx, String("negative"), s.store.m_negative, s.negative_edit):
        pass

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
        s.store.m_seed = Float32(Int(s.pseudo_rng % UInt32(1000000)))

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
        # P12: the queue rail renders the daemon's /v1/jobs directly
        var jobs = s.zrt.daemon_jobs_cache.copy()
        var nj = len(jobs)
        if s.zrt.daemon_ok and nj > 0:
            var shown = 0
            for i in range(nj):
                var idx = nj - 1 - i  # newest first
                if shown >= 12:
                    break
                shown += 1
                ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
                var mark = String("· ")
                if jobs[idx].state == String("running"):
                    mark = String("▶ ")
                elif jobs[idx].state == String("done"):
                    mark = String("✓ ")
                label(ctx, mark + jobs[idx].id + String("  ")
                      + jobs[idx].state + String("  ")
                      + String(jobs[idx].step) + String("/")
                      + String(jobs[idx].total))
                if jobs[idx].state == String("running"):
                    ctx.layout_row(_row1(_right_w(s)), _px(s, 14))
                    var frac = Float32(0.0)
                    if jobs[idx].total > 0:
                        frac = Float32(jobs[idx].step) / Float32(jobs[idx].total)
                    progress_bar(ctx, frac)
        elif s.model.has_running:
            # CLI fallback path: the in-memory mirror
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("▶ running #") + String(s.model.running.id))
            ctx.layout_row(_row1(_right_w(s)), _px(s, 16))
            progress_bar(ctx, s.model.running.progress())
        else:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            var msg = String("(queue empty)")
            if not s.zrt.daemon_ok:
                msg = String("(queue empty · daemon down)")
            label(ctx, msg)
    else:
        # P14-P16: persistent history (jobs.db + session) with star + reuse
        var nh = len(s.gallery)
        if nh == 0:
            ctx.layout_row(_row1(_right_w(s)), _px(s, 22))
            label(ctx, String("(no history)"))
        var shown = 0
        var star_clicked = -1
        var reuse_clicked = -1
        for i in range(nh):
            var idx = nh - 1 - i  # newest first
            if shown >= 14:
                break
            shown += 1
            ctx.layout_row(_row2(_px(s, 34), _px(s, 290)), _px(s, 24))
            var star_lbl = String("★ ") if s.gallery[idx].starred else String("☆ ")
            # unique per-row labels (button ids hash the label)
            if button(ctx, star_lbl + String(idx)):
                star_clicked = idx
            if button(ctx, s.gallery[idx].job_id + String(" · ")
                      + s.gallery[idx].model):
                reuse_clicked = idx
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
    var daemon_lbl = String("daemon ok (") + s.zrt.daemon_backend + String(")") \
        if s.zrt.daemon_ok else String("daemon down → CLI")
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
            # scramble through the widget mirrors (what user edits do)
            sp[].store.m_prompt = String("scrambled: totally different prompt")
            sp[].prompt_edit.set_text(sp[].store.m_prompt)
            sp[].store.m_steps = 77.0
            sp[].store.m_cfg = 9.9
            sp[].store.m_seed = 1.0
            sp[].store.m_width = 1344.0
            sp[].store.m_height = 768.0
        elif sp[].frame_no == 1500:
            for i in range(len(sp[].presets)):
                if sp[].presets[i] == String("uigate-roundtrip"):
                    sp[].preset_index = Int32(i)
            _do_load_preset(sp[])

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


# ---------------------------------------------------------------------------
# TEMPORARY scripted-gate selftests (--selftest / --selftest-cancel /
# --selftest-preset). Headless: they exercise the SAME store (H1/H2) and the
# SAME daemon submit/poll/cancel functions the UI buttons use, without a
# window. Clearly marked; fine to keep for regression runs.
# ---------------------------------------------------------------------------


def _selftest_wait_terminal(job_id: String, max_ticks: Int) raises -> DaemonJobInfo:
    var last_step = -1
    for _ in range(max_ticks):
        sleep(Float64(0.1))
        var jobs = daemon_jobs()
        for i in range(len(jobs)):
            if jobs[i].id != job_id:
                continue
            if jobs[i].step != last_step:
                last_step = jobs[i].step
                print("[selftest] ", job_id, jobs[i].state, " step ",
                      jobs[i].step, "/", jobs[i].total)
            if jobs[i].is_terminal():
                return jobs[i].copy()
    raise Error("selftest: job " + job_id + " did not finish in time")


def _selftest_daemon_e2e() raises:
    """G2b/G2f headless: store -> daemon -> PNG tEXt round-trip."""
    print("[selftest] === daemon e2e + genparams round-trip ===")
    var state = InferenceState()
    var rt = GraphUiRuntime()
    daemon_refresh_health(rt)
    if not rt.daemon_ok:
        raise Error("selftest: daemon not running on 127.0.0.1:7801")
    print("[selftest] health ok, backend =", rt.daemon_backend)
    var models = List[DaemonModelEntry]()
    var loras = List[DaemonLoraEntry]()
    daemon_models(models, loras)
    print("[selftest] /v1/models:", len(models), "models,", len(loras), "loras")

    # H1: one canonical param struct, set through the H2 dispatch point.
    var store = GenParamStore()
    var p = GenParams()
    p.model = String("zimage_base")
    p.prompt = String("selftest: neon koi pond at midnight, ukiyo-e")
    p.negative = String("blurry")
    p.width = 512
    p.height = 512
    p.steps = 6
    p.seed = 4242
    p.cfg = 3.25
    p.sampler = String("euler")
    p.scheduler = String("simple")
    p.variation_seed = 777
    p.variation_strength = 0.55
    p.images = 1
    if len(loras) > 0:
        p.loras.append(GenLora(loras[0].name.copy(), 1.35))
    store.set(p^)
    print("[selftest] UI genparams JSON:", store.last_set_json)

    if not daemon_submit_params(
        state, rt, store.last_set_json,
        store.params.width, store.params.height, store.params.steps,
    ):
        raise Error("selftest: daemon submit failed: " + rt.last_error)
    var job_id = rt.daemon_submitted[0].copy()
    var job = _selftest_wait_terminal(job_id, 1200)
    if job.state != String("done"):
        raise Error("selftest: job ended " + job.state + " err=" + job.error)
    var out = absolutize_output_path(job.output_path)
    print("[selftest] output:", out)

    # G2f: UI-state JSON == daemon-recorded PNG tEXt (modulo server job_id)
    var png_json = read_genparams_from_png(out)
    print("[selftest] PNG tEXt genparams:", png_json)
    var sent = GenParams.from_json(store.last_set_json)
    var got = GenParams.from_json(png_json)
    if not sent.same_as(got):
        raise Error("selftest: genparams MISMATCH between UI state and PNG tEXt")
    print("[selftest] PASS genparams round-trip (UI == daemon tEXt)")

    # P15/H2 observer round-trip: reuse-params through set() and re-emit
    var store2 = GenParamStore()
    store2.set(got^)
    var re = GenParams.from_json(store2.last_set_json)
    if not re.same_as(sent):
        raise Error("selftest: reuse-params re-serialize mismatch")
    print("[selftest] PASS reuse-params observer round-trip")


def _selftest_cancel() raises:
    """G2b: cancel a 50-step stub job mid-run (+ double-cancel -> 409)."""
    print("[selftest] === cancel mid-run ===")
    var state = InferenceState()
    var rt = GraphUiRuntime()
    daemon_refresh_health(rt)
    if not rt.daemon_ok:
        raise Error("selftest: daemon not running")
    var p = GenParams()
    p.model = String("zimage_base")
    p.prompt = String("selftest cancel probe")
    p.steps = 50
    p.seed = 7
    if not daemon_submit_params(state, rt, p.to_json(), p.width, p.height, p.steps):
        raise Error("selftest: submit failed")
    var job_id = rt.daemon_submitted[0].copy()
    # wait until visibly running (a few steps in)
    var running = False
    for _ in range(300):
        sleep(Float64(0.1))
        var jobs = daemon_jobs()
        for i in range(len(jobs)):
            if jobs[i].id == job_id and jobs[i].state == String("running") \
                    and jobs[i].step >= 3:
                running = True
        if running:
            break
    if not running:
        raise Error("selftest: job never reached running step>=3")
    _ = daemon_cancel(job_id)
    print("[selftest] cancel POSTed at running state")
    var job = _selftest_wait_terminal(job_id, 300)
    if job.state != String("cancelled"):
        raise Error("selftest: expected cancelled, got " + job.state)
    print("[selftest] PASS job cancelled mid-run (step ", job.step, "/50 )")
    if daemon_cancel(job_id):
        raise Error("selftest: double-cancel should 409")
    print("[selftest] PASS double-cancel -> 409")


def _selftest_preset() raises:
    """G2d headless: preset save -> load -> field round-trip."""
    print("[selftest] === preset round-trip ===")
    var p = GenParams()
    p.model = String("zimage_base")
    p.prompt = String("preset probe: glass cathedral")
    p.steps = 31
    p.cfg = 7.5
    p.seed = 999
    p.variation_seed = 13
    p.variation_strength = 0.25
    p.images = 3
    p.loras.append(GenLora(String("test-lora"), 0.65))
    var name = save_preset(String("selftest-preset"), p.to_json())
    var names = list_presets()
    var found = False
    for i in range(len(names)):
        if names[i] == name:
            found = True
    if not found:
        raise Error("selftest: saved preset not listed")
    var q = GenParams.from_json(load_preset(name))
    if not q.same_as(p):
        raise Error("selftest: preset round-trip mismatch")
    print("[selftest] PASS preset round-trip:", name)


def _graph_seam_selfcheck():
    """Compile and dry-run the Klein graph once at startup."""
    var state = InferenceState()
    try:
        var ok = dry_run_klein9b_graph(state)
        print("[graph-seam] klein9b_graph_dry=", ok, " model=", state.model_label())
    except e:
        print("[graph-seam] failed:", String(e))


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
        ):
            run_mode = a^
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
