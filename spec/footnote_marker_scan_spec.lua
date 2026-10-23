package.path = "./?.lua;./?/init.lua;" .. package.path
local External = require("weread.lib.external_annotations")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

expect(External.flatten_text("甲[36]乙") == "甲乙", "numeric marker is dropped")
expect(External.flatten_text("甲[注]乙") == "甲[注]乙", "non-numeric bracket is kept")
expect(External.flatten_text("甲[3a]乙[4]") == "甲[3a]乙", "only exact [digits] markers are dropped")

-- Many non-marker brackets before the last marker used to make every "["
-- rescan to the end of the chapter (quadratic).
local parts = {}
for _i = 1, 3000 do parts[#parts + 1] = "正文[注]文字" end
parts[#parts + 1] = "结尾[12]"
local started = os.clock()
local flat = External.flatten_text(table.concat(parts))
local elapsed = os.clock() - started
expect(not flat:find("[12]", 1, true), "trailing marker is dropped")
expect(elapsed < 0.2, string.format("flatten stays linear (%.3f s)", elapsed))

print(string.format("footnote_marker_scan_spec: %d checks", checks))
