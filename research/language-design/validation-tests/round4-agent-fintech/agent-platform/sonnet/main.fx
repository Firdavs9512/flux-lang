# main.fx — entry point: wire up all modules and start the server
# Import order matters for route registration (all routes collected before serve).

use http
use ./schema     as _schema    # SPEC GAP: side-effect import for tbl declarations
use ./agents     as _agents    # registers /agents routes
use ./conversations as _convs  # registers /conversations routes
use ./cron_jobs  as _cron      # registers cron.hr job

# ── Health check ──────────────────────────────────────────────────────────────
http.on :get "/health" \req ->
  rep 200 {status:"ok" service:"agent-platform"}

# ── 404 fallback ─────────────────────────────────────────────────────────────
# SPEC GAP: no wildcard catch-all route in spec.
# We assume http.on :get "/*" acts as a catch-all (undocumented).
http.on :get "/*" \req ->
  rep 404 {error:"not found"}

# ── Start the HTTP server ──────────────────────────────────────────────────────
port = env.PORT ?? "8080"
log "agent-platform starting on port ${port}"
http.serve (str.int port)
