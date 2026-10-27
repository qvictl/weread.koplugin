-- Chapter catalog styled consistently with the book detail page.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local TapFeedback = require("weread.ui.tap_feedback")
local WindowRegistry = require("weread.ui.window_registry")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local T = require("ffi/util").template

local function _(text) return I18n.tr(text) end
local PAGE_BAR_HEIGHT = 54

local ChapterRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    callback = nil,
    show_parent = nil,
}

function ChapterRow:init()
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", 20)
    local right = TextWidget:new{ text = self.status, face = face }
    local right_width = right:getSize().w
    local gap = Size.padding.large
    local left = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - right_width - gap),
    }
    gap = math.max(gap, inner_width - left:getSize().w - right_width)
    self.frame = FrameContainer:new{
        bordersize = 0, radius = 0, margin = 0,
        padding_left = padding, padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            left,
            HorizontalSpan:new{ width = gap },
            right,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapChapterRow = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function ChapterRow:onTapChapterRow()
    if not self.callback then return true end
    return TapFeedback.run(self.frame, self.callback)
end

function ChapterRow:onFocus()
    self.frame.invert = true
    return true
end

function ChapterRow:onUnfocus()
    self.frame.invert = false
    return true
end

local ChapterListView = FocusManager:extend{
    title = nil,
    chapters = nil,
    page = nil,
    focus_index = nil,
    on_refresh = nil,
    on_select_download = nil,
    on_select = nil,
    on_close = nil,
}

function ChapterListView:toolbar()
    local half = math.floor(self.screen_w / 2)
    local refresh_button = Button:new{
        text = _("↻ Refresh chapter list"),
        width = half,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 19,
        text_font_bold = false,
        show_parent = self,
        callback = function() if self.on_refresh then self.on_refresh() end end,
    }
    local select_button = Button:new{
        text = _("✓ Select chapters to download"),
        width = self.screen_w - half,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 19,
        text_font_bold = false,
        show_parent = self,
        callback = function()
            if self.on_select_download then self.on_select_download() end
        end,
    }
    self._toolbar_buttons = { refresh_button, select_button }
    return HorizontalGroup:new{ refresh_button, select_button }
end

-- Rows per page from the measured height of one row plus its separator.
function ChapterListView:computePageSize(available_height, with_page_bar)
    local sample = ChapterRow:new{ text = "", status = "", width = self.list_width }
    local row_height = math.max(1, sample:getSize().h + 1)
    if sample.free then sample:free() end
    local height = available_height
        - (with_page_bar and Screen:scaleBySize(PAGE_BAR_HEIGHT) or 0)
    return math.max(1, math.floor(height / row_height))
end

-- Only the rows of the current page are built: an 811-chapter catalog used
-- to create 1622 text widgets up front and repaint all of them through a
-- full-screen scroll buffer.
function ChapterListView:content()
    local group = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.list_width },
    }
    self._chapter_rows = {}
    local chapters = self.chapters or {}
    local first = (self.page - 1) * self.page_size + 1
    local last = math.min(#chapters, first + self.page_size - 1)
    for index = first, last do
        local chapter = chapters[index]
        local row = ChapterRow:new{
            text = chapter.title,
            status = chapter.status,
            width = self.list_width,
            show_parent = self,
            callback = function() self:selectChapter(chapter.source) end,
        }
        self._chapter_rows[#self._chapter_rows + 1] = row
        table.insert(group, row)
        table.insert(group, HorizontalGroup:new{
            HorizontalSpan:new{ width = Size.padding.large },
            LineWidget:new{
                dimen = Geom:new{ w = self.list_width - 2 * Size.padding.large, h = 1 },
                background = Blitbuffer.COLOR_GRAY,
            },
        })
    end
    return group
end

-- Open a chapter after the row feedback painted, once per tap burst.
function ChapterListView:selectChapter(chapter)
    if self._select_pending or not self.on_select then return end
    self._select_pending = true
    UIManager:nextTick(function()
        self._select_pending = nil
        if UIManager:isWidgetShown(self) then self.on_select(chapter) end
    end)
end

function ChapterListView:pageBar()
    if self.page_count <= 1 then return nil end
    local cell_w = math.floor(self.screen_w / 3)
    local button_height = Screen:scaleBySize(PAGE_BAR_HEIGHT)
    local previous = Button:new{
        text = _("Previous"), width = cell_w, height = button_height,
        text_font_size = 22, text_font_bold = true, radius = 0, margin = 0, padding = 0,
        bordersize = 0, enabled = self.page > 1, show_parent = self,
        callback = function() self:goToPage(self.page - 1) end,
    }
    local page_text = Button:new{
        text = T(_("%1/%2 pages"), tostring(self.page), tostring(self.page_count)),
        width = cell_w, height = button_height, text_font_size = 18,
        radius = 0, margin = 0, bordersize = 0, padding = 0,
        enabled = false, show_parent = self,
    }
    local next_page = Button:new{
        text = _("Next"), width = self.screen_w - 2 * cell_w,
        height = button_height, text_font_size = 22, text_font_bold = true,
        radius = 0, margin = 0, bordersize = 0, padding = 0,
        enabled = self.page < self.page_count, show_parent = self,
        callback = function() self:goToPage(self.page + 1) end,
    }
    self._page_buttons = { previous, page_text, next_page }
    return HorizontalGroup:new{ previous, page_text, next_page }
end

-- Page changes come from taps, swipes and paging keys. Defer the rebuild
-- so the tap feedback paints first, and ignore further requests until it
-- ran: queued swipes must not each rebuild the page.
function ChapterListView:goToPage(page)
    page = math.floor(tonumber(page) or self.page)
    if page < 1 or page > self.page_count or page == self.page then return false end
    if self._page_change_pending then return true end
    self._page_change_pending = true
    UIManager:nextTick(function()
        self._page_change_pending = nil
        if not UIManager:isWidgetShown(self) then return end
        self.page = page
        self:buildPage()
        UIManager:setDirty(self, "ui")
    end)
    return true
end

function ChapterListView:buildPage()
    if self._page_widgets then
        for _i, widget in ipairs(self._page_widgets) do
            if widget.free then widget:free() end
        end
    end
    self._page_buttons = nil
    local page_bar = self:pageBar()
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.screen_w,
            h = math.max(1, self.list_height
                - (page_bar and page_bar:getSize().h or 0)),
        },
        show_parent = self,
        self:content(),
    }
    self.scroll = scroll
    self._page_widgets = { scroll, page_bar }
    local rows = { self._toolbar_buttons }
    for _i, chapter_row in ipairs(self._chapter_rows) do
        rows[#rows + 1] = { chapter_row }
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._toolbar_buttons) do outside_scroll[button] = true end
    if self._page_buttons then
        rows[#rows + 1] = self._page_buttons
        for _i, button in ipairs(self._page_buttons) do outside_scroll[button] = true end
    end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    self.ges_events.ChapterPageSwipe = nil
    if self.page_count > 1 then
        if Device:hasKeys() then
            -- Paging keys turn catalog pages, like the bookshelf.
            self.onNextPage = function(view) view:goToPage(view.page + 1) return true end
            self.onPrevPage = function(view) view:goToPage(view.page - 1) return true end
        end
        -- Let horizontal swipes reach the pager, not the inner scroller.
        scroll.onScrollableSwipe = function() return false end
        self.ges_events.ChapterPageSwipe = {
            GestureRange:new{ ges = "swipe", range = scroll.dimen },
        }
    end
    -- Chapters follow the toolbar row.
    FocusNav.initialFocus(self, 1, #rows > 1 and 2 or 1)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{
            align = "left", self.title_bar, self._toolbar, scroll,
            page_bar or VerticalSpan:new{ width = 0 },
        },
    }
