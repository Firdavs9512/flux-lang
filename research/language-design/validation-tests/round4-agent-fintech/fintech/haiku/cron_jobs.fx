# Background jobs: daily reconciliation, cleanup
use cron
use ./reconciliation

exp fn setup_cron_jobs
  # Schedule daily reconciliation at 00:00 UTC
  cron.dy 0 0 fn
    log "[CRON] Running daily reconciliation..."
    reconciliation.reconcile_all
    log "[CRON] Reconciliation complete"

  # Could add more jobs here:
  # - Fee calculations (daily)
  # - Statement generation
  # - Fraud model retraining
  # - Old record cleanup

  log "Cron jobs scheduled"
