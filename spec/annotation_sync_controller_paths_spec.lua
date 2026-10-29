-- Edge paths of the annotation sync controller that the end-to-end spec does
-- not reach: guard rails of the menu actions, the subprocess request runner
-- (dismissal, garbage replies, worker errors), prefetch-worker completion,
-- overlay refresh decisions, automatic single-chapter prefetch on open, and
-- cleanup failures. Uses an in-memory store instead of SQLite.
-- Run from the repo root with:
--   luajit spec/annotation_sync_controller_paths_spec.lua

package.path = "./?.lua;" .. package.path
local restore_subprocess = require("spec.helpers.subprocess_stub").install()

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed"), 2) end
end

local logs = { warn = {}, info = {} }
package.preload["weread.lib.logger"] = function()
    return {
        warn = function(...) logs.warn[#logs.warn + 1] = table.concat({ ... }, " ") end,
        info = function(...) logs.info[#logs.info + 1] = table.concat({ ... }, " ") end,
        err = function() end,
    }
end

local shown, closed, dirty = {}, {}, 0
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function(_self, widget) closed[#closed + 1] = widget end,
        setDirty = function() dirty = dirty + 1 end,
        scheduleIn = function() error("UI scheduler must not be used here") end,
    }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, args) return args end }
end

local network = {}
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function(_client, remote)
            network[#network + 1] = "state:" .. remote.book_id
        end,
        fetch_catalog = function(_client, remote)
            network[#network + 1] = "catalog:" .. remote.book_id
            return { { chapterUid = "1", title = "One" } }
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        reader_open_perf = function() return 0 end,
        display_error = tostring,
        tr = function(s) return s end,
        T = function(s, ...)
            local v = { ... }
            return (s:gsub("%%(%d+)", function(i) return tostring(v[tonumber(i)]) end))
        end,
    }
end

local guards = { acquired = 0, released = 0 }
package.preload["weread.lib.standby_guard"] = function()
    return {
        acquire = function() guards.acquired = guards.acquired + 1; return {} end,
        release = function() guards.released = guards.released + 1 end,
    }
end

local merges = {}
local merge_result = true
package.preload["weread.lib.worker_settings"] = function()
    return {
        fingerprint = function() return "fp" end,
        capture = function() return function() return { cookies = "child" } end end,
        merge = function(_settings, fingerprint, auth)
            merges[#merges + 1] = { fingerprint = fingerprint, auth = auth }
            return merge_result
        end,
    }
end

-- Opaque JSON: encode hands out a token, decode resolves it (garbage fails).
local encoded_values = {}
package.preload["json"] = function()
    return {
        encode = function(value)
            encoded_values[#encoded_values + 1] = value
            return "token:" .. #encoded_values
        end,
        decode = function(text)
            local index = tonumber(text:match("^token:(%d+)$"))
            if not index then error("malformed json") end
            return encoded_values[index]
        end,
    }
end

local stores_created = 0
package.preload["weread.lib.annotation_store"] = function()
    return { new = function(_self, settings)
        stores_created = stores_created + 1
        return { settings = settings }
    end }
end

for _, name in ipairs({ "ui/bidi", "ui/widget/infomessage", "ui/widget/menu" }) do
    package.preload[name] = function() return {} end
end
local Controller = require("weread.ui.annotation_sync_controller")

-- Minimal in-memory store with the methods the controller touches.
local function new_store()
    local rows = {}
    local store = { writes = {}, cleared = {} }
    local function bucket(book, kind)
        rows[book] = rows[book] or {}
        rows[book][kind] = rows[book][kind] or {}
        return rows[book][kind]
    end
    function store:get(book, kind, key) return bucket(book, kind)[key] end
    function store:put(book, kind, key, value) bucket(book, kind)[key] = value end
    function store:list(book, kind) return bucket(book, kind) end
    function store.projectionKey(_self, document_key, uid) return document_key .. ":" .. uid end
    function store:clearKinds(book, kinds)
        if self.fail_clear then error("database is locked") end
        for _, kind in ipairs(kinds) do bucket(book, kind); rows[book][kind] = {} end
        self.cleared[#self.cleared + 1] = book
    end
    function store:write(book, changes)
        for _, change in ipairs(changes) do bucket(book, change.kind)[change.key] = change.value end
        self.writes[#self.writes + 1] = changes
    end
    return store
end

local function new_context(store, fields)
    local context = { path = "book.epub", book_id = "b1", document_key = "doc", store = store,
        binding = { book_id = "b1", title = "Fixture" }, statuses = {}, ranges = {},
        chapters = { { chapterUid = "1" }, { chapterUid = "2" } },
        catalog = { { chapterUid = "1" }, { chapterUid = "2" } } }
    for k, v in pairs(fields or {}) do context[k] = v end
    return context
end

local function new_host(fields)
    local cache = { show_annotations = true }
    local host = setmetatable({
        _reader_session_gen = 1,
        cache = cache,
        notices = {},
        calls = {},
        ui = { document = { file = "book.epub", getXPointer = function() return "0" end } },
        settings = {
            get = function(_self, key, default)
                if key == "cache" then return cache end
                return default
            end,
            set = function() end,
            flush = function() end,
        },
        showInfo = function(self, text) self.notices[#self.notices + 1] = text end,
        showTransientInfo = function(self, text) self.notices[#self.notices + 1] = text end,
        applyAnnotationVisibility = function(self) self.calls.apply = (self.calls.apply or 0) + 1 end,
        bindExternalAnnotationsBook = function(self) self.calls.bind = (self.calls.bind or 0) + 1 end,
        requireLogin = function() return true end,
        isNetworkConnected = function() return true end,
        runOnlineTask = function(self, _label, callback)
            self.calls.online = (self.calls.online or 0) + 1
            return callback()
        end,
        _xpointerOverlayPrototypeAvailable = function() return true end,
        _annotationBinding = function() return { book_id = "b1", title = "Fixture" } end,
    }, { __index = Controller })
    for k, v in pairs(fields or {}) do host[k] = v end
    return host
end

-- The store is created lazily, once per plugin instance.
do
    local host = new_host()
    local store = host:_annotationStore()
    expect(store.settings == host.settings and host:_annotationStore() == store and stores_created == 1,
        "the annotation store was not created once with the plugin settings")
end

-- Visibility for the current document.
do
    local host = new_host({ _usesUnifiedAnnotations = function() return false end,
        detectWeReadBook = function() return "b1" end })
    expect(host:_annotationsVisibleForCurrentDocument() == true,
        "a legacy WeRead book with the global preference on was not visible")
    host.detectWeReadBook = function() return nil end
    expect(host:_annotationsVisibleForCurrentDocument() == false,
        "a non-WeRead legacy document appeared visible")

    host._usesUnifiedAnnotations = function() return true end
    host._prepareAnnotationContext = function() error("database is locked") end
    expect(host:_annotationsVisibleForCurrentDocument() == false,
        "a failed context preparation raised or appeared visible")
    local store = new_store()
    local prepared = new_context(store, { chapters = { { chapterUid = "1" } } })
    prepared.statuses["doc:1"] = { stats = { total = 2, located = 1 } }
    host._prepareAnnotationContext = function() return prepared end
    expect(host:_annotationsVisibleForCurrentDocument() == true,
        "a prepared context with matched chapters was not visible")
    host.cache.show_annotations = false
    expect(host:_annotationsVisibleForCurrentDocument() == false, "the hidden preference was ignored")
end

-- Chapter index without a comparable document.
do
    local host = new_host()
    expect(host:_annotationChapterIndex({}, "0") == nil, "a document without compareXPointers indexed")
    host.ui.document = nil
    expect(host:_annotationChapterIndex({}, "0") == nil, "a closed document indexed")
end

-- Chapter index lookup: numeric xpointers, compareXPointers(a, b) is 1 when
-- a precedes b, 0 when equal and -1 when a follows b (crengine order).
do
    local compares = 0
    local document = { compareXPointers = function(_self, a, b)
        compares = compares + 1
        a, b = tonumber(a), tonumber(b)
        if not a or not b then error("invalid xpointer") end
        return a < b and 1 or (a == b and 0 or -1)
    end }
    local host = new_host()
    host.ui.document = document
    -- Chapter 3 shares chapter 2's TOC anchor; chapter 5 has no range.
    local context = new_context(new_store(), {
        chapters = { { chapterUid = "1" }, { chapterUid = "2" }, { chapterUid = "3" },
            { chapterUid = "4" }, { chapterUid = "5" } },
        ranges = { ["1"] = { start_xpointer = "10" }, ["2"] = { start_xpointer = "20" },
            ["3"] = { start_xpointer = "20" }, ["4"] = { start_xpointer = "40" } },
    })
    expect(host:_annotationChapterIndex(context, "5") == nil and context._chapter_lookup.cursor == nil,
        "a point before the first chapter was indexed")
    expect(#context._chapter_lookup.starts == 3, "equal TOC anchors were not collapsed")
    expect(host:_annotationChapterIndex(context, "10") == 1, "a chapter start was not indexed to its chapter")
    expect(host:_annotationChapterIndex(context, "25") == 2, "equal TOC anchors did not keep the first chapter")
    expect(host:_annotationChapterIndex(context, "45") == 4, "the last chapter was not found by binary search")
    local lookup = context._chapter_lookup
    -- Same-chapter page turns take the cursor fast path: one comparison on
    -- the last chapter, two in the middle, and the lookup is not rebuilt.
    compares = 0
    expect(host:_annotationChapterIndex(context, "47") == 4 and compares == 1,
        "a page turn in the last chapter did not use the cursor")
    expect(host:_annotationChapterIndex(context, "15") == 1, "jumping back did not binary search")
    compares = 0
    expect(host:_annotationChapterIndex(context, "16") == 1 and compares == 2,
        "a page turn in a middle chapter did not use the cursor")
    expect(context._chapter_lookup == lookup, "an unchanged context rebuilt its chapter lookup")
    -- A failing comparison aborts instead of guessing a chapter.
    expect(host:_annotationChapterIndex(context, "bad") == nil, "a failed comparison on the cursor indexed")
    lookup.cursor = nil
    expect(host:_annotationChapterIndex(context, "bad") == nil, "a failed comparison in the search indexed")
    -- New ranges rebuild the lookup.
    context.ranges = { ["1"] = { start_xpointer = "10" }, ["5"] = { start_xpointer = "50" } }
    expect(host:_annotationChapterIndex(context, "55") == 5 and context._chapter_lookup ~= lookup,
        "changed ranges did not rebuild the chapter lookup")
end

-- Overlay refresh decisions.
do
    local store = new_store()
    local overlay = { setRecords = function(self, records) self.sets = (self.sets or 0) + 1; self.records = records end }
    local host = new_host({ _xpointer_overlay = overlay })
    host._annotation_context = new_context(store, { chapters = {} })
    overlay._annotation_window = "1:1:0"
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 1 and #overlay.records == 0 and overlay._annotation_window == nil,
        "a context without mapped chapters did not clear the overlay")

    overlay.enabled = false
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 1, "a disabled overlay was refreshed")
    overlay.enabled = nil

    -- Automatic (non-clean) books stay blank until every mapped chapter is
    -- matched, and the decision is cached per generation.
    local context = new_context(store, { binding = { book_id = "b1", automatic = true }, generation = 4 })
    context.statuses["doc:1"] = { stats = { total = 1, located = 1 } }
    store:put("b1", "projection", "doc:1", { records = { { pos0 = "a" } } })
    host._annotation_context = context
    host._unified_annotations_active = false
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 2 and #overlay.records == 0 and context._overlay_blocked_generation == 4,
        "a partially matched automatic book exposed underlines")
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 2, "a blocked generation re-evaluated the overlay on every page turn")
    context.generation = 5
    context.statuses["doc:2"] = { stats = { total = 0, located = 0 } }
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 3 and #overlay.records == 1,
        "a fully matched automatic book did not show its underlines")
end

-- Overlay window: the visible page range picks the chapters to load (plus one
-- neighbour on each side), an unchanged window is not reloaded, a failed
-- projection read keeps the current underlines, and legacy projections turn
-- off the ordered index.
do
    local store = new_store()
    local overlay = { setRecords = function(self, records, ordered)
        self.sets = (self.sets or 0) + 1
        self.records, self.ordered = records, ordered
    end }
    local host = new_host({ _xpointer_overlay = overlay })
    -- Chapter N starts at xpointer N*10; page 3 has no anchor.
    local page_anchor = { [1] = "25", [2] = "35", [4] = "55", [5] = "65" }
    local document = {
        current_page = 1, page_count = 9,
        getXPointer = function(self) return page_anchor[self.current_page] end,
        getCurrentPage = function(self) return self.current_page end,
        getPageCount = function(self) return self.page_count end,
        getPageXPointer = function(_self, page) return page_anchor[page] end,
        compareXPointers = function(_self, a, b)
            a, b = tonumber(a), tonumber(b)
            return a < b and 1 or (a == b and 0 or -1)
        end,
    }
    host.ui.document = document
    local chapters, ranges = {}, {}
    for index = 1, 6 do
        chapters[index] = { chapterUid = tostring(index) }
        ranges[tostring(index)] = { start_xpointer = tostring(index * 10) }
        store:put("b1", "projection", "doc:" .. index, { records = { { chapter = index } } })
    end
    local context = new_context(store, { chapters = chapters, ranges = ranges, generation = 1 })
    host._annotation_context = context
    local function loaded()
        local ids = {}
        for _i, record in ipairs(overlay.records) do ids[#ids + 1] = record.chapter end
        return table.concat(ids, ",")
    end

    -- Page 1 is in chapter 2, the next page starts chapter 3.
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 1 and overlay._annotation_window == "2:3:1" and loaded() == "1,2,3,4",
        "the visible page window did not load its chapters and neighbours: " .. loaded())
    expect(overlay.ordered == true, "located projections were not marked ordered")
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 1, "an unchanged window reloaded the projections")

    -- A missing anchor for the next page keeps the window to one chapter
    -- instead of loading the rest of the book.
    document.current_page = 2
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 2 and overlay._annotation_window == "3:3:1" and loaded() == "2,3,4",
        "a missing page anchor widened the window: " .. loaded())

    -- On the last page the window runs to the last chapter.
    document.current_page, document.page_count = 4, 4
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 3 and overlay._annotation_window == "5:6:1" and loaded() == "4,5,6",
        "the last page did not extend the window to the last chapter")

    -- A busy database keeps the current underlines and logs once.
    document.current_page, document.page_count = 1, 9
    local real_get = store.get
    store.get = function() error("database is locked") end
    logs.warn = {}
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 3 and overlay._annotation_window == "5:6:1" and #logs.warn == 1
            and logs.warn[1]:find("database is locked", 1, true),
        "a failed projection read changed the overlay or was not logged")
    store.get = real_get

    -- Legacy projections have no ordering guarantee.
    store:put("b1", "projection", "doc:3", { legacy = true, records = { { chapter = 3 } } })
    host:_refreshAnnotationOverlay()
    expect(overlay.sets == 4 and overlay.ordered == false and loaded() == "1,2,3,4",
        "a legacy projection was handed to the ordered index")
