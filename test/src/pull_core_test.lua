-- Unit tests for pull_core's pagination + fetch + normalize logic, against a
-- plain Lua test double for client:api — no real network call. Fixtures are
-- built from the real GitLab merge_request field names captured in
-- BUILD-NOTES.md ("Empirically-verified REST API pagination shapes" — live
-- calls made 2026-09-02 against gitlab.com).
--
-- Envelope shape (item wrapper, table cursor, resolve_client fallback chain)
-- is asserted against the real, unpacked reference contract — see
-- BUILD-NOTES.md, "kickside.data:pullable's exact envelope — RESOLVED".
local test = require("test")
local pull_core = require("pull_core")
local conformance = require("conformance")

-- A realistic raw GitLab merge_request item.
local function raw_mr(overrides)
    local mr = {
        id = 111,
        iid = 7,
        project_id = 278964,
        title = "Fix flaky test",
        description = "See CI run #123",
        state = "opened",
        author = { id = 42, username = "jdoe", name = "Jane Doe" },
        source_branch = "fix/flaky-test",
        target_branch = "main",
        created_at = "2026-08-01T10:00:00.000Z",
        updated_at = "2026-08-02T11:00:00.000Z",
        merged_at = nil,
        web_url = "https://gitlab.com/example/project/-/merge_requests/7",
    }
    for k, v in pairs(overrides or {}) do
        mr[k] = v
    end
    return mr
end

