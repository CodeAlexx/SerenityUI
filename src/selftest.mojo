"""serenityUI — headless --selftest suites (split from serenity_ui_main.mojo).

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


def _selftest_p3_stub() raises:
    """G3b headless (stub daemon): a prompt with all three syntaxes ->
    the daemon receives the RESOLVED prompt + the merged LoRA list (deduped
    vs the UI stack); genparams carry prompt_raw + init_image + creativity;
    <random:> is deterministic per seed."""
    print("[selftest-p3] === G3b stub e2e: prompt syntax + img2img params ===")
    var s = InferenceUIState()
    if not s.zrt.daemon_ok:
        raise Error("selftest-p3: daemon not running on 127.0.0.1:7801")

    # ── job 0: a plain quick job to mint an init-image PNG ──
    var p0 = s.store.params.copy()
    p0.prompt = String("plain init-image source")
    p0.steps = 2
    p0.seed = 1001
    p0.images = 1
    s.store.set(p0^)
    _refresh_store(s)
    _submit_generate(s)
    if len(s.zrt.daemon_submitted) == 0:
        raise Error("selftest-p3: job0 submit failed: " + s.menu_status)
    var job0 = _selftest_wait_terminal(
        s.zrt.daemon_submitted[len(s.zrt.daemon_submitted) - 1], 600
    )
    if job0.state != String("done"):
        raise Error("selftest-p3: job0 ended " + job0.state)
    var init_png = absolutize_output_path(job0.output_path)
    print("[selftest-p3] init-image source:", init_png)

    # ── the syntax-loaded job (weight + lora + random + init image) ──
    var lora_name = String("syntax-probe-lora")
    if len(s.lora_names) > 0:
        lora_name = s.lora_names[0].copy()
    var raw = (
        String("an (ornate:1.2) gate <lora:") + lora_name
        + String(":0.7> at <random:dawn|dusk|midnight>")
    )
    var p = s.store.params.copy()
    p.prompt = raw.copy()
    p.prompt_raw = String("")
    p.negative = String("blurry")
    p.steps = 3
    p.seed = 31415
    p.images = 1
    p.init_image = init_png.copy()
    p.creativity = 0.4
    p.loras = List[GenLora]()
    p.loras.append(GenLora(lora_name.copy(), 1.5))  # dedup probe: UI stack wins
    s.store.set(p^)
    _refresh_store(s)
    var n_before = len(s.zrt.daemon_submitted)
    _submit_generate(s)
    if len(s.zrt.daemon_submitted) <= n_before:
        raise Error("selftest-p3: syntax job submit failed: " + s.menu_status)
    print("[selftest-p3] submit #1:", s.zrt.last_submit_json)
    var sub1 = GenParams.from_json(s.zrt.last_submit_json)
    var fails = List[String]()
    if sub1.prompt_raw != raw:
        fails.append(String("prompt_raw != original: '") + sub1.prompt_raw + "'")
    if sub1.prompt.find(String("<lora:")) >= 0 \
            or sub1.prompt.find(String("<random:")) >= 0:
        fails.append(String("resolved prompt still has tags: '") + sub1.prompt + "'")
    if sub1.prompt.find(String("(ornate:1.2)")) < 0:
        fails.append(String("weight syntax not passed through: '") + sub1.prompt + "'")
    var got_pick = (
        sub1.prompt.find(String("dawn")) >= 0
        or sub1.prompt.find(String("dusk")) >= 0
        or sub1.prompt.find(String("midnight")) >= 0
    )
    if not got_pick:
        fails.append(String("<random:> pick missing: '") + sub1.prompt + "'")
    if len(sub1.loras) != 1:
        fails.append(String("lora rows = ") + String(len(sub1.loras)) + " want 1 (dedup)")
    elif sub1.loras[0].name != lora_name or sub1.loras[0].weight != 1.5:
        fails.append(
            String("lora dedup lost the UI weight: ") + sub1.loras[0].name
            + ":" + String(sub1.loras[0].weight) + " want " + lora_name + ":1.5"
        )
    if sub1.init_image != init_png:
        fails.append(String("init_image not echoed: '") + sub1.init_image + "'")
    if sub1.creativity != 0.4:
        fails.append(String("creativity = ") + String(sub1.creativity) + " want 0.4")
    if len(fails) > 0:
        for i in range(len(fails)):
            print("[selftest-p3] FAIL", fails[i])
        raise Error("selftest-p3: submitted JSON wrong")
    print("[selftest-p3] PASS resolved prompt + merged lora + img2img params")

    var job1 = _selftest_wait_terminal(
        s.zrt.daemon_submitted[len(s.zrt.daemon_submitted) - 1], 600
    )
    if job1.state != String("done"):
        raise Error("selftest-p3: syntax job ended " + job1.state)
    var png_json = read_genparams_from_png(absolutize_output_path(job1.output_path))
    var got = GenParams.from_json(png_json)
    if got.prompt_raw != raw or got.prompt != sub1.prompt \
            or got.init_image != init_png or got.creativity != 0.4:
        print("[selftest-p3] PNG tEXt:", png_json)
        raise Error("selftest-p3: PNG tEXt genparams lost syntax/img2img fields")
    print("[selftest-p3] PASS PNG tEXt carries prompt_raw + init_image + creativity")

    # ── determinism: same seed -> identical resolution on resubmit ──
    _submit_generate(s)
    var sub2 = GenParams.from_json(s.zrt.last_submit_json)
    if sub2.prompt != sub1.prompt:
        raise Error(
            "selftest-p3: same-seed resolution differs: '" + sub1.prompt
            + "' vs '" + sub2.prompt + "'"
        )
    print("[selftest-p3] PASS same seed -> same <random:> resolution")

    # different seed: resolution follows the parser exactly (may differ)
    var p3 = s.store.params.copy()
    p3.seed = 999
    s.store.set(p3^)
    _refresh_store(s)
    _submit_generate(s)
    var sub3 = GenParams.from_json(s.zrt.last_submit_json)
    var expect3 = resolve_prompt(raw, 999)
    # the submitted prompt must equal the parser's pick for seed 999 with the
    # lora tag removed (resolve_prompt does both)
    if sub3.prompt != expect3.resolved:
        raise Error(
            "selftest-p3: seed-999 resolution mismatch: '" + sub3.prompt
            + "' vs parser '" + expect3.resolved + "'"
        )
    print("[selftest-p3] seed 31415 ->", sub1.prompt)
    print("[selftest-p3] seed   999 ->", sub3.prompt)
    print("[selftest-p3] ALL PASS")


def _diff_genparams(a: GenParams, b: GenParams) -> List[String]:
    """Full field diff (printed by the mirrors gate)."""
    var d = List[String]()
    if a.model != b.model:
        d.append(String("model: '") + a.model + String("' vs '") + b.model + String("'"))
    if a.prompt != b.prompt:
        d.append(String("prompt: '") + a.prompt + String("' vs '") + b.prompt + String("'"))
    if a.prompt_raw != b.prompt_raw:
        d.append(String("prompt_raw: '") + a.prompt_raw + String("' vs '")
                 + b.prompt_raw + String("'"))
    if a.negative != b.negative:
        d.append(String("negative: '") + a.negative + String("' vs '") + b.negative + String("'"))
    if a.width != b.width:
        d.append(String("width: ") + String(a.width) + String(" vs ") + String(b.width))
    if a.height != b.height:
        d.append(String("height: ") + String(a.height) + String(" vs ") + String(b.height))
    if a.steps != b.steps:
        d.append(String("steps: ") + String(a.steps) + String(" vs ") + String(b.steps))
    if a.seed != b.seed:
        d.append(String("seed: ") + String(a.seed) + String(" vs ") + String(b.seed))
    if a.cfg != b.cfg:
        d.append(String("cfg: ") + String(a.cfg) + String(" vs ") + String(b.cfg))
    if a.sampler != b.sampler:
        d.append(String("sampler: '") + a.sampler + String("' vs '") + b.sampler + String("'"))
    if a.scheduler != b.scheduler:
        d.append(String("scheduler: '") + a.scheduler + String("' vs '") + b.scheduler + String("'"))
    if a.variation_seed != b.variation_seed:
        d.append(String("variation_seed: ") + String(a.variation_seed)
                 + String(" vs ") + String(b.variation_seed))
    if a.variation_strength != b.variation_strength:
        d.append(String("variation_strength: ") + String(a.variation_strength)
                 + String(" vs ") + String(b.variation_strength))
    if a.images != b.images:
        d.append(String("images: ") + String(a.images) + String(" vs ") + String(b.images))
    if a.init_image != b.init_image:
        d.append(String("init_image: '") + a.init_image + String("' vs '")
                 + b.init_image + String("'"))
    if a.creativity != b.creativity:
        d.append(String("creativity: ") + String(a.creativity)
                 + String(" vs ") + String(b.creativity))
    if len(a.loras) != len(b.loras):
        d.append(String("loras: ") + String(len(a.loras)) + String(" vs ")
                 + String(len(b.loras)) + String(" rows"))
    else:
        for i in range(len(a.loras)):
            if a.loras[i].name != b.loras[i].name or a.loras[i].weight != b.loras[i].weight:
                d.append(String("lora[") + String(i) + String("]: ")
                         + a.loras[i].name + String(":") + String(a.loras[i].weight)
                         + String(" vs ") + b.loras[i].name + String(":")
                         + String(b.loras[i].weight))
    return d^


def _selftest_mirrors() raises:
    """F1/F2 gate (--selftest-mirrors): drive the WIDGET-COMMIT path —
    mirror fields + dirty flags exactly as the widget handlers leave them,
    then the real _commit_store/_submit_generate — NOT store.set(). The
    submitted JSON must carry the exact edited values; reuse-params from the
    produced PNG and a resubmit must be byte-identical."""
    print("[selftest-mirrors] === widget-mirror commit gate (F1/F2) ===")
    var s = InferenceUIState()
    if not s.zrt.daemon_ok:
        raise Error("selftest-mirrors: daemon not running on 127.0.0.1:7801")
    while len(s.lora_names) < 2:
        s.lora_names.append(String("synthetic-lora-") + String(len(s.lora_names)))

    # ── simulate widget edits: mirror + dirty flag (the exact state the
    # widget handlers leave; _commit_store is the code path under test) ──
    s.store.m_prompt = String("mirror-gate: copper kettle on a stone sill")
    s.store.d_prompt = True
    s.store.m_steps = 6.0
    s.store.d_steps = True
    s.store.m_cfg = 3.7                       # Float32 widget mirror
    s.store.d_cfg = True
    s.store.m_seed_text = String("123456789")  # F1: > 2^24, Float32-fatal
    s.store.d_seed = True
    s.store.m_variation_seed = 777.0
    s.store.d_variation_seed = True
    s.store.m_variation_strength = 0.66
    s.store.d_variation_strength = True
    s.store.m_lora_indices = List[Int32]()
    s.store.m_lora_indices.append(Int32(0))
    s.store.m_lora_indices.append(Int32(1))
    s.store.m_lora_weights = List[Float32]()
    s.store.m_lora_weights.append(Float32(0.13))
    s.store.m_lora_weights.append(Float32(1.97))
    s.store.d_loras = True
    _commit_store(s)   # end-of-frame commit (the H2 dispatch)
    _refresh_store(s)  # next frame's subscriber re-read

    _submit_generate(s)
    if len(s.zrt.daemon_submitted) == 0:
        raise Error("selftest-mirrors: submit did not reach the daemon: " + s.menu_status)
    var first_json = s.zrt.last_submit_json.copy()
    print("[selftest-mirrors] submit #1:", first_json)
    var sent = GenParams.from_json(first_json)
    var fails = List[String]()
    if sent.seed != 123456789:
        fails.append(String("seed=") + String(sent.seed) + String(" want 123456789"))
    if sent.cfg != 3.7:
        fails.append(String("cfg=") + String(sent.cfg) + String(" want 3.7"))
    if sent.variation_seed != 777:
        fails.append(String("variation_seed=") + String(sent.variation_seed)
                     + String(" want 777"))
    if sent.variation_strength != 0.66:
        fails.append(String("variation_strength=") + String(sent.variation_strength)
                     + String(" want 0.66"))
    if sent.steps != 6:
        fails.append(String("steps=") + String(sent.steps) + String(" want 6"))
    if len(sent.loras) != 2:
        fails.append(String("loras rows=") + String(len(sent.loras)) + String(" want 2"))
    else:
        if sent.loras[0].weight != 0.13:
            fails.append(String("lora[0].weight=") + String(sent.loras[0].weight)
                         + String(" want 0.13"))
        if sent.loras[1].weight != 1.97:
            fails.append(String("lora[1].weight=") + String(sent.loras[1].weight)
                         + String(" want 1.97"))
    if len(fails) > 0:
        for i in range(len(fails)):
            print("[selftest-mirrors] FAIL", fails[i])
        raise Error("selftest-mirrors: submitted JSON corrupted widget values")
    print("[selftest-mirrors] PASS exact widget values in submitted JSON")

    var job_id = s.zrt.daemon_submitted[0].copy()
    var job = _selftest_wait_terminal(job_id, 1200)
    if job.state != String("done"):
        raise Error("selftest-mirrors: job ended " + job.state + " err=" + job.error)
    var out = absolutize_output_path(job.output_path)
    print("[selftest-mirrors] output:", out)

    # ── reuse-params from the produced PNG (what a history click does) ──
    var png_json = read_genparams_from_png(out)
    var p2 = GenParams.from_json(png_json)
    s.store.set(p2^)
    _refresh_store(s)                  # mirrors rebuilt; dirty cleared
    var v_before = s.store.version
    _commit_store(s)                   # frame-end commit MUST be a no-op
    if s.store.version != v_before:
        raise Error(
            "selftest-mirrors: frame-end commit re-committed refreshed "
            "mirrors (version bumped) — the F2 corruption path"
        )
    print("[selftest-mirrors] PASS no re-commit after refresh (dirty-flag fix)")

    _submit_generate(s)
    var second_json = s.zrt.last_submit_json.copy()
    print("[selftest-mirrors] submit #2:", second_json)
    var got = GenParams.from_json(second_json)
    var diff = _diff_genparams(sent, got)
    if len(diff) > 0:
        for i in range(len(diff)):
            print("[selftest-mirrors] DIFF", diff[i])
        raise Error("selftest-mirrors: resubmit after PNG reuse-params differs")
    print("[selftest-mirrors] field diff: (none — all 14 fields identical)")
    if second_json != first_json:
        print("[selftest-mirrors] WARN: JSON strings differ (field values equal):")
        print("  #1:", first_json)
        print("  #2:", second_json)
        raise Error("selftest-mirrors: resubmit JSON not byte-identical")
    print("[selftest-mirrors] PASS resubmit byte-identical after reuse-params")
    print("[selftest-mirrors] ALL PASS")


def _graph_seam_selfcheck():
    """Compile and dry-run the Klein graph once at startup."""
    var state = InferenceState()
    try:
        var ok = dry_run_klein9b_graph(state)
        print("[graph-seam] klein9b_graph_dry=", ok, " model=", state.model_label())
    except e:
        print("[graph-seam] failed:", String(e))


