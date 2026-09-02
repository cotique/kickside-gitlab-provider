-- kickside.connection:connection.test_connection
--
-- Real live call per the provider brief: GET /api/v4/user — 200 with a JSON
-- body containing at least id and username means the token is valid. Any
-- non-2xx is a failed connection; surface GitLab's own error message where
-- present (client:data_error already extracts it from a {"message": "..."}
-- body).
local connection_lib = require("connection_lib")

local function test_connection()
    local client, err = connection_lib.get_client()
    if err or not client then
        return { success = false, error = tostring(err or "could not build a GitLab client") }
    end

    local resp, rerr = client:get("/user", { scope = "connection" })
    if rerr then
        return { success = false, error = rerr.message }
    end

    local body = resp.body
    if type(body) ~= "table" or body.id == nil or body.username == nil then
        return { success = false, error = "GitLab /user response did not include the expected id/username fields" }
    end

    return {
        success = true,
        details = {
            id = body.id,
            username = body.username,
        },
    }
end

return { test_connection = test_connection }
