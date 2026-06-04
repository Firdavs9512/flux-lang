# runtime.fx — the core agentic tool-loop
# Loads agent context, runs the LLM → tool-dispatch → feed-back loop,
# persists every step, and returns the final assistant reply.

use db
use ./memory
use ./tools_builtin as tb
use ./ai_client as aic

# Maximum tool-call rounds before we force a final reply (safety limit).
max_rounds = 8

# ── DESTRUCTIVE TOOL LIST — requires confirmation before execution ────────────
destructive_tools = ["set_memory" "web_search"]

# ── Load the agent's registered tools from DB ─────────────────────────────────
fn load_agent_tools agent_id
  db.q "select id, name, description, params_schema, handler_kind from tools where agent_id=$1" [agent_id]

# ── Build the tool list string injected into the system prompt ────────────────
fn tools_to_prompt_str tool_rows builtin_rows
  all_tools <- []
  each t in builtin_rows
    all_tools <- all_tools.push "- ${t.name}: ${t.description}"
  each t in tool_rows
    all_tools <- all_tools.push "- ${t.name}: ${t.description}"
  ret all_tools.join "\n"

# ── Build conversation history text from stored messages ──────────────────────
fn build_history_text conversation_id
  msgs = db.q "select role, content from messages where conversation_id=$1 order by created asc" [conversation_id]
  lines <- []
  each m in msgs
    role_label = match m.role
      :user      -> "User"
      :assistant -> "Assistant"
      :tool      -> "Tool Result"
      _          -> "System"
    lines <- lines.push "${role_label}: ${m.content}"
  ret lines.join "\n"

# ── Persist a message row ──────────────────────────────────────────────────────
fn save_message conversation_id role content tool_calls
  db.ins "messages" {
    conversation_id: conversation_id
    role: role
    content: content
    tool_calls: tool_calls
  }

# ── Execute a single tool call and record timing + audit log ──────────────────
# SPEC GAP: no native time.now arithmetic for elapsed ms.
# We assume time.now returns an integer-compatible epoch value and use subtraction.
fn execute_tool agent_id msg_id tool_name raw_input
  start = time.now
  # Determine if this is a builtin or a registered tool
  registered = db.one "select handler_kind from tools where agent_id=$1 and name=$2" [agent_id tool_name]

  output <- {ok:false error:"tool not found"}
  if registered
    match registered.handler_kind
      :builtin ->
        # Inject agent_id for memory tools automatically
        enriched_input = raw_input.set "agent_id" agent_id
        output <- tb.dispatch_builtin tool_name enriched_input
      :http ->
        # SPEC GAP: dynamic HTTP dispatch — we POST to a handler_url stored
        # in params_schema.handler_url (convention, not in spec).
        tool_row = db.one "select params_schema from tools where agent_id=$1 and name=$2" [agent_id tool_name]
        handler_url = tool_row.params_schema.handler_url ?? ""
        if handler_url == ""
          output <- {ok:false error:"no handler_url for http tool ${tool_name}"}
        else
          res = http.post handler_url raw_input
          output <- res.body
      :queue ->
        queue.push tool_name {agent_id:agent_id input:raw_input}
        output <- {ok:true queued:true}
      _ ->
        output <- tb.dispatch_builtin tool_name (raw_input.set "agent_id" agent_id)
  else
    # Fall back to built-in dispatch
    output <- tb.dispatch_builtin tool_name (raw_input.set "agent_id" agent_id)

  elapsed = time.now - start  # SPEC GAP: elapsed ms calculation — assumes numeric timestamps
  success = output.ok ?? false

  db.ins "tool_invocations" {
    message_id: msg_id
    tool_name:  tool_name
    input:      raw_input
    output:     output
    ms:         elapsed
    ok:         success
  }

  ret output

# ── Safety / confidence layer before executing a tool ────────────────────────
# Returns :proceed, :confirm_needed, or :blocked
fn check_tool_safety tool_name conf
  is_destructive = destructive_tools.has tool_name
  if conf < 0.6
    ret :blocked
  elif is_destructive & conf < 0.85
    ret :confirm_needed
  ret :proceed