-- A fake client:api instance. `pages` is an ordered array of either
-- { items = {...}, next_page = "2" | "" } or { err = {...} }. Each call to
-- :get() consumes the next page and records the query it was called with, so
-- tests can assert on the real pagination query params (state/order_by/
-- sort/per_page/page/updated_after) as well as on the walk itself.
local function new_fake_client(pages)
    local calls = {}
    local next_index = 1
    local client = {}

    function client:get(path, opts)
        opts = type(opts) == "table" and opts or {}
        calls[#calls + 1] = { path = path, query = opts.query }
        local page = pages[next_index]
        if page == nil then
            error("fake client:get called more times than fixture pages provided (" .. next_index .. ")")
        end
        next_index = next_index + 1

        if page.err then
            return nil, page.err
        end

        return {
            body = page.items,
            headers = { ["x-next-page"] = page.next_page or "" },
            status_code = 200,
        }, nil
    end

    function client:call_count()
        return #calls
    end

    function client:query_field(n, key)
        local call = calls[n]
        if not call then
            error("no recorded call #" .. n)
        end
        local query = call.query
        if not query then
            error("call #" .. n .. " recorded no query")
        end
        return query[key]
    end

    return client
end

-- A query-aware fake client for the pullable conformance kit, which issues
-- several independent pull()/pull_keys() calls (main loop, failure path,
-- backfill path, keys path) that do not follow one linear page sequence —
-- unlike new_fake_client above, this one derives its response purely from
-- the requested page/per_page/updated_after, so any call ordering works.
local function new_conformance_client(fixture)
    local client = {}
    function client:get(_path, opts)
        opts = type(opts) == "table" and opts or {}
        local query = opts.query or {}
        local page = tonumber(query.page) or 1
        local per_page = tonumber(query.per_page) or 100
        local since = query.updated_after

        local filtered = {}
        for _, mr in ipairs(fixture) do
            if since == nil or mr.updated_at >= since then
                filtered[#filtered + 1] = mr
            end
        end

        local start_idx = (page - 1) * per_page + 1
        local page_items = {}
        for i = start_idx, math.min(start_idx + per_page - 1, #filtered) do
            page_items[#page_items + 1] = filtered[i]
        end
        local next_page = ""
        if start_idx + per_page - 1 < #filtered then
            next_page = tostring(page + 1)
        end

        return {
            body = page_items,
            headers = { ["x-next-page"] = next_page },
            status_code = 200,
        }, nil
    end
    return client
end

local function define_tests()
    test.describe("cotique.gitlab.source pull_core", function()
        test.it("wraps every item in the pullable envelope with the payload normalized", function()
            local client = new_fake_client({
                { items = { raw_mr({}) }, next_page = "" },
            })
            local page = pull_core.list_merge_requests(client, "278964", {})
            test.eq(page.success, true)
            test.eq(#page.items, 1)

            local item = page.items[1]
            test.eq(item.item_key, "gitlab:278964:mr:7")
            test.eq(item.dedup_key, "gitlab:278964:mr:7:upsert:2026-08-02T11:00:00.000Z")
            test.eq(item.op, "upsert")
            test.eq(item.source_version, "2026-08-02T11:00:00.000Z")
            test.eq(item.occurred_at, "2026-08-02T11:00:00.000Z")

            local payload = item.payload
            test.eq(payload.id, "111")
            test.eq(payload.title, "Fix flaky test")
            test.eq(payload.state, "open") -- opened -> open
            test.eq(payload.author, "Jane Doe")
            test.eq(payload.source_branch, "fix/flaky-test")
            test.eq(payload.target_branch, "main")
            test.eq(payload.created_at, "2026-08-01T10:00:00.000Z")
            test.eq(payload.updated_at, "2026-08-02T11:00:00.000Z")
            test.is_nil(payload.merged_at)
            test.eq(payload.source_url, "https://gitlab.com/example/project/-/merge_requests/7")
            test.not_nil(payload.raw, "raw must carry the original API item")
            test.eq(payload.raw.iid, 7)
        end)

        test.it("maps merged and closed states", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 1, iid = 1, state = "merged", merged_at = "2026-08-03T00:00:00.000Z" }),
                            raw_mr({ id = 2, iid = 2, state = "closed" }) }, next_page = "" },
            })
            local page = pull_core.list_merge_requests(client, "278964", {})
            test.eq(page.items[1].payload.state, "merged")
            test.eq(page.items[1].payload.merged_at, "2026-08-03T00:00:00.000Z")
            test.eq(page.items[2].payload.state, "closed")
        end)

        test.it("falls back to author.username when author.name is blank", function()
            local client = new_fake_client({
                { items = { raw_mr({ author = { id = 9, username = "ghost", name = "" } }) }, next_page = "" },
            })
            local page = pull_core.list_merge_requests(client, "278964", {})
            test.eq(page.items[1].payload.author, "ghost")
        end)

        test.it("walks multiple pages via x-next-page, resets to a fresh resumable cursor on exhaustion", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 1, iid = 1, updated_at = "2026-08-01T00:00:00.000Z" }),
                            raw_mr({ id = 2, iid = 2, updated_at = "2026-08-02T00:00:00.000Z" }) }, next_page = "2" },
                { items = { raw_mr({ id = 3, iid = 3, updated_at = "2026-08-03T00:00:00.000Z" }) }, next_page = "3" },
                { items = { raw_mr({ id = 4, iid = 4, updated_at = "2026-08-04T00:00:00.000Z" }) }, next_page = "" },
            })
            local page = pull_core.list_merge_requests(client, "278964", { max_pages = 5 })
            test.eq(page.success, true)
            test.eq(#page.items, 4)
            test.eq(page.has_more, false)
            -- next_cursor is NEVER nil on success, even on exhaustion — it
            -- resets to a fresh resumable position so continuous polling
            -- keeps working.
            test.not_nil(page.next_cursor)
            test.eq(page.next_cursor.page, 1)
            test.eq(page.next_cursor.since, "2026-08-04T00:00:00.000Z")
            test.eq(client:call_count(), 3, "must have made exactly 3 HTTP calls, one per page")

            -- Real, verified pagination query params (see BUILD-NOTES.md):
            -- page/per_page offset pagination, sorted ascending by
            -- updated_at for monotonic cursor resumption.
            test.eq(client:query_field(1, "page"), "1")
            test.eq(client:query_field(2, "page"), "2")
            test.eq(client:query_field(3, "page"), "3")
            test.eq(client:query_field(1, "order_by"), "updated_at")
            test.eq(client:query_field(1, "sort"), "asc")
            test.eq(client:query_field(1, "state"), "all")
            test.eq(client:query_field(1, "per_page"), "100")
        end)

        test.it("stops at the per-call page cap and returns a resumable table cursor", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 1, iid = 1 }) }, next_page = "2" },
                -- Second page is never fetched: max_pages = 1 caps the walk.
            })
            local page = pull_core.list_merge_requests(client, "278964", { max_pages = 1 })
            test.eq(page.success, true)
            test.eq(#page.items, 1)
            test.eq(page.has_more, true)
            test.eq(page.next_cursor.page, 2)
            test.eq(page.next_cursor.since, "")
            test.eq(client:call_count(), 1)
        end)

        test.it("resumes from an explicit table cursor on the next call", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 9, iid = 9 }) }, next_page = "" },
            })
            local page = pull_core.list_merge_requests(client, "278964", { cursor = { page = 4, since = "2026-08-01T00:00:00.000Z" } })
            test.eq(page.success, true)
            test.eq(client:query_field(1, "page"), "4")
            test.eq(client:query_field(1, "updated_after"), "2026-08-01T00:00:00.000Z")
            test.eq(#page.items, 1)
        end)

        test.it("honors config.backfill_since as updated_after when the cursor carries no since", function()
            local client = new_fake_client({
                { items = {}, next_page = "" },
            })
            pull_core.list_merge_requests(client, "278964", { config = { backfill_since = "2026-01-01T00:00:00.000Z" } })
            test.eq(client:query_field(1, "updated_after"), "2026-01-01T00:00:00.000Z")
        end)

        test.it("propagates a client DataError without wrapping it again", function()
            local boom = { success = false, error = { code = "provider_unavailable", message = "boom", retriable = true, scope = "provider" } }
            local client = new_fake_client({ { err = boom } })
            local page = pull_core.list_merge_requests(client, "278964", {})
            test.eq(page.success, false)
            test.eq(page.error.code, "provider_unavailable")
            test.eq(page.error.message, "boom")
            test.eq(page.error.retriable, true)
            test.eq(page.error.scope, "provider")
        end)

        test.it("rejects a missing project_id as invalid_config", function()
            local client = new_fake_client({})
            local page = pull_core.list_merge_requests(client, nil, {})
            test.eq(page.success, false)
            test.eq(page.error.code, "invalid_config")
            test.eq(page.error.retriable, false)
        end)

        test.it("produces lightweight keys with the documented stable-key format", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 555, iid = 21, updated_at = "2026-08-02T11:00:00.000Z" }) }, next_page = "" },
            })
            local page = pull_core.list_merge_request_keys(client, "278964", {})
            test.eq(page.success, true)
            test.is_nil(page.items)
            test.eq(#page.keys, 1)
            local key_item = page.keys[1]
            test.eq(key_item.item_key, "gitlab:278964:mr:21")
            test.eq(key_item.dedup_key, "gitlab:278964:mr:21:upsert:2026-08-02T11:00:00.000Z")

            local field_count = 0
            for _ in pairs(key_item) do field_count = field_count + 1 end
            test.eq(field_count, 2, "keys-only items must carry exactly item_key/dedup_key, no full record fields")
        end)

        test.it("resolve_client resolves component_id via deps, then ctx, then config.connection_id", function()
            local seen = {}
            local fake_transport = {
                resolve = function(component_id)
                    seen[#seen + 1] = component_id
                    return { fake = true }, nil
                end,
            }
            local client, err = pull_core.resolve_client({ connection_id = "from-config" }, { transport = fake_transport, component_id = "from-deps" })
            test.is_nil(err)
            test.not_nil(client)
            test.eq(seen[1], "from-deps")
        end)

        test.it("resolve_client falls back to config.connection_id when nothing else supplies a component_id", function()
            local seen = {}
            local fake_transport = {
                resolve = function(component_id)
                    seen[#seen + 1] = component_id
                    return { fake = true }, nil
                end,
            }
            local client, err = pull_core.resolve_client({ connection_id = "from-config" }, { transport = fake_transport })
            test.is_nil(err)
            test.eq(seen[1], "from-config")
        end)

        test.it("resolve_client returns a connection DataError when no component_id resolves", function()
            local fake_transport = { resolve = function() return nil, "unused" end }
            local client, err = pull_core.resolve_client({}, { transport = fake_transport })
            test.is_nil(client)
            test.not_nil(err)
            test.eq(err.error.code, "auth_expired")
            test.eq(err.error.scope, "connection")
        end)

        test.it("resolve_client returns a connection DataError when transport.resolve itself fails", function()
            local fake_transport = { resolve = function() return nil, "revoked" end }
            local client, err = pull_core.resolve_client({ connection_id = "conn1" }, { transport = fake_transport })
            test.is_nil(client)
            test.eq(err.error.code, "auth_expired")
            test.eq(err.error.message, "revoked")
        end)

        test.it("passes the pullable conformance kit offline", function()
            local fixture = {
                raw_mr({ id = 1, iid = 1, updated_at = "2026-05-01T00:00:00.000Z" }),
                raw_mr({ id = 2, iid = 2, updated_at = "2026-06-01T00:00:00.000Z" }),
                raw_mr({ id = 3, iid = 3, updated_at = "2026-07-01T00:00:00.000Z" }),
            }
            local ok_client = new_conformance_client(fixture)
            local fake_transport = {
                resolve = function(component_id)
                    if component_id == "bad" then return nil, "revoked" end
                    return ok_client, nil
                end,
            }

            local function adapter(list_fn)
                return function(req)
                    req = type(req) == "table" and req or {}
                    local config = type(req.config) == "table" and req.config or {}
                    local client, cerr = pull_core.resolve_client(config, { transport = fake_transport })
                    if cerr then return cerr end
                    local project_id = tostring(config.project_id or "123")
                    return list_fn(client, project_id, {
                        cursor = req.cursor,
                        config = config,
                        limit = req.limit,
                        max_pages = 1,
                    })
                end
            end

            local result = conformance.run({
                pull = adapter(pull_core.list_merge_requests),
                config = { connection_id = "conn1", project_id = "123" },
                failure_config = { connection_id = "bad", project_id = "123" },
                backfill_since = { mode = "honored", value = "2026-06-01T00:00:00.000Z" },
                limit = 2,
                max_pages = 5,
                pull_keys = adapter(pull_core.list_merge_request_keys),
            })
            test.eq(result.success, true, conformance.format_failures(result))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
