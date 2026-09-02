-- Safe output encoding. Redacts anything that could be a credential before it
-- reaches a log line, error message, or test fixture dump — per AGENTS.md
-- "Never log tokens, credentials, private component context, authorization
-- headers, or full user payloads."
local REDACTED = "***redacted***"

-- Key names (lowercased) that are always treated as sensitive, wherever they
-- appear in a table passed to redact().
local SENSITIVE_KEYS = {
    token = true,
    private_token = true,
    ["private-token"] = true,
    ["authorization"] = true,
    app_password = true,
    access_token = true,
    password = true,
    secret = true,
}

local M = {}

-- Deep-copies `value`, replacing any table value whose key (case-insensitive)
-- is a known-sensitive name with a fixed redaction marker. Non-table leaves
-- pass through unchanged. Safe on cyclic-free plain data (JSON-shaped
-- request/response/credential tables); does not attempt cycle detection.
local function redact(value)
    if type(value) ~= "table" then
        return value
    end

    local out = {}
    for k, v in pairs(value) do
        local key_str = type(k) == "string" and k:lower() or nil
        if key_str and SENSITIVE_KEYS[key_str] then
            out[k] = REDACTED
        else
            out[k] = redact(v)
        end
    end
    return out
end

M.redact = redact
M.REDACTED = REDACTED

return M