# ── Main agentic loop ─────────────────────────────────────────────────────────
# Returns {reply: str, rounds: int, tool_calls_count: int, pending_confirmation: map|nil}
exp fn run_agent_loop agent_id conversation_id user_text
  # 1. Load agent config
  agent = db.one "select id, name, system_prompt, model, status from agents where id=$1" [agent_id]!
  if agent.status != :active
    fail "Agent ${agent.name} is not active (status: ${agent.status})"

  # 2. Persist the incoming user message
  save_message conversation_id :user user_text nil

  # 3. Load context: memory + tools
  mem_summary  = memory.mem_summary agent_id
  agent_tools  = load_agent_tools agent_id
  all_tools_str = tools_to_prompt_str agent_tools tb.builtin_catalog

  system_prompt = aic.build_system_prompt agent mem_summary all_tools_str

  # Mutable loop state
  rounds <- 0
  tool_calls_count <- 0
  final_reply <- ""
  done <- false
  pending_confirmation <- nil  # set if a tool needs user confirmation

  each _round in 1..max_rounds
    if done
      stop
    rounds <- rounds + 1

    history_text = build_history_text conversation_id

    decision = aic.llm_decide conversation_id system_prompt history_text user_text all_tools_str

    tier = aic.confidence_tier decision

    # Low confidence: escalate, do not execute anything
    if tier == :low
      final_reply <- "I'm not confident enough to proceed with this request. Please clarify or rephrase."
      save_message conversation_id :assistant final_reply nil
      done <- true
      stop

    action = decision.action ?? :reply

    if action == :reply
      final_reply <- decision.content ?? ""
      save_message conversation_id :assistant final_reply nil
      done <- true
      stop

    # action == :tool_call — execute each requested tool in sequence
    tool_calls = decision.tool_calls ?? []
    if tool_calls.len == 0
      final_reply <- decision.content ?? "Done."
      save_message conversation_id :assistant final_reply nil
      done <- true
      stop

    # Persist the assistant's tool-call intent as a message
    intent_msg = save_message conversation_id :assistant (decision.content ?? "") (json.enc tool_calls)

    # Execute tools
    tool_results <- []
    each tc in tool_calls
      tool_name = tc.name
      raw_input = tc.arguments ?? {}

      conf = decision._.conf ?? 1.0
      safety = check_tool_safety tool_name conf

      if safety == :blocked
        result = {ok:false error:"Tool call blocked — low confidence (${conf})"}
        tool_results <- tool_results.push {tool:tool_name result:result}
        skip

      elif safety == :confirm_needed
        # SPEC GAP: no suspend/resume mechanism.
        # We store the pending tool call in DB and return early with a prompt.
        pending_data = {
          conversation_id: conversation_id
          tool_name: tool_name
          input: raw_input
          rounds: rounds
        }
        db.ins "tool_invocations" {
          message_id: intent_msg.id
          tool_name:  tool_name
          input:      raw_input
          output:     {ok:false pending:true}
          ms:         0
          ok:         false
        }
        pending_confirmation <- pending_data
        done <- true
        stop

      else
        result = execute_tool agent_id intent_msg.id tool_name raw_input
        tool_results <- tool_results.push {tool:tool_name result:result}
        tool_calls_count <- tool_calls_count + 1

    if done
      stop

    # Feed tool results back into history as a :tool message
    results_text <- []
    each tr in tool_results
      results_text <- results_text.push "Tool ${tr.tool}: ${json.enc tr.result}"
    save_message conversation_id :tool (results_text.join "\n") nil

  # If loop exhausted rounds without a final reply, ask LLM to summarise
  if !done | final_reply == ""
    history_text = build_history_text conversation_id
    final_reply <- aic.llm_reply conversation_id system_prompt history_text
    save_message conversation_id :assistant final_reply nil

  ret {
    reply:                final_reply
    rounds:               rounds
    tool_calls_count:     tool_calls_count
    pending_confirmation: pending_confirmation
  }

# ── Resume a paused tool execution (user confirmed) ───────────────────────────
# Called by the HTTP handler when the user POSTs a confirmation.
exp fn resume_tool_execution agent_id conversation_id tool_name raw_input
  agent = db.one "select id from agents where id=$1" [agent_id]!
  # Find the last assistant message in the conversation to attach invocation to
  last_msg = db.one "select id from messages where conversation_id=$1 and role='assistant' order by created desc limit 1" [conversation_id]
  msg_id = last_msg.id ?? 0

  result = execute_tool agent_id msg_id tool_name raw_input

  # Feed result back and continue looping toward a final reply
  results_text = "Tool ${tool_name}: ${json.enc result}"
  save_message conversation_id :tool results_text nil

  mem_summary   = memory.mem_summary agent_id
  agent_tools   = load_agent_tools agent_id
  all_tools_str = tools_to_prompt_str agent_tools tb.builtin_catalog
  agent_row     = db.one "select id, name, system_prompt, model, status from agents where id=$1" [agent_id]!
  system_prompt = aic.build_system_prompt agent_row mem_summary all_tools_str
  history_text  = build_history_text conversation_id
  final_reply   = aic.llm_reply conversation_id system_prompt history_text
  save_message conversation_id :assistant final_reply nil
  ret {reply:final_reply confirmed:true}
