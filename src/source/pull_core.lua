-- The real, tested pagination + fetch + normalize logic for the merge-request
-- pull source. Deliberately independent of the guessed kickside.data:pullable
-- request/response envelope (see pull_items.lua / pull_keys.lua) — this
-- library takes a plain client:api instance and plain arguments, and is
-- fully unit-testable against a fake client with canned fixture responses.
-- No dependency on the guessed envelope being right; this is the part with
-- real engineering value regardless of how that question resolves later.
local data_error = require("data_error")
local types = require("types")
local api = require("api")

local M = {}

local DEFAULT_PER_PAGE = 100

-- One pull_core call walks up to this many GitLab API pages before
-- returning, folding several upstream pages into one cursored batch. This
-- bounds a single call's worst-case latency/size; has_more + next_cursor let
-- the caller (the engine, once wired — see pull_items.lua) resume beyond the
-- cap in a follow-up call. 5 pages * 100 per_page = up to 500 merge requests
-- per pull() invocation.
local DEFAULT_MAX_PAGES_PER_CALL = 5

-- The cursor is the GitLab page number to resume at next, encoded as a
-- decimal string. Opaque to callers on purpose — this internal encoding may
-- change without notice.
local function decode_cursor(cursor)
    if cursor == nil or cursor == "" then
        return 1
    end
    local n = tonumber(cursor)
    if type(n) ~= "number" or n < 1 then
        return 1
    end
    return math.floor(n)
end
M.decode_cursor = decode_cursor

local function encode_cursor(page)
    return tostring(page)
end
M.encode_cursor = encode_cursor

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

-- Maps one raw GitLab merge_request item to the shared normalized item
-- shape (see the shared build brief, "Normalized item shape").
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
        url = mr.web_url,
        raw = mr,
    }
end
M.normalize_mr = normalize_mr

-- Stable per-item key, mirroring kickside/github's documented convention
-- ("github:<owner>/<repo>:<issue|pull_request>:<number>") by direct analogy
-- — GitLab's project-scoped "iid" (not the global "id") is the number that
-- appears in the project's own MR URLs, so it is the natural analogue of
-- GitHub's issue/PR number here.
local function stable_key(project_id, mr)
    return string.format("gitlab:%s:mr:%s", tostring(project_id), tostring(mr.iid))
end
M.stable_key = stable_key

local function mr_key_item(project_id, mr)
    return {
        id = tostring(mr.id),
        key = stable_key(project_id, mr),
        updated_at = mr.updated_at,
    }
end

-- Shared pagination walk. `map_fn(mr) -> item` lets list_merge_requests and
-- list_merge_request_keys reuse one fetch/paginate loop while producing
-- different (full vs keys-only) item shapes — see the shared build brief's
-- "pull_keys ... items are lightweight keys, not full records."
local function paginate(client, project_id, opts, map_fn)
    if client == nil then
        return nil, data_error.envelope("invalid_request", "pull_core requires a client:api instance", false, "request")
    end
    if type(project_id) ~= "string" or project_id == "" then
        return nil, data_error.envelope("invalid_request", "project_id is required", false, "request")
    end

    opts = type(opts) == "table" and opts or {}
    local state = opts.state
    if type(state) ~= "string" or state == "" then
        state = "all"
    end
    local per_page = opts.per_page or DEFAULT_PER_PAGE
    local max_pages = opts.max_pages or DEFAULT_MAX_PAGES_PER_CALL

    local page = decode_cursor(opts.cursor)
    local items = {}

    for i = 1, max_pages do
        local resp, err = client:get("/projects/" .. project_id .. "/merge_requests", {
            scope = "pull",
            query = {
                state = state,
                -- sort=asc + order_by=updated_at keeps updated_at-based
                -- resumption monotonic across pages: each page's items are
                -- strictly non-decreasing by updated_at, so a cursor based
                -- on "the last updated_at seen" (or, as implemented here,
                -- the GitLab page number) never skips an item that was
                -- updated between two pull() calls landing "behind" the
                -- cursor. Sorting desc (GitLab's default) would make that
                -- kind of resumption unsound across separate invocations.
                order_by = "updated_at",
                sort = "asc",
                per_page = tostring(per_page),
                page = tostring(page),
            },
        })
        if err then
            return nil, err
        end

        local raw_items = resp.body
        if type(raw_items) ~= "table" then
            return nil, data_error.envelope("invalid_response", "GitLab merge_requests response was not a JSON array", false, "pull")
        end
        for _, mr in ipairs(raw_items) do
            items[#items + 1] = map_fn(project_id, mr)
        end

        local next_page_header = api.get_header(resp.headers, "x-next-page")
        if type(next_page_header) ~= "string" or next_page_header == "" then
            -- Exhausted: no more pages upstream.
            return { items = items, next_cursor = nil, has_more = false }, nil
        end

        local next_page = tonumber(next_page_header)
        if not next_page then
            return { items = items, next_cursor = nil, has_more = false }, nil
        end
        page = next_page

        if i == max_pages then
            -- Hit the per-call page cap with more upstream pages remaining;
            -- resume from here on the next pull() call.
            return { items = items, next_cursor = encode_cursor(page), has_more = true }, nil
        end
    end

    -- Unreachable (the loop above always returns), kept only so a future
    -- edit that changes the loop shape fails loudly instead of falling
    -- through silently.
    error("pull_core.paginate: pagination loop exited without returning")
end

-- list_merge_requests(client, project_id, opts) -> { items, next_cursor, has_more }, nil
--                                                -> nil, { code, message, retriable, scope }
-- opts: { cursor, state ("all"|"opened"|"merged"|"closed"), per_page, max_pages }
function M.list_merge_requests(client, project_id, opts)
    return paginate(client, project_id, opts, function(_, mr)
        return normalize_mr(mr)
    end)
end

-- list_merge_request_keys(client, project_id, opts) -> same shape, but each
-- item is { id, key, updated_at } instead of a full normalized record — used
-- for Data Sync reconcile (keys-only listing).
function M.list_merge_request_keys(client, project_id, opts)
    return paginate(client, project_id, opts, mr_key_item)
end

return M
