-- scripts/lib/fakeui.lua
--
-- A fake of the client's frame API, enough to build and drive the addon's
-- frames headlessly: frames and regions record what was set on them, scripts
-- can be fired by hand, and every frame made is counted by type and template.
--
--   local ui = require("scripts.lib.fakeui").install({ family = "forever" })
--   ui.frames            every frame made, in order
--   ui.named[name]       frames made with a global name
--   ui.count(pred)       how many frames match
--   ui.fire(frame, "OnClick", ...)   run a script as the client would
--   ui.slide(slider, value)          the player moves a slider's handle
--   ui.release(button)               a mouse button is let go with no frame hearing of it
--   ui.combat = true     what InCombatLockdown() reports
--   ui.event("PLAYER_REGEN_DISABLED")   deliver an event to registered frames
--
-- Unknown CamelCase methods are no-ops; unknown lowercase fields stay nil, so
-- `if frame.someChild then` behaves as in game.

local M = {}

local function noop() end

local function methodFallback(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end

function M.install(opts)
    opts = opts or {}
    local ui = { frames = {}, named = {}, combat = false, tooltip = nil, sounds = {}, timers = {} }

    local function newRegion(kind, parent)
        local r = setmetatable({ kind = kind, parent = parent, points = {}, alpha = 1, shown = true },
            { __index = methodFallback })
        function r:SetText(t) self.text = t end
        function r:GetText() return self.text end
        function r:SetTextColor(cr, cg, cb, ca) self.color = { cr, cg, cb, ca } end
        function r:SetTexture(t) self.texture = t end
        function r:GetTexture() return self.texture end
        function r:SetColorTexture(cr, cg, cb, ca) self.colorTexture = { cr, cg, cb, ca } end
        function r:SetVertexColor(cr, cg, cb, ca) self.vertexColor = { cr, cg, cb, ca } end
        function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function r:ClearAllPoints() self.points = {} end
        function r:SetAlpha(a) self.alpha = a end
        function r:GetAlpha() return self.alpha end
        function r:Show() self.shown = true end
        function r:Hide() self.shown = false end
        function r:SetShown(s) self.shown = s and true or false end
        function r:IsShown() return self.shown end
        function r:SetWidth(w) self.width = w end
        function r:SetHeight(h) self.height = h end
        function r:SetSize(w, h) self.width, self.height = w, h end
        function r:GetWidth() return self.width or 0 end
        function r:GetHeight() return self.height or 0 end
        function r:GetStringWidth() return self.text and #tostring(self.text) * 6 or 0 end
        function r:GetStringHeight() return self.stringHeight or 0 end
        function r:SetFontObject(f) self.font = f end
        function r:SetParent(p) self.parent = p end
        function r:GetParent() return self.parent end
        function r:SetJustifyH(j) self.justifyH = j end
        function r:SetWordWrap(w) self.wordWrap = w end
        return r
    end

    local function newFrame(ftype, name, parent, template)
        local f = setmetatable({
            ftype = ftype, name = name, parent = parent, template = template,
            shown = true, points = {}, scripts = {}, width = 0, height = 0,
            strata = "MEDIUM", level = 1, alpha = 1, events = {}, enabled = true, regions = {},
        }, { __index = methodFallback })
        function f:Show()
            local was = self.shown
            self.shown = true
            if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
        end
        function f:Hide()
            local was = self.shown
            self.shown = false
            if was and self.scripts.OnHide then self.scripts.OnHide(self) end
        end
        function f:SetShown(s) if s then self:Show() else self:Hide() end end
        function f:IsShown() return self.shown end
        -- Visible only when every ancestor is shown too.
        function f:IsVisible()
            local at = self
            while at do
                if at.shown == false then return false end
                at = at.parent
            end
            return true
        end
        function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function f:ClearAllPoints() self.points = {} end
        function f:GetNumPoints() return #self.points end
        function f:GetPoint(i) local p = self.points[i or 1]; if p then return unpack(p) end end
        function f:SetAllPoints(other) self.points = { { "ALL", other } } end
        function f:SetScript(n, fn) self.scripts[n] = fn end
        function f:GetScript(n) return self.scripts[n] end
        function f:HookScript(n, fn)
            local prev = self.scripts[n]
            self.scripts[n] = function(...)
                if prev then prev(...) end
                fn(...)
            end
        end
        function f:SetSize(w, h) self.width, self.height = w, h end
        function f:SetWidth(w) self.width = w end
        function f:SetHeight(h) self.height = h end
        function f:GetWidth() return self.width end
        function f:GetHeight() return self.height end
        function f:GetSize() return self.width, self.height end
        function f:GetLeft() return self.left end
        function f:GetTop() return self.top end
        function f:GetName() return self.name end
        function f:GetParent() return self.parent end
        function f:SetParent(p) self.parent = p end
        function f:SetID(id) self.id = id end
        function f:GetID() return self.id or 0 end
        function f:SetFrameStrata(s) self.strata = s end
        function f:GetFrameStrata() return self.strata end
        function f:SetFrameLevel(l) self.level = l end
        function f:GetFrameLevel() return self.level end
        function f:SetAlpha(a) self.alpha = a end
        function f:GetAlpha() return self.alpha end
        function f:SetMovable(m) self.movable = m end
        function f:IsMovable() return self.movable end
        function f:SetResizable(r) self.resizable = r end
        function f:SetResizeBounds(minW, minH, maxW, maxH) self.resizeBounds = { minW, minH, maxW, maxH } end
        function f:EnableMouse(m) self.mouse = m end
        function f:RegisterEvent(e) self.events[e] = true end
        function f:UnregisterEvent(e) self.events[e] = nil end
        function f:SetEnabled(e) self.enabled = e and true or false end
        function f:Enable() self.enabled = true end
        function f:Disable() self.enabled = false end
        function f:IsEnabled() return self.enabled end
        function f:SetBackdrop(b) self.backdrop = b end
        function f:SetBackdropColor(cr, cg, cb, ca) self.backdropColor = { cr, cg, cb, ca } end
        function f:SetBackdropBorderColor(cr, cg, cb, ca) self.backdropBorderColor = { cr, cg, cb, ca } end
        function f:CreateFontString(_, _, font)
            local r = newRegion("FontString", self)
            r.font = font
            self.regions[#self.regions + 1] = r
            return r
        end
        function f:CreateTexture(_, layer)
            local r = newRegion("Texture", self)
            r.layer = layer
            self.regions[#self.regions + 1] = r
            return r
        end
        function f:GetNormalTexture()
            self.normalTexture = self.normalTexture or newRegion("Texture", self)
            return self.normalTexture
        end
        function f:SetText(t)
            self.text = t
            if self.ftype == "EditBox" and self.scripts.OnTextChanged then
                self.scripts.OnTextChanged(self, false)
            end
        end
        function f:GetText() return self.text end
        function f:SetButtonState(state, locked) self.buttonState, self.buttonLocked = state, locked end
        function f:LockHighlight() self.highlightLocked = true end
        function f:UnlockHighlight() self.highlightLocked = false end
        function f:SetNormalFontObject(font) self.normalFont = font end

        if ftype == "DropdownButton" then
            function f:SetupMenu(generator) self.generator = generator; self.setupCalls = (self.setupCalls or 0) + 1 end
            function f:OverrideText(t) self.overrideText = t end
        elseif ftype == "EditBox" then
            f.text = ""
            function f:GetNumber() return tonumber(self.text) or 0 end
            function f:SetNumber(n) self:SetText(tostring(n)) end
            function f:SetNumeric(n) self.numeric = n end
            function f:SetMaxLetters(n) self.maxLetters = n end
            function f:SetAutoFocus(a) self.autoFocus = a end
            function f:SetFocus() self.focused = true end
            function f:ClearFocus()
                local was = self.focused
                self.focused = false
                if was and self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
            end
            function f:HasFocus() return self.focused or false end
            function f:SetCursorPosition(p) self.cursor = p end
        elseif ftype == "CheckButton" then
            function f:SetChecked(c) self.checked = c and true or false end
            function f:GetChecked() return self.checked or false end
        elseif ftype == "ScrollFrame" then
            f.scroll = 0
            function f:SetScrollChild(c) self.scrollChild = c end
            function f:SetVerticalScroll(v) self.scroll = v end
            function f:GetVerticalScroll() return self.scroll end
            -- How far the content scrolls: what of the scroll child does not
            -- fit in the frame (f.scrollRange overrides it).
            function f:GetVerticalScrollRange()
                if self.scrollRange then return self.scrollRange end
                local child = self.scrollChild
                return math.max(0, (child and child.height or 0) - (self.height or 0))
            end
        elseif ftype == "StatusBar" then
            function f:SetMinMaxValues(a, b) self.min, self.max = a, b end
            function f:SetValue(v) self.value = v end
            function f:SetStatusBarTexture(t) self.barTexture = t end
            function f:SetStatusBarColor(cr, cg, cb, ca) self.barColor = { cr, cg, cb, ca } end
        elseif ftype == "Slider" then
            -- A value set by code runs OnValueChanged like the client does,
            -- flagged as not coming from the player; ui.slide is the player.
            -- Every range given is kept in rangeCalls.
            f.min, f.max, f.value, f.step, f.rangeCalls = 0, 0, 0, 0, {}
            function f:SetMinMaxValues(a, b)
                self.min, self.max = a, b
                self.rangeCalls[#self.rangeCalls + 1] = { a, b }
                self:SetValue(self.value)
            end
            function f:GetMinMaxValues() return self.min, self.max end
            function f:SetValue(v)
                v = math.max(self.min, math.min(self.max, v))
                if v == self.value then return end
                self.value = v
                if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v, false) end
            end
            function f:GetValue() return self.value end
            function f:SetValueStep(s) self.step = s end
            function f:GetValueStep() return self.step end
            function f:SetObeyStepOnDrag(o) self.obeyStep = o end
            function f:SetOrientation(o) self.orientation = o end
            function f:SetThumbTexture(t)
                self.thumbTexture = self.thumbTexture or newRegion("Texture", self)
                self.thumbTexture.texture = t
            end
            function f:GetThumbTexture() return self.thumbTexture end
            function f:IsDraggingThumb() return self.draggingThumb or false end
        end

        -- A tab made from the Forever template joins its parent's Tabs array
        -- (parentArray="Tabs" in the template).
        if template == "PanelTabButtonTemplate" and parent then
            local tabs = rawget(parent, "Tabs") or {}
            rawset(parent, "Tabs", tabs)
            tabs[#tabs + 1] = f
        end
        if template == "UICheckButtonTemplate" then
            f.Text = newRegion("FontString", f)
        end
        -- The stock scroll frame carries its scroll bar under the key
        -- ScrollBar (ui.noScrollBar: a client whose template does not).
        if template == "UIPanelScrollFrameTemplate" and not ui.noScrollBar then
            f.ScrollBar = newFrame("Slider", name and (name .. "ScrollBar") or nil, f, "UIPanelScrollBarTemplate")
        end
        -- The stock plain slider: horizontal, 200 x 19, whole steps on a
        -- drag, its handle under the key Thumb.
        if template == "MinimalSliderTemplate" then
            f.width, f.height, f.orientation, f.obeyStep = 200, 19, "HORIZONTAL", true
            f.Thumb = newRegion("Texture", f)
        end
        return f
    end

    ui.newFrame = newFrame
    ui.newRegion = newRegion

    _G.UIParent = newFrame("Frame", "UIParent", nil, nil)
    _G.UIParent.width, _G.UIParent.height = 1920, 1080

    _G.CreateFrame = function(ftype, name, parent, template)
        local f = newFrame(ftype, name, parent, template)
        ui.frames[#ui.frames + 1] = f
        if name then
            ui.named[name] = f
            _G[name] = f
        end
        return f
    end

    function ui.count(pred)
        local n = 0
        for _, f in ipairs(ui.frames) do
            if pred(f) then n = n + 1 end
        end
        return n
    end

    function ui.find(pred)
        for _, f in ipairs(ui.frames) do
            if pred(f) then return f end
        end
    end

    -- Which mouse buttons are down, as IsMouseButtonDown reports it. Firing a
    -- frame's OnMouseDown / OnMouseUp presses and lets go of the button (the
    -- left one when none is named), as the click that runs them would.
    ui.buttons = {}
    function ui.fire(frame, script, ...)
        local fn = frame.scripts[script]
        assert(fn, "no script " .. script .. " on " .. tostring(frame.name or frame.ftype))
        if script == "OnMouseDown" then
            ui.buttons[(...) or "LeftButton"] = true
        elseif script == "OnMouseUp" then
            ui.buttons[(...) or "LeftButton"] = nil
        end
        return fn(frame, ...)
    end

    -- A mouse button is let go where no frame runs a script for it (every
    -- button when none is named).
    function ui.release(button)
        if button then
            ui.buttons[button] = nil
        else
            ui.buttons = {}
        end
    end
    _G.IsMouseButtonDown = function(button)
        if button then return ui.buttons[button] == true end
        return next(ui.buttons) ~= nil
    end

    -- The player moves a slider's handle to `value`: the frame reports it as
    -- the player's.
    function ui.slide(frame, value)
        frame.value = value
        if frame.scripts.OnValueChanged then frame.scripts.OnValueChanged(frame, value, true) end
    end

    -- Deliver an event to every frame registered for it.
    function ui.event(event, ...)
        for _, f in ipairs(ui.frames) do
            if f.events[event] and f.scripts.OnEvent then
                f.scripts.OnEvent(f, event, ...)
            end
        end
    end

    -- Tooltip: records what was put in it since the last SetOwner.
    local tooltip = setmetatable({ lines = {} }, { __index = methodFallback })
    function tooltip:SetOwner(owner, anchor) self.owner, self.anchor, self.lines, self.itemId = owner, anchor, {}, nil end
    function tooltip:AddLine(text, r, g, b, wrap) self.lines[#self.lines + 1] = { text = text, r = r, g = g, b = b, wrap = wrap } end
    function tooltip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = { text = left, right = right } end
    function tooltip:SetItemByID(id) self.itemId = id end
    function tooltip:SetText(text) self.lines = { { text = text } } end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown = false end
    function tooltip:Text()
        local out = {}
        for _, l in ipairs(self.lines) do out[#out + 1] = tostring(l.text) .. (l.right and (" | " .. tostring(l.right)) or "") end
        return table.concat(out, "\n")
    end
    _G.GameTooltip = tooltip
    ui.tooltip = tooltip

    _G.InCombatLockdown = function() return ui.combat end
    _G.UISpecialFrames = {}
    _G.tinsert = table.insert
    _G.tremove = table.remove
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.IsShiftKeyDown = function() return ui.shift or false end
    _G.HandleModifiedItemClick = function(link) ui.linked = link end
    _G.PlaySound = function(id) ui.sounds[#ui.sounds + 1] = id end
    _G.SOUNDKIT = { IG_CHARACTER_INFO_TAB = 841, IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_MAINMENU_OPTION_CHECKBOX_OFF = 857 }
    _G.GetTime = function() return ui.now or 0 end
    _G.C_Timer = { After = function(delay, fn) ui.timers[#ui.timers + 1] = { delay = delay, fn = fn } end }
    -- Run the timers queued so far (ones they queue run on the next call).
    function ui.runTimers()
        local due = ui.timers
        ui.timers = {}
        for _, t in ipairs(due) do t.fn() end
        return #due
    end

    -- Tab helpers of the shared panel templates.
    ui.tabCalls = { setNumTabs = 0, setTab = {}, resize = 0 }
    _G.PanelTemplates_SetNumTabs = function(frame, n)
        frame.numTabs = n
        ui.tabCalls.setNumTabs = ui.tabCalls.setNumTabs + 1
    end
    _G.PanelTemplates_SetTab = function(frame, id)
        frame.selectedTab = id
        ui.tabCalls.setTab[#ui.tabCalls.setTab + 1] = id
    end
    _G.PanelTemplates_TabResize = function() ui.tabCalls.resize = ui.tabCalls.resize + 1 end

    -- The stock scroll frame's handler for a changed scroll range: with
    -- scrollBarHideable on the frame, the bar is hidden while nothing
    -- scrolls and shown again when something does. Called without a range it
    -- reads the frame's own.
    ui.scrollRangeCalls = 0
    _G.ScrollFrame_OnScrollRangeChanged = function(frame, _, yrange)
        ui.scrollRangeCalls = ui.scrollRangeCalls + 1
        local bar = frame.ScrollBar
        yrange = math.floor(yrange or frame:GetVerticalScrollRange())
        bar:SetMinMaxValues(0, yrange)
        if yrange == 0 then
            if frame.scrollBarHideable then bar:Hide() end
        else
            bar:Show()
        end
    end

    if opts.family == "forever" then
        _G.NineSliceUtil = { ApplyLayoutByName = function(frame, layout) frame.layout = layout end }
    else
        _G.NineSliceUtil = nil
        -- Classic dropdown globals used by the dropdown widget.
        _G.UIDropDownMenu_SetWidth = function(frame, w) frame.ddWidth = w end
        _G.UIDropDownMenu_Initialize = function(frame, fn) frame.ddInit = fn end
        _G.UIDropDownMenu_CreateInfo = function() return {} end
        _G.UIDropDownMenu_AddButton = function(info) ui.ddButtons = ui.ddButtons or {}; ui.ddButtons[#ui.ddButtons + 1] = info end
        _G.UIDropDownMenu_SetText = function(frame, text) frame.ddText = text end
    end

    return ui
end

-- Menu root stub for a Forever dropdown generator: records radios and dividers.
function M.openMenu(button)
    local root = { radios = {}, items = {}, dividers = 0 }
    function root:CreateRadio(text, isSelected, setSelected, data)
        local r = { text = text, isSelected = isSelected, setSelected = setSelected, data = data }
        self.radios[#self.radios + 1] = r
        self.items[#self.items + 1] = r
        return r
    end
    function root:CreateDivider()
        self.dividers = self.dividers + 1
        self.items[#self.items + 1] = { divider = true }
    end
    assert(button and button.generator, "dropdown has no menu generator")
    button.generator(button, root)
    return root
end

return M
