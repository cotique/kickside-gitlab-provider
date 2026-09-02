-- Unit tests for pull_core's pagination + fetch + normalize logic, against a
-- plain Lua test double for client:api — no real network call. Fixtures are
-- built from the real GitLab merge_request field names captured in
-- BUILD-NOTES.md ("Empirically-verified REST API pagination shapes" — live
-- calls made 2026-09-02 against gitlab.com).
local test = require("test")
local pull_core = require("pull_core")

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
-- sort/per_page/page) as well as on the walk itself.
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

    -- Test-only accessors so assertions never chain-index client.calls[n]
    -- directly (calls[n] is possibly-nil to the type checker; these narrow
    -- with an explicit error() before returning).
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

local function define_tests()
    test.describe("cotique.gitlab_provider.source pull_core", function()
        test.it("normalizes every field in the shared normalized item shape", function()
            local client = new_fake_client({
                { items = { raw_mr({}) }, next_page = "" },
            })
            local result, err = pull_core.list_merge_requests(client, "278964", {})
            test.is_nil(err)
            test.not_nil(result)
            test.eq(#result.items, 1)

            local item = result.items[1]
            test.eq(item.id, "111")
            test.eq(item.title, "Fix flaky test")
            test.eq(item.state, "open") -- opened -> open
            test.eq(item.author, "Jane Doe")
            test.eq(item.source_branch, "fix/flaky-test")
            test.eq(item.target_branch, "main")
            test.eq(item.created_at, "2026-08-01T10:00:00.000Z")
            test.eq(item.updated_at, "2026-08-02T11:00:00.000Z")
            test.is_nil(item.merged_at)
            test.eq(item.url, "https://gitlab.com/example/project/-/merge_requests/7")
            test.not_nil(item.raw, "raw must carry the original API item")
            test.eq(item.raw.iid, 7)
        end)

        test.it("maps merged and closed states", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 1, iid = 1, state = "merged", merged_at = "2026-08-03T00:00:00.000Z" }),
                            raw_mr({ id = 2, iid = 2, state = "closed" }) }, next_page = "" },
            })
            local result, err = pull_core.list_merge_requests(client, "278964", {})
            test.is_nil(err)
            test.eq(result.items[1].state, "merged")
            test.eq(result.items[1].merged_at, "2026-08-03T00:00:00.000Z")
            test.eq(result.items[2].state, "closed")
        end)

        test.it("falls back to author.username when author.name is blank", function()
            local client = new_fake_client({
                { items = { raw_mr({ author = { id = 9, username = "ghost", name = "" } }) }, next_page = "" },
            })
            local result = pull_core.list_merge_requests(client, "278964", {})
            test.eq(result.items[1].author, "ghost")
        end)

        test.it("walks multiple pages via x-next-page and stops when it is empty", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 1, iid = 1 }), raw_mr({ id = 2, iid = 2 }) }, next_page = "2" },
                { items = { raw_mr({ id = 3, iid = 3 }) }, next_page = "3" },
                { items = { raw_mr({ id = 4, iid = 4 }) }, next_page = "" },
            })
            local result, err = pull_core.list_merge_requests(client, "278964", { max_pages = 5 })
            test.is_nil(err)
            test.eq(#result.items, 4)
            test.eq(result.has_more, false)
            test.is_nil(result.next_cursor)
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

        test.it("stops at the per-call page cap and returns a resumable cursor", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 1, iid = 1 }) }, next_page = "2" },
                -- Second page is never fetched: max_pages = 1 caps the walk.
            })
            local result, err = pull_core.list_merge_requests(client, "278964", { max_pages = 1 })
            test.is_nil(err)
            test.eq(#result.items, 1)
            test.eq(result.has_more, true)
            test.eq(result.next_cursor, "2")
            test.eq(client:call_count(), 1)
        end)

        test.it("resumes from an explicit cursor on the next call", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 9, iid = 9 }) }, next_page = "" },
            })
            local result, err = pull_core.list_merge_requests(client, "278964", { cursor = "4" })
            test.is_nil(err)
            test.eq(client:query_field(1, "page"), "4")
            test.eq(#result.items, 1)
        end)

        test.it("propagates a client error without wrapping it again", function()
            local boom = { code = "provider_unavailable", message = "boom", retriable = true, scope = "pull" }
            local client = new_fake_client({ { err = boom } })
            local result, err = pull_core.list_merge_requests(client, "278964", {})
            test.is_nil(result)
            test.not_nil(err)
            test.eq(err.code, "provider_unavailable")
            test.eq(err.message, "boom")
        end)

        test.it("rejects a missing project_id", function()
            local client = new_fake_client({})
            local result, err = pull_core.list_merge_requests(client, nil, {})
            test.is_nil(result)
            test.not_nil(err)
            test.eq(err.code, "invalid_request")
            test.eq(err.retriable, false)
        end)

        test.it("produces lightweight keys with the documented stable-key format", function()
            local client = new_fake_client({
                { items = { raw_mr({ id = 555, iid = 21 }) }, next_page = "" },
            })
            local result, err = pull_core.list_merge_request_keys(client, "278964", {})
            test.is_nil(err)
            test.eq(#result.items, 1)
            local key_item = result.items[1]
            test.eq(key_item.id, "555")
            test.eq(key_item.key, "gitlab:278964:mr:21")
            test.eq(key_item.updated_at, "2026-08-02T11:00:00.000Z")

            local field_count = 0
            for _ in pairs(key_item) do field_count = field_count + 1 end
            test.eq(field_count, 3, "keys-only items must carry exactly id/key/updated_at, no full record fields")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
