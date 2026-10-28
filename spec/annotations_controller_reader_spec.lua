-- Reader-side behaviour of the annotations controller: initial/applied
-- visibility stylesheets, the thought tap zone and ReaderLink filter, the
-- SQLite-backed thought tap -> popup pipeline (cache, repair, deferral to the
-- next tick, stale sessions) and teardown at the document boundary.
-- Run from the repo root with:
--   luajit spec/annotations_controller_reader_spec.lua

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed"), 2) end
end

local warnings = {}
package.preload["weread.lib.logger"] = function()
    return {
        warn = function(...) warnings[#warnings + 1] = table.concat({ tostring((...)) }, " ") end,
        info = function() end,
    }
end
package.preload["weread.lib.annotations"] = function() return {} end

local resolved_dirs = {}
package.preload["weread.lib.content"] = function()
    return {
        book_resolved_dir = function(_settings, book_id, book)
            resolved_dirs[#resolved_dirs + 1] = book_id
            return book.dir or ("/books/" .. book_id)
        end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_self, name) return { name = name } end }
end

-- ThoughtDB: in-memory rows keyed by dir -> chapter -> range.
local db_rows = {}
local db_log = { open = {}, close = {}, queries = {} }
local db_open_fails = {}
package.preload["weread.lib.thought_db"] = function()
    return {
        open = function(dir)
            db_log.open[#db_log.open + 1] = dir
            if db_open_fails[dir] then return nil end
            return { dir = dir }
        end,
        close = function(db) db_log.close[#db_log.close + 1] = db.dir end,
        getReviewItems = function(db, chapter_uid, range)
            db_log.queries[#db_log.queries + 1] = db.dir .. "|" .. chapter_uid .. "|" .. range
            local chapters = db_rows[db.dir] or {}
            return (chapters[chapter_uid] or {})[range] or {}
        end,
    }
end

local popup = { shows = {}, showing = false, cleanups = 0, closes = 0, fail = false }
package.preload["weread.ui.thought_popup"] = function()
    return {
        show = function(options)
            if popup.fail then error("widget exploded") end
            popup.shows[#popup.shows + 1] = options
            popup.showing = true
            return { options = options }
        end,
        isShowing = function() return popup.showing end,
        closeVisible = function() popup.closes = popup.closes + 1; popup.showing = false end,
        cleanup = function() popup.cleanups = popup.cleanups + 1; popup.showing = false end,
    }
end
package.preload["weread.ui.thought_popup.popup_config"] = function()
    return {
        build = function(_plugin, pages, extra)
            local options = { pages = pages }
            for k, v in pairs(extra or {}) do options[k] = v end
            return options
        end,
    }
end
package.preload["ui/time"] = function() return { now = function() return 0 end } end

local ticks, dirty = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_self, target, mode) dirty[#dirty + 1] = { target = target, mode = mode } end,
        nextTick = function(_self, callback) ticks[#ticks + 1] = callback end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        thought_perf = function() end,
    }
end
local touch_device = true
package.preload["device"] = function()
    return {
        isTouchDevice = function() return touch_device end,
        screen = { getWidth = function() return 1000 end },
    }
end

local Controller = require("weread.ui.annotations_controller")

local function run_ticks()
    local pending = ticks
    ticks = {}
    for _i, callback in ipairs(pending) do callback() end
end

-- Builds a plugin host with the controller mixed in and recording stubs for
-- ReaderUI, the document and ReaderLink.
local function new_host(opts)
    opts = opts or {}
    local cache = opts.cache or { show_annotations = true, ignore_edge_thought_taps = false }
    local books = opts.books or { b1 = { title = "Book" } }
    local log = { stylesheets = {}, events = {}, highlights = {}, zones = {}, unzones = {},
        ensure = 0, link_lookups = 0 }
    local links = {}
    local link = {}
    function link:getLinkFromGes(ges)
        log.link_lookups = log.link_lookups + 1
        if opts.link_raises then error("crengine busy") end
        return ges.pos and links[ges.pos.x] or nil
    end
    function link:onTap() return "native" end
    local document = {
        setStyleSheet = function(_self, css, tweaks)
            if opts.stylesheet_raises then error("reflow failed") end
            log.stylesheets[#log.stylesheets + 1] = { css = css, tweaks = tweaks }
        end,
        highlightXPointer = function(_self, xp)
            if opts.highlight_raises then error("no such node") end
            log.highlights[#log.highlights + 1] = xp or false
        end,
    }
    local ui = {
        document = document,
        link = link,
        typeset = opts.no_typeset and {} or { css = "base.css" },
        styletweak = { getCssText = function() return opts.tweaks or "p{margin:0}" end },
        handleEvent = function(_self, event) log.events[#log.events + 1] = event.name end,
        registerTouchZones = function(_self, zones) log.zones[#log.zones + 1] = zones end,
        unRegisterTouchZones = function(_self, zones) log.unzones[#log.unzones + 1] = zones end,
    }
    local settings = {
        get = function(_self, key, default)
            if key == "cache" then return cache end
            if key == "books" then return books end
            return default
        end,
    }
    if not opts.no_get_book then
        settings.get_book = function(_self, id) return books[id] end
    end
    local host = {
        ui = ui,
        settings = settings,
        _reader_session_gen = 1,
        _current_weread_book_id = "b1",
        detectWeReadBook = function()
            if opts.not_weread then return nil end
            return "b1"
        end,
        ensureAnnotationDisplay = function(self)
            log.ensure = log.ensure + 1
            self._ensure_called = true
            return true
        end,
    }
    if opts.unified ~= nil then
        host._usesUnifiedAnnotations = function()
            if opts.unified == "raise" then error("database is locked") end
            return opts.unified
        end
    end
    for name, method in pairs(Controller) do host[name] = method end
    return host, log, links, cache
end

local HIDE_MARK = ".wr-underline{border-bottom:0"

-- onReadSettings: only hidden/unified books get the hide stylesheet before the
-- first render; ordinary opens must not trigger any re-render.
do
    local host, log = new_host()
    host:onReadSettings()
    expect(#log.stylesheets == 0, "a visible, non-unified book was restyled on open")

    host, log = new_host({ cache = { show_annotations = false } })
    host:onReadSettings()
    expect(#log.stylesheets == 1 and log.stylesheets[1].css == "base.css",
        "hidden annotations were not applied before first render")
    local tweaks = log.stylesheets[1].tweaks
    expect(tweaks:find("p{margin:0}", 1, true) == 1 and tweaks:find(HIDE_MARK, 1, true),
        "the hide CSS did not keep the user's style tweaks")
    expect(#log.events == 0, "onReadSettings triggered a reflow event before render")

    host, log = new_host({ unified = true })
    host:onReadSettings()
    expect(#log.stylesheets == 1 and log.stylesheets[1].tweaks:find(HIDE_MARK, 1, true),
        "a unified book kept the baked underlines visible")

    -- A busy database while resolving the unified state is "not unified".
    warnings = {}
    host, log = new_host({ unified = "raise" })
    local ok = pcall(host.onReadSettings, host)
    expect(ok and #log.stylesheets == 0 and #warnings == 1,
        "a busy annotation database crashed or restyled reader open")

    host, log = new_host({ cache = { show_annotations = false }, not_weread = true })
    host:onReadSettings()
    expect(#log.stylesheets == 0, "a non-WeRead book was restyled")

    host, log = new_host({ cache = { show_annotations = false }, no_typeset = true })
    expect(pcall(host.onReadSettings, host) and #log.stylesheets == 0,
        "a missing typeset stylesheet was not tolerated")

    host = new_host({ cache = { show_annotations = false }, stylesheet_raises = true })
    expect(pcall(host.onReadSettings, host), "a stylesheet failure escaped onReadSettings")

    host = new_host()
    host.ui.document = nil
    expect(pcall(host.onReadSettings, host), "onReadSettings without a document raised")
end

-- applyAnnotationVisibility: overlay state + stylesheet + reflow.
do
    local host, log = new_host()
    local cache = host.settings:get("cache")
    local overlay = { enabled_calls = {} }
    function overlay:setEnabled(v) self.enabled_calls[#self.enabled_calls + 1] = v end
    local refreshed = 0
    host._xpointer_overlay = overlay
    host._refreshAnnotationOverlay = function() refreshed = refreshed + 1 end
    dirty = {}
    host:applyAnnotationVisibility()
    expect(overlay.enabled_calls[1] == true and refreshed == 1,
        "showing did not enable and refresh the overlay")
    expect(dirty[1] and dirty[1].target == host.ui, "overlay change did not repaint ReaderUI")
    expect(#log.stylesheets == 1 and not log.stylesheets[1].tweaks:find(HIDE_MARK, 1, true),
        "visible annotations still appended the hide CSS")
    expect(log.events[1] == "UpdatePos", "the stylesheet change did not reflow the document")

    cache.show_annotations = false
    host:applyAnnotationVisibility()
    expect(overlay.enabled_calls[2] == false and refreshed == 1,
        "hiding refreshed the overlay or kept it enabled")
    expect(log.stylesheets[2].tweaks:find(HIDE_MARK, 1, true), "hiding did not append the hide CSS")

    -- Non-WeRead documents only get the overlay update, never our stylesheet.
    host, log = new_host({ not_weread = true })
    host._xpointer_overlay = overlay
    host:applyAnnotationVisibility()
    expect(#log.stylesheets == 0 and overlay.enabled_calls[3] == true,
        "a non-WeRead document was restyled")

    host, log = new_host({ unified = true })
    host:applyAnnotationVisibility()
    expect(log.stylesheets[1].tweaks:find(HIDE_MARK, 1, true),
        "unified overlay books did not hide baked underlines")

    host, log = new_host({ no_typeset = true })
    host:applyAnnotationVisibility()
    expect(#log.stylesheets == 0 and #log.events == 0, "missing typeset still reflowed")

    host, log = new_host({ stylesheet_raises = true })
    expect(pcall(host.applyAnnotationVisibility, host) and #log.events == 0,
        "a stylesheet failure escaped or still reflowed")

    host = new_host()
    host.ui = nil
    expect(pcall(host.applyAnnotationVisibility, host), "applying without a reader raised")
end

-- The dispatcher action toggles and persists the global preference.
do
    local host, _, _, cache = new_host()
    local flushed = 0
    host.settings.set = function(_self, key, value) if key == "cache" then cache = value end end
    host.settings.flush = function() flushed = flushed + 1 end
    host._annotation_context = {}
    host._annotationSummary = function() return { chapters = 2 } end
    local info
    host.showTransientInfo = function(_self, text) info = text end
    popup.closes = 0
    expect(host:onToggleWeReadAnnotations() == true and cache.show_annotations == false,
        "the dispatcher action did not hide annotations")
    expect(flushed == 1 and popup.closes == 1 and info == "Underlines and thoughts hidden",
        "hiding was not persisted or did not close the popup")
    host:onToggleWeReadAnnotations()
    expect(cache.show_annotations == true and info == "Underlines and thoughts shown"
            and host._ensure_called == nil,
        "re-showing a matched book did not toggle back without the guide")
end

-- ReaderLink filter on getLinkFromGes: hides our anchors only.
do
    local host, _, links, cache = new_host({ unified = false })
    links[500] = { href = "#wrthought-b1-c1-1-5" }
    links[501] = { href = "#footnote-3" }
    links[502] = { target = { url = "chapter.html#thought_c1_10_20" } }
    host:_installLinkFilter()
    local link = host.ui.link
    local wrapped = link.getLinkFromGes
    host:_installLinkFilter()
    expect(link.getLinkFromGes == wrapped, "installing the filter twice double-wrapped ReaderLink")

    expect(link:getLinkFromGes({ pos = { x = 500 } }) == links[500],
        "a visible thought anchor was hidden from ReaderLink")
    cache.show_annotations = false
    expect(link:getLinkFromGes({ pos = { x = 500 } }) == nil, "hidden thoughts stayed tappable")
    expect(link:getLinkFromGes({ pos = { x = 502 } }) == nil, "a legacy thought anchor stayed tappable")
    expect(link:getLinkFromGes({ pos = { x = 501 } }) == links[501], "a footnote link was filtered")
    expect(link:getLinkFromGes({ pos = { x = 499 } }) == nil, "a missing link was invented")

    -- Edge zone: default ratio 0.20, clamped to [0.05, 0.45].
    cache.show_annotations = true
    cache.ignore_edge_thought_taps = true
    links[100] = links[500]
    links[150] = links[500]
    links[960] = links[500]
    links[40] = links[500]
    expect(link:getLinkFromGes({ pos = { x = 100 } }) == nil, "a left-edge thought tap was not ignored")
    expect(link:getLinkFromGes({ pos = { x = 960 } }) == nil, "a right-edge thought tap was not ignored")
    cache.edge_tap_ratio = 0.01
    expect(link:getLinkFromGes({ pos = { x = 100 } }) == links[500]
            and link:getLinkFromGes({ pos = { x = 40 } }) == nil,
        "a tiny edge ratio was not clamped to 5%")
    cache.edge_tap_ratio = 0.9
    expect(link:getLinkFromGes({ pos = { x = 500 } }) == links[500]
            and link:getLinkFromGes({ pos = { x = 150 } }) == nil,
        "a huge edge ratio was not clamped to 45%")
    cache.edge_tap_ratio = "bogus"
    expect(link:getLinkFromGes({ pos = { x = 150 } }) == nil, "a malformed ratio did not fall back to 20%")
    cache.ignore_edge_thought_taps = false
    expect(link:getLinkFromGes({ pos = { x = 40 } }) == links[500],
        "edge filtering applied although disabled")

    host._usesUnifiedAnnotations = function() return true end
    expect(link:getLinkFromGes({ pos = { x = 500 } }) == nil,
        "a unified book exposed thought anchors to ReaderLink")

    local bare = new_host()
    bare.ui.link = nil
    bare:_installLinkFilter()
    expect(bare._link_filter == nil, "a filter was installed without ReaderLink")
end

-- Tap zone setup / teardown at the document boundary.
do
    touch_device = false
    local host, log = new_host()
    local native_tap, native_get = host.ui.link.onTap, host.ui.link.getLinkFromGes
    host:_setupThoughtInterception()
    expect(#log.zones == 0 and not host._thought_interception_setup,
        "a non-touch device registered the thought tap zone")
    touch_device = true

    host:_setupThoughtInterception()
    host:_setupThoughtInterception()
    expect(#log.zones == 1, "the thought tap zone was registered twice")
    local zone = log.zones[1][1]
    expect(zone.id == "weread_thought_tap" and zone.overrides[1] == "tap_link",
        "the tap zone does not override tap_link")
    expect(host._link_filter ~= nil, "setup did not install the ReaderLink filter")
    expect(zone.handler({ pos = { x = 500 } }) == false,
        "a tap on plain text was consumed instead of turning the page")

    local dialog_closed = 0
    host._thought_refresh_request = { progress_dialog = { close = function() dialog_closed = dialog_closed + 1 end } }
    host._thought_db, host._thought_db_dir, host._thought_db_book_id = { dir = "/books/b1" }, "/books/b1", "b1"
    host._thought_page_cache, host._thought_page_cache_n = { x = {} }, 1
    host._thought_popup_open, host._thought_popup_pending = true, true
    host._thought_highlight_active = true
    db_log.close = {}
    popup.cleanups = 0
    host:_teardownThoughtInterception()
    expect(#log.unzones == 1 and log.unzones[1][1].id == "weread_thought_tap",
        "teardown did not unregister the tap zone")
    expect(host._link_filter == nil and host.ui.link.onTap == native_tap
            and host.ui.link.getLinkFromGes == native_get,
        "teardown left the ReaderLink filter installed")
    expect(popup.cleanups == 1, "teardown did not free the pooled popup")
    expect(dialog_closed == 1 and host._thought_refresh_request == nil,
        "teardown left the thought refresh dialog open")
    expect(db_log.close[1] == "/books/b1" and host._thought_db == nil and host._thought_db_dir == nil,
        "teardown did not close the thought database")
    expect(host._thought_page_cache == nil and host._thought_popup_open == nil
            and host._thought_popup_pending == nil and host._thought_highlight_active == nil
            and host._current_weread_book_id == nil,
        "teardown leaked per-document thought state")

    host:_teardownThoughtInterception()
    expect(#log.unzones == 1 and #db_log.close == 1 and dialog_closed == 1,
        "a repeated teardown unregistered or closed resources twice")
    host:_setupThoughtInterception()
    expect(#log.zones == 2, "the tap zone could not be registered again for the next document")
    host._thought_refresh_request = {}
    host:_teardownThoughtInterception()
    expect(host._thought_refresh_request == nil, "a refresh request without a dialog was kept")
end

-- Link href extraction and anchor parsing.
do
    local host = new_host()
    expect(host:_linkHref("x.html#wrthought-b1-c1-1-5") == "#wrthought-b1-c1-1-5",
        "a plain string href was not extracted")
    expect(host:_linkHref({ a = { b = { "wrthought-b1-c1-1-5" } } }) == "wrthought-b1-c1-1-5",
        "a nested href was not found by the shallow crawl")
    local cyclic = {}
    cyclic.self = cyclic
    cyclic.href = 42
    expect(host:_linkHref(cyclic) == nil, "a cyclic link table was not handled")
    expect(host:_linkHref({ a = { b = { c = { d = { e = "#wrthought-b1-c1-1-5" } } } } }) == nil,
        "the crawl went deeper than 4 levels")
    expect(host:_linkHref(nil) == nil and host:_linkHref({ href = "#chapter2" }) == nil,
        "a non-thought link produced an href")

    local info = host:_parseThoughtHref("#wrthought-b9-ch7-12-34")
    expect(info and info.book_id == "b9" and info.chapter_uid == "ch7" and info.range == "12-34"
            and not info.legacy_html,
        "a current anchor was not parsed")
    info = host:_parseThoughtHref("#thought_ch_7_12_34")
    expect(info and info.book_id == "b1" and info.chapter_uid == "ch_7" and info.range == "12-34"
            and info.legacy_html,
        "a legacy anchor did not use the open book")
    host._current_weread_book_id = nil
    expect(host:_parseThoughtHref("#thought_ch7_12_34") == nil,
        "a legacy anchor was parsed without an open WeRead book")
    warnings = {}
    expect(host:_parseThoughtHref("#wrthought-b9-ch7-x-34") == nil and #warnings == 1,
        "a malformed anchor was not rejected with a warning")
    expect(host:_parseThoughtHref(nil) == nil and host:_parseThoughtHref("#note") == nil,
        "non-anchor input was parsed")
end

-- Thought DB lifecycle: reuse per book, close on switch, tolerate failures.
do
    local host = new_host({ books = { b1 = {}, b2 = {}, b3 = { dir = "/books/b1" } } })
    db_log.open, db_log.close = {}, {}
    local db1 = host:_ensureThoughtDB("b1")
    expect(db1 and db1.dir == "/books/b1" and host._thought_db_book_id == "b1",
        "the thought database was not opened for the book")
    expect(host:_ensureThoughtDB("b1") == db1 and #db_log.open == 1,
        "the same book reopened its thought database")
    expect(host:_ensureThoughtDB("b3") == db1 and #db_log.open == 1,
        "a second id resolving to the same directory reopened the database")
    local db2 = host:_ensureThoughtDB("b2")
    expect(db2.dir == "/books/b2" and db_log.close[1] == "/books/b1" and #db_log.open == 2,
        "switching books did not close the previous database")
    expect(host:_ensureThoughtDB("unknown") == nil and host._thought_db == db2,
        "an unknown book dropped the open database")
    db_open_fails["/books/b1"] = true
    expect(host:_ensureThoughtDB("b1") == nil and host._thought_db == nil
            and host._thought_db_dir == nil and host._thought_db_book_id == nil,
        "a failed open left stale database state")
    db_open_fails["/books/b1"] = nil

    -- Older settings objects without get_book read the books table.
    local legacy = new_host({ no_get_book = true })
    expect(legacy:_ensureThoughtDB("b1") ~= nil, "the books-table fallback was not used")
end

-- Thought tap -> popup pipeline.
do
    db_rows["/books/b1"] = {
        c1 = { ["1-5"] = { { abstract = "quote", content = "thought" } } },
        c2 = { ["7-9"] = { { abstract = "legacy", content = "old" } } },
    }
    local host, log, links, cache = new_host({ unified = false })
    host:_setupThoughtInterception()
    links[500] = { href = "#wrthought-b1-c1-1-5", from_xpointer = "/body/p[2]/text().0" }
    links[501] = { href = "#footnote-1" }
    links[502] = { href = "#wrthought-b1-c1-90-99" }
    links[503] = { href = "#thought_c2_7_9" }
    links[504] = { href = "#wrthought-b1-c1-oops" }
    local tap = { pos = { x = 500, y = 10 } }

    db_log.queries, popup.shows, ticks = {}, {}, {}
    expect(host:_onThoughtTap(tap) == true, "a thought tap was not consumed")
    expect(db_log.queries[1] == "/books/b1|c1|1-5", "the tapped range was not queried")
    expect(#popup.shows == 0 and #ticks == 1, "the popup opened inside the gesture handler")
    expect(host:_onThoughtTap(tap) == true and #ticks == 1,
        "a second tap in the same input batch queued another popup")
    expect(#db_log.queries == 1, "a repeated tap re-queried SQLite instead of the page cache")
    run_ticks()
    expect(#popup.shows == 1 and popup.shows[1].pages[1].content == "thought",
        "the queued popup did not show the thought")
    expect(log.highlights[1] == false and log.highlights[2] == links[500].from_xpointer
            and host._thought_highlight_active,
        "the tapped range was not highlighted")
    expect(host._current_thought_popup and host._thought_popup_pending == nil,
        "popup state was not recorded")
    expect(host:_onThoughtTap(tap) == true and #ticks == 0,
        "a tap while the popup is visible queued another popup")

    dirty = {}
    popup.shows[1].close_callback()
    expect(host._thought_popup_open == nil and host._current_thought_popup == nil
            and host._thought_highlight_active == nil and log.highlights[3] == false,
        "closing the popup did not clear the highlight and state")
    expect(dirty[1] and dirty[1].target == host.ui, "closing did not repaint the reader")

    -- Stale "open" flag (popup closed elsewhere) must not swallow taps forever.
    host._thought_popup_open = true
    popup.showing = false
    expect(host:_onThoughtTap(tap) == true and #ticks == 1, "a stale open flag swallowed the tap")
    run_ticks()
    expect(#popup.shows == 2, "the popup did not reopen after a stale flag")
    popup.showing = false
    host._thought_popup_open = nil

    -- Missing SQLite rows enter the unified repair flow and are not cached.
    expect(host:_onThoughtTap({ pos = { x = 502 } }) == true and log.ensure == 1,
        "a thought without rows did not trigger annotation repair")
    expect(host._thought_page_cache["#wrthought-b1-c1-90-99"] == nil and #ticks == 0,
        "a missing thought was cached or queued a popup")
    expect(host:_onThoughtTap({ pos = { x = 502 } }) == true and log.ensure == 2,
        "a repeated tap on a missing thought did not retry the repair")

    -- Legacy HTML anchors resolve against the open book.
    expect(host:_onThoughtTap({ pos = { x = 503 } }) == true and #ticks == 1,
        "a legacy thought anchor did not queue a popup")
    run_ticks()
    expect(popup.shows[3].pages[1].content == "old", "the legacy anchor showed the wrong thought")
    popup.showing, host._thought_popup_open = false, nil

    -- Malformed anchors are consumed without repair attempts.
    local ensure_before = log.ensure
    expect(host:_onThoughtTap({ pos = { x = 504 } }) == true and log.ensure == ensure_before
            and #ticks == 0,
        "a malformed anchor triggered repair or a popup")

    -- Pass-through cases: KOReader keeps handling these taps.
    expect(host:_onThoughtTap({ pos = { x = 501 } }) == false, "a footnote tap was intercepted")
    expect(host:_onThoughtTap({ pos = { x = 999 } }) == false, "a tap without a link was consumed")
    cache.ignore_edge_thought_taps = true
    local lookups = log.link_lookups
    expect(host:_onThoughtTap({ pos = { x = 10 } }) == false and log.link_lookups == lookups,
        "an edge tap was intercepted or still looked up links")
    cache.ignore_edge_thought_taps = false
    cache.show_annotations = false
    expect(host:_onThoughtTap(tap) == false, "hidden annotations still opened thoughts")
    cache.show_annotations = true
    host._usesUnifiedAnnotations = function() return true end
    expect(host:_onThoughtTap(tap) == false, "a unified book opened the legacy thought popup")
    host._usesUnifiedAnnotations = function() return false end
    host._current_weread_book_id = nil
    expect(host:_onThoughtTap(tap) == false, "a non-WeRead document intercepted a tap")
    host._current_weread_book_id = "b1"
    local saved_link = host.ui.link
    host.ui.link = nil
    expect(host:_onThoughtTap(tap) == false, "a tap without ReaderLink was consumed")
    host.ui.link = saved_link
    expect(#ticks == 0, "a pass-through tap queued a popup")

    -- Defensive path when ReaderLink is not filtered (e.g. another plugin
    -- replaced it): hidden annotations still never open a thought.
    local unfiltered, unfiltered_log, unfiltered_links, unfiltered_cache = new_host({ unified = false })
    unfiltered_links[500] = links[500]
    unfiltered_cache.show_annotations = false
    expect(unfiltered:_onThoughtTap(tap) == false and #ticks == 0,
        "an unfiltered ReaderLink let hidden thoughts open")
    unfiltered_cache.show_annotations = true
    unfiltered_cache.ignore_edge_thought_taps = true
    local unfiltered_lookups = unfiltered_log.link_lookups
    expect(unfiltered:_onThoughtTap({}) == false and unfiltered_log.link_lookups == unfiltered_lookups + 1,
        "a gesture without a position was intercepted or skipped the link lookup")
    -- A unified book never opens the legacy popup, even when ReaderLink
    -- still returns our anchors.
    local unified_unfiltered, unified_log, unified_links = new_host({ unified = true })
    unified_links[500] = links[500]
    expect(unified_unfiltered:_onThoughtTap(tap) == false and unified_log.link_lookups == 1
            and unified_unfiltered._thought_page_cache == nil and #ticks == 0,
        "an unfiltered ReaderLink let a unified book open the legacy popup")
    expect(#ticks == 0, "a defensive pass-through queued a popup")

    local raising = new_host({ link_raises = true })
    local ok, consumed = pcall(raising._onThoughtTap, raising, tap)
    expect(ok and consumed == false, "a failing link lookup crashed or consumed the tap")

    -- The per-session page cache is bounded.
    host._thought_page_cache_n = 300
    host._thought_page_cache = { stale = { {} } }
    db_rows["/books/b1"].c3 = { ["1-2"] = { { content = "new" } } }
    links[505] = { href = "#wrthought-b1-c3-1-2" }
    host:_onThoughtTap({ pos = { x = 505 } })
    expect(host._thought_page_cache.stale == nil and host._thought_page_cache_n == 1
            and host._thought_page_cache["#wrthought-b1-c3-1-2"],
        "the thought page cache grew past its ceiling")
    run_ticks()
end

-- Deferred popup: a session change or closed document cancels it.
do
    local host = new_host()
    local pages = { { content = "x" } }
    popup.shows, ticks = {}, {}
    popup.showing = false
    expect(host:_queueThoughtPopup({}, {}) == true and #ticks == 0, "empty pages queued a popup")
    host:_queueThoughtPopup(pages, nil)
    host._reader_session_gen = 2
    run_ticks()
    expect(#popup.shows == 0 and host._thought_popup_open == nil and host._thought_popup_pending == nil,
        "a popup queued in a closed reader session was shown")

    host:_queueThoughtPopup(pages, nil)
    host.ui.document = nil
    run_ticks()
    expect(#popup.shows == 0 and host._thought_popup_open == nil,
        "a popup was shown after the document closed")

    host = new_host()
    host:_queueThoughtPopup(pages, nil)
    run_ticks()
    expect(#popup.shows == 1 and host._thought_highlight_active == nil,
        "a link without an xpointer failed or highlighted")
    popup.showing, host._thought_popup_open = false, nil

    -- Direct guards in _showThoughtPopup.
    host._thought_popup_open = true
    host:_showThoughtPopup(pages, {}, 99)
    expect(host._thought_popup_open == nil and #popup.shows == 1, "a stale session showed a popup")
    host._thought_popup_open = true
    host:_showThoughtPopup({}, {}, 1)
    expect(host._thought_popup_open == nil and #popup.shows == 1, "empty pages showed a popup")

    -- A failing popup clears the highlight it just drew.
    popup.fail = true
    warnings, dirty = {}, {}
    local log
    host, log = new_host()
    host._thought_popup_open = true
    expect(pcall(host._showThoughtPopup, host, pages, { from_xpointer = "/p" }, 1, 0),
        "a popup failure escaped")
    popup.fail = false
    expect(host._thought_popup_open == nil and host._thought_highlight_active == nil
            and log.highlights[3] == false and #warnings == 1,
        "a failed popup left the highlight or open flag behind")

    -- A highlight failure still shows the popup but records no highlight.
    host = new_host({ highlight_raises = true })
    host:_showThoughtPopup(pages, { from_xpointer = "/p" }, 1, 0)
    expect(#popup.shows == 2 and host._thought_highlight_active == nil,
        "a highlight failure blocked the popup or left a highlight flag")
    expect(pcall(host._clearThoughtHighlight, host, host.ui.document),
        "clearing without an active highlight raised")
    host._thought_highlight_active = true
    expect(pcall(host._clearThoughtHighlight, host, host.ui.document)
            and host._thought_highlight_active == nil,
        "a failing highlight clear left the flag set")
end

print(("annotations_controller_reader_spec: %d checks"):format(checks))
