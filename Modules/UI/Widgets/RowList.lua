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
--   button    { text, width, onClick, tooltip = lines, enabled }
--
-- "line": lead (text in a fixed column of leadWidth, default 62), text, color
--   { r, g, b }, font (font object name), right (right-aligned text),
--   rightColor, wrap (true: the text wraps and the row grows with it),
--   button2 (a second button, left of the first).
-- "cols": text, color, cols = { need, have, buy, cost } strings, colColors =
--   { [i] = { r, g, b } }, mark (short text in the last column, e.g. "vendor"),
--   header = true for the column titles. A button takes the mark's place.
-- "sep": a thin line.
local ADDON_NAME, LazyProf = ...

LazyProf.Widgets = LazyProf.Widgets or {}
local Widgets = LazyProf.Widgets

local WHITE = "Interface\\Buttons\\WHITE8x8"
local DEFAULT_HEIGHT = { line = 20, cols = 18, sep = 8 }

-- Column geometry of a "cols" row, from the right edge inwards.
local COL_MARK_WIDTH = 64
local COL_COST_WIDTH = 60
local COL_NUMBER_WIDTH = 34
local COLS = {
    { width = COL_NUMBER_WIDTH },   -- need
    { width = COL_NUMBER_WIDTH },   -- have
    { width = COL_NUMBER_WIDTH },   -- buy
    { width = COL_COST_WIDTH },     -- cost
}
Widgets.RowListColumnsWidth = COL_MARK_WIDTH + COL_COST_WIDTH + 3 * COL_NUMBER_WIDTH

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
        SetColor(row.text, desc.color, { 1, 1, 1 })

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
        row.icon:SetPoint("LEFT", 2, 0)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.mark = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.mark:SetJustifyH("LEFT")
        row.mark:SetPoint("LEFT", row, "RIGHT", -COL_MARK_WIDTH + 4, 0)
        row.cols = {}
        -- Right edges of the number columns, from the mark column leftwards.
        local right = COL_MARK_WIDTH
        for i = #COLS, 1, -1 do
            local col = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            col:SetJustifyH("RIGHT")
            col:SetWidth(COLS[i].width)
            col:SetPoint("RIGHT", row, "RIGHT", -right, 0)
            row.cols[i] = col
            right = right + COLS[i].width
        end
        row.numbersWidth = right
        return row
    end,
    apply = function(row, desc, width, height)
        local x = 4
        if desc.icon then
            row.icon:SetTexture(desc.icon)
            row.icon:Show()
            x = 20
        else
            row.icon:Hide()
        end
        local header = desc.header
        row.text:SetFontObject(Font(header and "GameFontNormalSmall" or "GameFontHighlightSmall"))
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", x, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -row.numbersWidth - 2, 0)
        row.text:SetText(desc.text or "")
        SetColor(row.text, desc.color, header and { 1, 0.82, 0 } or { 1, 1, 1 })
        for i, col in ipairs(row.cols) do
            col:SetFontObject(Font(header and "GameFontNormalSmall" or "GameFontHighlightSmall"))
            col:SetText(desc.cols and desc.cols[i] or "")
            SetColor(col, desc.colColors and desc.colColors[i], header and { 1, 0.82, 0 } or { 1, 1, 1 })
        end
        if desc.button then
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
        local indent = desc.indent or 0
        local height = desc.height or DEFAULT_HEIGHT[desc.kind] or DEFAULT_HEIGHT.line
        row.desc = desc
        row:SetAlpha(desc.alpha or 1)
        if not def.plain then
            SetBackground(row, desc.bg)
            SetRowScripts(row, desc)
        end
        row:SetWidth(math.max(1, width - indent))
        height = def.apply(row, desc, width - indent, height)
        row:SetHeight(height)
        row:SetPoint("TOPLEFT", self.content, "TOPLEFT", indent, -y)
        row:Show()
        self.rows[#self.rows + 1] = row
        y = y + height
    end
    self.content:SetHeight(math.max(y + 8, 1))
    if toTop then
        self.frame:SetVerticalScroll(0)
    end
end
