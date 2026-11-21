-- Modules/UI/PathBar.lua
-- The path bar of the LazyProf window: the whole journey as one strip, drawn
-- from Views.PathBar (Modules/Guide/Views.lua). One coloured segment per
-- stage (hover shows it, a click opens it), a tick at each rank still to
-- train, a marker at the real skill and the end skills underneath.
--
-- Plain textures on plain frames, so it is the same on every client. The fill
-- is the stock status-bar texture (Interface\TargetingFrame\UI-StatusBar,
-- used by Blizzard's own bars on every supported client), tinted per segment.
--
--   local bar = LazyProf.PathBar.Create(parent)
--   bar.frame                      anchor this; BAR_HEIGHT + label row tall
--   bar:Render(model, width, onOpenStage)
local ADDON_NAME, LazyProf = ...

local PathBar = {}
PathBar.__index = PathBar
LazyProf.PathBar = PathBar

local FILL = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local BAR_HEIGHT = 12
local LABEL_HEIGHT = 12
PathBar.HEIGHT = BAR_HEIGHT + LABEL_HEIGHT + 2

function PathBar.Create(parent)
    local RowPool = LazyProf.Widgets.RowPool
    local bar = setmetatable({}, PathBar)
    local frame = CreateFrame("Frame", nil, parent)
    bar.frame = frame
    frame:SetHeight(PathBar.HEIGHT)

    bar.track = frame:CreateTexture(nil, "BACKGROUND")
    bar.track:SetTexture(WHITE)
    bar.track:SetVertexColor(0, 0, 0, 0.6)
    bar.track:SetPoint("TOPLEFT", 0, 0)
    bar.track:SetPoint("TOPRIGHT", 0, 0)
    bar.track:SetHeight(BAR_HEIGHT)

    bar.segments = RowPool.New(function()
        local seg = CreateFrame("Button", nil, frame)
        seg.fill = seg:CreateTexture(nil, "ARTWORK")
        seg.fill:SetTexture(FILL)
        seg.fill:SetAllPoints()
        -- A light line under the selected stage's segment
        seg.mark = seg:CreateTexture(nil, "OVERLAY")
        seg.mark:SetTexture(WHITE)
        seg.mark:SetVertexColor(1, 1, 1, 0.9)
        seg.mark:SetHeight(2)
        seg.mark:SetPoint("BOTTOMLEFT", 0, 0)
        seg.mark:SetPoint("BOTTOMRIGHT", 0, 0)
        seg:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return seg
    end, function(seg)
        seg:SetScript("OnClick", nil)
        seg:SetScript("OnEnter", nil)
        seg.segment = nil
    end)

    -- Rank ticks and the skill marker draw above the segments.
    local overlay = CreateFrame("Frame", nil, frame)
    bar.overlay = overlay
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame:GetFrameLevel() + 3)

    bar.ticks = RowPool.New(function()
        local tick = overlay:CreateTexture(nil, "OVERLAY")
        tick:SetTexture(WHITE)
        tick:SetVertexColor(1, 0.82, 0, 1)
        tick:SetSize(2, BAR_HEIGHT + 4)
        return tick
    end)

    bar.marker = overlay:CreateTexture(nil, "OVERLAY")
    bar.marker:SetTexture(WHITE)
    bar.marker:SetVertexColor(1, 1, 1, 1)
    bar.marker:SetSize(2, BAR_HEIGHT + 6)

    bar.markerLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.startLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    bar.startLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -BAR_HEIGHT - 2)
    bar.endLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    bar.endLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -BAR_HEIGHT - 2)
    return bar
end

-- model: Views.PathBar(view); width: the bar's width in pixels;
-- onOpenStage(stage): a segment was clicked.
function PathBar:Render(model, width, onOpenStage)
    local frame = self.frame
    self.segments:ReleaseAll()
    self.ticks:ReleaseAll()
    self.shown = {}
    self.model = model

    for _, segment in ipairs(model.segments or {}) do
        local seg = self.segments:Acquire()
        seg.segment = segment
        seg:SetSize(math.max(1, segment.width * width), BAR_HEIGHT)
        seg:SetPoint("TOPLEFT", frame, "TOPLEFT", segment.left * width, 0)
        local c = segment.color
        seg.fill:SetVertexColor(c[1], c[2], c[3], segment.alpha or 1)
        seg.mark:SetShown(segment.selected and true or false)
        seg:SetScript("OnEnter", function(self)
            if not segment.tooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            for _, line in ipairs(segment.tooltip) do
                GameTooltip:AddLine(line.text, line.r or 1, line.g or 1, line.b or 1, true)
            end
            if segment.stage then
                GameTooltip:AddLine("Click to open this step", 0.5, 0.5, 0.5)
            end
            GameTooltip:Show()
        end)
        seg:SetScript("OnClick", function()
            if segment.stage and onOpenStage then onOpenStage(segment.stage) end
        end)
        seg:Show()
        self.shown[#self.shown + 1] = seg
    end

    for _, tick in ipairs(model.ticks or {}) do
        local texture = self.ticks:Acquire()
        texture:SetPoint("TOP", frame, "TOPLEFT", tick.pos * width, 2)
        texture:Show()
    end

    if model.marker then
        self.marker:ClearAllPoints()
        self.marker:SetPoint("TOP", frame, "TOPLEFT", model.marker * width, 3)
        self.marker:Show()
        self.markerLabel:ClearAllPoints()
        self.markerLabel:SetPoint("TOP", frame, "TOPLEFT", model.marker * width, -BAR_HEIGHT - 2)
        self.markerLabel:SetText(tostring(model.markerSkill))
        -- Next to an end of the bar the marker's number would sit on the end label.
        self.markerLabel:SetShown(model.marker > 0.08 and model.marker < 0.92)
    else
        self.marker:Hide()
        self.markerLabel:Hide()
    end
    self.startLabel:SetText(model.from and tostring(model.from) or "")
    self.endLabel:SetText(model.to and tostring(model.to) or "")
end