end

-- Prefetch worker completion: auth write-back, failures and stale requests.
do
    local host = new_host()
    local request = { guard = {}, worker_handle = {}, auth_fingerprint = "fp-parent" }
    host._external_annotation_sync = request
    local queued = {}
    host._runAnnotationJob = function(_self, context, options) queued[#queued + 1] = { context, options } end
    host._annotation_pending_prefetch = { context = "next", options = { prefetch = true } }
    merge_result, merges, logs.info = false, {}, {}
    local released = guards.released
    host:_finishAnnotationPrefetchWorker(request, { ok = true, value = { auth = { cookies = "c" } } })
    expect(guards.released == released + 1 and request.guard == nil and request.worker_handle == nil,
        "the standby guard or worker handle leaked")
    expect(#merges == 1 and merges[1].fingerprint == "fp-parent" and #logs.info == 1,
        "a changed parent login was overwritten or the skip was not logged")
    expect(host._external_annotation_sync == nil and #queued == 1 and queued[1][1] == "next",
        "the pending prefetch did not run after completion")
    merge_result = true

    logs.warn = {}
    request = { worker_handle = {} }
    host._external_annotation_sync = request
    host:_finishAnnotationPrefetchWorker(request, { ok = false, error = "HTTP 500" })
    expect(#logs.warn == 1 and logs.warn[1]:find("HTTP 500", 1, true) and host._external_annotation_sync == nil,
        "a worker failure was not logged")
    request = {}
    host._external_annotation_sync = request
    host:_finishAnnotationPrefetchWorker(request, nil)
    expect(#logs.warn == 2 and logs.warn[2]:find("no result", 1, true), "a missing result was not logged")
    request = { cancelled = true }
    host._external_annotation_sync = request
    host:_finishAnnotationPrefetchWorker(request, { ok = false, cancelled = true })
    expect(#logs.warn == 2, "a user cancellation was logged as a failure")

    -- A late completion for a replaced request leaves the new one alone.
    local current = {}
    host._external_annotation_sync = current
    host._annotation_pending_prefetch = { context = "kept", options = {} }
    host:_finishAnnotationPrefetchWorker({ guard = {} }, { ok = true, value = {} })
    expect(host._external_annotation_sync == current and host._annotation_pending_prefetch.context == "kept",
        "a stale worker completion cleared the current request")
end

-- Missing worker support reports a failure without touching the network.
do
    package.loaded["ffi/util"], package.loaded["ui/trapper"] = nil, nil
    local host = new_host()
    local ran = false
    host:_runAnnotationRequest("busy", "Load", function() ran = true end, function() ran = true end)
    expect(not ran and host.notices[1]:find("Network subprocess is unavailable", 1, true),
        "unavailable subprocess executed a network task inline or hid the failure")
end

-- Request runner with a subprocess: dismissal, garbage and worker errors.
do
    package.loaded["ffi/util"] = { runInSubProcess = function() end }
    local reply
    package.loaded["ui/trapper"] = {
        wrap = function(_self, callback) callback() end,
        dismissableRunInSubprocess = function(_self, task)
            if reply then return reply() end
            return true, task()
        end,
    }
    local host = new_host()
    local delivered = {}
    local function run(task)
        host:_runAnnotationRequest("busy", "Catalog", task or function() return "ok" end,
            function(value) delivered[#delivered + 1] = value end)
    end
    merges = {}
    run()
    expect(delivered[1] == "ok" and #merges == 1 and merges[1].auth.cookies == "child",
        "a subprocess result was not delivered with its auth write-back")
    run(function() error("HTTP 401", 0) end)
    expect(#delivered == 1 and host.notices[1]:find("HTTP 401", 1, true),
        "a subprocess error was not reported")
    reply = function() return false, nil end
    run()
    expect(#delivered == 1 and #host.notices == 1, "a user dismissal reported an error")
    reply = function() return false, "fork failed" end
    run()
    expect(host.notices[2]:find("fork failed", 1, true), "a failed fork was not reported")
    reply = function() return true, "garbage" end
    run()
    expect(#delivered == 1 and host.notices[3]:find("no result from the request subprocess", 1, true),
        "a malformed subprocess reply was not reported")
    reply = nil

    -- Catalog fetch runs in the subprocess; a stale reader session drops it.
    network = {}
    local prepared_with, callbacks = {}, 0
    host._prepareAnnotationContext = function(_self, _online, _refresh, options)
        prepared_with[#prepared_with + 1] = options
        if options and options.defer_network then return nil, { book_id = "b1" } end
        return { catalog = options and options.catalog }
    end
    host:_withAnnotationContext("Load", true, false, function(context)
        callbacks = callbacks + 1
        expect(context.catalog[1].chapterUid == "1", "the fetched catalog was not passed on")
    end)
    expect(callbacks == 1 and network[1] == "state:b1" and network[2] == "catalog:b1"
            and prepared_with[1].defer_network and prepared_with[2].catalog,
        "the catalog was not fetched via the deferred request")
    package.loaded["ui/trapper"].dismissableRunInSubprocess = function(_self, task)
        local result = task()
        host._reader_session_gen = host._reader_session_gen + 1
        return true, result
    end
    host:_withAnnotationContext("Load", true, false, function() callbacks = callbacks + 1 end)
    expect(callbacks == 1, "a catalog for a closed reader session was applied")
    package.loaded["ffi/util"], package.loaded["ui/trapper"] = nil, nil
end

-- Menu actions and their guard rails.
do
    local host = new_host({ _annotationBinding = function() return nil end })
    host:startUnifiedAnnotationSync({ offline = true })
    expect(host.calls.bind == 1, "syncing an unbound book did not start binding")
    host:chooseAnnotationChapters()
    expect(host.calls.bind == 2, "choosing chapters of an unbound book did not start binding")
    expect(host:ensureAnnotationDisplay() == true and #shown == 1 and shown[1].ok_callback,
        "an unbound book did not ask to bind")
    shown[1].ok_callback()
    expect(host.calls.bind == 3, "confirming the bind prompt did not bind")

    host = new_host({ _xpointerOverlayPrototypeAvailable = function() return false end })
    host:startUnifiedAnnotationSync({})
    expect(host:ensureAnnotationDisplay() == true and #host.notices == 2
            and host.notices[1]:find("reflowable", 1, true) and host.notices[2]:find("reflowable", 1, true),
        "a fixed-layout document was not refused")

    -- No mapped chapters: explain instead of starting a job.
    local store = new_store()
    host = new_host({ _prepareAnnotationContext = function() return new_context(store, { chapters = {} }) end,
        _runAnnotationJob = function() error("job started without chapters") end })
    host:startUnifiedAnnotationSync({ offline = true })
    expect(host.notices[1]:find("No matching chapters", 1, true), "an empty mapping did not explain itself")

    -- Online sync requires login first.
    host.requireLogin = function() return false end
    host:startUnifiedAnnotationSync({})
    expect(#host.notices == 1 and not host.calls.online, "sync without login reached the network")

    -- Chapter picker: empty catalog, and login gate when no catalog is cached.
    host = new_host({ _prepareAnnotationContext = function() return new_context(store, { catalog = {} }) end })
    host.requireLogin = function() return false end
    host:chooseAnnotationChapters()
    expect(not host.calls.online and #host.notices == 0, "the picker reached the network without login")
    host.requireLogin = function() return true end
    host:chooseAnnotationChapters()
    expect(host.calls.online == 1 and host.notices[1] == "No chapter catalog available.",
        "an empty catalog was not reported after loading")

    -- A failing chapter-match save is reported and keeps the menu open.
    package.loaded["weread.ui.annotation_chapter_picker"] = {
        show = function(options) return { options = options } end,
    }
    host = new_host({ _saveAnnotationChapterMatch = function() error("chapter already linked") end })
    local saved = 0
    local menu = host:_chooseAnnotationChapterMatch(new_context(store),
        { xpointer = "10", title = "Local" }, function() saved = saved + 1 end)
    closed = {}
    menu.options.choices[1].callback()
    expect(saved == 0 and #closed == 0 and host.notices[1]:find("chapter already linked", 1, true),
        "a failed chapter match was not reported")
    expect(menu.options.on_remove == nil, "an unlinked local chapter offered a remove action")
    package.loaded["weread.ui.annotation_chapter_picker"] = nil

    -- Menu items route to the actions and summarize progress.
    host = new_host()
    local routed = {}
    for _, name in ipairs({ "startUnifiedAnnotationSync", "chooseAnnotationChapters",
        "clearUnifiedAnnotationProjections", "bindExternalAnnotationsBook" }) do
        host[name] = function(_self, options) routed[#routed + 1] = { name = name, options = options } end
    end
    host.isNetworkConnected = function() return false end
    local items = host:getUnifiedAnnotationMenuItems()
    expect(items[1].text:find("Fixture", 1, true), "the linked book title was not shown")
    expect(items[2].text_func() == "Continue matching", "a missing context changed the label")
    local context = new_context(store)
    context.statuses["doc:1"] = { stats = { total = 5, located = 3 } }
    host._annotation_context = context
    expect(items[2].text_func():find("1/2 chapters, 3 underlines", 1, true),
        "the continue label did not summarize matched chapters")
    for index = 1, 4 do items[index].callback() end
    expect(routed[1].name == "bindExternalAnnotationsBook" and routed[2].name == "startUnifiedAnnotationSync"
            and routed[2].options.offline == true and routed[3].name == "chooseAnnotationChapters"
            and routed[4].name == "clearUnifiedAnnotationProjections",
        "menu items did not route to their actions")
    host._annotationBinding = function() return nil end
    expect(host:getUnifiedAnnotationMenuItems()[1].text == "Match with WeRead book",
        "an unbound book did not offer binding")
end

-- Opening an automatic single-chapter book prefetches its source in the
-- background worker only, never by matching positions on the UI thread.
do
    local store = new_store()
    local context = new_context(store, { binding = { book_id = "b1", automatic = true },
        chapters = { { chapterUid = "solo" } } })
    store:put("b1", "meta", "enabled", true)
    local jobs = {}
    local host = new_host({ _refreshAnnotationOverlay = function() end,
        _usesUnifiedAnnotations = function() return false end,
        _runAnnotationJob = function(_self, ctx, options) jobs[#jobs + 1] = { ctx, options } end })
    host.cache.auto_prefetch_next_chapter, host.cache.prefetch_annotations = true, true
    host:_activateAnnotationContext(context, 0)
    expect(#jobs == 1 and jobs[1][2].prefetch and jobs[1][2].background and jobs[1][2].chapters[1].chapterUid == "solo",
        "an untouched automatic chapter was not prefetched in the background")
    store:put("b1", "source_status", "solo", { revision = "1" })
    host:_activateAnnotationContext(context, 0)
    expect(#jobs == 1, "an already downloaded chapter was prefetched again on open")
end

-- Clearing reports database failures and leaves state untouched.
do
    local store = new_store()
    store.fail_clear = true
    local context = new_context(store)
    local overlay = { setRecords = function(self) self.sets = (self.sets or 0) + 1 end }
    local host = new_host({ _prepareAnnotationContext = function() return context end,
        _xpointer_overlay = overlay })
    logs.warn = {}
    expect(host:clearUnifiedAnnotationProjections() == false, "a failed clear reported success")
    expect(host.notices[1]:find("Failed to clear", 1, true) and host.notices[1]:find("database is locked", 1, true)
            and #logs.warn == 1,
        "a failed clear was not reported")
    expect(overlay.sets == nil and not host.calls.apply and host._unified_annotations_active == nil,
        "a failed clear still reset the overlay or display state")

    host.external_annotations_db = {
        getDocument = function() return { binding = { book_id = "b1" } } end,
        clearDocument = function() return true end,
        saveDocument = function() return nil, "disk full" end,
    }
    store.fail_clear = false
    expect(host:clearUnifiedAnnotationProjections() == false and host.notices[2]:find("disk full", 1, true),
        "a failed binding restore was not reported")

    host.external_annotations_db.saveDocument = function() return true end
    expect(host:clearUnifiedAnnotationProjections() == true and overlay.sets == 1 and host.calls.apply == 1
            and store:get("b1", "manual_only", "doc") == true and context.generation == 1,
        "a successful clear did not reset the overlay and mark the document manual-only")

    host._prepareAnnotationContext = function() return nil end
    expect(host:clearUnifiedAnnotationProjections() == nil, "clearing without a context did something")
end

print(("annotation_sync_controller_paths_spec: %d checks"):format(checks))

restore_subprocess()
