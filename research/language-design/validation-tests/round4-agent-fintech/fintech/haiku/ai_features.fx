# AI-powered features: explain transactions, fraud scoring
use ai json
use ./fraud

exp fn explain_transaction transaction_id
  # AI natural language explanation of why a transaction happened
  # and any risk signals

  txn = db.one "select * from transactions where id=$1" [transaction_id]
  if !txn
    fail "transaction not found"

  # Fetch related ledger entries
  entries = db.q
    "select * from ledger_entries where transaction_id=$1"
    [transaction_id]

  # Build context for AI
  match txn.kind
    :transfer -> explain_transfer_txn txn entries
    :deposit -> explain_deposit_txn txn entries
    :withdrawal -> explain_withdrawal_txn txn entries
    _ -> {explanation:"unknown transaction type"}

exp fn explain_transfer_txn txn entries
  # Find from/to accounts from ledger entries
  from_entry = nil
  to_entry = nil
  each e in entries
    if e.direction == :debit
      from_entry = e
    else
      to_entry = e

  from_acc = db.one "select * from accounts where id=$1" [from_entry.account_id]
  to_acc = db.one "select * from accounts where id=$1" [to_entry.account_id]

  # Use AI to explain the transfer
  prompt = "Transaction: ${from_acc.owner} transferred ${from_entry.amount_cents} cents to account ${to_acc.id}. Kind: ${txn.kind}. Status: ${txn.status}. Explain this transaction briefly."

  result = ai.ask prompt

  # Compute fraud score
  score = fraud.get_fraud_score from_entry.account_id to_entry.account_id from_entry.amount_cents
  reasons = fraud.get_reasons from_entry.account_id to_entry.account_id from_entry.amount_cents

  {
    transaction_id:txn.id
    kind:txn.kind
    explanation:result
    fraud_score:score
    fraud_reasons:reasons
    confidence:0.85
  }

exp fn explain_deposit_txn txn entries
  entry = entries.0
  {
    transaction_id:txn.id
    kind:txn.kind
    explanation:"deposit of ${entry.amount_cents} cents"
    fraud_score:0.05
    fraud_reasons:[]
    confidence:0.95
  }

exp fn explain_withdrawal_txn txn entries
  entry = entries.0
  {
    transaction_id:txn.id
    kind:txn.kind
    explanation:"withdrawal of ${entry.amount_cents} cents"
    fraud_score:0.05
    fraud_reasons:[]
    confidence:0.95
  }

exp fn score_transaction_for_fraud transaction_id
  # Structured fraud scoring via AI.json
  txn = db.one "select * from transactions where id=$1" [transaction_id]
  if !txn
    fail "transaction not found"

  entries = db.q
    "select * from ledger_entries where transaction_id=$1"
    [transaction_id]

  if txn.kind != :transfer
    ret {score:0.1 reasons:[]}

  # For transfers, compute fraud signals
  from_entry = entries.0
  to_entry = entries.1

  from_acc = db.one "select * from accounts where id=$1" [from_entry.account_id]
  to_acc = db.one "select * from accounts where id=$1" [to_entry.account_id]

  # Prompt AI for structured scoring
  prompt = "Analyze fraud risk for this transfer: ${from_entry.amount_cents} cents from account ${from_entry.account_id} to account ${to_entry.account_id}. Respond in JSON with score (0-1) and list of risk factors."

  result = ai.json prompt {
    score:flt
    risk_factors:[str]
  }

  {
    transaction_id:txn.id
    fraud_score:result.score
    risk_factors:result.risk_factors
    ai_confidence:result._.conf
  }
