-- Unit tests for the GitLabRead/GitLabWrite agent-tool handlers
-- (src/traits/read_tool.lua, write_tool.lua) against a fake client:api —
-- no real network call, mirroring both this module's own pull_core_test.lua
-- fake-client pattern and the real, unpacked kickside/github reference's
-- traits_test.lua (providers-master/github/src/traits/traits_test.lua).
-- Registry-shape assertions (agent.trait meta, tools: lists, mcp scopes,
-- action enums) live in wiring_test.lua instead — this file covers handler
-- behavior: validation, dispatch, and error surfacing.
local test = require("test")
local json = require("json")
local data_error = require("data_error")
local read_tool = require("read_tool")
local write_tool = require("write_tool")

local fake_output = {
    encode = function(data: any): string
        return json.encode(data)
    end,
}

-- Swaps a trait module's _transport/_output test seams for the duration of
-- fn, restoring them afterward even if fn throws — same shape as
-- traits_test.lua's real reference `with_tool`.
local function with_tool(tool: any, fake_transport: any, fn: any)
    local old_transport, old_output = tool._transport, tool._output
    tool._transport = fake_transport
    tool._output = fake_output
    local ok, err = pcall(fn)
    tool._transport, tool._output = old_transport, old_output
    if not ok then error(err) end
end

-- client:transport.resolve(component_id) -> client:api instance, nil (see
-- client/transport.lua) — NOT the same shape as GitHub's tp.connect, which
-- returns a `conn` with per-action methods already attached.
local function resolve_ok(fake_client: any): any
    return { resolve = function(_component_id: any): (any, any?) return fake_client, nil end }
end

local function resolve_should_not_be_called(): any
    return { resolve = function(): any error("resolve should not be called for invalid args") end }
end

