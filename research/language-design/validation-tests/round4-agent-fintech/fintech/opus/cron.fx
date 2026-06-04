# cron.fx — scheduled jobs.
# Daily reconciliation at 00:00. cron is a battery verb (no `use` import needed
# per spec "cron (fe'l)"), but we DO need to reference the battery; declaring it
# in `use` is harmless and explicit.

use cron
use ./recon

# Register the daily 00:00 reconciliation job. Call once at startup.
exp fn install
  cron.dy 0 0 \->
    log "cron: starting daily reconciliation"
    report = recon.run
    log "cron: reconciliation done ok=${report.ok} unbalanced=${report.unbalanced}"
