-- Unit tests for the HTTP/transport -> { code, message, retriable, scope }
-- error mapping. This envelope shape is the confirmed part of the whole
-- pull-source design (see source/pull_items.lua's header comment) — it must
-- match src/sink/write.lua's fail() shape from the original template
-- scaffold exactly.
local test = require("test")
local data_error = require("data_error")

local function define_tests()
    test.describe("cotique.gitlab_provider.client data_error", function()
        test.it("maps 401/403 to unauthorized, non-retriable", function()
            local err = data_error.from_http(401, '{"message":"401 Unauthorized"}', { scope = "connection" })
            test.eq(err.code, "unauthorized")
            test.eq(err.message, "401 Unauthorized")
            test.eq(err.retriable, false)
            test.eq(err.scope, "connection")

            local err403 = data_error.from_http(403, nil, {})
            test.eq(err403.code, "unauthorized")
            test.eq(err403.retriable, false)
        end)

        test.it("maps 404 to not_found, non-retriable", function()
            local err = data_error.from_http(404, "", {})
            test.eq(err.code, "not_found")
            test.eq(err.retriable, false)
        end)

        test.it("maps 429 to rate_limited, retriable", function()
            local err = data_error.from_http(429, "", { scope = "pull" })
            test.eq(err.code, "rate_limited")
            test.eq(err.retriable, true)
            test.eq(err.scope, "pull")
        end)

        test.it("maps 5xx to provider_unavailable, retriable", function()
            local err = data_error.from_http(503, "", {})
            test.eq(err.code, "provider_unavailable")
            test.eq(err.retriable, true)
        end)

        test.it("maps other non-2xx to invalid_request, non-retriable", function()
            local err = data_error.from_http(422, '{"message":"bad state param"}', {})
            test.eq(err.code, "invalid_request")
            test.eq(err.message, "bad state param")
            test.eq(err.retriable, false)
        end)

        test.it("defaults scope to request when not provided", function()
            local err = data_error.from_http(500, "", nil)
            test.eq(err.scope, "request")
        end)

        test.it("maps a transport failure to provider_unavailable, always retriable", function()
            local err = data_error.from_transport("connection reset by peer", { scope = "pull" })
            test.eq(err.code, "provider_unavailable")
            test.eq(err.retriable, true)
            test.eq(err.message, "connection reset by peer")
            test.eq(err.scope, "pull")
        end)

        test.it("envelope() only sets retriable true for an exact boolean true", function()
            local err_true = data_error.envelope("x", "y", true, "z")
            test.eq(err_true.retriable, true)
            local err_false = data_error.envelope("x", "y", false, "z")
            test.eq(err_false.retriable, false)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
