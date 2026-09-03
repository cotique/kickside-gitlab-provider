-- Unit tests for the DataError taxonomy: { success = false, error = { code,
-- message, retriable, scope }, retry_after_ms? }. This surface (M.failure,
-- M.connection, M.invalid_config, M.from_result) and vocabulary are
-- CONFIRMED against the real, unpacked reference
-- (providers-master/github/src/client/data_error.lua) — see BUILD-NOTES.md,
-- "kickside.data:pullable's exact envelope — RESOLVED".
local test = require("test")
local data_error = require("data_error")

local function define_tests()
    test.describe("cotique.gitlab.client data_error", function()
        test.it("failure() builds the full envelope, coercing retriable to an exact boolean", function()
            local err_true = data_error.failure("x", "y", true, "z")
            test.eq(err_true.success, false)
            test.eq(err_true.error.code, "x")
            test.eq(err_true.error.message, "y")
            test.eq(err_true.error.retriable, true)
            test.eq(err_true.error.scope, "z")
            test.is_nil(err_true.retry_after_ms)

            local err_false = data_error.failure("x", "y", false, "z")
            test.eq(err_false.error.retriable, false)

            local err_truthy = data_error.failure("x", "y", "not a real boolean", "z")
            test.eq(err_truthy.error.retriable, false, "retriable must only be true for an exact boolean true")
        end)

        test.it("failure() carries retry_after_ms only when given", function()
            local err = data_error.failure("rate_limited", "slow down", true, "provider", 2500)
            test.eq(err.retry_after_ms, 2500)
        end)

        test.it("connection() maps to auth_expired, non-retriable, connection scope", function()
            local err = data_error.connection("revoked")
            test.eq(err.success, false)
            test.eq(err.error.code, "auth_expired")
            test.eq(err.error.message, "revoked")
            test.eq(err.error.retriable, false)
            test.eq(err.error.scope, "connection")
        end)

        test.it("invalid_config() maps to invalid_config, non-retriable, flow scope", function()
            local err = data_error.invalid_config("config.project_id is required")
            test.eq(err.error.code, "invalid_config")
            test.eq(err.error.message, "config.project_id is required")
            test.eq(err.error.retriable, false)
            test.eq(err.error.scope, "flow")
        end)

        test.it("from_result() maps 401 to auth_expired, non-retriable, connection scope", function()
            local err = data_error.from_result({ status_code = 401, error = "bad token" }, "GitLab pull request")
            test.eq(err.error.code, "auth_expired")
            test.eq(err.error.message, "GitLab pull request: bad token")
            test.eq(err.error.retriable, false)
            test.eq(err.error.scope, "connection")
        end)

        test.it("from_result() maps 403 to permission_denied, non-retriable, flow scope", function()
            local err = data_error.from_result({ status_code = 403, error = "forbidden" }, "GitLab pull request")
            test.eq(err.error.code, "permission_denied")
            test.eq(err.error.retriable, false)
            test.eq(err.error.scope, "flow")
        end)

        test.it("from_result() maps 404 to not_found, non-retriable, flow scope", function()
            local err = data_error.from_result({ status_code = 404 }, "GitLab pull request")
            test.eq(err.error.code, "not_found")
            test.eq(err.error.message, "GitLab pull request: request failed")
            test.eq(err.error.retriable, false)
            test.eq(err.error.scope, "flow")
        end)

        test.it("from_result() maps 429 to rate_limited, retriable, provider scope, with a default retry_after_ms", function()
            local err = data_error.from_result({ status_code = 429, error = "slow down" }, "GitLab pull request")
            test.eq(err.error.code, "rate_limited")
            test.eq(err.error.retriable, true)
            test.eq(err.error.scope, "provider")
            test.eq(err.retry_after_ms, 1000)

            local err2 = data_error.from_result({ status_code = 429, error = "slow down", retry_after_ms = 5000 }, "GitLab pull request")
            test.eq(err2.retry_after_ms, 5000)
        end)

        test.it("from_result() maps 5xx and status 0 (transport failure) to provider_unavailable, retriable, provider scope", function()
            local err5xx = data_error.from_result({ status_code = 503 }, "GitLab pull request")
            test.eq(err5xx.error.code, "provider_unavailable")
            test.eq(err5xx.error.retriable, true)
            test.eq(err5xx.error.scope, "provider")

            local err0 = data_error.from_result({ status_code = 0, error = "connection reset by peer" }, "GitLab pull request")
            test.eq(err0.error.code, "provider_unavailable")
            test.eq(err0.error.message, "GitLab pull request: connection reset by peer")
            test.eq(err0.error.retriable, true)
        end)

        test.it("from_result() maps other statuses to provider_error, retriable, provider scope", function()
            local err = data_error.from_result({ status_code = 422, error = "bad state param" }, "GitLab pull request")
            test.eq(err.error.code, "provider_error")
            test.eq(err.error.message, "GitLab pull request: bad state param")
            test.eq(err.error.retriable, true)
            test.eq(err.error.scope, "provider")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
