# runtime.fx — the CORE agentic loop.
#
# Flow for one user message:
#   1. persist the user message
#   2. load system prompt + persistent memory + available tools
#   3. loop:
#        ask LLM for next step (manual tool-loop via llm.decide)
#        track cost/tokens onto the conversation
#        if :final  -> persist assistant message, return reply
#        if :call   -> safety/confidence gate -> maybe confirmation;
#                      else dispatch the tool by name, LOG the
#                      invocation with timing, feed result back
#   4. cap iterations so a misbehaving model can't loop forever
#
# Confidence/safety layer:
#   - confidence > 0.85           : auto-run
#   - 0.6..0.85 OR destructive    : require confirmation
#   - < 0.6                       : require confirmation (escalate)

use db json time
use ./agents as agents
use ./tools as tools
use ./llm as llm
use ./memory as mem

max_steps = 8
high_conf = 0.85
low_conf  = 0.6

# Persist a message row. tool_calls defaults to [].
fn save_msg conv_id role content tool_calls
  ret db.ins "messages" {
    conversation:conv_id
    role:role
    content:content
    tool_calls:(tool_calls ?? [])
  }

# Add token/cost usage onto the conversation total (mutable accumulation
# in the DB, since conversation state outlives this request).
fn add_usage conv_id u
  c = db.one "select total_tokens, total_cost from conversations where id=$1" [conv_id]
  db.up "conversations" {
    total_tokens:((c.total_tokens ?? 0) + u.tokens)
    total_cost:((c.total_cost ?? 0.0) + u.cost)
  } {id:conv_id}

# Build the tool-catalog text shown to the model.
fn tools_text tool_rows
  lines <- []
  each t in tool_rows
    lines <- lines.push "- ${t.name} — ${t.description} — params: ${json.enc t.params_schema}"
  ret lines.join "\n"

# Build the transcript text from persisted messages.
fn transcript_text conv_id
  rows = db.q "select role, content from messages where conversation=$1 order by id" [conv_id]
  lines <- []
  each m in rows
    lines <- lines.push "${m.role}: ${m.content}"
  ret lines.join "\n"

# Decide whether a tool call needs confirmation. Returns a reason string
# if confirmation is needed, else nil.
fn needs_confirm tool conf
  if tool.destructive
    ret "destructive tool"
  if conf < low_conf
    ret "low confidence (${conf})"
  if conf < high_conf
    ret "medium confidence (${conf})"
  ret nil

# Create a pending confirmation and stop the loop until the user acts.
fn request_confirm conv_id agent_id tool input reason
  c = db.ins "confirmations" {
    conversation:conv_id
    agent:agent_id
    tool_name:tool.name
    input:input
    reason:reason
    status::pending
  }
  ret {status::needs_confirmation confirmation_id:c.id tool:tool.name reason:reason}

# Run one tool call: dispatch by name, log invocation w/ timing.
# `assistant_msg_id` is the message that requested the call (FK target).
fn run_tool agent_id conv_id assistant_msg_id tool input
  t0 = time.now
  result = tools.dispatch tool agent_id input
  t1 = time.now
  ok = result.ok ?? true
  inv = db.ins "tool_invocations" {
    message:assistant_msg_id
    tool_name:tool.name
    input:input
    output:result
    ms:(t1 - t0)
    ok:ok
  }
  # Persist a :tool message carrying the result back into the transcript.
  save_msg conv_id :tool "tool ${tool.name} -> ${json.enc result}" []
  ret result

# The main entry point: run the agent for a freshly-posted user message.
# Returns a map describing the outcome (final reply OR a confirmation
# request the caller must surface to the user).
exp fn run agent_id conv_id user_text
  agent = db.one "select * from agents where id=$1" [agent_id]
  if !agent
    fail "agent not found"
  if agent.status != :active
    fail "agent not active"

  # 1. persist the user's message
  save_msg conv_id :user user_text []

  # 2. load context
  tool_rows = agents.tools_for agent_id
  tt = tools_text tool_rows
  mem_text = mem.render agent_id

  # 3. bounded loop
  step <- 0
  each i in 1..max_steps
    step <- i
    tx = transcript_text conv_id
    decision = llm.decide agent.system_prompt mem_text tt tx
    u = llm.usage decision
    add_usage conv_id u
    conf = decision.confidence ?? (u.conf)

    if decision.action == :final
      msg = save_msg conv_id :assistant (decision.answer ?? "") []
      ret {status::done reply:(decision.answer ?? "") steps:step msg_id:msg.id}

    # action == :call
    tool = agents.tool_by_name agent_id (decision.tool ?? "")
    if !tool
      # Tell the model it asked for a nonexistent tool and let it retry.
      save_msg conv_id :tool "error: unknown tool ${decision.tool}" []
      skip

    reason = needs_confirm tool conf
    if reason
      # Record the assistant's intent, then pause for confirmation.
      save_msg conv_id :assistant (decision.reasoning ?? "calling ${tool.name}") [
        {name:tool.name input:(decision.input ?? {})}
      ]
      ret (request_confirm conv_id agent_id tool (decision.input ?? {}) reason)

    # auto-run path
    amsg = save_msg conv_id :assistant (decision.reasoning ?? "calling ${tool.name}") [
      {name:tool.name input:(decision.input ?? {})}
    ]
    run_tool agent_id conv_id amsg.id tool (decision.input ?? {})
    # loop continues: the tool result is now in the transcript

  # Loop exhausted without a final answer.
  fallback = llm.ask "Summarize a final answer for the user from the conversation."
  msg = save_msg conv_id :assistant fallback []
  ret {status::done reply:fallback steps:step capped:true msg_id:msg.id}

# Resume after a user approves/denies a pending confirmation. On approve
# we run the gated tool, then continue the agent loop normally.
exp fn resume conv_id confirmation_id approve
  conf = db.one "select * from confirmations where id=$1" [confirmation_id]
  if !conf
    fail "confirmation not found"
  if conf.status != :pending
    fail "confirmation already resolved"

  if !approve
    db.up "confirmations" {status::denied} {id:confirmation_id}
    save_msg conf.conversation :tool "user DENIED tool ${conf.tool_name}" []
    # Let the agent react to the denial.
    ret (run conf.agent conf.conversation "(the requested tool was denied; continue)")

  db.up "confirmations" {status::approved} {id:confirmation_id}
  tool = agents.tool_by_name conf.agent conf.tool_name
  if !tool
    fail "tool no longer exists"
  amsg = save_msg conf.conversation :assistant "approved: running ${conf.tool_name}" [
    {name:conf.tool_name input:conf.input}
  ]
  run_tool conf.agent conf.conversation amsg.id tool conf.input
  # Continue the loop so the agent can use the tool result.
  ret (run conf.agent conf.conversation "(tool approved and executed; continue)")
