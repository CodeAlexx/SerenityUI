# SerenityUI ↔ generation daemon bridge spec (2026-06-10)

Switch SerenityUI's Generate path from per-job CLI spawn to the resident
pure-Mojo daemon (serenitymojo/serve/serenity_daemon.mojo, localhost:7801).
CLI spawn stays as fallback when the daemon isn't running.

## Protocol (implemented + gated on the daemon side)
- POST /v1/generate  body: {model, prompt, negative, width, height, steps,
  seed, cfg, lora:[{name,weight}]} → {job_id, queue_position} (422 on bad body)
- GET  /v1/jobs            → [{id, created, model, state, progress, step,
                               total, output_path, error}]
- GET  /v1/job/<id>        → one job (404 unknown)
- POST /v1/cancel/<id>     → 409 if already terminal
- WS   /v1/progress        → JSON events {job_id, state, step, total,
                               progress, preview?} (RFC6455, server-push)
- GET  /v1/health          → {status, backend, model}
Outputs: PNG with full param JSON embedded as tEXt `serenity.genparams.v1`;
every finished job recorded in output/serenity_daemon/jobs.db (SQLite,
readable with MOJO-libs sqlite — the gallery index).

## UI-side changes (MojoUI/mojoui/app/inference_graph_bridge.mojo)
1. Daemon client (MOJO-libs http/client.mojo): health-check at app start +
   on Generate; if healthy → POST /v1/generate; else → existing CLI spawn
   path (unchanged).
2. Progress: per-frame tick polls GET /v1/jobs (cheap, local) OR holds the
   WS connection and drains events non-blocking — start with polling
   (matches the existing progress-file poll pattern), WS later.
3. Cancel button → POST /v1/cancel/<id>.
4. Queue rail: render /v1/jobs directly (replaces in-memory queue mirror for
   daemon jobs).
5. History: completed jobs append from /v1/jobs; "reuse params" reads the
   PNG tEXt chunk (MOJO-libs image read_png_text) — no sidecar needed.
6. Model dropdown → JobParams.model; only daemon-supported models route to
   the daemon (health.model / future /v1/models lists them), others → CLI.

## Build/run notes
- serenityUI builds with -I /home/alex/mojodiffusion already; ADD
  -I /home/alex/MOJO-libs for the http client + png text reader.
- One mojo build at a time across repos (shared serenitymojo.mojopkg).
- Daemon lifecycle: UI may spawn it (same pattern as the trainer terminal
  launcher) or the user runs it standalone; UI must handle "daemon appears
  /disappears mid-session" (health re-check on error).
