# Fraud detection and limits: daily caps, suspicious patterns
use db time

# Daily transfer limit per account (in cents: $1000)
daily_limit_cents = 100000

exp fn check_transfer from_account_id to_account_id amount_cents currency
  # Check if transfer violates fraud rules
  # Returns {blocked:bool, reason:str, score:0-1}

  # Rule 1: Daily transfer limit
  today_spent = get_daily_spent from_account_id
  if (today_spent + amount_cents) > daily_limit_cents
    ret {
      blocked:true
      reason:"daily transfer limit exceeded"
      score:0.95
    }

  # Rule 2: Large transfer (above 50% of daily limit triggers score increase)
  risk_score <- 0.1

  if amount_cents > (daily_limit_cents / 2)
    risk_score = 0.75

  # Rule 3: New destination account (never transferred to before)
  prev_transfer = db.one
    "select id from transfers where from_account_id=$1 and to_account_id=$2 limit 1"
    [from_account_id, to_account_id]

  if !prev_transfer
    risk_score = risk_score + 0.2

  # Cap score at 1.0
  if risk_score > 1.0
    risk_score = 1.0

  # Rule 4: Very high risk — block
  if risk_score > 0.95
    ret {
      blocked:true
      reason:"transfer blocked by risk score"
      score:risk_score
    }

  # Pass: not blocked
  {
    blocked:false
    reason:""
    score:risk_score
  }

exp fn get_daily_spent account_id
  # Total amount transferred OUT today (in cents)
  result = db.one
    "select coalesce(sum(amount_cents), 0) as total from transfers where from_account_id=$1 and status=:completed and created > $2"
    [account_id, time.ago 24 :hr]

  if result
    ret result.total
  ret 0

exp fn get_fraud_score account_id to_account_id amount_cents
  # Compute risk score 0..1
  # Used by AI explanation endpoint

  result = check_transfer account_id to_account_id amount_cents ""
  result.score

exp fn get_reasons account_id to_account_id amount_cents
  # Why is this transfer risky? List of reasons
  reasons <- []

  # Check daily limit
  today_spent = get_daily_spent account_id
  if (today_spent + amount_cents) > daily_limit_cents
    reasons = reasons.push "daily transfer limit would be exceeded"

  # Check large transfer
  if amount_cents > (daily_limit_cents / 2)
    reasons = reasons.push "large transfer amount"

  # Check new destination
  prev = db.one
    "select id from transfers where from_account_id=$1 and to_account_id=$2 limit 1"
    [account_id, to_account_id]

  if !prev
    reasons = reasons.push "new transfer destination"

  reasons
