-- kickside.contract:component.get_status / kickside.connection:connection.get_status
--
-- ================================ CAVEAT =================================
-- docs/kickside-development/04-connections-and-integrations.md states
-- plainly: "get_status is a component read-model, not a live probe... The
-- implementation imports kickside.connection:base_connection for
-- get_status/delete boilerplate" and calls the resulting binding "a thin
-- adapter" that "delegate[s] to the base library." What is NOT documented
-- anywhere reachable from this checkout (same Hub-visibility wall as the
-- kickside.data:pullable envelope — kickside/connection ships as a packed
-- Hub module, `wippy registry show kickside.connection:base_connection
-- --json` returns "data": null) is base_connection's exact exported
-- function name/signature.
--
-- This file makes the smallest possible assumption: that base_connection
-- exports a table with a `get_status` function whose call signature matches
-- whatever this contract method is invoked with (varargs passthrough, no
-- shape assumed beyond "a function named get_status exists"). If that
-- assumption is wrong, only this file needs to change — see BUILD-NOTES.md
-- "Secondary open item: base_connection's exact export shape".
-- ===========================================================================
local base_connection = require("base_connection")

local function get_status(...)
    return base_connection.get_status(...)
end

return { get_status = get_status }
