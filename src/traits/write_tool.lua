-- Real implementation of the GitLabWrite agent tool. Mirrors the real,
-- unpacked kickside/github reference (providers-master/github/src/traits/
-- write_tool.lua) in shape and in SCOPE DISCIPLINE: exactly three
-- merge-request-workflow mutations are exposed (create_merge_request,
-- update_merge_request, create_note) — never merge, approve, delete, or
-- touch repository files/branches/releases/settings/collaborators/CI
-- pipelines. See traits/_index.yaml's writer/manager prompts for the
-- user-facing statement of the same restriction.
--
-- The three entity-specific operations (M.create_merge_request/
-- M.update_merge_request/M.create_note) live HERE rather than in
-- client/api.lua. This is a deliberate placement choice, not a literal
-- reading of the shared build brief's "extend client:api with
-- create_merge_request/..." wording — client/api.lua's own established
-- convention (see its file header, and source/pull_core.lua) is that it
-- stays a purely generic REST client (get/post/put by path), while every
-- entity-specific path/body is owned by the layer above (pull_core.lua for
-- reads, this file for writes). Kept consistent with that existing, tested
-- split rather than mixing generic and entity-specific concerns into
-- client:api. See BUILD-NOTES.md, "Where the write methods actually live."
--
-- Field shapes below (source_branch/target_branch/title required on create;
-- state_event with close/reopen values, NOT state, for closing/reopening on
-- update; labels as a comma-separated string, not an array) are CONFIRMED
-- against the live docs.gitlab.com/ee/api/merge_requests.html and
-- .../notes.html pages (2026-09-03) — not against a live API call. See
-- client/api.lua's file header and BUILD-NOTES.md for what that does and
-- does not mean.
local ctx = require("ctx")
local output = require("output")
local transport = require("transport")
local pull_core = require("pull_core")

local M = {}
M._transport = transport
M._output = output
M._pull_core = pull_core

local MAX_OUTPUT = 8000

type Args = {
    action: string,
    project_id: string?,
    iid: string?,
    title: string?,
    description: string?,
    source_branch: string?,
    target_branch: string?,
    labels: { any }?,
    assignee_ids: { any }?,
    reviewer_ids: { any }?,
    remove_source_branch: boolean?,
    state: string?,
    body: string?,
}

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Same ambient-context convention as read_tool.lua: the trait picker binds
-- the selected connection's component id under ctx key "connection_id".
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

local function error_message(err: any): string
    if type(err) == "table" and type(err.error) == "table" and err.error.message then
        return tostring(err.error.message)
    end
    return tostring(err or "request failed")
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
    return action == "create_merge_request"
        or action == "update_merge_request"
        or action == "create_note"
end

-- GitLab's labels attribute is a single comma-separated STRING, not a JSON
-- array (confirmed live against both the Create MR and Update MR sections
-- of docs.gitlab.com/ee/api/merge_requests.html — flagged in the provider
-- brief as an easy mistake to make from memory). An empty array is
-- deliberately preserved as "" (not omitted) so a caller can explicitly
-- unassign all labels on update, per the documented "Set to an empty string
-- to unassign all labels."
local function labels_string(value: any): string?
    if type(value) ~= "table" then return nil end
    local parts = {}
    for _, v in ipairs(value) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, ",")
end

