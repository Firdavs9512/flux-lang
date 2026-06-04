# recon.fx — reconciliation: verify the ledger invariants.
#
# Two checks:
#   A) GLOBAL: sum of every ledger line (debit positive, credit negative) must
#      be exactly zero. Double-entry guarantees this; any non-zero is corruption.
#   B) PER-TRANSACTION: every transaction's debits must equal its credits.
#
# Returns a structured report and writes audit entries for any discrepancy.
# Pure integer arithmetic.

use db
use ./audit

# Global zero-sum check across the whole ledger.
exp fn global_balanced
  r = db.one "select coalesce(sum(case when dir='debit' then amount else -amount end),0) net from ledger_entries"
  ret (r.net ?? 0) == 0

# Find transactions whose debits != credits. Returns list of {txn d c}.
exp fn unbalanced_txns
  rows = db.q "select txn, coalesce(sum(case when dir='debit' then amount else 0 end),0) d, coalesce(sum(case when dir='credit' then amount else 0 end),0) c from ledger_entries group by txn"
  ret rows.filter \r -> r.d != r.c

# Run a full reconciliation pass. Logs discrepancies to audit_log.
exp fn run
  net_ok = global_balanced
  bad = unbalanced_txns

  if !net_ok
    r = db.one "select coalesce(sum(case when dir='debit' then amount else -amount end),0) net from ledger_entries"
    audit.write "system" "recon.discrepancy" "ledger:global" nil {
      kind:"global_nonzero" net: r.net
    }
    log "RECON FAIL: global ledger net is ${r.net} (expected 0)"

  each b in bad
    audit.write "system" "recon.discrepancy" "txn:${b.txn}" nil {
      kind:"txn_unbalanced" txn: b.txn debits: b.d credits: b.c
    }
    log "RECON FAIL: txn ${b.txn} unbalanced d=${b.d} c=${b.c}"

  ok = net_ok & (bad.len == 0)
  if ok
    log "RECON OK: ledger fully balanced"
  ret {ok: ok global_zero: net_ok unbalanced: bad.len}
