# Phase 5 — Process-isolation-per-model (design)

Status: DESIGN + SCAFFOLD (CPU-only). GPU VRAM-reclaim verification deferred.
Author pass: 2026-06-11. Grounded in the real code, not from memory.

## Why

Phase-4 MEASURED finding: the Mojo GPU runtime (AsyncRT) caching allocator never
returns pool bytes to the OS while the `DeviceContext` singleton lives;
`cuMemPoolTrimTo` reclaims 0 (the runtime doesn't allocate from the CUDA default
stream-ordered pool). Consequence: after a zimage job ~21 GB stays pinned, so a
zimage->qwen switch OOMs (qwen 1024² can't fit in the ~3 GB left). The switch
*mechanism* is correct and the failure is honest (F3: zimage[done] ->
qwen[failed] -> zimage[done], daemon survives), but a 24 GB card can't hold two
big models, and in-process trimming can't fix it.

The ONLY robust reclaim on this runtime is **process exit** — F3 measured it:
killing the daemon dropped VRAM 21416 -> 788 MiB. Phase 5 turns that into the
switch primitive: run each resident model in a CHILD PROCESS; a model switch =
kill child (OS reclaims ALL its VRAM) + spawn a fresh child.

## The seam we plug into (verified)

- `serve/backend.mojo`: `trait GenBackend` — backend_name / model_name /
  resident_model / start(params) / step()->StepResult / cancel() /
  between_jobs_trim(). step() is pull-based, ~100 ms-bounded, runs INSIDE the
  daemon event loop (no threads).
- `serve/serenity_daemon.mojo:853`: `def run_daemon[B: GenBackend](mut backend: B, port)`
  is GENERIC. A new backend type drops in with one `main()` branch.
- `main()` already dispatches argv modes `stub | zimage | dispatch`. Phase 5 adds
  `isolated` (the parent dispatcher) + a hidden `worker <kind> <fd>` (the child).
- `net/syscalls.mojo` already FFIs: socket, bind, listen, connect, accept, recv,
  send, close, fcntl, **fork**. Phase 5 ADDS: socketpair, execv, waitpid, kill.

## Why fork+exec (not fork alone)

fork() in a multithreaded process leaves the child with ONLY the forking thread;
any lock held by a vanished AsyncRT thread stays locked → deadlock the moment the
child touches the runtime, and CUDA contexts are not fork-safe. So between fork()
and exec() we do ONLY async-signal-safe calls (dup2, close, execv), then
**execv(self)** to get a clean process image: fresh Mojo runtime, fresh CUDA
context. The parent dispatcher NEVER initializes CUDA itself — it only manages
children — so the parent stays light and its own fork() is clean.

## Topology

```
serenity_daemon isolated            (PARENT — HTTP/WS/SQLite, NO GPU, NO CUDA)
  GenBackend = ProcessIsolatedBackend
    holds: current child pid + child kind + AF_UNIX socket (parent end)
    start(params):
       want = _kind_for_model(params.model)        # reuse dispatch_backend rule
       if child kind != want: _kill_child(); _spawn_child(want)
       send {"cmd":"start","params":{...}} to child
    step():                                          # bounded, non-blocking
       recv one line from child socket (O_NONBLOCK);
       EAGAIN -> StepResult(no progress this tick)
       "progress"->StepResult(step,total,phase); "done"->terminal+output_path;
       "failed"->terminal+error; "cancelled"->terminal
    cancel():  send {"cmd":"cancel"}
    between_jobs_trim(): no-op  (child holds VRAM; reclaim is on kill, not trim)

  _spawn_child(kind):
    socketpair(AF_UNIX,SOCK_STREAM) -> (parent_fd, child_fd)
    pid = fork()
    child: close(parent_fd); dup2(child_fd, WORKER_FD); execv(self_exe,
           ["serenity_daemon","worker",kind, str(WORKER_FD)])
    parent: close(child_fd); set parent_fd O_NONBLOCK; remember pid+kind
  _kill_child(): kill(pid, SIGTERM); waitpid(pid); close(parent_fd)
                 (OS reclaims the child's VRAM on exit — the whole point)

serenity_daemon worker <kind> <fd>  (CHILD — one real backend, IPC not HTTP)
  run_worker(kind, fd):
    backend = ZImageBackend() | QwenImageBackend() | StubBackend()  # by kind
    loop:
      msg = read_line(fd)                    # blocking read from parent
      if cmd==start: backend.start(params); while not terminal:
            r = backend.step(); send ev(progress|done|failed|cancelled)
            (poll fd between steps for an interleaved "cancel" -> backend.cancel())
      if EOF (parent died/closed) -> _exit(0)
```

## IPC wire protocol (newline-delimited JSON, one msg per line)

Parent -> child:
  {"cmd":"start","params":{model,prompt,negative,width,height,steps,seed,cfg,
                           init_image,creativity,loras:[{name,weight}],
                           params_json,out_dir,job_id}}
  {"cmd":"cancel"}
Child -> parent:
  {"ev":"progress","step":N,"total":M,"phase":"loading|encoding|...|"}
  {"ev":"done","output_path":"..."}
  {"ev":"failed","error":"..."}
  {"ev":"cancelled"}
  {"ev":"ready"}    # sent once after the child constructs its backend

The `params` object is exactly the JobParams fields; we reuse the existing JSON
lib (the daemon already serializes JobParams for jobs.db / PNG tEXt). No new
schema — process isolation is a TRANSPORT change, not a contract change.

## What is CPU-verifiable now (this scaffold)

The worker can construct the **stub** backend (no GPU). So the FULL isolation
machinery — socketpair, fork, execv into `worker stub <fd>`, send start, stream
progress, get done, kill+respawn, switch — is exercised end-to-end on CPU:

  isolated-mode daemon with a STUB child:
    submit job -> child runs stub steps -> progress over socket -> done + png
    submit job with a different "model" -> parent kills stub child, respawns ->
    second job done  (proves the kill+respawn switch path)

That validates everything except the one number that needs a GPU: that killing a
REAL (zimage/qwen) child drops VRAM back to baseline. That single measurement is
the deferred GPU gate.

## Deferred to a GPU window (one measurement)

  isolated daemon, dispatch-equivalent sequence:
    zimage child -> done; switch to qwen = KILL zimage child (VRAM -> ~baseline)
    + spawn qwen child -> qwen 1024² now FITS (was the F3 OOM) -> done;
    switch back -> kill qwen, spawn zimage -> done.
  Expected: idle VRAM between jobs tracks ONE model, and zimage->qwen no longer
  OOMs (the whole reason for Phase 5). nvidia-smi sampled at each boundary.

## Failure / edge handling (designed in)

- Child dies mid-job (crash/OOM-kill): parent's recv returns 0/EOF or waitpid
  reaps a non-zero exit -> step() returns failed("worker exited") -> job FAILED,
  parent respawns lazily on next start(). (Mirrors F3's daemon-survives property,
  now at process granularity.)
- Parent dies: children get SIGTERM via the parent's process-group teardown; each
  worker's read_line hits EOF -> _exit. No orphaned GPU holders.
- Cancel races: a "cancel" arriving after the child already sent "done" is a
  no-op (parent already saw terminal); child checks cancel between steps only.
- Bounded step(): parent socket is O_NONBLOCK; a tick with no child message is a
  zero-progress StepResult, keeping HTTP responsive exactly like today.

## Files (scaffold)

- `serve/proc_ipc.mojo`   (NEW) — FFI: socketpair, execv, waitpid, kill, dup2,
                                  _exit; line read/write helpers over a fd.
- `serve/worker.mojo`     (NEW) — run_worker(kind, fd): the child loop.
- `serve/process_isolated_backend.mojo` (NEW) — ProcessIsolatedBackend(GenBackend).
- `serve/serenity_daemon.mojo` (EDIT) — main(): add `isolated` + `worker` argv.

## Non-goals (kept out on purpose)

- No change to the GenBackend contract, the HTTP/WS API, or the UI. Isolated mode
  is a drop-in daemon mode; the UI/`--selftest` see identical behavior.
- Not wired as the default — `dispatch` stays default until the GPU gate passes.
- Not the node-graph backend itself; Phase 5 just makes multi-model switching
  actually fit in 24 GB, which the node graph will sit on top of.

## STATUS — scaffold built + CPU-verified (2026-06-11)

Files landed: serve/proc_ipc.mojo, serve/ipc_codec.mojo, serve/worker.mojo,
serve/process_isolated_backend.mojo, serenity_daemon.mojo (isolated+worker argv).
Full daemon build: exit 0.

CPU end-to-end PASS (`serenity_daemon isolated` with STUB workers, /tmp/p5_test.sh,
GPU idle 827 MiB throughout — parent never touches CUDA):
  JOB1 model=stub  -> done       (spawned stub worker pid A)
  JOB2 model=stub2 -> done       (SWITCH: killed pid A, spawned stub2 worker pid B≠A)
  JOB3 model=stub  -> done       (SWITCH back: spawned pid C, all distinct)
  JOB4 cancel mid-run -> cancelled (cancel delivered over IPC)
  live worker children during run = 1 (exactly one resident child)
  orphan workers after daemon teardown = 0
=> spawn (fork+execv), IPC job round-trip, kill+respawn SWITCH, and cancel are
   all proven on CPU. Distinct PIDs across switches = real process replacement.

BUG FOUND + FIXED during this verification (real, would have bitten the GPU path):
  The daemon installs a signalfd which BLOCKS SIGTERM/SIGINT in the process mask.
  fork() inherits the mask and execv() preserves it, so the worker child has
  SIGTERM blocked — a SIGTERM kill stays pending forever and the parent's
  waitpid() hangs (observed: switch wedged, worker never died). Fix: _kill_child
  uses SIGKILL (unblockable), which is also semantically right — process
  isolation WANTS a hard exit so the OS reclaims VRAM (no graceful child cleanup
  needed). Worker idle-poll + EOF-on-parent-death paths are signal-independent.

DEFERRED — the one GPU measurement (needs a GPU window):
  `serenity_daemon isolated` with REAL children: zimage child -> done; switch to
  qwen = kill zimage child (nvidia-smi should drop to ~baseline) + spawn qwen
  child -> qwen 1024² FITS (the F3 OOM is gone); switch back. Confirms the whole
  point: idle VRAM tracks ONE model and zimage<->qwen no longer OOMs. NOT wired
  as the daemon default until this passes (dispatch stays default).
