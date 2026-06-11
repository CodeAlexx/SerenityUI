"""serenityUI — app state + constants + helpers/actions/catalog/layout (split from serenity_ui_main.mojo).

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
    var preset_was_open: Bool     # F7: detect dropdown OPEN -> rescan dir
    var preset_page: Int          # F7: dropdown page (PRESET_PAGE entries)
    var preset_name_buf: String
    var preset_name_state: TextEditState

    # persistent history (P14-P16)
    var gallery: List[GalleryItem]
    var starred_ids: List[String]
    var hist_page: Int            # F6: history rail pager
    var queue_page: Int           # F6: queue rail pager
    var starred_first: Bool       # F6: starred-first sort toggle

    # F1: seed is a TEXT mirror (integer end-to-end) — its edit engine
    var seed_edit: TextEditState

    # ── P7 init image (img2img): edit engine + validation/thumbnail state
    # (VIEW state only — the param itself lives in store.params.init_image) ──
    var init_path_state: TextEditState
    var init_thumb_tex: UInt32
    var init_thumb_w: Int32
    var init_thumb_h: Int32
    var init_status: String
    var init_validated_path: String   # path the current thumbnail belongs to

    # ── P13 batch thumbnails: this session's last submitted batch ──
    var batch_job_ids: List[String]
    var batch_paths: List[String]
    var batch_tex: List[UInt32]       # lazy-loaded thumb textures (0 = pending)
    var batch_sel: Int                # selected thumb (preview swap target)

    # TEMPORARY --selftest-ui driver (scripted gates): 0=off, 1=auto-generate,
    # 2=auto-generate then auto-cancel. Drives the SAME functions the buttons
    # call. Fine to keep; remove when xdotool-driven gates land.
    var autogen_mode: Int
    var autogen_stamp: Int   # frame stamp for multi-step scripted gates
    var frame_no: Int

    # collapsing-header open flags (left panel)
    var sec_model: Bool
    var sec_resolution: Bool
    var sec_sampling: Bool
    var sec_seed: Bool
    var sec_lora: Bool
    var sec_batch: Bool
    var sec_init: Bool       # P7 init-image section
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
        self.preset_was_open = False
        self.preset_page = 0
        self.preset_name_buf = String("my-preset")
        self.preset_name_state = TextEditState(single_line=True)
        var stars_warning = String("")
        self.starred_ids = load_stars(stars_warning)
        self.gallery = load_gallery_from_db(self.starred_ids)
        self.hist_page = 0
        self.queue_page = 0
        self.starred_first = False
        self.seed_edit = TextEditState(single_line=True)
        self.init_path_state = TextEditState(single_line=True)
        self.init_thumb_tex = UInt32(0)
        self.init_thumb_w = 0
        self.init_thumb_h = 0
        self.init_status = String("")
        self.init_validated_path = String("")
        self.batch_job_ids = List[String]()
        self.batch_paths = List[String]()
        self.batch_tex = List[UInt32]()
        self.batch_sel = 0
        self.autogen_mode = 0
        self.autogen_stamp = 0
        self.frame_no = 0

        self.prompt_edit = MultiLineState()
        self.negative_edit = MultiLineState()
        self.sec_model = True
        self.sec_resolution = True
        self.sec_sampling = True
        self.sec_seed = True
        self.sec_lora = True
        self.sec_batch = True
        self.sec_init = True
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
        if stars_warning.byte_length() > 0:
            self.menu_status = stars_warning.copy()  # F9: never silently lose
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


def _resolve_prompt_syntax(mut p: GenParams, mut notes: List[String]):
    """P9/P10 submit-time resolution against the CONCRETE job seed:
    (text:w) passes through (validated), <lora:> extractions are merged into
    the LoRA stack (dedup by name — the UI stack wins), <random:> picks are
    seed-deterministic. The ORIGINAL prompt is preserved in prompt_raw; the
    resolved prompt goes in prompt. No syntax -> prompt_raw stays ''."""
    var raw = p.prompt.copy()
    if p.prompt_raw.byte_length() > 0:
        raw = p.prompt_raw.copy()  # re-resolve from the original (reuse-params)
    var parsed = resolve_prompt(raw, p.seed)
    for i in range(len(parsed.notes)):
        notes.append(parsed.notes[i].copy())
    if parsed.had_syntax:
        p.prompt_raw = raw^
        p.prompt = parsed.resolved.copy()
        for i in range(len(parsed.loras)):
            var dup = False
            for k in range(len(p.loras)):
                if p.loras[k].name == parsed.loras[i].name:
                    dup = True  # dedup vs the UI stack (UI weight wins)
                    break
            if not dup:
                p.loras.append(GenLora(
                    parsed.loras[i].name.copy(), parsed.loras[i].weight
                ))
    else:
        p.prompt_raw = String("")


def _clear_init_thumb(mut s: InferenceUIState):
    if s.init_thumb_tex != UInt32(0):
        Backend.destroy_texture(s.init_thumb_tex)
        s.init_thumb_tex = UInt32(0)
    s.init_thumb_w = 0
    s.init_thumb_h = 0
    s.init_validated_path = String("")


def _validate_init_image(mut s: InferenceUIState):
    """P7: decode the init-image path via MOJO-libs image (png/jpeg/webp),
    downscale to ~128 px (MOJO-libs resize_bilinear) and upload the thumbnail
    texture. Errors land in init_status, never crash."""
    var path = s.store.m_init_image.copy()
    _clear_init_thumb(s)
    if path.byte_length() == 0:
        s.init_status = String("no init image (txt2img)")
        return
    try:
        var img = decode_image_any(path)
        var tw = img.width
        var th = img.height
        if tw >= th and tw > 128:
            th = (th * 128) // tw
            tw = 128
        elif th > tw and th > 128:
            tw = (tw * 128) // th
            th = 128
        if tw < 1:
            tw = 1
        if th < 1:
            th = 1
        var thumb = resize_bilinear(img, tw, th)
        var rgba = image_to_rgba_bytes(thumb)
        var tex = Backend.make_texture_rgba(Int32(tw), Int32(th), rgba)
        if tex == UInt32(0):
            s.init_status = String("thumbnail upload failed (no GL context?)")
            return
        s.init_thumb_tex = tex
        s.init_thumb_w = Int32(tw)
        s.init_thumb_h = Int32(th)
        s.init_validated_path = path.copy()
        s.init_status = (
            String("ok: ") + String(img.width) + String("x") + String(img.height)
        )
    except e:
        s.init_status = String(e)


def _reset_batch_strip(mut s: InferenceUIState):
    """P13: a new Generate starts a fresh batch strip."""
    for i in range(len(s.batch_tex)):
        if s.batch_tex[i] != UInt32(0):
            Backend.destroy_texture(s.batch_tex[i])
    s.batch_job_ids = List[String]()
    s.batch_paths = List[String]()
    s.batch_tex = List[UInt32]()
    s.batch_sel = 0


def _batch_select(mut s: InferenceUIState, idx: Int):
    """P13: thumbnail click — swap the full preview to that job's output."""
    if idx < 0 or idx >= len(s.batch_paths):
        return
    s.batch_sel = idx
    s.zrt.result_path = s.batch_paths[idx].copy()
    s.zrt.result_pixels = List[UInt8]()
    s.zrt.result_job_id += 1  # forces _sync_result_texture to re-upload
    s.menu_status = String("preview: ") + s.batch_job_ids[idx]


