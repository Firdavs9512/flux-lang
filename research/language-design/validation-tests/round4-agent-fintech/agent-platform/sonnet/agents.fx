# agents.fx — HTTP routes for agent and tool CRUD
# POST /agents                   — create an agent
# GET  /agents/:id               — get agent details
# PUT  /agents/:id               — update agent config
# POST /agents/:id/tools         — register a tool for an agent
# GET  /agents/:id/tools         — list agent's tools
# GET  /agents/:id/memory        — read all memory
# DEL  /agents/:id/memory/:key   — delete a memory key

use http db
use ./memory

# ── Create agent ──────────────────────────────────────────────────────────────
http.on :post "/agents" \req ->
  if !req.body.name
    ret rep 400 {error:"name required"}
  if !req.body.system_prompt
    ret rep 400 {error:"system_prompt required"}

  model  = req.body.model  ?? "gpt-4o"
  status = :active

  agent = db.ins "agents" {
    owner:         req.body.owner_id ?? nil
    name:          req.body.name
    system_prompt: req.body.system_prompt
    model:         model
    status:        status
  }

  log "agent created id=${agent.id} name=${agent.name}"
  rep 201 agent

# ── Get agent ─────────────────────────────────────────────────────────────────
http.on :get "/agents/:id" \req ->
  agent = db.one "select * from agents where id=$1" [str.int req.params.id]
  if !agent
    ret rep 404 {error:"agent not found"}
  rep 200 agent

# ── Update agent config ───────────────────────────────────────────────────────
http.on :put "/agents/:id" \req ->
  agent_id = str.int req.params.id
  agent = db.one "select id from agents where id=$1" [agent_id]
  if !agent
    ret rep 404 {error:"agent not found"}

  # Build update map from whichever fields were provided
  # SPEC GAP: no built-in "pick non-nil fields" helper — manual elif chain.
  updates <- {}
  if req.body.name
    updates <- updates.set "name" req.body.name
  if req.body.system_prompt
    updates <- updates.set "system_prompt" req.body.system_prompt
  if req.body.model
    updates <- updates.set "model" req.body.model
  if req.body.status
    updates <- updates.set "status" req.body.status

  if updates.keys.len == 0
    ret rep 400 {error:"no fields to update"}

  db.up "agents" updates {id:agent_id}
  updated = db.one "select * from agents where id=$1" [agent_id]
  rep 200 updated

# ── Register a tool for an agent ─────────────────────────────────────────────
http.on :post "/agents/:id/tools" \req ->
  agent_id = str.int req.params.id
  agent = db.one "select id from agents where id=$1" [agent_id]
  if !agent
    ret rep 404 {error:"agent not found"}
  if !req.body.name
    ret rep 400 {error:"name required"}
  if !req.body.description
    ret rep 400 {error:"description required"}

  # Default handler_kind to :builtin if not specified
  handler_kind = req.body.handler_kind ?? :builtin

  # Check for duplicate tool name on this agent
  existing = db.one "select id from tools where agent_id=$1 and name=$2" [agent_id req.body.name]
  if existing
    ret rep 409 {error:"tool '${req.body.name}' already registered for this agent"}

  tool = db.ins "tools" {
    agent_id:      agent_id
    name:          req.body.name
    description:   req.body.description
    params_schema: req.body.params_schema ?? {}
    handler_kind:  handler_kind
  }

  log "tool registered agent=${agent_id} tool=${tool.name} kind=${tool.handler_kind}"
  rep 201 tool

# ── List tools for an agent ───────────────────────────────────────────────────
http.on :get "/agents/:id/tools" \req ->
  agent_id = str.int req.params.id
  agent = db.one "select id from agents where id=$1" [agent_id]
  if !agent
    ret rep 404 {error:"agent not found"}
  tools_rows = db.q "select * from tools where agent_id=$1 order by id" [agent_id]
  rep 200 {agent_id:agent_id tools:tools_rows}

# ── Read all memory for an agent ──────────────────────────────────────────────
http.on :get "/agents/:id/memory" \req ->
  agent_id = str.int req.params.id
  agent = db.one "select id from agents where id=$1" [agent_id]
  if !agent
    ret rep 404 {error:"agent not found"}
  mem = memory.mem_load_all agent_id
  rep 200 {agent_id:agent_id memory:mem}

# ── Delete a memory key for an agent ─────────────────────────────────────────
http.on :del "/agents/:id/memory/:key" \req ->
  agent_id = str.int req.params.id
  key = req.params.key
  agent = db.one "select id from agents where id=$1" [agent_id]
  if !agent
    ret rep 404 {error:"agent not found"}
  memory.mem_del agent_id key
  rep 200 {ok:true deleted:key}
