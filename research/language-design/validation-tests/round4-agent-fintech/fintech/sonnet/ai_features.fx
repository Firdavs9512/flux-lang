# ai_features.fx — AI-powered transaction explanation and fraud scoring
#
# Naming note: this file is named ai_features.fx (not ai.fx) to avoid
# conflicting with the built-in `ai` battery module. The `use ./ai as ...`
# alias pattern would work too, but naming the file differently is cleaner.

use db ai http
use ./fraud as fraud_mod

# POST /transactions/:id/explain
# Returns a plain-language explanation of a transaction.
http.on :post "/transactions/:id/explain" \req ->
  txn = db.one "select * from transactions where id=$1" [req.params.id]
  if txn == nil
    ret rep 404 {error:"transaction not found"}

  entries = db.q "select le.*, a.owner, a.currency from ledger_entries le join accounts a on le.account_id=a.id where le.transaction_id=$1" [txn.id]

  entries_desc <- ""
  each e in entries
    entries_desc <- entries_desc + "${e.direction} ${e.amount} cents (${e.currency}) on account ${e.account_id} (owner: ${e.owner}); "

  prompt = "Explain this financial transaction in plain language for a customer. Transaction id=${txn.id} kind=${txn.kind} status=${txn.status} created=${txn.created}. Ledger entries: ${entries_desc}. Be concise, friendly, and avoid technical jargon."

  explanation = ai.ask prompt
  rep 200 {
    transaction_id:txn.id
    explanation:explanation
  }

# POST /transfers/:id/fraud-score
# Returns AI fraud score for an existing transfer.
http.on :post "/transfers/:id/fraud-score" \req ->
  transfer = db.one "select * from transfers where id=$1" [req.params.id]
  if transfer == nil
    ret rep 404 {error:"transfer not found"}

  from_acct = db.one "select * from accounts where id=$1" [transfer.from_account]
  to_acct   = db.one "select * from accounts where id=$1" [transfer.to_account]

  score_result = fraud_mod.score_transfer transfer from_acct to_acct
  rep 200 {
    transfer_id:transfer.id
    fraud_score:score_result.score
    reasons:score_result.reasons
    flagged:score_result.flagged
    ai_confidence:score_result._.conf
  }
