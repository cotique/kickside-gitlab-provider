-- Actor-scoped resolver: given a connection component_id, reads its
-- private_context through the actor-validated component service and hands
-- back a configured client:api instance.
--
-- Per docs/kickside-development/04-connections-and-integrations.md:
-- "Providers read credentials through the actor-validated component service,
-- normally component.get_private_context(component_id). There is no
-- registry or raw-SQL fallback for credential lookup." This is the ONLY
-- place in the module that reads private_context — both the connection
-- functions (via connection_lib) and the pull source share this one
-- resolver, per AGENTS.md "One package owns each declaration."
local component = require("component")
local api = require("api")
local types = require("types")

local M = {}

-- resolve(component_id) -> client:api instance, nil
--                       -> nil, error message (string)
function M.resolve(component_id)
    if type(component_id) ~= "string" or component_id == "" then
        return nil, "component_id is required"
    end

    local creds, err = component.get_private_context(component_id)
    if err then
        return nil, err
    end
    if type(creds) ~= "table" then
        return nil, "connection has no private context"
    end

    local token = creds.token
    if type(token) ~= "string" or token == "" then
        return nil, "connection is missing its access token"
    end

    local base_url = creds.base_url
    if type(base_url) ~= "string" or base_url == "" then
        base_url = types.DEFAULT_BASE_URL
    end
    -- Trim trailing slashes so path concatenation in client:api never
    -- produces a doubled "//api/v4".
    base_url = base_url:gsub("/+$", "")

    return api.new({
        base_url = base_url .. "/api/v4",
        token = token,
    }), nil
end

return M
