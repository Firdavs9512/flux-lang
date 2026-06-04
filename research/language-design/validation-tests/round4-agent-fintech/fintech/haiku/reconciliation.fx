# Daily reconciliation: verify ledger sum = account balances
# Detects data corruption, race conditions, bugs
use db json time

exp fn reconcile_all
  # Run daily reconciliation on all accounts
  # Verify: for each account, sum(ledger_entries) == balance_cents

  log "Starting daily reconciliation..."

  discrepancies <- []
  accounts_checked <- 0

  all_accounts = db.q "select id, balance_cents from accounts"

  each acc in all_accounts
    accounts_checked = accounts_checked + 1

    # Compute balance from ledger
    ledger_result = db.one
      "select coalesce(sum(case when direction='credit' then amount_cents else -amount_cents end), 0) as computed_balance from ledger_entries where account_id=$1"
      [acc.id]

    computed_balance = ledger_result.computed_balance ?? 0
    stored_balance = acc.balance_cents

    # Check if they match
    if computed_balance != stored_balance
      discrepancies = discrepancies.push {
        account_id:acc.id
        stored_balance:stored_balance
        computed_balance:computed_balance
        diff:(computed_balance - stored_balance)
      }

      # Audit the discrepancy
      db.ins "audit_log"
        actor:0
        action:"reconciliation_discrepancy"
        entity:"accounts"
        entity_id:acc.id
        before_json:(json.enc {balance_cents:stored_balance})
        after_json:(json.enc {balance_cents:computed_balance})
        created:time.now

      log "DISCREPANCY: Account ${acc.id} stored=${stored_balance} computed=${computed_balance}"

  # Log reconciliation result
  recon = db.ins "reconciliation_log"
    reconciliation_date:(time.fmt time.now "%Y-%m-%d")
    accounts_checked:accounts_checked
    discrepancies:(discrepancies.len)
    details_json:(json.enc discrepancies)
    status:(if discrepancies.len > 0 :failed else :success)
    created:time.now

  log "Reconciliation complete: ${accounts_checked} accounts, ${discrepancies.len} discrepancies"

  recon

exp fn get_discrepancies since_days
  # Get recent reconciliation results with discrepancies
  threshold = time.ago since_days :day

  db.q
    "select * from reconciliation_log where created > $1 and discrepancies > 0 order by created desc"
    [threshold]

exp fn fix_balance account_id
  # Emergency function: fix balance by recomputing from ledger
  # ONLY for verified discrepancies
  if !account_id
    fail "account_id required"

  fixed <- nil

  db.tx \->
    # Compute correct balance
    ledger_result = db.one
      "select coalesce(sum(case when direction='credit' then amount_cents else -amount_cents end), 0) as balance from ledger_entries where account_id=$1"
      [account_id]

    correct_balance = ledger_result.balance ?? 0

    # Update account
    old_acc = db.one "select * from accounts where id=$1" [account_id]

    db.up "accounts" {balance_cents:correct_balance updated:time.now} {id:account_id}

    fixed = db.one "select * from accounts where id=$1" [account_id]

    # Audit the fix
    db.ins "audit_log"
      actor:0
      action:"fix_balance"
      entity:"accounts"
      entity_id:account_id
      before_json:(json.enc old_acc)
      after_json:(json.enc fixed)
      created:time.now

  fixed
