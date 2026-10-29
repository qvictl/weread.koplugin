-- Component specs keep their controllable child simulator. The actual process
-- adapter, admission and reaping are exercised by subprocess_budget_spec.
local M = {}
function M.install(run)
    local previous = package.loaded["weread.lib.subprocess"]
    package.loaded["weread.lib.subprocess"] = {
        run = run or function(task, trap, simple)
            return require("ui/trapper"):dismissableRunInSubprocess(task, trap, simple)
        end,
    }
    return function() package.loaded["weread.lib.subprocess"] = previous end
end
return M
