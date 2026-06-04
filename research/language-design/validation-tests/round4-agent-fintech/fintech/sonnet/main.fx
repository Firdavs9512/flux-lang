# main.fx — entry point: wire up all modules and start the HTTP server
#
# Import order matters for route registration: all modules register their
# http.on handlers when loaded. We load them all here, then call http.serve.

use http env

# Load schema definitions (tbl declarations)
use ./schema

# Core modules
use ./audit         as audit_mod
use ./idempotency   as idem
use ./ledger        as ledger_mod

# Feature modules (each registers its own http.on routes)
use ./accounts
use ./balance
use ./transfers
use ./payment_methods
use ./ai_features

# Fraud module (no HTTP routes; used by transfers)
use ./fraud as fraud_mod

# Scheduled jobs
use ./cron

port = str.int (env.PORT ?? "8080")

log "fintech ledger service starting on port ${port}"
log "double-entry accounting backend — all amounts in integer cents"

# Health check
http.on :get "/health" \req ->
  rep 200 {status:"ok" service:"fintech-ledger"}

# Audit log query (read-only)
http.on :get "/audit-log" \req ->
  entity = req.query.entity
  if entity != nil
    rows = db.q "select * from audit_log where entity=$1 order by created desc limit 100" [entity]
    ret rep 200 rows
  rows = db.q "select * from audit_log order by created desc limit 100"
  rep 200 rows

http.serve port
