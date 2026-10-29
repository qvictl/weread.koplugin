-- Component specs keep their controllable child simulator. The actual process
-- adapter, admission and reaping are exercised by subprocess_budget_spec.
local M = {}
function M.install(run)
    local previous = package.loaded["weread.lib.subprocess"]
    local delegate = run or function(task, trap, simple)
        return require("ui/trapper"):dismissableRunInSubprocess(task, trap, simple)
    end
    package.loaded["weread.lib.subprocess"] = {
        run = function(task, trap, simple, options)
            if options and options.before_launch then
                local current, reason = options.before_launch()
                if not current then return false, nil, reason end
            end
            return delegate(task, trap, simple, options)
        end,
    }
    return function() package.loaded["weread.lib.subprocess"] = previous end
end
return M
