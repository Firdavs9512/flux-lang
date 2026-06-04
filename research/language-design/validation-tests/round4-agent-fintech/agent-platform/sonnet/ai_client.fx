# ai_client.fx — thin wrapper around the `ai` battery with cost tracking
# Exposes helpers used by the runtime loop.
# Named "ai_client" (not "ai") to avoid clashing with the built-in ai battery.

use ai db
use ./schema as _schema  # SPEC GAP: imported only for side-effects (tbl defs)
                          # The `as _schema` alias avoids name pollution.

# ── Accumulate token/cost metadata from an ai.* call into conversation_cost ──
fn record_cost conversation_id result
  tokens = result._.tokens ?? 0
  cost   = result._.cost   ?? 0.0
  existing = db.one "select id, tokens, cost from conversation_cost where conversation_id=$1" [conversation_id]
  if existing
    db.up "conversation_cost" {tokens:existing.tokens + tokens cost:existing.cost + cost} {id:existing.id}
  else
    db.ins "conversation_cost" {conversation_id:conversation_id tokens:tokens cost:cost}

# ── Build a combined system prompt for the agent ─────────────────────────────
exp fn build_system_prompt agent memory_summary tool_list_str
  parts <- []
  parts <- parts.push agent.system_prompt
  if memory_summary != "No persistent memory stored."
    parts <- parts.push "\n## Persistent Memory\n${memory_summary}"
  if tool_list_str != ""
    parts <- parts.push "\n## Available Tools\n${tool_list_str}"
  ret parts.join "\n"

# ── Call the LLM for a structured JSON tool-call decision ────────────────────
# Returns {action: :reply|:tool_call, content: str, tool_calls: list}
# SPEC GAP: ai.json with a schema that includes union / conditional shapes
# is not clearly defined. We use the closest approximation.
exp fn llm_decide conversation_id system_prompt history_text user_text tools_schema
  prompt = "${system_prompt}\n\n## Conversation History\n${history_text}\n\nUser: ${user_text}"

  result = ai.json prompt {
    action:":reply|:tool_call"
    content:str
    tool_calls:[{name:str arguments:{}}]
    reasoning:str
  }

  record_cost conversation_id result
  ret result

# ── Plain text LLM call (final reply synthesis with no tool calls) ────────────
exp fn llm_reply conversation_id system_prompt history_text
  prompt = "${system_prompt}\n\n## Conversation History\n${history_text}\n\nProvide your final reply to the user based on all tool results above."
  result = ai.ask prompt
  record_cost conversation_id result
  ret result

# ── Check confidence of a decision ───────────────────────────────────────────
exp fn confidence_tier result
  conf = result._.conf ?? 1.0
  if conf > 0.85
    ret :high
  elif conf >= 0.6
    ret :medium
  ret :low
