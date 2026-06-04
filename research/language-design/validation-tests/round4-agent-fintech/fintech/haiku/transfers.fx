# Transfer between accounts: atomic, idempotent, with double-entry ledger
use db json
use ./accounts
use ./fraud
use ./idempotency

exp fn transfer from_account_id to_account_id amount_cents currency idempotency_key
  # Core transfer operation: atomic, idempotent, fraud-checked
  if !from_account_id
    fail "from_account_id required"
  if !to_account_id
    fail "to_account_id required"
  if amount_cents <= 0
    fail "amount must be positive"
  if !currency
    fail "currency required"
  if !idempotency_key
    fail "idempotency_key required"

  # Check idempotency: have we seen this key before?
  existing = idempotency.check_and_lock idempotency_key

  # If already processed, return cached result
  if existing
    ret {
      status::already_processed
      transfer_id:existing.transfer_id
      message:"transfer already processed with this key"
    }

  transfer_result <- nil

  db.tx \->
    # Get both accounts
    from_acc = db.one "select * from accounts where id=$1" [from_account_id]
    to_acc = db.one "select * from accounts where id=$1" [to_account_id]

    # Validate accounts exist and are active
    if !from_acc
      fail "source account not found"
    if !to_acc
      fail "destination account not found"
    if from_acc.status != :active
      fail "source account not active"
    if to_acc.status != :active
      fail "destination account not active"

    # Validate currencies match
    if from_acc.currency != currency
      fail "source account currency mismatch"
    if to_acc.currency != currency
      fail "destination account currency mismatch"

    # Check balance (CRUCIAL: must be atomic with debit operation)
    balance = accounts.get_balance from_account_id
    if balance < amount_cents
      fail "insufficient balance"

    # FRAUD CHECK: check daily limits and patterns
    fraud_result = fraud.check_transfer from_account_id to_account_id amount_cents currency
    if fraud_result.blocked
      fail fraud_result.reason

    # Create transaction record
    txn = db.ins "transactions"
      kind::transfer
      status::completed
      idempotency_key:idempotency_key
      created:time.now
      updated:time.now

    # Create DEBIT ledger entry (source loses money)
    db.ins "ledger_entries"
      transaction_id:txn.id
      account_id:from_account_id
      direction::debit
      amount_cents:amount_cents
      created:time.now

    # Create CREDIT ledger entry (destination gains money)
    db.ins "ledger_entries"
      transaction_id:txn.id
      account_id:to_account_id
      direction::credit
      amount_cents:amount_cents
      created:time.now

    # Create transfer record
    xfer = db.ins "transfers"
      from_account_id:from_account_id
      to_account_id:to_account_id
      amount_cents:amount_cents
      currency:currency
      status::completed
      idempotency_key:idempotency_key
      created:time.now
      updated:time.now

    # Store idempotency result
    idempotency.store_result idempotency_key xfer.id txn.id

    # Audit
    db.ins "audit_log"
      actor:from_acc.owner
      action:"transfer"
      entity:"transfers"
      entity_id:xfer.id
      before_json:nil
      after_json:(json.enc xfer)
      created:time.now

    transfer_result = {
      status::completed
      transfer_id:xfer.id
      transaction_id:txn.id
      from_account:from_account_id
      to_account:to_account_id
      amount_cents:amount_cents
      currency:currency
    }

  # If we get here, transfer succeeded
  transfer_result

exp fn reverse_transfer transfer_id
  # Reverse a transfer: debit becomes credit, credit becomes debit
  # Creates inverse transaction
  if !transfer_id
    fail "transfer_id required"

  reversal <- nil

  db.tx \->
    xfer = db.one "select * from transfers where id=$1" [transfer_id]
    if !xfer
      fail "transfer not found"

    # Create reversal transaction
    rev_txn = db.ins "transactions"
      kind::reversal
      status::completed
      idempotency_key:("reversal_${transfer_id}_${time.now}")
      created:time.now
      updated:time.now

    # Reverse ledger entries: what was debit becomes credit
    db.ins "ledger_entries"
      transaction_id:rev_txn.id
      account_id:xfer.to_account_id
      direction::debit
      amount_cents:xfer.amount_cents
      created:time.now

    db.ins "ledger_entries"
      transaction_id:rev_txn.id
      account_id:xfer.from_account_id
      direction::credit
      amount_cents:xfer.amount_cents
      created:time.now

    # Mark original transfer as rolled back
    db.up "transfers" {status::rolled_back updated:time.now} {id:transfer_id}

    # Create reversal transfer record
    reversal = db.ins "transfers"
      from_account_id:xfer.to_account_id
      to_account_id:xfer.from_account_id
      amount_cents:xfer.amount_cents
      currency:xfer.currency
      status::completed
      idempotency_key:("reversal_${transfer_id}")
      created:time.now
      updated:time.now

    # Audit
    db.ins "audit_log"
      actor:0
      action:"reverse_transfer"
      entity:"transfers"
      entity_id:reversal.id
      before_json:(json.enc xfer)
      after_json:(json.enc reversal)
      created:time.now

  reversal

exp fn get_transfer id
  db.one "select * from transfers where id=$1" [id]

exp fn list_transfers account_id
  # All transfers involving an account (as source or dest)
  db.q
    "select * from transfers where from_account_id=$1 or to_account_id=$1 order by created desc"
    [account_id]
