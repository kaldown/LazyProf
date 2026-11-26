-- Modules/UI/Widgets/RowList.lua
-- A scrolling list drawn from row descriptors. The tabs of the LazyProf
-- window describe what they show as plain tables (built by pure code, so it
-- can be tested without frames); this widget turns them into pooled rows.
--
--   local list = LazyProf.Widgets.CreateRowList(parent, name)
--   list.frame                  the scroll frame to anchor (UIPanelScrollFrameTemplate)
--   list:Render(descriptors)    draw; rows are reused between renders
--   list:Render(descriptors, true)   same, back at the top
--   list.rows                   the rows of the last render, in order (row.desc is its descriptor)
--
-- Descriptor fields shared by the row kinds:
--   kind      "line" | "cols" | "sep"
--   height    row height (default per kind)
--   indent    pixels from the left
--   bg        { r, g, b, a } background; hoverBg while the mouse is over it
--   alpha     row alpha (dimmed rows)
--   icon      texture path
--   onClick   function(mouseButton)
--   itemId    item tooltip on hover; link: shift-click links it
--   tooltip   { { text, r, g, b }, ... } lines (added under the item when both)
--   button    { text, width, onClick, tooltip = lines, enabled, rightClick }
--             (onClick gets the mouse button; right-clicks reach it only with
--             rightClick = true)
--
-- "line": lead (text in a fixed column of leadWidth, default 62), text, color
--   { r, g, b }, font (font object name), right (right-aligned text),
--   rightColor, wrap (true: the text wraps and the row grows with it),
--   button2 (a second button, left of the first). sub = true makes it a
--   sub-line of the row above: lower (16), indented (18) and grey, each
--   unless the descriptor says otherwise.
-- "cols": text, color, cols = { ... } strings for the right-aligned columns,
--   colColors = { [i] = { r, g, b } }, header = true for the column titles.
--   lead (a short text, e.g. a number) in a column of leadWidth (default 18)
--   at the left, leadColor (default gold); the icon comes after it, and the
--   text starts at the same place with or without an icon, so rows with a
--   lead line up.
--   layout picks the columns:
--     nil        need / have / buy / cost, then a mark column: mark (short
--                text, e.g. "vendor") or a button in its place
--     "nomark"   need / have / buy / cost up to the right edge
--     "crafts"   skill range / cost up to the right edge
--   (the last two have neither mark nor button).
--   The text ends where the first column that has something in it begins, so
--   a row that only fills its last column has the room of the empty ones.
-- "sep": a thin line.
--
-- The scroll bar is only there while something scrolls: the stock scroll
-- frame hides and shows it by itself once the frame carries
-- scrollBarHideable (WoW Forever: Blizzard UI source 1.60.1,
-- Interface/AddOns/Blizzard_SharedXML/SecureScrollTemplates.xml:44-53 - the
-- bar is frame.ScrollBar - and SecureScrollTemplates.lua:64-103, where
-- ScrollFrame_OnScrollRangeChanged, called without a range, reads the
-- frame's own (:67-69); set after load as :254-255 does). The room the bar
-- takes is the caller's to leave free, so rows keep their width when it
-- comes and goes.
local ADDON_NAME, LazyProf = ...

LazyProf.Widgets = LazyProf.Widgets or {}
local Widgets = LazyProf.Widgets

local WHITE = "Interface\\Buttons\\WHITE8x8"
local DEFAULT_HEIGHT = { line = 20, cols = 18, sep = 8 }
local SUB_HEIGHT = 16
local SUB_INDENT = 18
local SUB_COLOR = { 0.7, 0.7, 0.7 }

-- Column geometry of a "cols" row: the widths of its right-aligned columns,
-- left to right, and what is kept free right of the last one (the mark
-- column, or a little air before the row's edge). The cost column is as
-- wide as an amount written to the copper ("888g 88s 88c") in the small
-- font; a number column holds four digits and the titles "Need" and "Have";
-- the mark column holds "vendor", "in list" and the craft / buy button.
-- What they leave is the name's, so they are no wider than that needs.
local COL_MARK_WIDTH = 56
local COL_COST_WIDTH = 84
local COL_NUMBER_WIDTH = 30
local COL_EDGE = 4
local MAX_COLUMNS = 4
local REAGENT_WIDTHS = { COL_NUMBER_WIDTH, COL_NUMBER_WIDTH, COL_NUMBER_WIDTH, COL_COST_WIDTH }
local DEFAULT_LAYOUT = { widths = REAGENT_WIDTHS, trailing = COL_MARK_WIDTH, mark = true }
local LAYOUTS = {
    nomark = { widths = REAGENT_WIDTHS, trailing = COL_EDGE },
    crafts = { widths = { 62, COL_COST_WIDTH }, trailing = COL_EDGE },   -- skill range, cost
}

local function Font(name)
    return _G[name] or name
end

local function SetColor(fontString, color, default)
    color = color or default
    fontString:SetTextColor(color[1] or color.r, color[2] or color.g, color[3] or color.b)
end

local function SetBackground(row, color)
    if color then
        row.bg:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
        row.bg:Show()
    else
        row.bg:Hide()
    end
end

local function ShowTooltip(owner, desc)
    if not (desc.itemId or desc.tooltip) then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if desc.itemId then
        GameTooltip:SetItemByID(desc.itemId)
        if desc.tooltip and #desc.tooltip > 0 then
            GameTooltip:AddLine(" ")
        end
    end
    for _, line in ipairs(desc.tooltip or {}) do
        GameTooltip:AddLine(line.text or line[1], line.r or line[2] or 1, line.g or line[3] or 1,
            line.b or line[4] or 1, true)
    end
    GameTooltip:Show()
end

-- Hover, click and tooltip of a row (every interactive kind).
local function SetRowScripts(row, desc)
    row:SetScript("OnClick", function(_, mouseButton)
        if desc.link and IsShiftKeyDown() then
            HandleModifiedItemClick(desc.link)
            return
        end
        if desc.onClick then desc.onClick(mouseButton) end
    end)
    row:SetScript("OnEnter", function(self)
        if desc.hoverBg then SetBackground(self, desc.hoverBg) end
        ShowTooltip(self, desc)
    end)
    row:SetScript("OnLeave", function(self)
        SetBackground(self, desc.bg)
        GameTooltip:Hide()
    end)
end

local function ClearRowScripts(row)
    row:SetScript("OnClick", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)
    for _, key in ipairs({ "button", "button2" }) do
        local button = row[key]
        if button then
            button:SetScript("OnClick", nil)
            button:SetScript("OnEnter", nil)
            button:Hide()
        end
    end
    row.desc = nil
end

-- A small stock button on a row, made the first time a row needs one.
local function RowButton(row, key)
    local button = row[key]
    if not button then
        button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        button:SetNormalFontObject(Font("GameFontNormalSmall"))
        button:SetHighlightFontObject(Font("GameFontHighlightSmall"))
        button:SetDisabledFontObject(Font("GameFontDisableSmall"))
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row[key] = button
    end
    return button
end

-- Show a descriptor's button on a row, right-aligned at `rightOffset` from the
-- row's right edge. Returns the width it takes (0 when there is none).
local function ApplyButton(row, key, spec, rightOffset, height)
    if not spec then
        if row[key] then row[key]:Hide() end
        return 0
    end
    local button = RowButton(row, key)
    local width = spec.width or 60
    button:SetSize(width, math.min(20, height))
    button:ClearAllPoints()
    button:SetPoint("RIGHT", row, "RIGHT", -rightOffset, 0)
    button:SetText(spec.text)
    button:SetEnabled(spec.enabled ~= false)
    -- The stock template takes left clicks only.
    if spec.rightClick then
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    else
        button:RegisterForClicks("LeftButtonUp")
    end
    button:SetScript("OnClick", function(_, mouseButton)
        if spec.onClick then spec.onClick(mouseButton) end
    end)
    button:SetScript("OnEnter", function(self)
        if spec.tooltip then ShowTooltip(self, { tooltip = spec.tooltip }) end
    end)
    button:Show()
    return width + 4
end

-- Row kinds: build once, apply per render ------------------------------------

local KINDS = {}

KINDS.line = {
    build = function(content)
        local row = CreateFrame("Button", nil, content)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 2, 0)
        row.lead = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.lead:SetJustifyH("LEFT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetJustifyH("LEFT")
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.right:SetJustifyH("RIGHT")
        return row
    end,
    apply = function(row, desc, width, height)
        local x = 4
        if desc.icon then
            row.icon:SetTexture(desc.icon)
            row.icon:Show()
            x = 22
        else
            row.icon:Hide()
        end
        if desc.lead then
            local leadWidth = desc.leadWidth or 62
            row.lead:ClearAllPoints()
            row.lead:SetPoint("LEFT", row, "LEFT", x, 0)
            row.lead:SetWidth(leadWidth)
            row.lead:SetText(desc.lead)
            SetColor(row.lead, desc.leadColor, { 1, 0.82, 0 })
            row.lead:Show()
            x = x + leadWidth
        else
            row.lead:Hide()
        end

        local rightOffset = 4
        rightOffset = rightOffset + ApplyButton(row, "button", desc.button, rightOffset, height)
        rightOffset = rightOffset + ApplyButton(row, "button2", desc.button2, rightOffset, height)

        row.right:ClearAllPoints()
        row.right:SetPoint("RIGHT", row, "RIGHT", -rightOffset, 0)
        row.right:SetText(desc.right or "")
        SetColor(row.right, desc.rightColor, { 1, 1, 1 })

        row.text:SetFontObject(Font(desc.font or "GameFontHighlightSmall"))
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", x, 0)
        if desc.right and desc.right ~= "" then
            row.text:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
        else
            row.text:SetPoint("RIGHT", row, "RIGHT", -rightOffset, 0)
        end
        row.text:SetWordWrap(desc.wrap and true or false)
        row.text:SetText(desc.text or "")
        SetColor(row.text, desc.color, desc.sub and SUB_COLOR or { 1, 1, 1 })

        -- A wrapped line is as tall as its text needs.
        if desc.wrap then
            row.text:SetWidth(math.max(40, width - x - rightOffset))
            local needed = (row.text:GetStringHeight() or 0) + 6
            if needed > height then height = needed end
        end
        return height
    end,
}

KINDS.cols = {
    build = function(content)
        local row = CreateFrame("Button", nil, content)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.lead = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.lead:SetJustifyH("LEFT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.mark = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.mark:SetJustifyH("LEFT")
        row.mark:SetPoint("LEFT", row, "RIGHT", -COL_MARK_WIDTH + 4, 0)
        -- Placed per render: a pooled row serves every layout.
        row.cols = {}
        for i = 1, MAX_COLUMNS do
            local col = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            col:SetJustifyH("RIGHT")
            row.cols[i] = col
        end
        return row
    end,
    apply = function(row, desc, width, height)
        -- Lead, icon and text, from the left. (Placed per render: a pooled
        -- row serves rows with and without a lead.)
        local x = 4
        if desc.lead then
            local leadWidth = desc.leadWidth or 18
            row.lead:ClearAllPoints()
            row.lead:SetPoint("LEFT", row, "LEFT", x, 0)
            row.lead:SetWidth(leadWidth)
            row.lead:SetText(desc.lead)
            SetColor(row.lead, desc.leadColor, { 1, 0.82, 0 })
            row.lead:Show()
            x = x + leadWidth
        else
            row.lead:SetText("")
            row.lead:Hide()
        end
        local iconAt = x - 2
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", iconAt, 0)
        if desc.icon then
            row.icon:SetTexture(desc.icon)
            row.icon:Show()
            x = iconAt + 18
        else
            row.icon:Hide()
            -- (A row with a lead keeps the icon's room: its name lines up
            -- with the names of the rows that have one.)
            if desc.lead then x = iconAt + 18 end
        end
        local header = desc.header
        local layout = LAYOUTS[desc.layout] or DEFAULT_LAYOUT
        local widths = layout.widths
        -- Columns from the right edge inwards. The text ends where the
        -- first column with something in it begins.
        local right = layout.trailing
        local textEnd = right
        for i = MAX_COLUMNS, 1, -1 do
            local col = row.cols[i]
            if widths[i] then
                local value = desc.cols and desc.cols[i] or ""
                col:SetFontObject(Font(header and "GameFontNormalSmall" or "GameFontHighlightSmall"))
                col:ClearAllPoints()
                col:SetWidth(widths[i])
                col:SetPoint("RIGHT", row, "RIGHT", -right, 0)
                col:SetText(value)
                SetColor(col, desc.colColors and desc.colColors[i], header and { 1, 0.82, 0 } or { 1, 1, 1 })
                col:Show()
                right = right + widths[i]
                if value ~= "" then textEnd = right end
            else
                col:SetText("")
                col:Hide()
            end
        end
        row.text:SetFontObject(Font(header and "GameFontNormalSmall" or "GameFontHighlightSmall"))
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", x, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -textEnd - 2, 0)
        row.text:SetText(desc.text or "")
        SetColor(row.text, desc.color, header and { 1, 0.82, 0 } or { 1, 1, 1 })
        if not layout.mark then
            ApplyButton(row, "button", nil, 0, height)
            row.mark:SetText("")
        elseif desc.button then
            row.mark:SetText("")
            local spec = desc.button
            if not spec.width then
                spec = setmetatable({ width = COL_MARK_WIDTH - 4 }, { __index = desc.button })
            end
            ApplyButton(row, "button", spec, 2, height)
        else
            ApplyButton(row, "button", nil, 0, height)
            row.mark:SetText(desc.mark or "")
        end
        return height
    end,
}

KINDS.sep = {
    build = function(content)
        local row = CreateFrame("Frame", nil, content)
        row.line = row:CreateTexture(nil, "ARTWORK")
        row.line:SetTexture(WHITE)
        row.line:SetVertexColor(0.4, 0.4, 0.4, 0.6)
        row.line:SetHeight(1)
        row.line:SetPoint("LEFT", 2, 0)
        row.line:SetPoint("RIGHT", -2, 0)
        return row
    end,
    apply = function(_, _, _, height)
        return height
    end,
    plain = true,   -- no scripts
}

-- The list -------------------------------------------------------------------

local RowList = {}
RowList.__index = RowList

function Widgets.CreateRowList(parent, name)
    local list = setmetatable({ rows = {}, pools = {} }, RowList)
    list.frame = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    list.content = CreateFrame("Frame", nil, list.frame)
    list.content:SetSize(100, 100)
    list.frame:SetScrollChild(list.content)
    -- The bar may hide while nothing scrolls (see the header). Both the bar
    -- and the stock handler are looked up first: without them the bar stays
    -- as the template made it.
    local bar = list.frame.ScrollBar
    if type(bar) == "table" and type(ScrollFrame_OnScrollRangeChanged) == "function" then
        list.frame.scrollBarHideable = 1
        bar:Hide()
        list.barHides = true
    end
    for kind, def in pairs(KINDS) do
        list.pools[kind] = Widgets.RowPool.New(function()
            return def.build(list.content)
        end, (not def.plain) and ClearRowScripts or nil)
    end
    return list
end

-- Width rows are laid out to. The scroll frame has no size before its first
-- layout; `fallback` (the window's inner width) is used then.
function RowList:SetWidth(width)
    self.width = width
    self.content:SetWidth(width)
end

function RowList:Render(descriptors, toTop)
    for _, pool in pairs(self.pools) do
        pool:ReleaseAll()
    end
    self.rows = {}
    local width = self.width or self.frame:GetWidth() or 0
    local y = 0
    for _, desc in ipairs(descriptors) do
        local def = KINDS[desc.kind] or KINDS.line
        local row = self.pools[KINDS[desc.kind] and desc.kind or "line"]:Acquire()
        local sub = desc.sub and def == KINDS.line
        local indent = desc.indent or (sub and SUB_INDENT or 0)
        local height = desc.height or (sub and SUB_HEIGHT) or DEFAULT_HEIGHT[desc.kind] or DEFAULT_HEIGHT.line
        row.desc = desc
        row:SetAlpha(desc.alpha or 1)
        if not def.plain then
            SetBackground(row, desc.bg)
            SetRowScripts(row, desc)
        end
        -- Placed and shown before it is filled, so wrapped text is measured
        -- on a row that has its place and width.
        row:SetWidth(math.max(1, width - indent))
        row:SetHeight(height)
        row:SetPoint("TOPLEFT", self.content, "TOPLEFT", indent, -y)
        row:Show()
        height = def.apply(row, desc, width - indent, height)
        row:SetHeight(height)
        self.rows[#self.rows + 1] = row
        y = y + height
    end
    self.content:SetHeight(math.max(y + 8, 1))
    if toTop then
        self.frame:SetVerticalScroll(0)
    end
    -- Have the stock handler read the new scroll range: it shows the bar
    -- when the rows no longer fit and hides it when they do.
    if self.barHides then
        ScrollFrame_OnScrollRangeChanged(self.frame)
    end
end
