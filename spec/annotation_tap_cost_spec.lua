-- Per-tap cost of the ReaderLink thought-anchor filter. The tap_link zone
-- overrides the page-turn zones, so the wrapped ReaderLink.onTap runs for
-- every tap: it must not re-resolve the WeRead binding (SQLite + library scan)
-- per tap, must cache a negative unified-annotation answer, and must never
-- raise when the annotation database is busy.
-- Run from the repo root with:
--   luajit spec/annotation_tap_cost_spec.lua

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed"), 2) end
end

package.preload["weread.lib.annotations"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_self, name) return { name = name } end }
end
package.preload["weread.lib.logger"] = function()
    return { warn = function() end, info = function() end }
end
package.preload["weread.lib.thought_db"] = function() return {} end
package.preload["weread.ui.thought_popup"] = function()
    return { closeVisible = function() end, cleanup = function() end }
end
package.preload["weread.ui.thought_popup.popup_config"] = function() return {} end
package.preload["ui/time"] = function() return { now = function() return 0 end } end
local dirty_targets = {}
package.preload["ui/uimanager"] = function()
    return { setDirty = function(_self, target) dirty_targets[#dirty_targets + 1] = target or false end,
        nextTick = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        thought_perf = function() end,
        reader_open_perf = function() return 0 end,
    }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 1000 end } }
end

local Annotations = require("weread.ui.annotations_controller")
local Sync = require("weread.ui.annotation_sync_controller")

local counts = { documents = 0, detect = 0, store_get = 0, links = 0, native_taps = 0 }
local busy = false
local link_at = {}
local native_link = {}
function native_link:getLinkFromGes(ges)
    counts.links = counts.links + 1
    return link_at[ges.pos.x]
end
function native_link:onTap(_arg, _ges)
    counts.native_taps = counts.native_taps + 1
    return "native"
end

local cache = { show_annotations = true, ignore_edge_thought_taps = false }
local host = {
    ui = { document = { file = "/books/weread/b1/book.epub" }, link = native_link },
    settings = {
        get = function(_self, key, default)
            if key == "cache" then return cache end
            if key == "books" then return { b1 = { title = "Book" } } end
            return default
        end,
    },
    external_annotations_db = {
        getDocument = function()
            counts.documents = counts.documents + 1
            if busy then return nil, "database is locked" end
            return nil
        end,
    },
    detectWeReadBook = function()
        counts.detect = counts.detect + 1
        return "b1"
    end,
    annotation_store = {
        documentKey = function() return "doc-key" end,
        get = function()
            counts.store_get = counts.store_get + 1
            if busy then error("database is locked") end
            return nil
        end,
    },
}
for name, method in pairs(Annotations) do host[name] = method end
for name, method in pairs(Sync) do host[name] = method end
host:_installLinkFilter()

local plain_tap = { pos = { x = 500, y = 10 } }
local thought_tap = { pos = { x = 400, y = 10 } }
link_at[400] = { xpointer = "/body/a", href = "#wrthought-b1-c1-1-5" }
link_at[300] = { href = "#footnote-1" }

-- A page-turn tap on a book whose unified state is still unknown must not
-- resolve the binding: only thought anchors need that answer.
expect(native_link.onTap(native_link, nil, plain_tap) == "native", "plain tap not forwarded")
expect(counts.documents == 0 and counts.detect == 0 and counts.store_get == 0,
    "a plain page-turn tap resolved the WeRead binding")

-- The first thought-anchor tap resolves and caches a negative answer.
busy = false
expect(native_link.onTap(native_link, nil, thought_tap) == "native",
    "thought tap on a legacy (non-unified) book was suppressed")
local resolved = { documents = counts.documents, detect = counts.detect, store_get = counts.store_get }
expect(resolved.documents == 1 and resolved.detect == 1, "binding was not resolved once")
expect(host._unified_annotations_active == false, "negative unified answer was not cached")

-- Subsequent taps reuse the cached answer and skip the extra link lookup.
local links_before = counts.links
for _i = 1, 20 do
    native_link.onTap(native_link, nil, plain_tap)
    native_link.onTap(native_link, nil, thought_tap)
end
expect(counts.documents == resolved.documents and counts.detect == resolved.detect
        and counts.store_get == resolved.store_get,
    "taps re-resolved the binding or re-read SQLite")
