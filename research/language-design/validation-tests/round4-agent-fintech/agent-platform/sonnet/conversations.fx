# conversations.fx — HTTP routes for conversations and the core run endpoint
#
# POST /conversations                         — start a conversation
# GET  /conversations/:id                     — fetch conversation + messages
# POST /conversations/:id/messages            — post a user message → RUN AGENT
# POST /conversations/:id/confirm             — resume a pending tool confirmation
# GET  /conversations/:id/cost                — token/cost summary

use http db
use ./runtime

# ── Start a conversation ──────────────────────────────────────────────────────
http.on :post "/conversations" \req ->
  if !req.body.agent_id
    ret rep 400 {error:"agent_id required"}
  if !req.body.user_id
    ret rep 400 {error:"user_id required"}

  agent_id = req.body.agent_id
  user_id  = req.body.user_id

  agent = db.one "select id, status from agents where id=$1" [agent_id]
  if !agent
    ret rep 404 {error:"agent not found"}
  if agent.status != :active
    ret rep 422 {error:"agent is not active"}

  conv = db.ins "conversations" {agent_id:agent_id user_id:user_id}
  log "conversation started id=${conv.id} agent=${agent_id} user=${user_id}"
  rep 201 conv

# ── Get conversation with messages ───────────────────────────────────────────
http.on :get "/conversations/:id" \req ->
  conv_id = str.int req.params.id
  conv = db.one "select * from conversations where id=$1" [conv_id]
  if !conv
    ret rep 404 {error:"conversation not found"}
  msgs = db.q "select * from messages where conversation_id=$1 order by created asc" [conv_id]
  rep 200 {conversation:conv messages:msgs}

# ── POST a user message → run the agent ──────────────────────────────────────
# This is THE CORE endpoint — triggers the full agentic tool-loop.
http.on :post "/conversations/:id/messages" \req ->
  conv_id = str.int req.params.id

  if !req.body.content
    ret rep 400 {error:"content required"}

  conv = db.one "select * from conversations where id=$1" [conv_id]
  if !conv
    ret rep 404 {error:"conversation not found"}

  user_text = req.body.content

  # Run the agentic loop (may call tools, loop multiple rounds)
  result = runtime.run_agent_loop conv.agent_id conv_id user_text

  # If a tool needs user confirmation, return 202 Accepted with details
  if result.pending_confirmation != nil
    ret rep 202 {
      status:            "awaiting_confirmation"
      pending:           result.pending_confirmation
      partial_reply:     result.reply
      rounds_completed:  result.rounds
      tool_calls_so_far: result.tool_calls_count
    }

  rep 200 {
    reply:           result.reply
    rounds:          result.rounds
    tool_calls_count: result.tool_calls_count
    conversation_id: conv_id
  }

# ── User confirms a pending tool call ────────────────────────────────────────
http.on :post "/conversations/:id/confirm" \req ->
  conv_id = str.int req.params.id

  if !req.body.tool_name
    ret rep 400 {error:"tool_name required"}

  conv = db.one "select * from conversations where id=$1" [conv_id]
  if !conv
    ret rep 404 {error:"conversation not found"}

  tool_name = req.body.tool_name
  raw_input = req.body.input ?? {}

  result = runtime.resume_tool_execution conv.agent_id conv_id tool_name raw_input

  rep 200 {
    reply:           result.reply
    confirmed:       result.confirmed
    conversation_id: conv_id
  }

# ── Token / cost summary for a conversation ───────────────────────────────────
http.on :get "/conversations/:id/cost" \req ->
  conv_id = str.int req.params.id
  conv = db.one "select id from conversations where id=$1" [conv_id]
  if !conv
    ret rep 404 {error:"conversation not found"}

  cost_row = db.one "select tokens, cost from conversation_cost where conversation_id=$1" [conv_id]
  if !cost_row
    ret rep 200 {conversation_id:conv_id tokens:0 cost:0.0}

  rep 200 {
    conversation_id: conv_id
    tokens:          cost_row.tokens ?? 0
    cost:            cost_row.cost   ?? 0.0
  }

# ── Tool invocation log for a conversation ────────────────────────────────────
http.on :get "/conversations/:id/tool-log" \req ->
  conv_id = str.int req.params.id
  conv = db.one "select id from conversations where id=$1" [conv_id]
  if !conv
    ret rep 404 {error:"conversation not found"}

  invocations = db.q "
    select ti.id, ti.tool_name, ti.input, ti.output, ti.ms, ti.ok, ti.message_id
    from tool_invocations ti
    join messages m on m.id = ti.message_id
    where m.conversation_id = $1
    order by ti.id asc
  " [conv_id]

  rep 200 {conversation_id:conv_id invocations:invocations}
