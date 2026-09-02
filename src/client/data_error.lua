-- Maps HTTP/transport/config-level failures onto the kickside.data DataError
-- envelope: { success = false, error = { code, message, retriable, scope },
-- retry_after_ms? }. This shape and function surface (M.failure, M.connection,
-- M.invalid_config, M.from_result) are CONFIRMED, not inferred — copied
-- verbatim in spirit from the real, unpacked reference implementation:
--   providers-master/github/src/client/data_error.lua
-- and cross-checked against kickside/atlassian's own error handling, which
-- calls the identically-named M.connection/M.invalid_config/M.from_result
-- helpers from kickside.atlassian.jira.source:pull_core (see
-- providers-master/atlassian/src/jira/source/pull_core.lua). See
-- BUILD-NOTES.md, "kickside.data:pullable's exact envelope — RESOLVED".
--
-- Earlier revision of this file exposed a different surface (M.envelope,
-- M.from_http, M.from_transport) returning a *bare* { code, message,
-- retriable, scope } table, inferred by analogy rather than confirmed. That
-- surface is gone; every call site (client/api.lua, source/pull_core.lua,
-- connection/test_connection.lua, connection/discover_resources.lua) has
-- been updated to the shape below.
local M = {}

-- One full pullable-contract failure envelope.
local function failure(code, message, retriable, scope, retry_after_ms)
    local out = {
        success = false,
        error = {
            code = code,
            message = tostring(message),
            retriable = retriable == true,
            scope = scope,
        },
    }
    if retry_after_ms ~= nil then
        out.retry_after_ms = retry_after_ms
    end
    return out
end
M.failure = failure

-- A revoked/expired/unresolvable connection component.
function M.connection(message)
    return failure("auth_expired", message, false, "connection")
end

-- A structurally invalid config (missing/malformed required field).
function M.invalid_config(message)
    return failure("invalid_config", message, false, "flow")
end

-- Map a client-result-shaped table ({ status_code, error, retry_after_ms? })
-- onto the taxonomy above. `result.status_code = 0` means "no HTTP response
-- at all" (transport-level failure: DNS, TLS, timeout, connection reset) —
-- always mapped to provider_unavailable, same as a real 5xx.
function M.from_result(result, action)
    local r = type(result) == "table" and result or {}
    local status = tonumber(r.status_code) or 0
    local message = tostring(action) .. ": " .. tostring(r.error or "request failed")
    if status == 429 then
        return failure("rate_limited", message, true, "provider", tonumber(r.retry_after_ms) or 1000)
    end
    if status == 401 then
        return failure("auth_expired", message, false, "connection")
    end
    if status == 403 then
        return failure("permission_denied", message, false, "flow")
    end
    if status == 404 then
        return failure("not_found", message, false, "flow")
    end
    if status >= 500 or status == 0 then
        return failure("provider_unavailable", message, true, "provider")
    end
    return failure("provider_error", message, true, "provider")
end

return M
