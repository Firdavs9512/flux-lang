# Main HTTP server: REST API for the agent platform
use http db json
use ./agents
use ./conversations as conv
use ./builtin_tools
use ./memory
use ./runtime
use ./cron_jobs

# Middleware: extract auth header, get user_id
fn get_user_id req
  auth = req.headers.authorization ?? ""
  if str.len auth == 0
    ret nil
  # In production: validate JWT, get user_id from claims
  # For now, extract from "Bearer <user_id>" format
  parts = str.split auth " "
  if parts.len >= 2
    ret parts.1
  ret nil

# Error response helper
fn error_response status message
  ret rep status {error: message}

# =============================================================================
# AGENT ENDPOINTS
# =============================================================================

# POST /agents - create a new agent
http.on :post "/agents" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  body = req.body
  if !body.name | !body.system_prompt | !body.model
    ret error_response 400 "Missing required fields: name, system_prompt, model"

  agent = agents.create_agent user_id body.name body.system_prompt body.model
  ret rep 201 agent

# GET /agents - list agents for current user
http.on :get "/agents" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_list = agents.list_agents user_id
  ret rep 200 {agents: agent_list}

# GET /agents/:id - get agent details
http.on :get "/agents/:id" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  ret rep 200 agent_rec

# PATCH /agents/:id - update agent
http.on :patch "/agents/:id" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  updates = req.body
  updated = agents.update_agent agent_id updates
  ret rep 200 updated

# =============================================================================
# TOOL ENDPOINTS
# =============================================================================

# POST /agents/:id/tools - register a tool for an agent
http.on :post "/agents/:id/tools" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  body = req.body
  if !body.name | !body.description | !body.handler_kind
    ret error_response 400 "Missing required fields: name, description, handler_kind"

  tool = agents.register_tool agent_id body.name body.description (body.params_schema ?? {}) body.handler_kind (body.webhook_url ?? nil)
  ret rep 201 tool

# GET /agents/:id/tools - list tools for an agent
http.on :get "/agents/:id/tools" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  tools_list = agents.get_agent_tools agent_id
  ret rep 200 {tools: tools_list}

# DELETE /agents/:agent_id/tools/:tool_id - delete a tool
http.on :del "/agents/:agent_id/tools/:tool_id" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.agent_id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  tool_id = str.int req.params.tool_id
  agents.delete_tool tool_id
  ret rep 204 nil

# =============================================================================
# CONVERSATION ENDPOINTS
# =============================================================================

# POST /agents/:id/conversations - start a new conversation
http.on :post "/agents/:id/conversations" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  conversation = conv.create_conversation agent_id user_id
  ret rep 201 conversation

# GET /conversations/:id - get conversation details and history
http.on :get "/conversations/:id" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  conv_id = str.int req.params.id
  conversation = conv.get_conversation conv_id

  if !conversation
    ret error_response 404 "Conversation not found"

  # Check auth: verify user owns the agent
  agent_rec = agents.get_agent conversation.agent_id
  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  history = conv.get_history conv_id

  ret rep 200 {
    conversation: conversation
    messages: history
  }

# POST /conversations/:id/messages - send a message and run the agent
http.on :post "/conversations/:id/messages" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  conv_id = str.int req.params.id
  conversation = conv.get_conversation conv_id

  if !conversation
    ret error_response 404 "Conversation not found"

  # Check auth
  agent_rec = agents.get_agent conversation.agent_id
  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  body = req.body
  if !body.message
    ret error_response 400 "Missing field: message"

  # Store user message
  user_msg = conv.add_message conv_id :user body.message nil nil nil nil nil nil

  # Run the agent
  result = runtime.run_agent_loop conv_id body.message

  ret rep 200 {
    agent_response: result.reply
    tool_calls: result.tool_calls
    total_cost: result.total_cost
    total_ms: result.total_ms
    turns: result.turns
    confidence: result.confidence
  }

# =============================================================================
# MEMORY ENDPOINTS (agent reads/writes own memory)
# =============================================================================

# GET /agents/:id/memory/:key - read memory
http.on :get "/agents/:id/memory/:key" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  key = req.params.key
  value = memory.get_memory agent_id key

  ret rep 200 {key: key value: value found: !(value == nil)}

# POST /agents/:id/memory/:key - write memory
http.on :post "/agents/:id/memory/:key" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  key = req.params.key
  body = req.body

  if !body.value
    ret error_response 400 "Missing field: value"

  memory.set_memory agent_id key body.value

  ret rep 200 {key: key value: body.value status: :ok}

# =============================================================================
# USAGE & ANALYTICS ENDPOINTS
# =============================================================================

# GET /agents/:id/usage - get usage stats for an agent
http.on :get "/agents/:id/usage" \req ->
  user_id = get_user_id req
  if !user_id
    ret error_response 401 "Unauthorized"

  agent_id = str.int req.params.id
  agent_rec = agents.get_agent agent_id

  if !agent_rec
    ret error_response 404 "Agent not found"

  if agent_rec.owner != user_id
    ret error_response 403 "Forbidden"

  # Get usage stats (last 30 days)
  usage_rows = db.q "select date, conversations, messages, tool_calls, total_cost, total_tokens from agent_usage where agent_id=$1 and date >= $2 order by date desc" [agent_id time.ago 30 :day]

  ret rep 200 {usage: usage_rows}

# Health check
http.on :get "/health" \req ->
  ret rep 200 {status: :ok service: "agent-platform"}

# Start the HTTP server on port 8080
log "Starting agent platform server on port 8080"
http.serve 8080

# Initialize cron jobs
cron_jobs.setup_crons
