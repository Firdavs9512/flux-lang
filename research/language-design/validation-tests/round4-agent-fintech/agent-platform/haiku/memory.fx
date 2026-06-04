# Agent memory: persistent key-value store, one per agent
use db json

# Load an agent's memory (key -> parsed JSON value)
exp fn load_memory agent_id
  rows = db.q "select key, value_json from agent_memory where agent_id = $1" [agent_id]
  mem <- {}
  each r in rows
    parsed = json.dec r.value_json
    mem <- mem.set r.key parsed
  ret mem

# Get a single memory value (returns nil if missing)
exp fn get_memory agent_id key
  row = db.one "select value_json from agent_memory where agent_id=$1 and key=$2" [agent_id key]
  if !row
    ret nil
  ret json.dec row.value_json

# Set a memory value (creates or updates)
exp fn set_memory agent_id key value
  # Encode value as JSON
  encoded = json.enc value

  # Check if exists
  exists = db.one "select id from agent_memory where agent_id=$1 and key=$2" [agent_id key]

  if exists
    db.up "agent_memory" {value_json:encoded updated:time.now} {agent_id:agent_id key:key}
  else
    db.ins "agent_memory" {agent_id:agent_id key:key value_json:encoded}

  ret value

# Delete a memory key
exp fn delete_memory agent_id key
  db.del "agent_memory" {agent_id:agent_id key:key}
  ret nil

# Clear all memory for an agent (careful!)
exp fn clear_memory agent_id
  db.del "agent_memory" {agent_id:agent_id}
  ret nil

# Increment a numeric counter (for usage tracking within agent memory)
exp fn increment_counter agent_id key increment_by
  current = get_memory agent_id key
  new_val = (current ?? 0) + increment_by
  set_memory agent_id key new_val
  ret new_val
