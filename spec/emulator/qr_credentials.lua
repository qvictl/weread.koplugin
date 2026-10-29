-- Fetch real protocol credentials first, then let the scenario delay only the
-- parent completion. Waiting for B's network login while A's response is held
-- would manufacture a dependency cycle under the single-worker budget.
return function(H, plugin)
    local credentials, failure
    local login = plugin.qr_login
    local generation = login.generation
    H.call(function()
        login:_run_protocol_request({}, generation, function(worker)
            return worker:_fetch_credentials{
                succeed = true, webLoginVid = "900000",
                accessToken = "mock-access-token", refreshToken = "mock-refresh-token",
            }
        end, function(value) credentials = value end, function(err) failure = err end)
    end)
    H.wait_until("real QR protocol credentials ready before the held worker", function()
        return credentials or failure
    end, 10)
    H.check(not failure and credentials and credentials.account.user_vid == "900000",
        "QR protocol produced the next account", tostring(failure))
    return function() login:_apply_credentials(credentials, generation) end
end