-- assignee_ids/reviewer_ids are JSON integer arrays (unlike labels). Accepts
-- numbers or numeric strings defensively (a value that isn't numeric is
-- silently dropped rather than sent through as garbage); an empty array is
-- preserved (GitLab documents an empty value as "unassign all").
local function id_list(value: any): { number }?
    if type(value) ~= "table" then return nil end
    local out: { number } = {}
    for _, v in ipairs(value) do
        local n = tonumber(v)
        if n then out[#out + 1] = n end
    end
    return out
end

-- POST /projects/:id/merge_requests. Required: source_branch, target_branch,
-- title. Optional: description, labels, assignee_ids, reviewer_ids,
-- remove_source_branch.
local function create_body(args: Args): (any?, string?)
    local source_branch = trim(args.source_branch)
    local target_branch = trim(args.target_branch)
    local title = trim(args.title)
    if source_branch == "" then return nil, "source_branch is required for create_merge_request" end
    if target_branch == "" then return nil, "target_branch is required for create_merge_request" end
    if title == "" then return nil, "title is required for create_merge_request" end

    local body: { [string]: any } = {
        source_branch = source_branch,
        target_branch = target_branch,
        title = title,
    }
    if trim(args.description) ~= "" then body.description = trim(args.description) end
    local labels = labels_string(args.labels)
    if labels then body.labels = labels end
    local assignees = id_list(args.assignee_ids)
    if assignees then body.assignee_ids = assignees end
    local reviewers = id_list(args.reviewer_ids)
    if reviewers then body.reviewer_ids = reviewers end
    if type(args.remove_source_branch) == "boolean" then body.remove_source_branch = args.remove_source_branch end
    return body, nil
end

-- PUT /projects/:id/merge_requests/:iid. All fields optional, but at least
-- one is required. `state` here is the tool-facing open|closed vocabulary
-- (matching GitHub's own update_issue shape, per the shared build brief) —
-- translated to GitLab's real wire field state_event (close|reopen) below.
-- Never accepts or produces "merged" — this tool never merges anything.
local function update_body(args: Args): (any?, string?)
    local body: { [string]: any } = {}
    if trim(args.title) ~= "" then body.title = trim(args.title) end
    if trim(args.description) ~= "" then body.description = trim(args.description) end
    if trim(args.target_branch) ~= "" then body.target_branch = trim(args.target_branch) end
    local labels = labels_string(args.labels)
    if labels then body.labels = labels end
    local assignees = id_list(args.assignee_ids)
    if assignees then body.assignee_ids = assignees end
    local reviewers = id_list(args.reviewer_ids)
    if reviewers then body.reviewer_ids = reviewers end
    if trim(args.state) ~= "" then
        local state = trim(args.state)
        if state ~= "open" and state ~= "closed" then return nil, "state must be open or closed" end
        -- CONFIRMED live against docs.gitlab.com/ee/api/merge_requests.html
        -- "Update MR": the real field is state_event (values close/reopen),
        -- not state (values opened/closed) — see file header.
        body.state_event = state == "closed" and "close" or "reopen"
    end
    if next(body) == nil then return nil, "at least one field is required for update_merge_request" end
    return body, nil
end

-- project_id is interpolated unescaped into the path, matching
-- source/pull_core.lua's own existing (tested) convention — this module has
-- no URL-escaping helper for path segments today, and adding one is out of
-- this pass's scope.
local function project_path(project_id: string, suffix: string): string
    return "/projects/" .. project_id .. suffix
end

function M.create_merge_request(client: any, project_id: string, body: any): (any?, any?)
    return client:post(project_path(project_id, "/merge_requests"), body, { scope = "create_merge_request" })
end

function M.update_merge_request(client: any, project_id: string, iid: string, body: any): (any?, any?)
    return client:put(project_path(project_id, "/merge_requests/" .. iid), body, { scope = "update_merge_request" })
end

function M.create_note(client: any, project_id: string, iid: string, body: any): (any?, any?)
    return client:post(project_path(project_id, "/merge_requests/" .. iid .. "/notes"), body, { scope = "create_note" })
end

-- Builds the create_merge_request/update_merge_request response by reusing
-- pull_core's own normalize_mr/stable_key — the exact same normalized shape
-- and item_key convention the read side and the Data Sync pull source both
-- use, not a new one invented for this tool. `iid` is flattened onto the
-- top level too (normalize_mr's own `id` field is the GitLab-global id, not
-- the project-scoped iid a caller needs to pass into update_merge_request/
-- create_note next).
local function mr_response(project_id: string, mr: any): any
    local normalized = M._pull_core.normalize_mr(mr)
    normalized.iid = mr.iid
    normalized.item_key = M._pull_core.stable_key(project_id, mr)
    return normalized
end

local function note_response(note: any): any
    local author = nil
    if type(note.author) == "table" then
        author = (type(note.author.name) == "string" and note.author.name ~= "") and note.author.name or note.author.username
    end
    return {
        id = note.id,
        body = note.body,
        author = author,
        created_at = note.created_at,
        updated_at = note.updated_at,
    }
end

local function handler(args: Args): any
    args = type(args) == "table" and args or ({ action = "" } :: Args)
    local action = trim(args.action)
    if action == "" then return fail("action is required") end
    if not known_action(action) then return fail("unknown action '" .. tostring(action) .. "'") end

    local project_id, perr = require_project(args)
    if perr then return fail(perr) end

    local iid: string? = nil
    local request_body: any = nil
    if action == "create_merge_request" then
        local berr
        request_body, berr = create_body(args)
        if berr then return fail(berr) end
    elseif action == "update_merge_request" then
        local ierr, berr
        iid, ierr = require_iid(args)
        if ierr then return fail(ierr) end
        request_body, berr = update_body(args)
        if berr then return fail(berr) end
    else
        local ierr
        iid, ierr = require_iid(args)
        if ierr then return fail(ierr) end
        local note_body = trim(args.body)
        if note_body == "" then return fail("body is required for create_note") end
        request_body = { body = note_body }
    end

    local tp = M._transport
    local conn, cerr = tp.resolve(connection_id())
    if cerr or not conn then return fail(cerr or "no connection") end

    if action == "create_merge_request" then
        local resp, err = M.create_merge_request(conn, project_id :: string, request_body)
        if err then return fail(error_message(err)) end
        if not resp or type(resp.body) ~= "table" then return fail("GitLab returned an unexpected response") end
        return encode(mr_response(project_id :: string, resp.body))
    elseif action == "update_merge_request" then
        local resp, err = M.update_merge_request(conn, project_id :: string, iid :: string, request_body)
        if err then return fail(error_message(err)) end
        if not resp or type(resp.body) ~= "table" then return fail("GitLab returned an unexpected response") end
        return encode(mr_response(project_id :: string, resp.body))
    else
        local resp, err = M.create_note(conn, project_id :: string, iid :: string, request_body)
        if err then return fail(error_message(err)) end
        if not resp or type(resp.body) ~= "table" then return fail("GitLab returned an unexpected response") end
        return encode(note_response(resp.body))
    end
end

M.handler = handler

return M