end

function ChapterListView:onChapterPageSwipe(_arg, ges)
    local delta = ges and (ges.direction == "west" and 1 or ges.direction == "east" and -1)
    if not delta then return false end
    self:goToPage(self.page + delta)
    return true
end

function ChapterListView:init()
    self.ges_events = {}
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    self.covers_fullscreen = true
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or _("Chapter list"),
        title_face = Font:getFace("tfont", 28),
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self._toolbar = self:toolbar()
    self.list_height = math.max(1, self.screen_h - self.title_bar:getHeight()
        - self._toolbar:getSize().h)
    local page = tonumber(self.page)
    self:paginate()
    if not page and tonumber(self.focus_index) then
        page = math.floor((tonumber(self.focus_index) - 1) / self.page_size) + 1
    end
    self.page = math.max(1, math.min(math.floor(page or 1), self.page_count))
    self:buildPage()
end

function ChapterListView:paginate()
    local count = #(self.chapters or {})
    self.page_size = self:computePageSize(self.list_height, false)
    if count > self.page_size then
        self.page_size = self:computePageSize(self.list_height, true)
    end
    self.page_count = math.max(1, math.ceil(count / self.page_size))
    self.page = math.max(1, math.min(math.floor(tonumber(self.page) or 1), self.page_count))
end

-- Replace the catalog rows (after a download or refresh) in place, keeping
-- the current page. Showing a new list instead would cover the download
-- completion dialog or whatever else is on top.
function ChapterListView:setChapters(chapters)
    self.chapters = chapters
    self:paginate()
    self:buildPage()
    UIManager:setDirty(self, "ui")
end

function ChapterListView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function ChapterListView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function ChapterListView:onClose()
    UIManager:close(self)
    if self.on_close then
        UIManager:scheduleIn(0.1, self.on_close)
    end
    return true
end

local M = {}
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = ChapterListView:new{
        title = data.title,
        chapters = data.chapters,
        page = data.page,
        focus_index = data.focus_index,
        on_refresh = callbacks.on_refresh,
        on_select_download = callbacks.on_select_download,
        on_select = callbacks.on_select,
        on_close = callbacks.on_close,
    }
    UIManager:show(view)
    return WindowRegistry.track(view)
end

return M
