-- Low-level GitLab REST client. Independently unit-testable: pull_core and
-- the connection functions depend on this object's interface, not on
-- http_client directly, so tests can substitute a fake client that returns
-- canned responses without any real network call.
--
-- Auth/pagination mechanics implemented here are EMPIRICALLY VERIFIED (see
-- BUILD-NOTES.md "Empirically-verified REST API pagination shapes" — live
-- calls made 2026-09-02 against gitlab.com):
--   - Header: PRIVATE-TOKEN: <token> on every request.
--   - Pagination via page/per_page query params; x-next-page response header
--     is empty string (not absent) when there is no next page; X-Total /
--     X-Total-Pages are NOT present on list endpoints — never depend on a
--     total count to decide when to stop paginating.
--
-- Deliberately not a metatable/class object (this codebase's own convention
-- — see repo.lua in the template scaffold this module started from — is
-- plain module-level tables of named functions, and the Wippy Luau-style
-- type checker does not follow setmetatable-based method dispatch). Each
-- client is a fresh table of closures over its own base_url/token.
local http_client = require("http_client")
local json = require("json")
local data_error = require("data_error")

local M = {}

-- Case-insensitive header lookup. http_client's Go-side transport may
-- canonicalize header casing (e.g. "X-Next-Page") differently than the
-- lowercase form GitLab's own docs use ("x-next-page") — do not assume
-- either casing survives into the Lua table verbatim.
local function get_header(headers, name)
    if type(headers) ~= "table" then return nil end
    local wanted = name:lower()
    for k, v in pairs(headers) do
        if type(k) == "string" and k:lower() == wanted then
            return v
        end
    end
    return nil
end
M.get_header = get_header

-- new({ base_url, token }) -> client table with a get(path, opts) method.
function M.new(opts)
    opts = type(opts) == "table" and opts or {}
    local base_url = type(opts.base_url) == "string" and opts.base_url or ""
    local token = type(opts.token) == "string" and opts.token or ""

    local client = {}

    -- GET path (relative to base_url, must start with "/") with optional
    -- { query = {...}, scope = "..." }. Returns
    --   { body = <decoded JSON>, headers = <response headers>, status_code = n }, nil
    -- on success (2xx with a JSON body), or nil, <data_error envelope> on any
    -- failure (transport failure, non-2xx, or a non-JSON 2xx body).
    function client.get(_, path, get_opts)
        get_opts = type(get_opts) == "table" and get_opts or {}
        local scope = type(get_opts.scope) == "string" and get_opts.scope or "request"
        local headers = { ["PRIVATE-TOKEN"] = token }
        local url = base_url .. path

        local resp, err = http_client.get(url, {
            headers = headers,
            query = type(get_opts.query) == "table" and get_opts.query or {},
            timeout = "30s",
        })
        if err then
            return nil, data_error.from_transport(err, { scope = scope })
        end

        if resp.status_code < 200 or resp.status_code >= 300 then
            return nil, data_error.from_http(resp.status_code, resp.body, { scope = scope })
        end

        local body = resp.body
        if type(body) ~= "string" then
            return nil, data_error.envelope("invalid_response", "GitLab response had no body", false, scope)
        end

        local decoded, derr = json.decode(body)
        if derr then
            return nil, data_error.envelope(
                "invalid_response",
                "GitLab response was not valid JSON: " .. tostring(derr),
                false,
                scope)
        end

        return { body = decoded, headers = resp.headers, status_code = resp.status_code }, nil
    end

    return client
end

return M
