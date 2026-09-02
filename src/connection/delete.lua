-- kickside.contract:deletable.delete — delegates to base_connection.
-- See get_status.lua for the full caveat on base_connection's exact export
-- shape (same reasoning applies here verbatim).
local base_connection = require("base_connection")

local function delete(...)
    return base_connection.delete(...)
end

return { delete = delete }
