-- The real, tested pagination + fetch + normalize logic for the merge-request
-- pull source. Builds the FULL kickside.data:pullable envelope directly
-- (item_key/dedup_key/op/source_version/occurred_at/payload per item, a
-- table cursor, next_cursor set on every branch) per the real, unpacked
-- reference implementations:
--   providers-master/github/src/source/pull_core.lua
--   providers-master/atlassian/src/jira/source/pull_core.lua
-- See BUILD-NOTES.md, "kickside.data:pullable's exact envelope — RESOLVED".
--
-- list_merge_requests/list_merge_request_keys each return exactly ONE value
-- (the complete pull()/pull_keys() response — success or DataError failure),
-- matching both real references' M.pull(req, deps) convention. Client
-- resolution (component_id -> client:api instance) now lives here too, via
-- resolve_client, so source/pull_items.lua and source/pull_keys.lua are thin
-- wrappers, mirroring kickside/github's pull_items.lua/pull_keys.lua
-- (`local implementation = require("implementation"); return { pull =
-- implementation.pull }`).
local ctx = require("ctx")
local data_error = require("data_error")
local types = require("types")
local transport = require("transport")
local api = require("api")

local M = {}

local DEFAULT_PER_PAGE = 100
local MAX_PER_PAGE = 100

-- One pull() call walks up to this many GitLab API pages before returning,
-- folding several upstream pages into one cursored batch. This bounds a
-- single call's worst-case latency/size; has_more + next_cursor let the
-- caller resume beyond the cap in a follow-up call. Callers (tests, the
-- pullable conformance kit's adapter) may override via req.max_pages.
local DEFAULT_MAX_PAGES_PER_CALL = 5

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function config_value(config: any, key: string)
    return trim(type(config) == "table" and config[key] or nil)
end

-- component_id resolution fallback chain, per the real reference
-- (providers-master/github/src/source/pull_core.lua M.pull):
--   deps.component_id -> ctx.get("component_id") -> config.connection_id
-- The connection binding's own context_required: [component_id] handles the
-- common case (ctx already has it); config.connection_id is the last-resort
-- fallback for when Data Sync invokes pull outside a fully-scoped ctx.
-- deps.component_id/deps.transport exist purely as a test seam (see
-- pull_core_test.lua) — production callers (pull_items.lua, pull_keys.lua)
-- never pass deps.
local function resolve_client(config: any, deps: any?)
    deps = type(deps) == "table" and deps or {}
    local tp = deps.transport or transport

    local component_id = trim(deps.component_id)
    if component_id == "" then
        component_id = trim(ctx.get("component_id"))
    end
    if component_id == "" then
        component_id = config_value(config, "connection_id")
    end
    if component_id == "" then
        return nil, data_error.connection("component_id not in scope")
    end

    local client, err = tp.resolve(component_id)
    if err or not client then
        return nil, data_error.connection(tostring(err or "could not build a GitLab client"))
    end
    return client, nil
end
M.resolve_client = resolve_client

-- GitLab's author field is an object ({id, username, name, ...}) per the
-- provider brief — use author.name, falling back to author.username when
-- name is blank.
local function author_display_name(mr)
    if type(mr.author) ~= "table" then
        return nil
    end
    local name = mr.author.name
    if type(name) == "string" and name ~= "" then
        return name
    end
    return mr.author.username
end

-- Maps one raw GitLab merge_request item to the port's payload shape.
-- `source_url` (not `url`) per the platform-wide payload convention
-- confirmed by both real reference sources.
local function normalize_mr(mr)
    return {
        id = tostring(mr.id),
        title = mr.title,
        state = types.MR_STATE_MAP[mr.state] or mr.state,
        author = author_display_name(mr),
        source_branch = mr.source_branch,
        target_branch = mr.target_branch,
        created_at = mr.created_at,
        updated_at = mr.updated_at,
        merged_at = mr.merged_at,
        source_url = mr.web_url,
        raw = mr,
    }
end
M.normalize_mr = normalize_mr

-- Stable per-item key, mirroring kickside/github's documented convention
-- ("github:<owner>/<repo>:<issue|pull_request>:<number>") — GitLab's
-- project-scoped "iid" (not the global "id") is the number that appears in
-- the project's own MR URLs, so it is the natural analogue of GitHub's
-- issue/PR number here.
local function stable_key(project_id, mr)
    return string.format("gitlab:%s:mr:%s", tostring(project_id), tostring(mr.iid))
end
M.stable_key = stable_key

local function version_of(mr)
    return tostring(mr.updated_at or mr.created_at or mr.id or "")
end

-- Wraps one raw GitLab merge_request into the pullable item envelope:
-- { item_key, dedup_key, op = "upsert", source_version, occurred_at, payload }.
local function item_from(project_id, mr)
    local key = stable_key(project_id, mr)
    local version = version_of(mr)
    return {
        item_key = key,
        dedup_key = key .. ":upsert:" .. version,
        op = "upsert",
        source_version = version,
        occurred_at = version,
        payload = normalize_mr(mr),
    }
end
M.item_from = item_from

-- Lightweight keys-only entry: { item_key, dedup_key } only, used for Data
-- Sync reconcile (see list_merge_request_keys below).
local function key_item_from(project_id, mr)
    local key = stable_key(project_id, mr)
    return { item_key = key, dedup_key = key .. ":upsert:" .. version_of(mr) }
end

-- The cursor is a table { page = N, since = "..." }, never a bare string.
local function decode_cursor(cursor: any)
    cursor = type(cursor) == "table" and cursor or {}
    local page = tonumber(cursor.page) or 1
    if page < 1 then page = 1 end
    local since = type(cursor.since) == "string" and cursor.since or ""
    return math.floor(page), since
end

-- Shared pagination walk. `map_fn(project_id, mr) -> item` lets
-- list_merge_requests and list_merge_request_keys reuse one fetch/paginate
-- loop while producing different (full vs keys-only) item shapes.
--
-- Returns exactly ONE value: the complete pull() response —
-- { success = true, items = {...}, next_cursor = { page, since }, has_more }
-- on success, or a DataError failure envelope
-- ({ success = false, error = { code, message, retriable, scope } }) on
-- failure — matching both real references' M.pull(req, deps) convention.
local function walk(client: any, project_id: any, req: any, map_fn: any)
    req = type(req) == "table" and req or {}
    local config = type(req.config) == "table" and req.config or {}

    if client == nil then
        return data_error.failure("invalid_request", "pull_core requires a client:api instance", false, "request")
    end
    if type(project_id) ~= "string" or project_id == "" then
        return data_error.invalid_config("config.project_id is required")
    end

    local state = config_value(config, "state")
    if state == "" then state = "all" end

    local per_page = tonumber(req.limit) or DEFAULT_PER_PAGE
    if per_page < 1 then per_page = 1 end
    if per_page > MAX_PER_PAGE then per_page = MAX_PER_PAGE end

    local max_pages = tonumber(req.max_pages) or DEFAULT_MAX_PAGES_PER_CALL

    local page, since = decode_cursor(req.cursor)
    if since == "" then since = config_value(config, "backfill_since") end

    local items = {}
    local max_seen = since

    for i = 1, max_pages do
        local query = {
            state = state,
            -- sort=asc + order_by=updated_at keeps updated_at-based
            -- resumption monotonic across pages: each page's items are
            -- strictly non-decreasing by updated_at, so a cursor based on
            -- "the last updated_at seen" never skips an item that was
            -- updated between two pull() calls landing "behind" the cursor.
            order_by = "updated_at",
            sort = "asc",
            per_page = tostring(per_page),
            page = tostring(page),
        }
        if since ~= "" then
            -- Honors config.backfill_since / a resumed cursor's since
            -- directly at the API level (GitLab's merge_requests list
            -- endpoint supports updated_after).
            query.updated_after = since
        end

        local resp, err = client:get("/projects/" .. project_id .. "/merge_requests", {
            scope = "pull",
            query = query,
        })
        if err then
            return err
        end

        local raw_items = resp.body
        if type(raw_items) ~= "table" then
            return data_error.failure("invalid_response", "GitLab merge_requests response was not a JSON array", false, "pull")
        end
        for _, mr in ipairs(raw_items) do
            items[#items + 1] = map_fn(project_id, mr)
            local v = version_of(mr)
            if v ~= "" and v > max_seen then max_seen = v end
        end

        local next_page_header = api.get_header(resp.headers, "x-next-page")
        local next_page = tonumber(next_page_header)
        if not next_page then
            -- Exhausted: reset to a fresh resumable position (page 1, since
            -- the max updated_at seen this pull) so continuous polling keeps
            -- working — next_cursor is never nil on success.
            return { success = true, items = items, next_cursor = { page = 1, since = max_seen }, has_more = false }
        end

        page = next_page
        if i == max_pages then
            -- Hit the per-call page cap with more upstream pages remaining;
            -- resume from here (since unchanged — still filtering this same
            -- backfill window) on the next call.
            return { success = true, items = items, next_cursor = { page = page, since = since }, has_more = true }
        end
    end

    -- Unreachable (the loop above always returns), kept only so a future
    -- edit that changes the loop shape fails loudly instead of falling
    -- through silently.
    error("pull_core.walk: pagination loop exited without returning")
end

-- list_merge_requests(client, project_id, req) -> the complete
-- kickside.data:pullable.pull response. req: { cursor = {page, since}?,
-- config = { project_id, state?, backfill_since?, connection_id? }, limit?,
-- max_pages? }.
function M.list_merge_requests(client, project_id, req)
    return walk(client, project_id, req, item_from)
end

-- list_merge_request_keys(client, project_id, req) -> same envelope shape,
-- but `keys` (not `items`), each entry { item_key, dedup_key } only — used
-- for Data Sync reconcile (keys-only listing).
function M.list_merge_request_keys(client, project_id, req)
    local page = walk(client, project_id, req, key_item_from)
    if page.success ~= true then
        return page
    end
    page.keys = page.items
    page.items = nil
    return page
end

return M
