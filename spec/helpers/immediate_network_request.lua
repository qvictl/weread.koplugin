-- Library/cache view specs exercise parent callbacks independently of forking.
-- The real child/parent boundary and credential transfer have separate specs.
return function(self, _busy, _label, task, on_success, on_failure)
    if self.cancel_network_request then return on_failure(nil, true, self.network_cancel_reason) end
    local ok, value = pcall(task)
    if ok then return on_success(value) end
    return on_failure(value, false)
end
