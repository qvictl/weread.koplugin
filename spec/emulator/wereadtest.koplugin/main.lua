-- Test-only KOReader plugin: runs one emulator scenario inside the real app.
-- Installed next to the candidate weread.koplugin by
-- scripts/run_emulator_scenarios.py; never part of the release package.
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local harness_dir = os.getenv("WEREAD_TEST_HARNESS_DIR")
local Harness
if harness_dir then
    Harness = package.loaded["wereadtest.harness"]
    if not Harness then
        Harness = dofile(harness_dir .. "/harness.lua")
        package.loaded["wereadtest.harness"] = Harness
    end
end

local Driver = WidgetContainer:extend{
    name = "wereadtest",
    is_doc_only = false,
}

function Driver:init()
    if Harness then Harness.attach(self.ui) end
end

return Driver
