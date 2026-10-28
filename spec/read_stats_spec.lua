package.path = "./?.lua;./?/init.lua;" .. package.path

-- Reading statistics data layer: response normalization, Beijing-time period
-- arithmetic and fetch navigation. Every timestamp below is a fixed Beijing
-- (UTC+8) instant so the results must not depend on the device time zone.

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed"), 2) end
end
local function expect_eq(actual, expected, message)
    expect(actual == expected,
        (message or "value mismatch") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

local ReadStats = require("weread.lib.read_stats")

-- Beijing wall-clock instants (UTC+8).
local T = {
    wed_2024_03_13_2330 = 1710343800,
    mon_2024_03_04 = 1709481600,
    mon_2024_03_11 = 1710086400,
    sun_2024_03_17_2359 = 1710691140,
    mon_2024_03_18 = 1710691200,
    feb_2024 = 1706716800,
    mar_2024 = 1709222400,
    apr_2024 = 1711900800,
    dec_2023 = 1701360000,
    dec_2024 = 1732982400,
    jan_2023 = 1672502400,
    jan_2024 = 1704038400,
    jan_2025 = 1735660800,
    tue_2024_12_31_2000 = 1735646400,
    mon_2024_12_30 = 1735488000,
    mon_2025_01_06 = 1736092800,
}

-- Pin "now" for fetch()'s allow_next / fallback decisions; table conversions
-- still go to the real os.time so period arithmetic is exercised for real.
local real_time = os.time
local fake_now
os.time = function(t) -- luacheck: ignore 122
    if t == nil and fake_now then return fake_now end
    return real_time(t)
end

-- ── constants ───────────────────────────────────────────────────────────────
expect(#ReadStats.MODES == 4, "unexpected mode count")
expect(ReadStats.MODES[1] == "weekly" and ReadStats.MODES[4] == "overall",
    "tab order changed")

-- ── cst_fmt: formatting is pinned to Beijing time ───────────────────────────
-- 2024-03-13 23:30 CST is 15:30 UTC; a UTC-based formatter would say 13 too,
-- but 2024-03-17 23:59 CST is still Sunday 17th in Beijing (15:59 UTC).
expect_eq(ReadStats.cst_fmt("%Y-%m-%d %H:%M", T.wed_2024_03_13_2330),
    "2024-03-13 23:30", "cst_fmt wall clock")
-- 2024-03-18 00:00 CST is 2024-03-17 16:00 UTC: must already be the 18th.
expect_eq(ReadStats.cst_fmt("%Y-%m-%d", T.mon_2024_03_18), "2024-03-18",
    "cst_fmt drifted to UTC day")

-- ── period_start ────────────────────────────────────────────────────────────
expect_eq(ReadStats.period_start("weekly", T.wed_2024_03_13_2330), T.mon_2024_03_11,
    "weekly start of a Wednesday")
expect_eq(ReadStats.period_start("weekly", T.mon_2024_03_11), T.mon_2024_03_11,
    "weekly start of Monday midnight is itself")
-- Sunday belongs to the week that started six days earlier (Monday-first weeks).
expect_eq(ReadStats.period_start("weekly", T.sun_2024_03_17_2359), T.mon_2024_03_11,
    "Sunday must map to the preceding Monday")
-- Week that straddles the new year starts in December.
expect_eq(ReadStats.period_start("weekly", T.tue_2024_12_31_2000), T.mon_2024_12_30,
    "weekly start across the year boundary")
expect_eq(ReadStats.period_start("monthly", T.wed_2024_03_13_2330), T.mar_2024,
    "monthly start")
expect_eq(ReadStats.period_start("annually", T.wed_2024_03_13_2330), T.jan_2024,
    "annual start")
-- Unknown/overall modes fall back to Beijing midnight of the same day.
expect_eq(ReadStats.cst_fmt("%Y-%m-%d %H:%M:%S",
        ReadStats.period_start("overall", T.wed_2024_03_13_2330)),
    "2024-03-13 00:00:00", "fallback period start is not midnight")

-- ── shift_period ────────────────────────────────────────────────────────────
expect_eq(ReadStats.shift_period("weekly", T.mon_2024_03_11, -1), T.mon_2024_03_04,
    "previous week")
expect_eq(ReadStats.shift_period("weekly", T.mon_2024_03_11, 1), T.mon_2024_03_18,
    "next week")
expect_eq(ReadStats.shift_period("weekly", T.mon_2024_12_30, 1), T.mon_2025_01_06,
    "next week across the year boundary")
expect_eq(ReadStats.shift_period("monthly", T.mar_2024, -1), T.feb_2024, "previous month")
expect_eq(ReadStats.shift_period("monthly", T.mar_2024, 1), T.apr_2024, "next month")
-- Month underflow / overflow must normalize into the neighbouring year.
expect_eq(ReadStats.shift_period("monthly", T.jan_2024, -1), T.dec_2023,
    "January -> previous December")
expect_eq(ReadStats.shift_period("monthly", T.dec_2024, 1), T.jan_2025,
    "December -> next January")
expect_eq(ReadStats.shift_period("annually", T.jan_2024, -1), T.jan_2023, "previous year")
expect_eq(ReadStats.shift_period("annually", T.jan_2024, 1), T.jan_2025, "next year")

-- ── period_label ────────────────────────────────────────────────────────────
expect_eq(ReadStats.period_label("weekly", T.mon_2024_03_11), "2024-03-11 ~ 03-17",
    "weekly label")
expect_eq(ReadStats.period_label("weekly", T.mon_2024_12_30), "2024-12-30 ~ 01-05",
    "weekly label across the year boundary")
expect_eq(ReadStats.period_label("monthly", T.mar_2024), "2024-03", "monthly label")
expect_eq(ReadStats.period_label("annually", T.jan_2024), "2024", "annual label")
expect_eq(ReadStats.period_label("overall", T.jan_2024), "", "overall has no label")
expect_eq(ReadStats.period_label("daily", T.mon_2024_03_18), "2024-03-18",
    "unknown mode falls back to a date")

-- ── normalize: defensive defaults ───────────────────────────────────────────
for _, raw in ipairs({ false, "oops", 42 }) do
    local empty = ReadStats.normalize(raw, "weekly")
    expect(empty.mode == "weekly", "mode not carried through")
    expect(empty.total_read_time == 0 and empty.read_days == 0 and empty.day_average == 0,
        "non-table response produced non-zero totals")
    expect(empty.compare == nil and empty.read_rate == nil and empty.rank_text == nil,
        "non-table response invented optional fields")
    for _, key in ipairs({ "buckets", "top_books", "prefer_category",
            "prefer_author", "prefer_publisher", "summary" }) do
        expect(type(empty[key]) == "table" and #empty[key] == 0,
            key .. " should be an empty list for a non-table response")
    end
end
local nil_raw = ReadStats.normalize(nil, "monthly")
expect(nil_raw.mode == "monthly" and #nil_raw.buckets == 0, "nil response not handled")

-- Wrong-typed sections are ignored instead of crashing.
local wrong = ReadStats.normalize({
    readTimes = "x", readLongest = 1, preferCategory = true,
    preferAuthor = "a", preferPublisher = 3, readStat = "s", rank = "top",
    totalReadTime = "not a number",
}, "monthly")
expect(#wrong.buckets == 0 and #wrong.top_books == 0 and #wrong.prefer_category == 0,
    "wrong-typed list sections were not ignored")
expect(#wrong.prefer_author == 0 and #wrong.prefer_publisher == 0 and #wrong.summary == 0,
    "wrong-typed named sections were not ignored")
expect(wrong.rank_text == nil, "non-table rank produced text")
expect(wrong.total_read_time == 0, "non-numeric total was not coerced to zero")

-- ── normalize: full payload ─────────────────────────────────────────────────
local full = ReadStats.normalize({
    totalReadTime = "7200",
    readDays = 3,
    dayAverageReadTime = 2400,
    compare = "-0.25",
    readRate = 88,
    readTimes = {
        -- Unordered string keys, one non-numeric key that must be dropped and a
        -- non-numeric value that must become 0.
        [tostring(T.mon_2024_03_18)] = 60,
        [tostring(T.mon_2024_03_11)] = "120",
        [tostring(T.wed_2024_03_13_2330)] = "n/a",
        note = 999,
    },
    readLongest = {
        { book = { title = "Book A", author = "Author A" }, readTime = "3600" },
        { albumInfo = { name = "Album B", authorName = "Narrator" }, readTime = 1800 },
        { book = { title = "" }, readTime = 10 },        -- empty title dropped
        { book = {}, readTime = 10 },                    -- no title dropped
        { book = { title = "Book C" } },                 -- missing readTime -> 0
    },
    preferCategory = {
        { categoryTitle = "History", readingTime = "500", readingCount = "2" },
        { categoryTitle = "", readingTime = 1 },
        { readingTime = 1 },
        { categoryTitle = "Poetry" },
    },
    preferCategoryWord = "History buff",
    preferTimeWord = "Night owl",
    preferAuthor = {
        { name = "Lu Xun", count = "4" }, { name = "" }, { count = 9 }, { name = "Ba Jin" },
    },
    preferPublisher = { { name = "Press", count = 1 } },
    readStat = {
        { stat = "Read", counts = "12" }, { stat = "Finished" }, { counts = "3" },
        { stat = "Notes", counts = "40" },
    },
    rank = { text = "Top 5%" },
}, "weekly")

expect_eq(full.total_read_time, 7200, "string total not converted")
expect_eq(full.read_days, 3, "read days")
expect_eq(full.day_average, 2400, "day average")
expect_eq(full.compare, -0.25, "compare not converted")
expect_eq(full.read_rate, 88, "read rate")
expect_eq(full.rank_text, "Top 5%", "rank text")
expect_eq(full.prefer_category_word, "History buff", "category word")
expect_eq(full.prefer_time_word, "Night owl", "time word")

expect_eq(#full.buckets, 3, "non-numeric bucket key was not dropped")
expect(full.buckets[1].ts == T.mon_2024_03_11 and full.buckets[2].ts == T.wed_2024_03_13_2330
    and full.buckets[3].ts == T.mon_2024_03_18, "buckets not sorted by time")
expect(full.buckets[1].value == 120 and full.buckets[2].value == 0
    and full.buckets[3].value == 60, "bucket values not coerced")
-- Weekly buckets are labelled by Beijing day-of-month without zero padding.
expect(full.buckets[1].label == "11" and full.buckets[2].label == "13"
    and full.buckets[3].label == "18", "weekly bucket labels")

expect_eq(#full.top_books, 3, "top books without a title must be dropped")
expect(full.top_books[1].title == "Book A" and full.top_books[1].author == "Author A"
    and full.top_books[1].seconds == 3600, "book ranking entry")
expect(full.top_books[2].title == "Album B" and full.top_books[2].author == "Narrator"
    and full.top_books[2].seconds == 1800, "audio album ranking entry")
expect(full.top_books[3].title == "Book C" and full.top_books[3].author == nil
    and full.top_books[3].seconds == 0, "missing readTime/author")

expect_eq(#full.prefer_category, 2, "untitled categories must be dropped")
expect(full.prefer_category[1].title == "History" and full.prefer_category[1].seconds == 500
    and full.prefer_category[1].count == 2, "category numbers not converted")
expect(full.prefer_category[2].title == "Poetry" and full.prefer_category[2].seconds == 0
    and full.prefer_category[2].count == 0, "missing category numbers")

expect_eq(#full.prefer_author, 2, "unnamed authors must be dropped")
expect(full.prefer_author[1].name == "Lu Xun" and full.prefer_author[1].count == 4,
    "author count")
expect(full.prefer_author[2].name == "Ba Jin" and full.prefer_author[2].count == 0,
    "missing author count")
expect(#full.prefer_publisher == 1 and full.prefer_publisher[1].name == "Press"
    and full.prefer_publisher[1].count == 1, "publisher list")

expect_eq(#full.summary, 2, "incomplete summary chips must be dropped")
expect(full.summary[1].name == "Read" and full.summary[1].counts == "12"
    and full.summary[2].name == "Notes" and full.summary[2].counts == "40",
    "summary chips keep server text verbatim")

-- Bucket labels per mode.
local annual = ReadStats.normalize({ readTimes = {
    [tostring(T.dec_2024)] = 1, [tostring(T.feb_2024)] = 2,
} }, "annually")
expect(annual.buckets[1].label == "2" and annual.buckets[2].label == "12",
    "annual buckets must be labelled by unpadded month")
local overall = ReadStats.normalize({ readTimes = {
    [tostring(T.jan_2025)] = 1, [tostring(T.jan_2023)] = 2,
} }, "overall")
expect(overall.buckets[1].label == "2023" and overall.buckets[2].label == "2025",
    "overall buckets must be labelled by year")
-- 2024-03-01 00:00 CST is still Feb 29 in UTC: label must follow Beijing time.
local monthly = ReadStats.normalize({ readTimes = { [tostring(T.mar_2024)] = 5 } }, "monthly")
expect_eq(monthly.buckets[1].label, "1", "monthly bucket label drifted out of Beijing time")

-- ── fetch ───────────────────────────────────────────────────────────────────
local function fake_client(response)
    local client = { calls = {} }
    function client:get_read_stats(mode, base_time)
        self.calls[#self.calls + 1] = { mode = mode, base_time = base_time }
        return response
    end
    return client
end

fake_now = T.wed_2024_03_13_2330

-- Default mode is monthly; the server-normalized baseTime wins.
local client = fake_client({ baseTime = T.feb_2024, totalReadTime = 60 })
local data = ReadStats.fetch(client, nil, 12345)
expect(#client.calls == 1 and client.calls[1].mode == "monthly"
    and client.calls[1].base_time == 12345, "fetch did not forward mode/base_time")
expect(data.mode == "monthly" and data.total_read_time == 60, "fetch did not normalize")
expect_eq(data.base_time, T.feb_2024, "server baseTime not preferred")
expect_eq(data.period_label, "2024-02", "period label")
expect_eq(data.prev_base_time, T.jan_2024, "prev target")
expect_eq(data.next_base_time, T.mar_2024, "next target")
expect(data.allow_prev == true, "previous navigation must always be allowed")
expect(data.allow_next == true, "a past period must allow navigating forward")

-- Current period: the next one has not begun yet.
data = ReadStats.fetch(fake_client({ baseTime = tostring(T.mar_2024) }), "monthly", 0)
expect_eq(data.base_time, T.mar_2024, "string baseTime not converted")
expect(data.allow_next == false, "current month must not allow navigating forward")

-- Boundary: next period starting exactly "now" is navigable.
fake_now = T.apr_2024
data = ReadStats.fetch(fake_client({ baseTime = T.mar_2024 }), "monthly")
expect(data.allow_next == true, "period beginning exactly now must be navigable")

-- Missing baseTime: compute from the requested base_time.
fake_now = T.mon_2025_01_06
client = fake_client({})
data = ReadStats.fetch(client, "weekly", tostring(T.wed_2024_03_13_2330))
expect_eq(data.base_time, T.mon_2024_03_11, "fallback did not normalize the seed")
expect_eq(data.period_label, "2024-03-11 ~ 03-17", "fallback weekly label")
expect(data.prev_base_time == T.mon_2024_03_04 and data.next_base_time == T.mon_2024_03_18,
    "fallback weekly navigation")
expect(data.allow_next == true, "past week must allow navigating forward")

-- Missing baseTime and no usable seed: use "now" (non-positive / nil / junk seeds).
fake_now = T.tue_2024_12_31_2000
for _, seed in ipairs({ 0, -5, "abc" }) do
    data = ReadStats.fetch(fake_client(nil), "annually", seed)
    expect_eq(data.base_time, T.jan_2024, "seed " .. tostring(seed) .. " did not fall back to now")
    expect(data.period_label == "2024" and data.next_base_time == T.jan_2025
        and data.allow_next == false, "current year navigation")
    expect(data.total_read_time == 0 and #data.buckets == 0, "nil response not defaulted")
end
data = ReadStats.fetch(fake_client({ baseTime = "bogus" }), "weekly")
expect_eq(data.base_time, T.mon_2024_12_30, "nil seed did not fall back to now")
expect(data.allow_next == false, "current week must not allow navigating forward")

-- Overall: single unbounded period with no navigation, even if the server sends baseTime.
client = fake_client({ baseTime = T.jan_2024, totalReadTime = 99, readTimes = {
    [tostring(T.jan_2024)] = 99,
} })
data = ReadStats.fetch(client, "overall", T.jan_2025)
expect(client.calls[1].mode == "overall", "overall mode not forwarded")
expect(data.base_time == 0 and data.period_label == "", "overall must not have a period")
expect(data.allow_prev == false and data.allow_next == false, "overall must not navigate")
expect(data.prev_base_time == nil and data.next_base_time == nil,
    "overall must not expose navigation targets")
expect(data.total_read_time == 99 and data.buckets[1].label == "2024", "overall data")

-- Client errors propagate to the caller (the view wraps fetch in its own pcall).
local failing = { get_read_stats = function() error("HTTP 500 from gateway") end }
local ok, err = pcall(ReadStats.fetch, failing, "weekly")
expect(not ok and tostring(err):find("HTTP 500", 1, true), "client error was swallowed")

os.time = real_time -- luacheck: ignore 122
print(("read_stats_spec: %d checks"):format(checks))
