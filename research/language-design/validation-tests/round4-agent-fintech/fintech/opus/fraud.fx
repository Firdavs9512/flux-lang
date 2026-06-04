# fraud.fx — daily limit enforcement + suspicious-pattern flagging.
#
# All amounts integer cents.

use db time

# Per-account daily outbound limit (in minor units). Exported so tests/ops
# can read it. 1_000_000 cents = 10,000.00 of the account currency.
exp limit = 1000000

# Sum of today's (last 24h) posted/pending outbound transfers from an account.
exp fn today_outbound account_id
  r = db.one "select coalesce(sum(amount),0) s from transfers where from_account=$1 and status in ('pending','posted') and created > $2" [account_id (time.ago 24 :hr)]
  ret r.s ?? 0

# Check whether a new transfer of `amount` would exceed the daily limit.
# Returns a map {ok:bool used:int limit:int}.
exp fn check_daily_limit account_id amount
  used = today_outbound account_id
  total = used + amount
  ret {ok: (total <= limit) used: used limit: limit would_be: total}

# Heuristic suspicious-pattern detection. Returns a list of string reasons
# (empty => nothing suspicious). Pure integer / count logic — deterministic.
exp fn suspicious_reasons account_id amount currency
  reasons <- []

  # 1) burst: many transfers in the last 5 minutes
  burst = db.one "select count(*) c from transfers where from_account=$1 and created > $2" [account_id (time.ago 5 :min)]
  if (burst.c ?? 0) >= 5
    reasons <- reasons.push "high-velocity: ${burst.c} transfers in 5 minutes"

  # 2) large single amount relative to limit (> 80% of daily limit in one shot)
  if amount * 100 > limit * 80
    reasons <- reasons.push "large-amount: single transfer is >80% of daily limit"

  # 3) round-number structuring just under the limit
  if amount >= (limit - 100) & amount < limit
    reasons <- reasons.push "structuring: amount sits just below the daily limit"

  ret reasons
