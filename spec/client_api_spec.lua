-- WeRead API wrappers in weread.lib.client: gateway endpoints, MP articles and
-- content, reading reports, underlines/thought reviews and review comments.
-- LuaSocket is faked (spec/helpers/client_http_fake.lua); cookie and protocol
-- are the real modules. Error texts are matched by substring only.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end

local Fake = require("spec.helpers.client_http_fake")
local fake = Fake.install()
local header = Fake.header

local Client = require("weread.lib.client")
local WeRead = require("weread.lib.protocol")

local GATEWAY = "https://i.weread.qq.com/api/agent/gateway"

local function respond(response)
    fake.responses[#fake.responses + 1] = response
end

local function respond_json(value, code)
    respond({ code = code or 200, body = fake.json(value), headers = { ["Content-Type"] = "application/json" } })
end

local function raises(fn, ...)
    local ok, err = pcall(fn, ...)
    return not ok, tostring(err)
end

local function query_value(url, key)
    return url:match("[?&]" .. key .. "=([^&]*)")
end

local settings = Fake.settings({
    api_key = "api-key-1",
    cookies = { wr_skey = "skey-12345" },
    wr_ticket = "stored-ticket",
    wr_wrpa = "stored-wrpa",
})
local client = Client:new(settings)

-- Gateway wrappers send the right api_name and parameters.
do
    fake.reset()
    respond_json({ bookId = "b1", title = "T" })
    local info = client:get_book_info("b1")
    expect(info.title == "T" and fake.requests[1].url == GATEWAY, "get_book_info result/URL wrong")
    expect(fake.encoded[1].api_name == "/book/info" and fake.encoded[1].bookId == "b1",
        "get_book_info payload wrong")

    respond_json({ reviews = {} })
    respond_json({ reviews = {} })
    client:get_book_reviews("b1")
    client:get_book_reviews("b1", 3, 5)
    expect(fake.encoded[2].api_name == "/review/list" and fake.encoded[2].reviewListType == 1
        and fake.encoded[2].count == 20, "get_book_reviews defaults wrong")
    expect(fake.encoded[3].reviewListType == 3 and fake.encoded[3].count == 5, "get_book_reviews arguments ignored")

    respond_json({ progress = 10 })
    expect(client:get_progress("b2").progress == 10 and fake.encoded[4].api_name == "/book/getprogress"
        and fake.encoded[4].bookId == "b2", "get_progress wrong")

    for _ = 1, 4 do respond_json({}) end
    client:get_read_stats()
    client:get_read_stats("weekly", 1700000000)
    client:get_read_stats("annually", 0)
    client:get_read_stats("overall", "not-a-number")
    local stats = { fake.encoded[5], fake.encoded[6], fake.encoded[7], fake.encoded[8] }
    expect(stats[1].api_name == "/readdata/detail" and stats[1].mode == "monthly" and stats[1].baseTime == nil,
        "get_read_stats must default to the current month")
    expect(stats[2].mode == "weekly" and stats[2].baseTime == 1700000000, "get_read_stats lost baseTime")
    expect(stats[3].baseTime == nil and stats[4].baseTime == nil, "non-positive/invalid baseTime must be omitted")
    for _, req in ipairs(fake.requests) do
        expect(header(req.headers, "Authorization") == "Bearer api-key-1" and header(req.headers, "Cookie") == nil,
            "gateway wrapper sent cookies or no bearer token")
    end

    respond_json({ errCode = -1 }, 500)
    local raised, err = raises(client.get_book_info, client, "b1")
    expect(raised and err:find("HTTP 500", 1, true), "gateway HTTP failure did not raise with its code")
end

-- get_shelf(): shape-only diagnostics, full error re-raised
do
    fake.reset()
    respond_json({ books = { { bookId = "secret-book" } }, archive = {} })
    local shelf, code = client:get_shelf()
    expect(shelf.books[1].bookId == "secret-book" and code == 200, "shelf result not returned")
    expect(fake.encoded[1].api_name == "/shelf/sync" and fake.encoded[1].skill_version == WeRead.SKILL_VERSION,
        "shelf payload wrong")
    local log = fake.log_text()
    expect(log:find("books= table(1)", 1, true) and log:find("albums= nil", 1, true)
        and not log:find("secret-book", 1, true), "shelf log must describe shape only")

    fake.logs = {}
    respond_json("maintenance")
    expect(client:get_shelf() == "maintenance" and fake.log_text():find("response= string", 1, true),
        "non-table shelf response not passed through/logged by type")

    fake.logs = {}
    local long_cause = "proxy said: " .. string.rep("x", 900)
    respond({ raise = long_cause })
    local raised, err = raises(client.get_shelf, client)
    expect(raised and err:find(long_cause, 1, true), "shelf failure must re-raise the full cause")
    local failure_log = fake.log_text():match("shelf sync failed:[^\n]*") or ""
    expect(failure_log:find("proxy said", 1, true) and failure_log:find("...", 1, true) and #failure_log < 700,
        "shelf failure log was not truncated: " .. #failure_log)

    respond_json({})
    client:gateway("/user/info")
    expect(fake.encoded[#fake.encoded].api_name == "/user/info" and fake.encoded[#fake.encoded].skill_version == WeRead.SKILL_VERSION,
        "gateway without params must still send api_name/skill_version")
end

-- get_web_progress(): cookie-authenticated web endpoint
do
    fake.reset()
    respond_json({ book = { progress = 42 } })
    local data = client:get_web_progress("book 1")
    local req = fake.requests[1]
    expect(data.book.progress == 42, "web progress not decoded")
    expect(req.url:find("^https://weread%.qq%.com/web/book/getProgress%?bookId=book%%201&_=%d+$"),
        "web progress URL wrong: " .. req.url)
    expect(header(req.headers, "Accept") == "application/json, text/plain, */*"
        and header(req.headers, "Referer") == WeRead.reader_url("book 1")
        and header(req.headers, "Cookie") == "wr_skey=skey-12345", "web progress headers wrong")

    respond({ code = 401, body = "" })
    local raised, err = raises(client.get_web_progress, client, "b")
    expect(raised and err:find("HTTP 401", 1, true), "web progress 401 did not raise with its code")
    respond({ code = 200, body = "<html>login</html>" })
    expect(raises(client.get_web_progress, client, "b"), "web progress accepted a non-JSON body")
end

-- get_mp_articles(): ticket headers, errCode results and HTTP failures
do
    fake.reset()
    respond_json({ reviews = { { reviewId = "r1" } } })
    local data, err_code = client:get_mp_articles("MP_WXS_1&x", 5, 10, "arg-ticket")
    local req = fake.requests[1]
    expect(data.reviews[1].reviewId == "r1" and err_code == nil, "mp articles not returned")
    expect(req.url == "https://weread.qq.com/web/mp/articles?bookId=MP_WXS_1%26x&maxIdx=5&count=10",
        "mp articles URL wrong: " .. req.url)
    expect(header(req.headers, "x-wr-ticket") == "arg-ticket" and header(req.headers, "x-wrpa-0") == "stored-wrpa"
        and header(req.headers, "Cookie") == "wr_skey=skey-12345", "mp articles auth headers wrong")

    local bare = Client:new(Fake.settings({ cookies = {} }))
    respond_json({ reviews = {} })
    bare:get_mp_articles("b", nil, nil, "")
    req = fake.requests[2]
    expect(query_value(req.url, "maxIdx") == "0" and query_value(req.url, "count") == "100",
        "mp articles paging defaults wrong")
    expect(header(req.headers, "x-wr-ticket") == nil and header(req.headers, "x-wrpa-0") == nil,
        "empty ticket/wrpa must not be sent")

    respond_json({ errCode = -2041, errMsg = "ticket expired" })
    local none, code = client:get_mp_articles("b", 0, 1, "t")
    expect(none == nil and code == -2041, "mp errCode must be returned, not raised")
    respond_json({ errCode = 0, reviews = {} })
    expect(client:get_mp_articles("b") ~= nil, "errCode 0 was treated as a failure")

    respond({ code = 503, body = "" })
    local raised, err = raises(client.get_mp_articles, client, "b")
    expect(raised and err:find("HTTP 503", 1, true), "mp articles HTTP failure did not raise with its code")
end

-- get_mp_content()
do
    fake.reset()
    respond({ code = 200, body = "<div>article</div>", headers = { ["content-type"] = "text/html" } })
    local html, meta = client:get_mp_content("r/1", { timeout = { 5, 10 }, referer = "https://weread.qq.com/mp" })
    local req = fake.requests[1]
    expect(html == "<div>article</div>" and meta.code == 200 and meta.length == 18
        and meta.content_type == "text/html" and meta.url == "https://weread.qq.com/web/mp/content?reviewId=r%2F1",
        "mp content meta wrong")
    expect(header(req.headers, "x-wr-ticket") == "stored-ticket" and header(req.headers, "x-wrpa-0") == "stored-wrpa"
        and header(req.headers, "Referer") == "https://weread.qq.com/mp", "mp content headers wrong")
    expect(req.timeout[1] == 5 and req.timeout[2] == 10, "mp content timeout not applied")

    respond({ code = 200, body = "x" })
    client:get_mp_content("r2", { skip_mp_auth_headers = true })
    req = fake.requests[2]
    expect(header(req.headers, "x-wr-ticket") == nil and header(req.headers, "x-wrpa-0") == nil
        and header(req.headers, "Referer") == "https://weread.qq.com/", "skip_mp_auth_headers ignored")

    respond({ code = 404, body = "" })
    local raised, err = raises(client.get_mp_content, client, "r3")
    expect(raised and err:find("HTTP 404", 1, true), "mp content 404 did not raise with its code")
    expect(not fake.timeout_active, "mp content left the socket timeout active")
end

-- report_read()
do
    fake.reset()
    respond_json({ succ = 1 })
    respond_json({ succ = 1 })
    local payload = { b = "x", pr = 50 }
    local result = client:report_read(payload, "https://weread.qq.com/web/reader/abc")
    client:report_read({ b = "y" })
    local first, second = fake.requests[1], fake.requests[2]
    expect(result.succ == 1 and first.url == "https://weread.qq.com/web/book/read" and first.method == "POST",
        "report_read request wrong")
    expect(fake.encoded[1] == payload and header(first.headers, "Referer") == "https://weread.qq.com/web/reader/abc"
        and header(second.headers, "Referer") == "https://weread.qq.com/", "report_read payload/referer wrong")
    expect(header(first.headers, "Cookie") == "wr_skey=skey-12345", "report_read did not send the session cookie")
end

-- get_chapter_underlines()
do
    fake.reset()
    local _
    local ok, data, err = client:get_chapter_underlines("", 1)
    expect(not ok and data == nil and err:find("book_id", 1, true), "empty book id accepted")
    ok, _, err = client:get_chapter_underlines("b", nil)
    expect(not ok and err:find("chapter_uid", 1, true) and #fake.requests == 0, "missing chapter accepted")

    respond_json({ underlines = { { range = "1-2" } } })
    ok, data = client:get_chapter_underlines(123, 7)
    expect(ok and data.underlines[1].range == "1-2", "underlines not returned")
    expect(fake.encoded[1].api_name == "/book/underlines" and fake.encoded[1].bookId == "123"
        and fake.encoded[1].chapterUid == 7, "underlines payload wrong")

    respond_json("not-a-table")
    ok, data, err = client:get_chapter_underlines("b", 1)
    expect(not ok and data == nil and type(err) == "string", "non-table underlines accepted")
    respond({ code = 500, body = "" })
    ok, _, err = client:get_chapter_underlines("b", 1)
    expect(not ok and err:find("HTTP 500", 1, true), "underlines HTTP error not reported: " .. tostring(err))
    local unkeyed = Client:new(Fake.settings({}))
    ok = unkeyed:get_chapter_underlines("b", 1)
    expect(not ok and #fake.requests == 3, "underlines without API key must fail without a request")
end

-- get_chapter_reviews_batch() / get_chapter_reviews()
do
    fake.reset()
    local _
    local ok, data, err = client:get_chapter_reviews_batch(nil, 1, { {} })
    expect(not ok and data == nil and err:find("book_id", 1, true), "batch accepted a missing book id")
    ok, _, err = client:get_chapter_reviews_batch("b", nil, { {} })
    expect(not ok and err:find("chapter_uid", 1, true), "batch accepted a missing chapter")
    ok, data = client:get_chapter_reviews_batch("b", 1, {})
    expect(ok and #data.reviews == 0 and #fake.requests == 0, "empty batch must succeed without a request")

    local batch = client:build_chapter_review_batches({ "0-5" })[1]
    respond_json({ reviews = { { reviewId = "a" } } })
    ok, data = client:get_chapter_reviews_batch(9, 3, batch)
    expect(ok and data.reviews[1].reviewId == "a", "batch reviews not returned")
    expect(fake.encoded[1].api_name == "/book/readreviews" and fake.encoded[1].bookId == "9"
        and fake.encoded[1].chapterUid == 3 and fake.encoded[1].reviews[1].range == "0-5",
        "batch payload wrong")
    respond_json({ something = "else" })
    ok, _, err = client:get_chapter_reviews_batch("b", 1, batch)
    expect(not ok and type(err) == "string", "batch without a reviews list accepted")
    respond({ raise = "socket closed" })
    ok, _, err = client:get_chapter_reviews_batch("b", 1, batch)
    expect(not ok and err:find("socket closed", 1, true), "batch transport error not reported")

    fake.reset()
    ok, data = client:get_chapter_reviews("b", 1, {})
    expect(ok and #data.reviews == 0 and #fake.requests == 0, "no ranges must not hit the network")

    local ranges = {}
    for index = 1, 61 do ranges[index] = tostring(index) end
    respond_json({ reviews = { { reviewId = "r1" }, { reviewId = "r2" } } })
    respond({ code = 500, body = "" })
    respond_json({ reviews = { { reviewId = "r3" } } })
    ok, data = client:get_chapter_reviews("b", 1, ranges)
    expect(#fake.requests == 3 and #fake.encoded[1].reviews == 30 and #fake.encoded[3].reviews == 1,
        "61 ranges must be fetched as 30 + 30 + 1")
    expect(ok and #data.reviews == 3 and data.reviews[1].reviewId == "r1" and data.reviews[3].reviewId == "r3",
        "reviews from successful batches must be kept in order when one batch fails")
    expect(#fake.sleeps == 2 and fake.sleeps[1] == 0.3 and fake.sleeps[2] == 0.3,
        "batches must be paced between (not after) requests")
end

-- get_review_comments()
do
    fake.reset()
    local ok, _, err = client:get_review_comments(42)
    expect(not ok and err:find("review_id", 1, true) and #fake.requests == 0, "non-string review id accepted")

    respond_json({ comments = {} })
    ok = client:get_review_comments("id/1", 5, {
        comments_direction = 1, likes_count = 3, synckey = 77,
        referer = "https://weread.qq.com/web/reader/x", timeout = { 2, 4 },
    })
    local req = fake.requests[1]
    expect(ok and query_value(req.url, "reviewId") == "id%2F1" and query_value(req.url, "commentsCount") == "5"
        and query_value(req.url, "commentsDirection") == "1" and query_value(req.url, "likesCount") == "3"
        and query_value(req.url, "synckey") == "77", "review comments query wrong: " .. req.url)
    expect(header(req.headers, "Referer") == "https://weread.qq.com/web/reader/x"
        and header(req.headers, "Accept") == "application/json, text/plain, */*"
        and req.timeout[1] == 2 and req.timeout[2] == 4, "review comments headers/timeout wrong")

    respond({ code = 500, body = fake.json({ errcode = -1 }) })
    local data
    ok, data, err = client:get_review_comments("id")
    expect(not ok and data == nil and err:find("HTTP 500", 1, true), "review comments HTTP error not reported")
    respond_json("scalar")
    ok, data, err = client:get_review_comments("id")
    expect(not ok and type(data) == "string" and type(err) == "string", "non-table review comments accepted")
    expect(not fake.timeout_active, "review comments left the socket timeout active")
end

print(("client_api_spec: %d checks"):format(checks))
