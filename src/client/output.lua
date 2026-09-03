-- Safe output encoding. Redacts anything that could be a credential before it
-- reaches a log line, error message, or test fixture dump — per AGENTS.md
-- "Never log tokens, credentials, private component context, authorization
-- headers, or full user payloads."
--
-- M.encode (added for the v2 write-access agent traits, src/traits/) is new;
-- M.redact/M.REDACTED below are the original, unchanged, independently
-- tested (test/src/output_test.lua) surface this module always had.
-- M.encode is a thin composition on top of the existing M.redact — same
-- sensitive-key taxonomy, no new redaction logic — plus JSON encoding and a
-- UTF-8-safe truncation to a byte budget, matching the real, unpacked
-- kickside/github reference's own client:output.encode(data, max_output)
-- shape (providers-master/github/src/client/output.lua) that
-- src/traits/read_tool.lua and write_tool.lua call.
local json = require("json")

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

-- UTF-8-safe prefix: never cuts a multi-byte character in half. Walks
-- backward from max_bytes to the start of the character straddling the
-- boundary and drops it whole, same algorithm as the real reference
-- (providers-master/github/src/client/output.lua's safe_prefix/
-- utf8_char_len).
local function utf8_char_len(first_byte)
    if first_byte < 128 then return 1 end
    if first_byte < 224 then return 2 end
    if first_byte < 240 then return 3 end
    if first_byte < 248 then return 4 end
    return 1
end

local function safe_prefix(text, max_bytes)
    local limit = math.floor(max_bytes)
    if #text <= limit then return text end
    local n = limit
    while n > 0 do
        local b = string.byte(text, n)
        if not b or b < 128 or b >= 192 then break end
        n = n - 1
    end
    local b = n > 0 and string.byte(text, n) or nil
    if b and b >= 128 and n + utf8_char_len(b) - 1 > limit then n = n - 1 end
    if n < 1 then return "" end
    return text:sub(1, n)
end
M.safe_prefix = safe_prefix

-- encode(data, max_output) -> JSON text as a string, safe to hand straight
-- to an agent-tool caller: redacted via the same M.redact used everywhere
-- else in this module, then truncated (with a { truncated, original_length,
-- json_preview } wrapper) if it would exceed max_output bytes. Used by
-- src/traits/read_tool.lua and write_tool.lua — every other caller in this
-- module goes through data_error/DataError instead, which never carries a
-- credential.
function M.encode(data, max_output)
    local text, encode_err = json.encode(redact(data == nil and {} or data))
    if encode_err then
        return json.encode({ error = "encode error", message = tostring(encode_err) })
    end
    if #text > max_output then
        return json.encode({
            truncated = true,
            original_length = #text,
            json_preview = safe_prefix(text, max_output),
        })
    end
    return text
end

return M