def _batch_reuse_selected(mut s: InferenceUIState):
    """P13: make the selected batch job's params the current params (PNG
    tEXt -> H2 dispatch), same as a history reuse click."""
    if s.batch_sel < 0 or s.batch_sel >= len(s.batch_paths):
        return
    try:
        var p = GenParams.from_json(
            read_genparams_from_png(s.batch_paths[s.batch_sel])
        )
        s.store.set(p^)
        s.menu_status = (
            String("params restored from ") + s.batch_job_ids[s.batch_sel]
        )
    except e:
        s.menu_status = String("batch reuse-params failed: ") + String(e)


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
        # P13: feed the batch strip (this session's finished outputs)
        var in_batch = False
        for k in range(len(s.batch_job_ids)):
            if s.batch_job_ids[k] == ev.id:
                in_batch = True
                break
        if not in_batch and len(s.batch_paths) < 8:
            s.batch_job_ids.append(ev.id.copy())
            s.batch_paths.append(item.output_path.copy())
            s.batch_tex.append(UInt32(0))  # thumb loads lazily in the strip
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
        # F8: typed load — wrong-typed fields keep the CURRENT value and are
        # reported, never silently defaulted.
        var ignored = List[String]()
        var p = GenParams.from_json_validated(
            load_preset(s.presets[idx]), s.store.params, ignored
        )
        s.store.set(p^)   # H2 dispatch; mirrors refresh next frame
        if len(ignored) > 0:
            var msg = String("preset field")
            if len(ignored) > 1:
                msg += String("s")
            for i in range(len(ignored)):
                if i > 0:
                    msg += String(",")
                msg += String(" '") + ignored[i] + String("'")
            s.menu_status = msg + String(" ignored (wrong type) — ") \
                + s.presets[idx]
        else:
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
    # P9/P10: resolve prompt syntax against the concrete seed (prompt_raw
    # keeps the original; <lora:> merges into the stack; <random:> picks
    # deterministically per seed). Malformed syntax -> status note only.
    var syntax_notes = List[String]()
    _resolve_prompt_syntax(p, syntax_notes)
    if len(syntax_notes) > 0:
        s.menu_status = String("prompt syntax: ") + join_notes(syntax_notes)
        print("[gen-screen] prompt syntax:", join_notes(syntax_notes))
    if not p.same_as(s.store.params):
        try:
            # H2: the submitted seed + resolved prompt ARE the param state
            s.store.set(p.copy())
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
        _reset_batch_strip(s)  # P13: a new Generate starts a fresh strip
        var all_ok = True
        for k in range(p.images):  # P6: one daemon job per image
            var pk = p.copy()
            pk.seed = p.seed + k
            if k > 0 and pk.prompt_raw.byte_length() > 0:
                # P10: per-image seeds re-resolve <random:> from the raw
                # prompt (image k's pick is deterministic for seed+k)
                var nk = List[String]()
                var pr = pk.prompt_raw.copy()
                pk.prompt_raw = String("")
                pk.prompt = pr.copy()
                _resolve_prompt_syntax(pk, nk)
                if pk.prompt_raw.byte_length() == 0:
                    pk.prompt_raw = pr^  # keep raw even if k's pick == raw
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
    graph_submit_current(s.model, s.zrt)
    # F11: be honest about what the CLI request JSON drops.
    if s.zrt.cli_active:
        s.menu_status = String("CLI ") + cli_name + String(" — ") + s.zrt.cli_note
    else:
        s.menu_status = s.zrt.last_error.copy()


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


