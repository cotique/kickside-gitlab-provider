-- Maps HTTP/transport-level failures onto the { code, message, retriable,
-- scope } error envelope. This shape is CONFIRMED, not inferred — it is the
-- failure envelope of the real, unpacked kickside.data:writable.write
-- reference (the template scaffold's src/sink/write.lua before it was
-- removed; see BUILD-NOTES.md and the shared build brief). pull_core reuses
-- it verbatim for its own failures so both the (confirmed) write-side shape
-- and the (inferred, see source/pull_items.lua) read-side envelope agree on
-- how an error looks.
local M = {}

-- One error envelope, always `{ code, message, retriable, scope }`.
local function envelope(code, message, retriable, scope)
    return {
        code = code,
        message = tostring(message),
        retriable = retriable == true,
        scope = scope or "request",
    }
end

M.envelope = envelope

-- Map a GitLab API non-2xx HTTP response onto the envelope. `body` is the
-- raw response body string; GitLab typically returns `{"message": "..."}` on
-- 401s (per the provider brief) — surface that when present.
function M.from_http(status, body, opts)
    opts = opts or {}
    local scope = opts.scope or "request"

    local api_message
    if type(body) == "string" and body ~= "" then
        local json = require("json")
        local decoded, derr = json.decode(body)
        if not derr and type(decoded) == "table" then
            if type(decoded.message) == "string" then
                api_message = decoded.message
            elseif type(decoded.message) == "table" then
                -- GitLab sometimes returns message as an array/table of
                -- validation errors; stringify defensively rather than
                -- dropping it.
                local ok, encoded = pcall(json.encode, decoded.message)
                api_message = ok and encoded or "validation error"
            elseif type(decoded.error) == "string" then
                api_message = decoded.error
            end
        end
    end

    if status == 401 or status == 403 then
        return envelope("unauthorized", api_message or ("GitLab request unauthorized (HTTP " .. tostring(status) .. ")"), false, scope)
    elseif status == 404 then
        return envelope("not_found", api_message or "GitLab resource not found", false, scope)
    elseif status == 429 then
        return envelope("rate_limited", api_message or "GitLab rate limit exceeded", true, scope)
    elseif type(status) == "number" and status >= 500 then
        return envelope("provider_unavailable", api_message or ("GitLab server error (HTTP " .. tostring(status) .. ")"), true, scope)
    else
        return envelope("invalid_request", api_message or ("GitLab request failed (HTTP " .. tostring(status) .. ")"), false, scope)
    end
end

-- Map a transport-level failure (DNS, TLS, timeout, connection reset — no
-- HTTP response at all) onto the envelope. Always retriable: none of these
-- indicate a malformed request, only that this attempt didn't reach GitLab.
function M.from_transport(err, opts)
    opts = opts or {}
    local scope = opts.scope or "request"
    local message = "GitLab request failed"
    if err ~= nil then
        if type(err) == "table" and err.message then
            local ok, m = pcall(function() return err:message() end)
            message = ok and m or tostring(err.message)
        else
            message = tostring(err)
        end
    end
    return envelope("provider_unavailable", message, true, scope)
end

return M
