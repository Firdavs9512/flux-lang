# The agentic loop: orchestrates tool-calling, execution, and looping
use ai json http
use ./agents
use ./conversations as conv
use ./builtin_tools
use ./memory

# Configuration for the agentic loop
AGENT_MAX_TURNS = 15
TOOL_CONFIDENCE_THRESHOLD = 0.7

# The main agent run: takes a user message, runs the loop until final answer
# Returns {reply, tool_calls_made, total_cost, total_ms}
exp fn run_agent_loop conversation_id user_message
  conv_rec = conv.get_conversation conversation_id
  agent_rec = agents.get_agent conv_rec.agent_id

  # Load agent's tools and memory
  agent_tools = agents.get_agent_tools agent_rec.id
  agent_memory = memory.load_memory agent_rec.id

  # Build available tools list for AI context
  tools_desc <- ""
  each t in agent_tools
    tools_desc <- tools_desc + "\n- ${t.name}: ${t.description}"

  # Build memory context (for system prompt injection)
  memory_context <- "Agent Memory: "
  if agent_memory.len > 0
    each k, v in agent_memory
      memory_context <- memory_context + "\n  ${k}: ${json.enc v}"
  else
    memory_context <- memory_context + "(empty)"

  # Build initial system prompt with tools and memory
  system_msg = agent_rec.system_prompt + "\n\nAvailable Tools:" + tools_desc + "\n\n" + memory_context

  # Initialize conversation history for the AI
  history = conv.get_history conversation_id
  messages <- history

  # Add the new user message
  user_msg_obj = {role: :user content: user_message}
  messages <- messages.push user_msg_obj

  # Track metrics across the loop
  total_cost <- 0
  total_ms <- 0
  total_tokens_in <- 0
  total_tokens_out <- 0
  tool_calls_made <- []
  turn <- 0
  final_reply <- nil

  # Agentic loop: keep going until no tool calls or max turns
  each iteration in 1..AGENT_MAX_TURNS
    turn <- iteration

    # Call AI to get next action/response
    # NOTE: This is where the spec is ambiguous. We use ai.json to get tool calls.
    # In a real system, we'd use ai.run which handles the loop internally.
    # Here we implement the loop manually for control.

    ai_prompt = "You are an AI agent. Use tools to help answer the user's question. When you have the answer, respond directly (no tool calls). Format tool calls as JSON list: [{\"name\": \"tool_name\", \"input\": {...}}]"

    # Build messages for AI context (simplified: just feed history)
    # In production: use proper message format for multi-turn
    context_text = ""
    each m in messages
      if m.role == :user
        context_text <- context_text + "\nUser: ${m.content}"
      elif m.role == :assistant
        context_text <- context_text + "\nAssistant: ${m.content}"

    # Call AI to decide: respond or call tool?
    # Strategy: use ai.json with a structured response format
    ai_decision = ai.json "${system_msg}\n\nConversation:\n${context_text}\n\nRespond with either:\n1. A final answer (field 'response')\n2. Tool calls (field 'tool_calls' with array of {name, input})" {
      response: ":str|nil"
      tool_calls: "[{name:str input:map}]|nil"
    }

    total_cost <- total_cost + (ai_decision._.cost ?? 0)
    total_ms <- total_ms + (ai_decision._.ms ?? 0)
    total_tokens_in <- total_tokens_in + (ai_decision._.tokens ?? 0)

    # Check confidence
    conf = ai_decision._.conf ?? 0.5

    # Handle the AI's decision
    if ai_decision.tool_calls
      # Tool calls detected: execute them
      tool_results <- []

      each tc in ai_decision.tool_calls
        tool_name = tc.name
        input_params = tc.input

        # Log the tool call
        log "TOOL_CALL: ${tool_name} with ${json.enc input_params}"

        # Dispatch: builtin or custom?
        # First check if it's a builtin
        is_builtin = tool_name == "web_search" | tool_name == "calculator" | tool_name == "get_memory" | tool_name == "set_memory"

        start_ms = time.now

        result <- nil
        error <- nil

        if is_builtin
          # Execute builtin
          result = builtin_tools.dispatch_builtin tool_name agent_rec.id input_params
        else
          # Try to find custom tool and call via webhook
          found_tool = nil
          each t in agent_tools
            if t.name == tool_name
              found_tool <- t
              skip

          if found_tool
            # Call webhook if configured
            if found_tool.webhook_url
              wh_res = http.post found_tool.webhook_url input_params
              if wh_res.status >= 200 & wh_res.status < 300
                result <- json.dec wh_res.body
              else
                error <- "Webhook returned ${wh_res.status}"
            else
              error <- "Tool ${tool_name} has no webhook URL"
          else
            error <- "Tool ${tool_name} not found"

        end_ms = time.now
        exec_ms = end_ms - start_ms

        # Log the invocation
        tool_result_msg = nil
        tool_result_msg_id = nil

        # Store tool invocation
        if tool_result_msg_id
          conv.log_tool_invocation tool_result_msg_id tool_name input_params result error exec_ms (error == nil)

        # Collect result for context
        tool_res_obj = {
          name: tool_name
          input: input_params
          output: result
          error: error
          ok: (error == nil)
        }
        tool_results <- tool_results.push tool_res_obj
        tool_calls_made <- tool_calls_made.push {tool_name: tool_name input: input_params result: result error: error ms: exec_ms}

      # Add assistant message with tool calls
      assistant_msg = {
        role: :assistant
        content: "Calling tools..."
        tool_calls: ai_decision.tool_calls
        tool_results: tool_results
      }
      messages <- messages.push assistant_msg

      # Continue loop for next AI turn
    else
      # No tool calls: AI has responded with final answer
      final_reply <- ai_decision.response ?? "I could not determine a response."

      # Add final assistant message
      final_msg = {
        role: :assistant
        content: final_reply
        tool_calls: nil
      }
      messages <- messages.push final_msg

      # Exit loop
      stop

  # If we hit max turns without a final reply
  if !final_reply
    final_reply <- "Maximum conversation turns reached. Unable to complete request."

  # Store the conversation in the database
  # First, store assistant response with metrics
  msg_record = conv.add_message conversation_id :assistant final_reply nil nil total_cost total_tokens_in total_tokens_out total_ms

  # Store tool calls separately if any
  each tc in tool_calls_made
    conv.log_tool_invocation msg_record.id tc.tool_name tc.input tc.result tc.error tc.ms (tc.error == nil)

  ret {
    reply: final_reply
    tool_calls: tool_calls_made
    total_cost: total_cost
    total_ms: total_ms
    turns: turn
    confidence: (ai_decision._.conf ?? 0.5)
  }