expect(counts.links == links_before, "a cached non-unified state still doubled link lookups")

-- Unified books suppress thought anchors without further SQLite reads.
host._unified_annotations_active = true
expect(native_link.onTap(native_link, nil, thought_tap) == false,
    "a thought anchor in a unified book reached ReaderLink")
expect(native_link.onTap(native_link, nil, { pos = { x = 300, y = 10 } }) == "native",
    "an ordinary footnote link was suppressed")

-- A busy database during the first evaluation never raises from a tap and is
-- not cached as an answer.
host:_invalidateAnnotationBinding()
busy = true
local ok, result = pcall(native_link.onTap, native_link, nil, thought_tap)
expect(ok and result == "native", "a busy annotation database crashed the tap")
expect(host._unified_annotations_active == nil and host._annotation_binding_cache == nil,
    "a transient database failure was cached")
local ok_filter, filtered = pcall(native_link.getLinkFromGes, native_link, thought_tap)
expect(ok_filter and filtered == link_at[400], "a busy database crashed link lookup")
busy = false
native_link.onTap(native_link, nil, thought_tap)
expect(host._unified_annotations_active == false and host._annotation_binding_cache,
    "state was not resolved after the database recovered")

-- Book open: reading settings, then reader-ready, resolve the binding once.
host:_invalidateAnnotationBinding()
counts.documents, counts.detect = 0, 0
host.ui.typeset = { css = "base.css" }
host.ui.document.setStyleSheet = function() end
host:onReadSettings()
for _i = 1, 3 do host:_usesUnifiedAnnotations() end
expect(counts.documents == 1, "book open re-read the per-file binding database")
expect(counts.detect == 2, "book open rescanned the library more than once for the binding")

-- Reader-ready runs unprotected from onReaderReady: a locked annotation
-- database after the context was prepared must not crash opening the book.
local locked_store = {
    get = function() error("database is locked") end,
    put = function() error("database is locked") end,
    projectionKey = function(_self, key, uid) return key .. ":" .. uid end,
}
host._prepareAnnotationContext = function()
    return { book_id = "b1", document_key = "doc-key", store = locked_store,
        chapters = { { chapterUid = "1" } }, statuses = {}, binding = { book_id = "b1" } }
end
local ready_ok, ready_err = pcall(host.onUnifiedAnnotationsReady, host)
expect(ready_ok, "a locked database crashed reader-ready: " .. tostring(ready_err))

-- Overlay/highlight changes must repaint the reader view itself: the plugin
-- has no "dialog" widget, and setDirty(nil) refreshes without repainting.
dirty_targets = {}
host._thought_highlight_active = true
host:_clearThoughtHighlight({ highlightXPointer = function() end })
expect(dirty_targets[1] == host.ui, "clearing the thought highlight did not repaint ReaderUI")

-- Teardown restores ReaderLink only where our wrapper is still installed.
local class_link = {}
function class_link:getLinkFromGes(ges) return link_at[ges.pos.x] end
function class_link:onTap() return "class" end
local instance = setmetatable({}, { __index = class_link })
local filter_host = { ui = { link = instance }, settings = host.settings,
    _unified_annotations_active = true }
for name, method in pairs(Annotations) do filter_host[name] = method end
filter_host:_installLinkFilter()
filter_host:_removeLinkFilter()
expect(rawget(instance, "getLinkFromGes") == nil and rawget(instance, "onTap") == nil,
    "teardown left our wrappers on ReaderLink")
filter_host:_installLinkFilter()
local ours = instance.onTap
local other_calls = 0
instance.onTap = function(link_self, arg, ges) -- another plugin wraps after us
    other_calls = other_calls + 1
    return ours(link_self, arg, ges)
end
local theirs = instance.onTap
filter_host:_removeLinkFilter()
expect(instance.onTap == theirs, "teardown dropped a wrapper installed after ours")
local tap_ok, tap_result = pcall(instance.onTap, instance, nil, thought_tap)
expect(tap_ok and tap_result == "class" and other_calls == 1,
    "our disabled wrapper broke the remaining chain or still filtered taps")

print(("annotation_tap_cost_spec: %d checks"):format(checks))