-- A realistic raw GitLab merge_request item — same fixture shape as
-- pull_core_test.lua's own raw_mr, since both exercise the same
-- normalize_mr/stable_key logic.
local function raw_mr(overrides: any): any
    local mr: any = {
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

local function define_tests()
    test.describe("GitLabRead tool", function()
        test.it("validates action and project/iid arguments before opening a connection", function()
            with_tool(read_tool, resolve_should_not_be_called(), function()
                test.ok(read_tool.handler({}):find("action is required"))
                test.ok(read_tool.handler({ action = "nope" }):find("unknown action"))
                test.ok(read_tool.handler({ action = "get_merge_request" }):find("project_id is required"))
                test.ok(read_tool.handler({ action = "get_merge_request", project_id = "1" }):find("iid is required"))
                test.ok(read_tool.handler({ action = "list_merge_request_notes", project_id = "1" }):find("iid is required"))
                -- list_merge_requests needs no iid, only project_id.
                test.is_nil(read_tool.handler({ action = "list_merge_requests" }):find("iid is required"))
            end)
        end)

        test.it("lists merge requests by reusing pull_core, unwrapped down to payloads", function()
            local fake_client: any = {}
            function fake_client:get(path: string, _opts: any): any
                test.ok(path:find("/projects/278964/merge_requests", 1, true))
                return { body = { raw_mr({}) }, headers = { ["x-next-page"] = "" }, status_code = 200 }, nil
            end
            with_tool(read_tool, resolve_ok(fake_client), function()
                local decoded = json.decode(tostring(read_tool.handler({ action = "list_merge_requests", project_id = "278964" })))
                test.eq(#decoded.merge_requests, 1)
                test.eq(decoded.merge_requests[1].title, "Fix flaky test")
                test.eq(decoded.merge_requests[1].state, "open") -- opened -> open, via pull_core's own MR_STATE_MAP
                test.eq(decoded.has_more, false)
            end)
        end)

        test.it("gets one merge request by iid and normalizes it via pull_core", function()
            local fake_client: any = {}
            function fake_client:get(path: string, _opts: any): any
                test.ok(path:find("/projects/278964/merge_requests/7", 1, true))
                return { body = raw_mr({}), headers = {}, status_code = 200 }, nil
            end
            with_tool(read_tool, resolve_ok(fake_client), function()
                local decoded = json.decode(tostring(read_tool.handler({ action = "get_merge_request", project_id = "278964", iid = "7" })))
                test.eq(decoded.title, "Fix flaky test")
                test.eq(decoded.state, "open")
                test.eq(decoded.source_url, "https://gitlab.com/example/project/-/merge_requests/7")
            end)
        end)

        test.it("lists merge request notes, falling back to author.username when name is blank", function()
            local fake_client: any = {}
            function fake_client:get(path: string, _opts: any): any
                test.ok(path:find("/projects/278964/merge_requests/7/notes", 1, true))
                return {
                    body = {
                        { id = 1, body = "looks good", author = { name = "Jane Doe", username = "jdoe" },
                          created_at = "2026-08-02T00:00:00Z", updated_at = "2026-08-02T00:00:00Z", system = false },
                        { id = 2, body = "ping", author = { name = "", username = "ghost" },
                          created_at = "2026-08-02T01:00:00Z", updated_at = "2026-08-02T01:00:00Z", system = false },
                    },
                    headers = {},
                    status_code = 200,
                }, nil
            end
            with_tool(read_tool, resolve_ok(fake_client), function()
                local decoded = json.decode(tostring(read_tool.handler({ action = "list_merge_request_notes", project_id = "278964", iid = "7" })))
                test.eq(#decoded, 2)
                test.eq(decoded[1].body, "looks good")
                test.eq(decoded[1].author, "Jane Doe")
                test.eq(decoded[2].author, "ghost")
            end)
        end)

        test.it("surfaces connection and API errors", function()
            with_tool(read_tool, { resolve = function(): (any?, string) return nil, "no GitLab connection selected" end }, function()
                test.ok(read_tool.handler({ action = "list_merge_requests", project_id = "1" }):find("no GitLab connection selected"))
            end)
            local fake_client: any = {}
            function fake_client:get(): any
                return nil, { success = false, error = { code = "permission_denied", message = "forbidden", retriable = false, scope = "flow" } }
            end
            with_tool(read_tool, resolve_ok(fake_client), function()
                test.ok(read_tool.handler({ action = "get_merge_request", project_id = "1", iid = "1" }):find("forbidden"))
            end)
        end)
    end)

    test.describe("GitLabWrite tool", function()
        test.it("validates write arguments before opening a connection", function()
            with_tool(write_tool, resolve_should_not_be_called(), function()
                test.ok(write_tool.handler({}):find("action is required"))
                test.ok(write_tool.handler({ action = "drop", project_id = "1" }):find("unknown action"))
                test.ok(write_tool.handler({ action = "create_merge_request" }):find("project_id is required"))
                test.ok(write_tool.handler({ action = "create_merge_request", project_id = "1" }):find("source_branch is required"))
                test.ok(write_tool.handler({ action = "create_merge_request", project_id = "1", source_branch = "a", target_branch = "main" }):find("title is required"))
                test.ok(write_tool.handler({ action = "update_merge_request", project_id = "1" }):find("iid is required"))
                test.ok(write_tool.handler({ action = "update_merge_request", project_id = "1", iid = "1" }):find("at least one field"))
                test.ok(write_tool.handler({ action = "update_merge_request", project_id = "1", iid = "1", state = "merged" }):find("state must be open or closed"))
                test.ok(write_tool.handler({ action = "create_note", project_id = "1", iid = "1" }):find("body is required"))
            end)
        end)

        test.it("never dispatches a merge/approve/delete action — no such action exists to route to", function()
            with_tool(write_tool, resolve_should_not_be_called(), function()
                for _, action in ipairs({ "merge_merge_request", "merge", "approve_merge_request", "delete_merge_request" }) do
                    test.ok(write_tool.handler({ action = action, project_id = "1" }):find("unknown action"), action .. " must not be a known action")
                end
            end)
        end)

        test.it("creates a merge request with comma-joined labels and integer id arrays", function()
            local seen: any = nil
            local fake_client: any = {}
            function fake_client:post(path: string, body: any, opts: any): any
                seen = { path = path, body = body, scope = opts and opts.scope }
                return { body = raw_mr({ id = 900, iid = 42 }), headers = {}, status_code = 201 }, nil
            end
            with_tool(write_tool, resolve_ok(fake_client), function()
                local decoded = json.decode(tostring(write_tool.handler({
                    action = "create_merge_request",
                    project_id = "278964",
                    source_branch = "feature/x",
                    target_branch = "main",
                    title = "Add X",
                    labels = { "bug", "urgent" },
                    assignee_ids = { 1, 2 },
                    reviewer_ids = { 3 },
                    remove_source_branch = true,
                })))
                test.eq(decoded.iid, 42)
                test.eq(decoded.item_key, "gitlab:278964:mr:42")
                test.ok(seen.path:find("/projects/278964/merge_requests", 1, true))
                test.eq(seen.scope, "create_merge_request")
                test.eq(seen.body.source_branch, "feature/x")
                test.eq(seen.body.target_branch, "main")
                test.eq(seen.body.title, "Add X")
                test.eq(seen.body.labels, "bug,urgent")
                test.eq(seen.body.assignee_ids[1], 1)
                test.eq(seen.body.assignee_ids[2], 2)
                test.eq(seen.body.reviewer_ids[1], 3)
                test.eq(seen.body.remove_source_branch, true)
            end)
        end)

        test.it("updates a merge request, translating the tool's open|closed to the real state_event close|reopen field", function()
            local calls: { any } = {}
            local fake_client: any = {}
            function fake_client:put(path: string, body: any, _opts: any): any
                calls[#calls + 1] = { path = path, body = body }
                return { body = raw_mr({ id = 111, iid = 7, state = "closed" }), headers = {}, status_code = 200 }, nil
            end
            with_tool(write_tool, resolve_ok(fake_client), function()
                local closed = json.decode(tostring(write_tool.handler({ action = "update_merge_request", project_id = "278964", iid = "7", state = "closed" })))
                test.eq(closed.state, "closed")
                test.ok(calls[1].path:find("/projects/278964/merge_requests/7", 1, true))
                -- CONFIRMED live against docs.gitlab.com/ee/api/merge_requests.html
                -- "Update MR": the wire field is state_event (close/reopen),
                -- never state (opened/closed) — see write_tool.lua's header.
                test.eq(calls[1].body.state_event, "close")
                test.is_nil(calls[1].body.state)

                write_tool.handler({ action = "update_merge_request", project_id = "278964", iid = "7", state = "open" })
                test.eq(calls[2].body.state_event, "reopen")
            end)
        end)

        test.it("clears all labels on update when given an empty labels array, per GitLab's documented unassign-via-empty-string", function()
            local seen: any = nil
            local fake_client: any = {}
            function fake_client:put(_path: string, body: any, _opts: any): any
                seen = body
                return { body = raw_mr({}), headers = {}, status_code = 200 }, nil
            end
            with_tool(write_tool, resolve_ok(fake_client), function()
                write_tool.handler({ action = "update_merge_request", project_id = "278964", iid = "7", labels = {} })
                test.eq(seen.labels, "")
            end)
        end)

        test.it("creates a note", function()
            local seen: any = nil
            local fake_client: any = {}
            function fake_client:post(path: string, body: any, _opts: any): any
                seen = { path = path, body = body }
                return {
                    body = { id = 55, body = "done", author = { name = "Jane Doe" }, created_at = "2026-08-02T00:00:00Z", updated_at = "2026-08-02T00:00:00Z" },
                    headers = {}, status_code = 201,
                }, nil
            end
            with_tool(write_tool, resolve_ok(fake_client), function()
                local decoded = json.decode(tostring(write_tool.handler({ action = "create_note", project_id = "278964", iid = "7", body = "done" })))
                test.eq(decoded.id, 55)
                test.eq(decoded.body, "done")
                test.eq(decoded.author, "Jane Doe")
                test.ok(seen.path:find("/projects/278964/merge_requests/7/notes", 1, true))
                test.eq(seen.body.body, "done")
            end)
        end)

        test.it("surfaces write API errors, including the real data_error 403 -> permission_denied mapping", function()
            with_tool(write_tool, { resolve = function(): (any?, string) return nil, "no GitLab connection selected" end }, function()
                test.ok(write_tool.handler({ action = "create_note", project_id = "1", iid = "1", body = "x" }):find("no GitLab connection selected"))
            end)

            -- Fakes only the network layer (http_client indirectly, via a
            -- fake client:post) while running the module's REAL data_error
            -- mapping — the same taxonomy client/api.lua's own client.post
            -- would produce for a real 403, per data_error_test.lua.
            local fake_client: any = {}
            function fake_client:post(): any
                return nil, data_error.from_result({ status_code = 403, error = "insufficient_scope" }, "GitLab create_merge_request request")
            end
            with_tool(write_tool, resolve_ok(fake_client), function()
                local raw = write_tool.handler({ action = "create_merge_request", project_id = "1", source_branch = "a", target_branch = "main", title = "t" })
                test.ok(raw:find("insufficient_scope"))
            end)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
