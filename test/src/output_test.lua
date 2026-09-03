-- Unit tests for credential redaction — per AGENTS.md "Never log tokens,
-- credentials, private component context, authorization headers, or full
-- user payloads."
local test = require("test")
local output = require("output")

local function define_tests()
    test.describe("cotique.gitlab.client output redaction", function()
        test.it("redacts a top-level token field", function()
            local redacted = output.redact({ token = "fake-token-fixture-value", base_url = "https://gitlab.com" })
            test.eq(redacted.token, output.REDACTED)
            test.eq(redacted.base_url, "https://gitlab.com")
        end)

        test.it("redacts known-sensitive keys case-insensitively and nested", function()
            local redacted = output.redact({
                headers = { ["PRIVATE-TOKEN"] = "fake-token-fixture-value", Authorization = "Bearer fake-value" },
                credentials = { access_token = "fake-access-fixture", app_password = "fake-app-password-fixture" },
                project_id = "278964",
            })
            test.eq(redacted.headers["PRIVATE-TOKEN"], output.REDACTED)
            test.eq(redacted.headers.Authorization, output.REDACTED)
            test.eq(redacted.credentials.access_token, output.REDACTED)
            test.eq(redacted.credentials.app_password, output.REDACTED)
            test.eq(redacted.project_id, "278964")
        end)

        test.it("leaves non-sensitive scalars and non-table values untouched", function()
            test.eq(output.redact("plain string"), "plain string")
            test.eq(output.redact(42), 42)
            test.eq(output.redact(nil), nil)
        end)

        test.it("does not mutate the original table", function()
            local original = { token = "fake-token-fixture-value" }
            local _ = output.redact(original)
            test.eq(original.token, "fake-token-fixture-value")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
