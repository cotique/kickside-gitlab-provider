-- Real implementation of the GitLabRead agent tool. Mirrors the real,
-- unpacked kickside/github reference (providers-master/github/src/traits/
-- read_tool.lua) in shape: one flat `action` enum, validated before opening
-- a connection, dispatched to the transport/pull_core layer.
--
-- Unlike GitHub's transport (which exposes one action method per verb —
-- tp.viewer, tp.get_repo, tp.list_issues, ...), this module's
-- client:transport.resolve(component_id) hands back a plain client:api
-- instance whose only primitive is client:get(path, opts) — see
-- client/transport.lua and client/api.lua. list_merge_requests below reuses
-- source/pull_core.lua's real, tested pagination + normalization logic
-- (the exact same function the Data Sync pull source calls) rather than
-- re-implementing GitLab's merge_requests list call a second time;
-- get_merge_request/list_merge_request_notes call client:get directly with
-- hand-built paths, the same way pull_core.lua itself does, since neither
-- endpoint has an existing tested wrapper to reuse.
local ctx = require("ctx")
local output = require("output")
local transport = require("transport")
local pull_core = require("pull_core")

local M = {}
M._transport = transport
M._output = output
M._pull_core = pull_core

local MAX_OUTPUT = 8000
local DEFAULT_LIMIT = 25
local MAX_LIMIT = 100

type Args = {
    action: string,
    project_id: string?,
    iid: string?,
    state: string?,
    limit: number?,
    page: number?,
}

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The trait picker binds the selected connection's component id into ambient
-- context under the key "connection_id" (matching the real kickside/github
-- reference's own traits — see context_schema in traits/_index.yaml). It is
-- a component id, despite the key name; client:transport.resolve expects
-- exactly that.
local function connection_id(): string?
    local configured = ctx.get("connection_id")
    if type(configured) == "string" and configured ~= "" then return configured end
    return nil
end

local function encode(data: any): string
    return M._output.encode(data, MAX_OUTPUT)
end

local function fail(message: any): string
    return encode({ success = false, error = tostring(message or "request failed") })
end

local function clamp_limit(args: Args): number
    local n = tonumber(args.limit) or DEFAULT_LIMIT
    if n < 1 then n = 1 end
    if n > MAX_LIMIT then n = MAX_LIMIT end
    return math.floor(n)
end

local function require_project(args: Args): (string?, string?)
    local project_id = trim(args.project_id)
    if project_id == "" then return nil, "project_id is required" end
    return project_id, nil
end

local function require_iid(args: Args): (string?, string?)
    local iid = trim(args.iid)
    if iid == "" then return nil, "iid is required" end
    return iid, nil
end

local function known_action(action: string): boolean
    return action == "list_merge_requests"
        or action == "get_merge_request"
        or action == "list_merge_request_notes"
end

-- Reuses pull_core.list_merge_requests (the same pagination/fetch/normalize
-- logic the Data Sync pull source runs) for one page of results, then
-- unwraps pull_core's pullable-envelope items (item_key/dedup_key/op/
-- source_version/occurred_at/payload) down to just the payload — an agent
-- tool caller has no use for Data Sync's own dedup/cursor bookkeeping
-- vocabulary, only the normalized merge request fields.
local function list_merge_requests(client: any, project_id: string, args: Args): (any?, any?)
    local state = trim(args.state)
    if state == "" then state = "all" end
    local page = tonumber(args.page) or 1
    if page < 1 then page = 1 end

    local result = M._pull_core.list_merge_requests(client, project_id, {
        cursor = { page = math.floor(page) },
        config = { project_id = project_id, state = state },
        limit = clamp_limit(args),
        max_pages = 1,
    })
    if result.success ~= true then
        return nil, result
    end

    local merge_requests = {}
    for _, item in ipairs(result.items) do
        merge_requests[#merge_requests + 1] = item.payload
    end
    return {
        merge_requests = merge_requests,
        next_page = result.has_more and result.next_cursor.page or nil,
        has_more = result.has_more,
    }, nil
end

local function get_merge_request(client: any, project_id: string, iid: string): (any?, any?)
    local resp, err = client:get("/projects/" .. project_id .. "/merge_requests/" .. iid, { scope = "get_merge_request" })
    if err then return nil, err end
    return M._pull_core.normalize_mr(resp.body), nil
end

local function list_merge_request_notes(client: any, project_id: string, iid: string, args: Args): (any?, any?)
    local resp, err = client:get("/projects/" .. project_id .. "/merge_requests/" .. iid .. "/notes", {
        scope = "list_merge_request_notes",
        query = { per_page = tostring(clamp_limit(args)), page = tostring(tonumber(args.page) or 1) },
    })
    if err then return nil, err end

    local raw_notes = resp.body
    if type(raw_notes) ~= "table" then
        return nil, { error = { message = "GitLab notes response was not a JSON array" } }
    end
    local notes = {}
    for _, note in ipairs(raw_notes) do
        local author = nil
        if type(note.author) == "table" then
            author = (type(note.author.name) == "string" and note.author.name ~= "") and note.author.name or note.author.username
        end
        notes[#notes + 1] = {
            id = note.id,
            body = note.body,
            author = author,
            created_at = note.created_at,
            updated_at = note.updated_at,
            system = note.system,
        }
    end
    return notes, nil
end

local function error_message(err: any): string
    if type(err) == "table" and type(err.error) == "table" and err.error.message then
        return tostring(err.error.message)
    end
    return tostring(err or "request failed")
end

local function handler(args: Args): any
    args = type(args) == "table" and args or ({ action = "" } :: Args)
    local action = trim(args.action)
    if action == "" then return fail("action is required") end
    if not known_action(action) then return fail("unknown action '" .. tostring(action) .. "'") end

    local project_id, perr = require_project(args)
    if perr then return fail(perr) end

    local iid: string? = nil
    if action == "get_merge_request" or action == "list_merge_request_notes" then
        local ierr
        iid, ierr = require_iid(args)
        if ierr then return fail(ierr) end
    end

    local tp = M._transport
    local conn, cerr = tp.resolve(connection_id())
    if cerr or not conn then return fail(cerr or "no connection") end

    if action == "list_merge_requests" then
        local data, err = list_merge_requests(conn, project_id :: string, args)
        if err then return fail(error_message(err)) end
        return encode(data)
    elseif action == "get_merge_request" then
        local data, err = get_merge_request(conn, project_id :: string, iid :: string)
        if err then return fail(error_message(err)) end
        return encode(data)
    else
        local data, err = list_merge_request_notes(conn, project_id :: string, iid :: string, args)
        if err then return fail(error_message(err)) end
        return encode(data)
    end
end

M.handler = handler

return M
