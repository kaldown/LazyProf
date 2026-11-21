-- scripts/lib/check.lua
-- Shared pass/fail bookkeeping for the headless suites.
--   local T = require("scripts.lib.check").new()
--   T.check(name, cond, detail); T.eq(name, got, want); T.section(name, fn); T.finish()
local M = {}

function M.new()
    local T = { failures = 0, total = 0 }

    function T.check(name, cond, detail)
        T.total = T.total + 1
        if cond then
            print("PASS: " .. name)
        else
            T.failures = T.failures + 1
            print("FAIL: " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
        end
    end

    function T.eq(name, got, want)
        T.check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
    end

    -- A section that raises counts as one failure instead of ending the run.
    function T.section(name, fn)
        local ok, err = pcall(fn)
        if not ok then T.check(name .. " executed without error", false, err) end
    end

    function T.finish()
        print(string.format("\n%d/%d checks passed", T.total - T.failures, T.total))
        os.exit(T.failures == 0 and 0 or 1)
    end

    return T
end

return M
