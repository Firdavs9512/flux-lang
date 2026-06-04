# memory.fx — persistent per-agent key-value memory operations
# Agents read and write memory across conversations via these helpers.

use db

# ── Read a single memory value for an agent (returns nil if missing) ─────────
exp fn mem_get agent_id key
  row = db.one "select value from agent_memory where agent_id=$1 and key=$2" [agent_id key]
  ret row.value ?? nil

# ── Write (upsert) a memory value for an agent ───────────────────────────────
# SPEC GAP: no native upsert — we do manual check-then-insert-or-update.
exp fn mem_set agent_id key value
  existing = db.one "select id from agent_memory where agent_id=$1 and key=$2" [agent_id key]
  if existing
    db.up "agent_memory" {value:value} {id:existing.id}
  else
    db.ins "agent_memory" {agent_id:agent_id key:key value:value}

# ── Delete a memory entry ─────────────────────────────────────────────────────
exp fn mem_del agent_id key
  db.del "agent_memory" {agent_id:agent_id key:key}

# ── Load ALL memory entries for an agent as a flat map {key → value} ─────────
# Used by the runtime to inject memory into the system prompt context.
exp fn mem_load_all agent_id
  rows = db.q "select key, value from agent_memory where agent_id=$1 order by key" [agent_id]
  # SPEC GAP: no map.from_entries or zip-style constructor.
  # We build up a map incrementally using map.set which returns a new map.
  mem <- {}
  each row in rows
    mem <- mem.set row.key row.value
  ret mem

# ── Summarise memory as a human-readable string for prompt injection ──────────
exp fn mem_summary agent_id
  mem = mem_load_all agent_id
  keys = mem.keys
  if keys.len == 0
    ret "No persistent memory stored."
  lines <- []
  each k in keys
    v = mem[k]
    lines <- lines.push "- ${k}: ${json.enc v}"
  ret lines.join "\n"
