# main.fx — HTTP server wiring the AI agent platform together.
#
# Auth note (spec gap): the spec shows req.headers but no auth helper.
# We derive `owner` from the X-Owner-Id header for owner-scoping/isolation
# and treat missing as unauthorized. A real deploy would verify a token.

use http db json
use ./agents as agents
use ./conversations as convos
use ./runtime as runtime
use ./memory as mem
use ./jobs as jobs

# --- helpers ---------------------------------------------------------

fn owner_of req
  ret req.headers["x-owner-id"]

# --- agent CRUD ------------------------------------------------------

# Create/configure an agent.
http.on :post "/agents" \req ->
  owner = owner_of req
  if !owner
    ret rep 401 {error:"owner required"}
  if !req.body.name
    ret rep 400 {error:"name required"}
  if !req.body.system_prompt
    ret rep 400 {error:"system_prompt required"}
  rep 201 (agents.create (str.int owner) req.body.name req.body.system_prompt req.body.model)

http.on :get "/agents" \req ->
  owner = owner_of req
  if !owner
    ret rep 401 {error:"owner required"}
  rep 200 (agents.list (str.int owner))

http.on :get "/agents/:id" \req ->
  owner = owner_of req
  if !owner
    ret rep 401 {error:"owner required"}
  a = agents.get (str.int owner) (str.int req.params.id)
  if !a
    ret rep 404 {error:"not found"}
  rep 200 a

# Configure mutable agent fields (prompt/model/status).
http.on :patch "/agents/:id" \req ->
  owner = owner_of req
  if !owner
    ret rep 401 {error:"owner required"}
  rep 200 (agents.configure (str.int owner) (str.int req.params.id) req.body)

# --- tool registration ----------------------------------------------

http.on :post "/agents/:id/tools" \req ->
  owner = owner_of req
  if !owner
    ret rep 401 {error:"owner required"}
  if !req.body.name
    ret rep 400 {error:"tool name required"}
  rep 201 (agents.register_tool (str.int owner) (str.int req.params.id) req.body)

http.on :get "/agents/:id/tools" \req ->
  rep 200 (agents.tools_for (str.int req.params.id))

# --- agent memory (inspect/manage persistent state) -----------------

http.on :get "/agents/:id/memory" \req ->
  rep 200 (mem.dump (str.int req.params.id))

http.on :put "/agents/:id/memory/:key" \req ->
  rep 200 {key:req.params.key value:(mem.set (str.int req.params.id) req.params.key req.body.value)}

http.on :del "/agents/:id/memory/:key" \req ->
  mem.drop (str.int req.params.id) req.params.key
  rep 200 {ok:true}

# --- conversations ---------------------------------------------------

http.on :post "/agents/:id/conversations" \req ->
  owner = owner_of req
  if !owner
    ret rep 401 {error:"owner required"}
  if !req.body.user_id
    ret rep 400 {error:"user_id required"}
  rep 201 (convos.start (str.int owner) (str.int req.params.id) req.body.user_id)

http.on :get "/conversations/:id" \req ->
  c = convos.get (str.int req.params.id)
  if !c
    ret rep 404 {error:"not found"}
  rep 200 c

http.on :get "/conversations/:id/messages" \req ->
  rep 200 (convos.history (str.int req.params.id))

http.on :get "/conversations/:id/invocations" \req ->
  rep 200 (convos.invocations (str.int req.params.id))

# --- THE CORE: post a user message -> run the agent -----------------

http.on :post "/conversations/:id/messages" \req ->
  if !req.body.text
    ret rep 400 {error:"text required"}
  conv = convos.get (str.int req.params.id)
  if !conv
    ret rep 404 {error:"conversation not found"}
  result = runtime.run conv.agent conv.id req.body.text
  rep 200 result

# --- confirmation resolution (safety layer) -------------------------

http.on :get "/conversations/:id/confirmations" \req ->
  rep 200 (convos.pending_confirmations (str.int req.params.id))

http.on :post "/confirmations/:cid/resolve" \req ->
  conv = db.one "select conversation from confirmations where id=$1" [str.int req.params.cid]
  if !conv
    ret rep 404 {error:"confirmation not found"}
  approve = req.body.approve ?? false
  rep 200 (runtime.resume conv.conversation (str.int req.params.cid) approve)

# --- startup ---------------------------------------------------------

jobs.schedule
port = env.PORT ?? "8080"
log "agent platform listening on ${port}"
http.serve (str.int port)
