local ctx = require("ctx")
local transport = require("transport")
local pull_core = require("pull_core")
local data_error = require("data_error")

local function fail(code, message, retriable, scope)
    return { success = false, error = data_error.envelope(code, message, retriable, scope) }
end

-- Same context_required: [component_id] convention as the connection
-- contract (see connection/connection_lib.lua) — inferred by analogy for
-- this contract too, since a pull source needs the SAME kind of
-- credential-bearing component a connection does. Flagged alongside the rest
-- of the envelope uncertainty below.
local function resolve_client()
    local component_id, err = ctx.get("component_id")
    if err then
        return nil, err
    end
    if type(component_id) ~= "string" or component_id == "" then
        return nil, "component_id not in scope"
    end
    return transport.resolve(component_id)
end

--[[ ==========================================================================
UNVERIFIED: kickside.data:pullable's exact request/response envelope.

We do NOT have access to kickside.data:pullable's real Lua source or to a
working implementation of it (kickside/github, the reference module, ships as
a packed Hub module — `wippy registry show <id> --json` returns "data": null
for every entry in it; the Hub Structure/Bindings tabs surface only the same
declared meta, never method bodies; the source repo
git.wippy.ai/kickside/providers needs auth this checkout doesn't have). This
is the exact same wall cotique/eng-metrics hit for
kickside.atlassian.jira:api — see that module's docs/BUILD-NOTES.md #3a/#3b.

What IS confirmed (via `wippy registry show kickside.data:pullable --json`
and the Hub's Bindings tab, per the shared build brief):
  - The contract id is kickside.data:pullable, comment "Stateless cursored
    producer. Engine owns cursor, lease, schedule, dedup, id-map, and sink
    routing."
  - kickside/github's kickside.github.source:repo_items_source implements
    it; its pull_items entry's own comment is literally "kickside.data:
    pullable.pull for GitHub repository issues / pull requests" — confirming
    the method name is "pull".
  - Its pull_keys entry's comment: "Keys-only GitHub repository issue / pull
    request listing used by Data Sync reconcile" — kickside/github clearly
    HAS a keys-only reconcile hook.
  - CORRECTION, empirically verified once kickside/core became a real,
    unpacked test-harness dependency (see BUILD-NOTES.md): the real
    kickside.data:pullable contract binds ONLY "pull". The platform's own
    contract-binding validator rejected a "pull_keys" method on this
    contract at boot. pull_keys.lua is kept (kickside/github's own comment
    proves the capability exists somewhere) but is NOT bound to this
    contract — see that file's header for the corrected story and
    BUILD-NOTES.md for what's still open about how it's actually wired.

What is INFERRED BY ANALOGY to the real, verified kickside.data:writable.write
shape (src/sink/write.lua in the template scaffold this module started from,
before it was removed — see BUILD-NOTES.md for the full text):
  - Request shape: { config, cursor } — no sink_op/idempotency_key, since
    those are write-specific.
  - Success response: { success = true, items = {...}, next_cursor = "..."
    or nil, has_more = true|false }.
  - Failure response: { success = false, error = { code, message, retriable,
    scope } } — this part IS confirmed generic, since it's the exact shape
    write.lua uses.

If this guess is wrong, ONLY this file and pull_keys.lua need to change —
everything they call (pull_core.lua, client/*.lua) is independently correct
regardless of how this resolves, and is fully unit-tested against that
independence. See BUILD-NOTES.md, section "OPEN: kickside.data:pullable's
exact envelope", for what would resolve this (real source/repo access to
git.wippy.ai/kickside/providers, or a working Keeper console against a
booted host with kickside/github installed unpacked).
============================================================================ ]]
local function pull(req)
    req = type(req) == "table" and req or {}
    local config = type(req.config) == "table" and req.config or {}
    local cursor = req.cursor

    local project_id = config.project_id
    if type(project_id) ~= "string" and type(project_id) ~= "number" then
        return fail("invalid_request", "pull requires config.project_id", false, "config")
    end
    project_id = tostring(project_id)

    local client, cerr = resolve_client()
    if cerr or not client then
        return fail("provider_unavailable", tostring(cerr or "could not build a GitLab client"), true, "connection")
    end

    local result, perr = pull_core.list_merge_requests(client, project_id, {
        cursor = cursor,
        state = config.state,
    })
    if perr then
        return { success = false, error = perr }
    end

    return {
        success = true,
        items = result.items,
        next_cursor = result.next_cursor,
        has_more = result.has_more,
    }
end

return { pull = pull }
