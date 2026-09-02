local ctx = require("ctx")
local transport = require("transport")
local pull_core = require("pull_core")
local data_error = require("data_error")

local function fail(code, message, retriable, scope)
    return { success = false, error = data_error.envelope(code, message, retriable, scope) }
end

-- Same context_required: [component_id] convention as the connection
-- contract — see pull_items.lua's resolve_client for the full reasoning.
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
UNVERIFIED envelope, PLUS a since-corrected wiring assumption — read both.

Originally this function was bound as a second kickside.data:pullable
method ("pull_keys"), inferred from kickside/github's own pull_keys entry
comment ("Keys-only GitHub repository issue / pull request listing used by
Data Sync reconcile"). That assumption was WRONG and has since been
empirically corrected: once kickside/core became a real, unpacked test
harness dependency (see BUILD-NOTES.md), the platform's own contract-binding
validator rejected the binding at boot — "bound method is not defined in
contract definition: ... binds kickside.data:pullable.pull_keys". The real
kickside.data:pullable contract binds ONLY "pull" (source/_index.yaml's
project_mrs_source binding was fixed accordingly). No second "keys"/
"reconcile" contract exists anywhere in the resolved dependency graph either.

This function is kept — a keys-only Data Sync reconcile hook clearly exists
in kickside/github by its own doc comment, this module's own logic for it
(pull_core.list_merge_request_keys) is real and tested — but it is not
currently wired to anything. How Data Sync actually discovers/invokes a
keys-only reconcile hook (a differently-named contract method, a
convention-based function id, a second binding declaration) is now the
genuinely open question; the { success, items, next_cursor, has_more } /
{ success, error } envelope shape below is unchanged from before and remains
inferred by analogy to pull_items.lua's pull() for whenever that wiring
question resolves. See BUILD-NOTES.md, section "OPEN: kickside.data:pullable's
exact envelope".
============================================================================ ]]
local function pull_keys(req)
    req = type(req) == "table" and req or {}
    local config = type(req.config) == "table" and req.config or {}
    local cursor = req.cursor

    local project_id = config.project_id
    if type(project_id) ~= "string" and type(project_id) ~= "number" then
        return fail("invalid_request", "pull_keys requires config.project_id", false, "config")
    end
    project_id = tostring(project_id)

    local client, cerr = resolve_client()
    if cerr or not client then
        return fail("provider_unavailable", tostring(cerr or "could not build a GitLab client"), true, "connection")
    end

    local result, perr = pull_core.list_merge_request_keys(client, project_id, {
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

return { pull_keys = pull_keys }
