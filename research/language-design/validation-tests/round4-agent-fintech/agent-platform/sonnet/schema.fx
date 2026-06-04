# schema.fx — tbl definitions for the AI agent platform
# All database tables are declared here and auto-migrated.

use db

# ── Agents ────────────────────────────────────────────────────────────────────
tbl agents
  id            serial pk
  owner         int    ref:users.id null
  name          str
  system_prompt str
  model         str
  status        sym    # :active :paused :archived

# ── Tools registered for an agent ────────────────────────────────────────────
tbl tools
  id            serial pk
  agent_id      int    ref:agents.id
  name          str
  description   str
  params_schema json   # JSON Schema object describing input params
  handler_kind  sym    # :builtin :http :queue

# ── Conversations ─────────────────────────────────────────────────────────────
tbl conversations
  id            serial pk
  agent_id      int    ref:agents.id
  user_id       int
  created       now

# ── Messages ──────────────────────────────────────────────────────────────────
tbl messages
  id            serial pk
  conversation_id int  ref:conversations.id
  role          sym    # :user :assistant :tool
  content       str
  tool_calls    json   # list of {name input} when role=:assistant
  created       now

# ── Tool invocations (timing + audit log) ────────────────────────────────────
tbl tool_invocations
  id            serial pk
  message_id    int    ref:messages.id
  tool_name     str
  input         json
  output        json
  ms            int    # elapsed milliseconds
  ok            bool   # did it succeed?

# ── Persistent per-agent key-value memory ────────────────────────────────────
tbl agent_memory
  id            serial pk
  agent_id      int    ref:agents.id
  key           str
  value         json   # any JSON-serialisable value

# ── Users (minimal — agents reference these) ─────────────────────────────────
tbl users
  id            serial pk
  email         str    uniq
  created       now

# ── AI cost/token tracking per conversation ──────────────────────────────────
tbl conversation_cost
  id            serial pk
  conversation_id int  ref:conversations.id
  tokens        int
  cost          flt
  recorded      now
