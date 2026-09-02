-- Shared constants for the GitLab client layer.
local M = {}

-- GitLab is very commonly self-managed, unlike GitHub's github.com-only
-- reference binding — the credential_schema exposes an optional base_url
-- field; this is the fallback when it is left blank. See BUILD-NOTES.md
-- "Deliberate deviation from the mirrored kickside/github shape" for why.
M.DEFAULT_BASE_URL = "https://gitlab.com"

-- GitLab merge_request.state -> normalized item shape's state field.
-- GitLab has no "declined" state (Bitbucket does) — this map simply never
-- produces it.
M.MR_STATE_MAP = {
    opened = "open",
    merged = "merged",
    closed = "closed",
    locked = "closed", -- GitLab's rare "locked" MR state has no dedicated
                        -- normalized bucket; closest is closed, not open.
}

return M
