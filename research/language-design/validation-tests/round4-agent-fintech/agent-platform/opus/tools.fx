# tools.fx — built-in tool implementations + dynamic dispatch.
#
# The agent loop produces tool calls as {name, input}. We must run the
# right code given a runtime STRING name. The spec has no first-class
# "call function by string name" (no reflection / no fn-from-string), so
# we dispatch on the tool's `handler_kind` symbol via `match`. This is
# the documented work-around for dynamic dispatch (see spec-gaps).
#
# Each handler takes (agent_id, input-map) and returns a result map.
# Errors are returned as {ok:false error:...} rather than thrown, so the
# loop can feed the failure back to the LLM instead of aborting.

use http json
use ./memory as mem

# --- web_search: stubbed via http.get against a search endpoint ---
fn web_search agent_id input
  q = input.query ?? ""
  if q == ""
    ret {ok:false error:"query required"}
  url = "https://api.search.example/q?text=${q}"
  res = http.get url
  if res.status >= 400
    ret {ok:false error:"search upstream ${res.status}"}
  # res.body is JSON→map per spec. Normalize to a results list.
  ret {ok:true query:q results:(res.body.results ?? [])}

# --- calculator: a tiny safe evaluator over {op a b} ---
# We do NOT eval arbitrary strings (no eval in spec, and unsafe). The
# tool schema is {op: ":add|:sub|:mul|:div", a:flt, b:flt}.
fn calculator agent_id input
  a = input.a ?? 0
  b = input.b ?? 0
  op = input.op ?? :add
  # Guard division-by-zero before the match so every arm is single-line
  # (the spec only documents single-line match arms).
  if op == :div & b == 0
    ret {ok:false error:"division by zero"}
  match op
    :add -> ret {ok:true result:(a + b)}
    :sub -> ret {ok:true result:(a - b)}
    :mul -> ret {ok:true result:(a * b)}
    :div -> ret {ok:true result:(a / b)}
    _ -> ret {ok:false error:"unknown op ${op}"}

# --- get_memory: read agent's persistent memory ---
fn get_memory agent_id input
  key = input.key ?? ""
  if key == ""
    ret {ok:false error:"key required"}
  ret {ok:true key:key value:(mem.get agent_id key)}

# --- set_memory: write agent's persistent memory across conversations ---
fn set_memory agent_id input
  key = input.key ?? ""
  if key == ""
    ret {ok:false error:"key required"}
  mem.set agent_id key input.value
  ret {ok:true key:key value:input.value}

# --- generic http tool (registered per-agent, kind :http) ---
fn http_call agent_id input
  url = input.url ?? ""
  if url == ""
    ret {ok:false error:"url required"}
  method = input.method ?? :get
  res <- nil
  match method
    :post -> res <- http.post url (input.body ?? {})
    _ -> res <- http.get url
  ret {ok:(res.status < 400) status:res.status body:res.body}

# dispatch: given a tool ROW (with handler_kind) + input, run it.
# This is our dynamic dispatch surface. Returns a result map; never
# throws — failures become {ok:false error:...}.
exp fn dispatch tool agent_id input
  match tool.handler_kind
    :web_search -> ret (web_search agent_id input)
    :calculator -> ret (calculator agent_id input)
    :get_memory -> ret (get_memory agent_id input)
    :set_memory -> ret (set_memory agent_id input)
    :http       -> ret (http_call agent_id input)
    _ -> ret {ok:false error:"no handler for kind ${tool.handler_kind}"}

# The built-in tool catalog every agent gets for free. Used when
# seeding a new agent and when building the ai.run tool list. The
# params_schema strings are passed to the LLM so it knows the shape.
exp builtin_catalog = [
  {name:"web_search"
   description:"Search the web for up-to-date information."
   handler_kind::web_search
   destructive:false
   params_schema:{query:"str"}}
  {name:"calculator"
   description:"Do arithmetic. op is one of add/sub/mul/div."
   handler_kind::calculator
   destructive:false
   params_schema:{op:":add|:sub|:mul|:div" a:"flt" b:"flt"}}
  {name:"get_memory"
   description:"Read a value from your persistent memory by key."
   handler_kind::get_memory
   destructive:false
   params_schema:{key:"str"}}
  {name:"set_memory"
   description:"Store a value in your persistent memory under a key."
   handler_kind::set_memory
   destructive:true
   params_schema:{key:"str" value:"any"}}
]
