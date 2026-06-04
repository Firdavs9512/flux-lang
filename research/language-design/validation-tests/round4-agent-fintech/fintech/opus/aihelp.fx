# aihelp.fx — AI features. Named aihelp (not "ai") to avoid colliding with the
# `ai` battery module (spec rule: rename own file if it shadows a battery).
#
# All money values shown to the AI are formatted from integer cents to a
# human string at the boundary; we never let the model do the money math.

use ai db json

# Format integer cents into a human-readable decimal string for display only.
# e.g. 123456 -> "1234.56". Integer math only (no float division).
exp fn fmt_money cents currency
  whole = cents / 100
  frac  = math.abs (cents % 100)
  fs = "$frac"
  if frac < 10
    fs = "0$frac"
  ret "${whole}.${fs} ${currency}"

# Plain-language explanation of a transaction for the customer.
exp fn explain_txn txn
  entries = db.q "select * from ledger_entries where txn=$1 order by id" [txn.id]
  lines <- []
  each e in entries
    lines <- lines.push "${e.dir} ${fmt_money e.amount e.currency} on account ${e.account}"
  detail = lines.join "; "
  txt = ai.ask "Explain this banking transaction to a non-technical customer in 2-3 plain sentences. Do not invent details. Transaction kind: ${txn.kind}, status: ${txn.status}. Ledger lines: ${detail}."
  ret {explanation: txt confidence: txt._.conf}

# Fraud scoring on a transfer's features. Returns a normalized score 0..1 and
# reasons. We pass already-computed numeric features so the model scores, but
# the authoritative limit check is still done in fraud.fx (deterministic).
exp fn score_transfer features
  r = ai.json "Score the fraud risk of this money transfer from 0 (safe) to 1 (fraud). Base it ONLY on the provided features. Features: ${json.enc features}" {
    score: flt
    reasons: [str]
  }
  ret {score: r.score reasons: r.reasons confidence: r._.conf}
