# Idempotency: ensure repeated requests with same key return same result
# Solves: what if transfer request is retried? Must not double-charge.
use db json

# In-memory cache of recent idempotency results for speed
# In production: Redis. Here: simple map.
idempotency_cache <- {}

exp fn check_and_lock key
  # Check if idempotency key has been seen before
  # Returns cached result or nil if not yet processed

  # First check DB (for persistence across restarts)
  existing = db.one
    "select transfer_id, transaction_id from idempotency_log where idempotency_key=$1"
    [key]

  if existing
    # Add to in-memory cache for fast subsequent hits
    idempotency_cache = idempotency_cache.set key existing
    ret existing

  # Not seen before — caller can proceed with new transaction
  nil

exp fn store_result key transfer_id transaction_id
  # After successful transfer, store the result for future idempotency checks
  if !key
    fail "key required"
  if !transfer_id
    fail "transfer_id required"
  if !transaction_id
    fail "transaction_id required"

  # Store in DB
  db.ins "idempotency_log"
    idempotency_key:key
    transfer_id:transfer_id
    transaction_id:transaction_id
    created:time.now

  # Also cache in memory
  idempotency_cache = idempotency_cache.set key {
    transfer_id:transfer_id
    transaction_id:transaction_id
  }

  nil

# Create schema for idempotency log (called from main during setup)
exp fn create_schema
  db.q "
    create table if not exists idempotency_log (
      id serial primary key,
      idempotency_key text unique not null,
      transfer_id int not null,
      transaction_id int not null,
      created timestamp default now()
    )
  "
