# cron.fx — scheduled jobs: nightly reconciliation at 00:00
#
# The reconciliation job scans every account, computes the authoritative
# ledger balance, compares it to the cached `balances` row, and logs any
# discrepancies. This is the canonical invariant check:
#   FOR ALL accounts: balances.available == SUM(ledger_entries WHERE direction=credit)
#                                         - SUM(ledger_entries WHERE direction=debit)

use db cron
use ./ledger as ledger_mod
use ./audit  as audit_mod

fn run_reconciliation
  log "reconciliation: starting nightly ledger balance check"
  accounts = db.q "select id, owner, currency from accounts where status='active'"
  discrepancy_count <- 0
  total_count       <- 0

  each acct in accounts
    total_count <- total_count + 1
    cached  = ledger_mod.get_balance acct.id
    ledger  = ledger_mod.compute_balance acct.id

    cached_available = cached.available ?? 0

    if cached_available != ledger.net
      discrepancy_count <- discrepancy_count + 1
      diff = cached_available - ledger.net
      log "reconciliation DISCREPANCY: account ${acct.id} owner=${acct.owner} cached=${cached_available} ledger=${ledger.net} diff=${diff}"

      # Write to audit log so discrepancies are traceable
      audit_mod.write_audit "cron:reconciliation" "reconciliation_discrepancy" "account:${acct.id}" {cached:cached_available} {ledger_net:ledger.net diff:diff}

      # Auto-correct the cached balance to match the authoritative ledger
      # SPEC GAP: Ideally we'd do this inside a db.tx with a lock on the
      # balance row to prevent a concurrent transfer from racing here.
      # Without row locking, a correction could overwrite a legitimate update.
      db.up "balances" {available:ledger.net} {account_id:acct.id}
      log "reconciliation: auto-corrected account ${acct.id} to ${ledger.net}"

  log "reconciliation: done. checked=${total_count} discrepancies=${discrepancy_count}"

# Schedule at 00:00 daily
cron.dy 0 0 run_reconciliation
