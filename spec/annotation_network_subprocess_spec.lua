-- User-triggered annotation requests (binding search, chapter catalog) must
-- not block the UI thread: they run in a dismissable Trapper subprocess and
-- continue in the parent only for the document/session that started them.
-- Run from the repo root with:
--   luajit spec/annotation_network_subprocess_spec.lua

package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed"), 2) end
end

local scheduled, shown_lists, notices = {}, {}, {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        close = function() end, setDirty = function() end, show = function() end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return { size = 1, modification = 2 } end }
end
package.preload["version"] = function()
    return { getCurrentRevision = function() return "test" end }
end
local dialog
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_self, options)
        options.getInputText = function() return "keyword" end
        dialog = options
        return options
    end }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end } }
end
package.preload["weread.ui.xpointer_overlay"] = function() return {} end
package.preload["weread.ui.thought_popup.popup_config"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        reader_open_perf = function() return 0 end,
    }
end

-- Fake Trapper: the task runs synchronously but flagged as "in the child".
local in_child, busy_texts, dismiss = false, {}, false
package.loaded["ffi/util"] = { runInSubProcess = function() end }
package.loaded["ui/trapper"] = {
    wrap = function(_self, callback)
        local ok, err = coroutine.resume(coroutine.create(callback))
        assert(ok, err)
    end,
    dismissableRunInSubprocess = function(_self, task, busy_text, simple)
        assert(coroutine.running(), "subprocess request outside Trapper:wrap")
        assert(simple == true, "JSON result must use the plain string pipe")
        busy_texts[#busy_texts + 1] = busy_text
        if dismiss then return false end
        in_child = true
        local result = task()
        in_child = false
        return true, result
    end,
}
local WorkerSettings = require("weread.lib.worker_settings")
WorkerSettings.capture = function() return function() return nil end end

local content = {}
package.preload["weread.lib.content"] = function() return content end
local Overlay = require("weread.ui.xpointer_overlay_controller")
local Sync = require("weread.ui.annotation_sync_controller")
local External = require("weread.lib.external_annotations")

local gateway_calls = 0
local store = helper.new()
local host = {
    _reader_session_gen = 1,
    ui = { document = { file = "/books/local.epub", getToc = function() return {} end } },
    settings = { get = function(_self, _key, default) return default end },
    client = { gateway = function(_self, path)
        assert(in_child, "book search ran on the UI thread")
        gateway_calls = gateway_calls + 1
        expect(path == "/store/search", "unexpected gateway path")
        return { books = { { bookInfo = { bookId = "b1", title = "Found" } } } }
    end },
    annotation_store = store,
    external_annotations_db = store.legacy,
    requireLogin = function() return true end,
    showInputDialog = function() end,
    runOnlineTask = function(_self, _label, callback) scheduled[#scheduled + 1] = callback end,
    showList = function(_self, title, items) shown_lists[#shown_lists + 1] = { title = title, items = items } end,
    showInfo = function(_self, text) notices[#notices + 1] = text end,
    detectWeReadBook = function() return nil end,
    _xpointerOverlayPrototypeAvailable = function() return true end,
}
for name, method in pairs(Overlay) do host[name] = method end
for name, method in pairs(Sync) do host[name] = method end
host._xpointerOverlayPrototypeAvailable = function() return true end
local function drain()
    while #scheduled > 0 do table.remove(scheduled, 1)() end
end

-- Binding search: the gateway request runs in the subprocess, the result
-- list is built in the parent.
External.normalize_search = function(result)
    return { { book_id = result.books[1].bookInfo.bookId, title = result.books[1].bookInfo.title } }
end
host:bindExternalAnnotationsBook()
dialog.buttons[1][2].callback()
drain()
expect(gateway_calls == 1 and busy_texts[1] == "Search WeRead", "search did not use the subprocess")
expect(#shown_lists == 1 and shown_lists[1].items[1].text == "Found", "search results were not listed")

-- A result arriving after the reader switched documents is dropped.
dialog.buttons[1][2].callback()
host.ui.document.file = "/books/other.epub"
drain()
expect(gateway_calls == 2 and #shown_lists == 1, "a stale search result was shown")
host.ui.document.file = "/books/local.epub"

-- A failed request is reported once, in the parent, without a traceback.
host.client.gateway = function() error("HTTP 503\nstack traceback: ...") end
dialog.buttons[1][2].callback()
drain()
expect(notices[#notices] == "Search failed:\nHTTP 503" or notices[#notices]:find("HTTP 503", 1, true),
    "search failure was not reported")
expect(not notices[#notices]:find("traceback", 1, true), "traceback leaked into the message")

-- Chapter catalog: _prepareAnnotationContext defers the fetch instead of
-- running it on the UI thread; the subprocess result completes the context.
store.legacy:saveDocument("/books/local.epub", { binding = { book_id = "remote", title = "Remote" } })
host:_invalidateAnnotationBinding() -- as the rebinding flow does
local fetches = 0
content.ensure_reader_state = function()
    assert(in_child, "reader state was fetched on the UI thread")
end
content.fetch_catalog = function()
    assert(in_child, "the chapter catalog was fetched on the UI thread")
    fetches = fetches + 1
    return { { chapterUid = "1", title = "One" } }
end
local deferred, remote = host:_prepareAnnotationContext(true, false, { defer_network = true })
expect(deferred == nil and remote and remote.book_id == "remote",
    "catalog preparation did not defer its network request")
local prepared
host:_withAnnotationContext("Loading chapter list...", true, false, function(context)
    prepared = context
end)
expect(fetches == 1 and prepared and #prepared.catalog == 1, "fetched catalog did not complete the context")
expect(store:get("remote", "meta", "catalog")[1].chapterUid == "1", "fetched catalog was not saved")
host:_withAnnotationContext("Loading chapter list...", true, false, function(context)
    expect(context == prepared, "a cached context was not reused without a request")
end)
expect(fetches == 1, "a cached catalog was fetched again")

-- Dismissing the request (tap on the busy message) does nothing further.
host._annotation_context = nil
store:put("remote", "meta", "catalog", nil)
dismiss = true
local called = false
host:_withAnnotationContext("Loading chapter list...", true, false, function() called = true end)
expect(not called and fetches == 1, "a dismissed request continued")
dismiss = false

helper.cleanup()
print(("annotation_network_subprocess_spec: %d checks"):format(checks))
