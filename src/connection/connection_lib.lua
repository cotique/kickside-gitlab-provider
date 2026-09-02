-- Shared connection helper for this binding's provider-specific methods
-- (test_connection, discover_resources). Resolves component_id from ambient
-- context and builds a configured GitLab API client for it.
--
-- Per docs/kickside-development/04-connections-and-integrations.md:
-- "test_connection/discover_resources resolve component_id from ambient
-- context and open a transport handle" — and per
-- docs/kickside-development/19-discovery-addressing-and-context.md: "The
-- binding declares context_required: [component_id]; its implementation
-- reads ctx.get('component_id')."
local ctx = require("ctx")
local transport = require("transport")

local M = {}

-- The component_id the platform bound into ambient context for this call
-- (context_required: [component_id] on every method of this binding).
function M.component_id()
    local id, err = ctx.get("component_id")
    if err then
        return nil, err
    end
    if type(id) ~= "string" or id == "" then
        return nil, "component_id not in scope"
    end
    return id, nil
end

-- Resolve the ambient component_id and hand back a configured GitLab API
-- client for it. Delegates the actual credential read to client:transport
-- so the connection layer and the pull source layer share one
-- private_context->client resolution path.
function M.get_client()
    local component_id, err = M.component_id()
    if err then
        return nil, err
    end
    return transport.resolve(component_id)
end

return M
