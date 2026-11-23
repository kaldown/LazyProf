-- scripts/test_controls.lua
--
-- The window's widget layer: tabs (one template per client family), the
-- button group, numeric input, checkbox, search box, resize bounds and the
-- row list that draws the tabs' row descriptors with pooled rows.
--
-- Run from the addon root:  lua5.1 scripts/test_controls.lua

package.path = "./?.lua;" .. package.path
local fakeui = require("scripts.lib.fakeui")
local T = require("scripts.lib.check").new()

local function load(family)
    local ui = fakeui.install({ family = family })
    local addon = { ClientFamily = family, Widgets = {} }
    for _, path in ipairs({
        "Modules/UI/Widgets/RowPool.lua",
        "Modules/UI/Widgets/Controls.lua",
        "Modules/UI/Widgets/Slider.lua",
        "Modules/UI/Widgets/Tabs.lua",
        "Modules/UI/Widgets/RowList.lua",
    }) do
        assert(loadfile(path))("LazyProf", addon)
    end
    return ui, addon.Widgets
end

-- The slider: one implementation per client family, same behaviour. Moving
-- the handle only reports values; letting go commits once.
for _, family in ipairs({ "forever", "classic" }) do
    T.section(family .. " slider", function()
        local p = family .. " slider: "
        local ui, W = load(family)
        local parent = CreateFrame("Frame", nil, UIParent)
        local moving, released = {}, {}
        local slider = W.CreateSlider(parent, "TestSlider", {
            onChanging = function(v) moving[#moving + 1] = v end,
            onReleased = function(v) released[#released + 1] = v end,
        })
        local frame = slider.frame
        local function calls() return table.concat(moving, ",") .. " / " .. table.concat(released, ",") end
        local function reset() moving, released = {}, {} end
        -- No range ever reaches the frame empty or the wrong way round.
        local function rangesSound()
            for _, range in ipairs(frame.rangeCalls) do
                if not (range[1] < range[2]) then return false end
            end
            return #frame.rangeCalls > 0
        end

        T.eq(p .. "a slider frame", frame.ftype, "Slider")
        T.eq(p .. "with the given name", frame.name, "TestSlider")
        T.check(p .. "child of the given parent", frame.parent == parent)
        if family == "forever" then
            T.eq(p .. "the client's plain slider", frame.template, "MinimalSliderTemplate")
            T.check(p .. "no thumb of its own", frame.thumbTexture == nil)
        else
            T.check(p .. "no template", frame.template == nil)
            T.eq(p .. "horizontal", frame.orientation, "HORIZONTAL")
            T.eq(p .. "the stock thumb", frame.thumbTexture and frame.thumbTexture.texture,
                "Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
            T.check(p .. "a track of its own", slider.track ~= nil and slider.track.kind == "Texture")
            T.check(p .. "a size of its own", frame.height > 0)
            -- The track has to show on a dark window: a light grey, nearly
            -- opaque, with a thin darker edge drawn under it.
            local c, e = slider.track.vertexColor, slider.trackEdge and slider.trackEdge.vertexColor
            T.check(p .. "the track is a light grey", c[1] >= 0.3 and c[1] == c[2] and c[2] == c[3] and c[4] >= 0.85, table.concat(c, ","))
            T.check(p .. "with a darker edge", e ~= nil and e[1] < c[1] and e[4] >= 0.8)
            T.check(p .. "the edge is a little larger than the track", slider.trackEdge ~= nil
                and slider.trackEdge.height == slider.track.height + 2)
            T.check(p .. "and drawn under it", slider.trackEdge ~= nil and slider.trackEdge.layer == "BACKGROUND"
                and slider.track.layer == "BORDER")
        end
        T.eq(p .. "whole steps", frame.step, 1)
        T.check(p .. "steps obeyed while dragging", frame.obeyStep == true)
        slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -80)
        T.check(p .. "SetPoint places the frame", frame.points[1][1] == "TOPLEFT" and frame.points[1][4] == 14)

        -- Set from code: silent.
        slider:SetRange(117, 300, 225)
        T.eq(p .. "range on the frame", frame.min .. "-" .. frame.max, "117-300")
        T.eq(p .. "value on the frame", frame.value, 225)
        T.eq(p .. "GetValue", slider:GetValue(), 225)
        T.check(p .. "enabled when there is room", frame.enabled == true)
        slider:SetValue(200)
        T.eq(p .. "SetValue moves the handle", frame.value, 200)
        slider:SetValue(999)
        T.eq(p .. "a value above the range is held at its end", slider:GetValue(), 300)
        slider:SetValue(1)
        T.eq(p .. "a value below it at its start", slider:GetValue(), 117)
        slider:SetValue(224.6)
        T.eq(p .. "values are whole numbers", slider:GetValue(), 225)
        T.eq(p .. "values set from code call neither callback", calls(), " / ")
        T.check(p .. "not held", slider:IsHeld() == false)

        -- Dragging reports every new value and commits nothing.
        ui.fire(frame, "OnMouseDown", "LeftButton")
        T.check(p .. "held while the button is down", slider:IsHeld() == true)
        ui.slide(frame, 117)
        ui.slide(frame, 130)
        ui.slide(frame, 160)
        T.eq(p .. "dragging: a call per value, nothing released", calls(), "117,130,160 / ")
        ui.slide(frame, 160)
        ui.slide(frame, 160.3)
        T.eq(p .. "dragging: the same whole number is not reported twice", #moving, 3)
        T.eq(p .. "GetValue follows the drag", slider:GetValue(), 160)

        -- A redraw while the handle is held leaves it alone.
        slider:SetRange(120, 300, 300)
        T.eq(p .. "SetRange while held: range untouched", frame.min .. "-" .. frame.max, "117-300")
        T.eq(p .. "SetRange while held: value untouched", slider:GetValue(), 160)
        slider:SetValue(250)
        T.eq(p .. "SetValue while held: ignored too", slider:GetValue(), 160)

        -- Letting go commits once.
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "letting go releases once, with the value", calls(), "117,130,160 / 160")
        T.check(p .. "no longer held", slider:IsHeld() == false)
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "a second mouse-up releases nothing", #released, 1)

        -- Back where it was committed: nothing to commit.
        reset()
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.slide(frame, 200)
        ui.slide(frame, 160)
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "dragged away and back: moving reported, nothing released", calls(), "200,160 / ")

        -- A click that moves nothing.
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "a click that moves nothing calls nothing", calls(), "200,160 / ")

        -- Any mouse button holds the handle and lets it go.
        reset()
        ui.fire(frame, "OnMouseDown", "RightButton")
        T.check(p .. "another mouse button holds it too", slider:IsHeld() == true)
        ui.slide(frame, 150)
        ui.slide(frame, 140)
        T.eq(p .. "a drag with another button: values reported, nothing released", calls(), "150,140 / ")
        ui.fire(frame, "OnMouseUp", "RightButton")
        T.eq(p .. "and its release commits once", calls(), "150,140 / 140")
        T.check(p .. "after which it is not held", slider:IsHeld() == false)
        -- ...also while the client calls the handle dragged.
        reset()
        ui.fire(frame, "OnMouseDown", "MiddleButton")
        frame.draggingThumb = true
        ui.slide(frame, 160)
        frame.draggingThumb = false
        ui.fire(frame, "OnMouseUp", "MiddleButton")
        T.eq(p .. "another button's release is not lost while the handle counts as dragged", calls(), "160 / 160")

        -- A value from the player with no button held commits at once.
        reset()
        ui.slide(frame, 180)
        T.eq(p .. "moved without a held button: committed at once", calls(), "180 / 180")

        -- The client says the handle is being dragged although no mouse-down
        -- was seen: values still wait for the release.
        reset()
        frame.draggingThumb = true
        ui.slide(frame, 190)
        T.eq(p .. "the client's own drag state also counts as held", calls(), "190 / ")
        T.check(p .. "IsHeld says so", slider:IsHeld() == true)
        frame.draggingThumb = false
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "and its release commits", calls(), "190 / 190")

        -- The button is let go where the slider hears nothing of it (no
        -- mouse-up script): once no mouse button is down the hold is over,
        -- and it ends like a release.
        reset()
        slider:SetRange(117, 300, 225)
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.slide(frame, 200)
        slider:SetRange(120, 300, 225)
        T.eq(p .. "button still down: a redraw is ignored", frame.min .. ":" .. slider:GetValue(), "117:200")
        ui.release("LeftButton")
        T.eq(p .. "let go unheard: nothing happens by itself", calls(), "200 / ")
        slider:SetRange(120, 300, 225)
        T.eq(p .. "let go unheard, then a redraw: committed once", calls(), "200 / 200")
        T.check(p .. "let go unheard: no longer held", slider:IsHeld() == false)
        T.eq(p .. "let go unheard: the redraw is taken", frame.min .. ":" .. slider:GetValue(), "120:225")
        slider:SetRange(117, 300, 225)
        T.eq(p .. "let go unheard: a second redraw commits nothing more", #released, 1)
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "let go unheard: nor does a mouse-up that comes late", #released, 1)
        -- Asking whether it is held finds it as well.
        reset()
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.slide(frame, 190)
        ui.release()
        T.check(p .. "let go unheard: asking finds the hold over", slider:IsHeld() == false)
        T.eq(p .. "and commits", calls(), "190 / 190")
        -- So does a value set from code.
        reset()
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.slide(frame, 180)
        ui.release()
        slider:SetValue(250)
        T.eq(p .. "let go unheard, then a value from code: committed once, then set", calls() .. " " .. slider:GetValue(), "180 / 180 250")
        -- When the mouse-up does arrive, nothing is committed twice.
        reset()
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.slide(frame, 210)
        ui.fire(frame, "OnMouseUp", "LeftButton")
        slider:SetRange(117, 300, 210)
        T.check(p .. "mouse-up heard: not held", slider:IsHeld() == false)
        T.eq(p .. "mouse-up heard: one commit, also after a redraw", calls(), "210 / 210")
        -- While the client still calls the handle dragged the hold is not over.
        reset()
        ui.fire(frame, "OnMouseDown", "LeftButton")
        frame.draggingThumb = true
        ui.slide(frame, 170)
        ui.release()
        T.check(p .. "no button down but the handle still counts as dragged: held", slider:IsHeld() == true)
        T.eq(p .. "and nothing is committed yet", #released, 0)
        frame.draggingThumb = false
        T.check(p .. "once it no longer does: over", slider:IsHeld() == false)
        T.eq(p .. "and committed once", calls(), "170 / 170")
        -- A press that moved nothing and was let go unheard commits nothing.
        reset()
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.release()
        T.check(p .. "a press let go unheard without a move: over", slider:IsHeld() == false)
        T.eq(p .. "and nothing to commit", calls(), " / ")
        -- A client that cannot say which buttons are down keeps the hold
        -- until the mouse-up (or until the slider goes out of sight).
        reset()
        local buttonDown = _G.IsMouseButtonDown
        _G.IsMouseButtonDown = nil
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.slide(frame, 130)
        ui.release()
        slider:SetRange(120, 300, 225)
        T.check(p .. "no way to ask for the buttons: still held", slider:IsHeld() == true)
        T.eq(p .. "no way to ask: the redraw is ignored, nothing committed", calls() .. " " .. slider:GetValue(), "130 /  130")
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "no way to ask: the mouse-up commits", calls(), "130 / 130")
        _G.IsMouseButtonDown = buttonDown

        -- The owner redraws from inside the release (a new path arrives):
        -- that range is taken, even if the client still calls the handle
        -- dragged while its mouse-up script runs.
        local redraw = W.CreateSlider(parent, nil, {})
        redraw.onReleased = function() redraw:SetRange(118, 300, 118) end
        redraw:SetRange(117, 300, 225)
        ui.fire(redraw.frame, "OnMouseDown", "LeftButton")
        redraw.frame.draggingThumb = true
        ui.slide(redraw.frame, 117)
        ui.fire(redraw.frame, "OnMouseUp", "LeftButton")
        redraw.frame.draggingThumb = false
        T.eq(p .. "a range set from inside the release is applied", redraw.frame.min .. ":" .. redraw:GetValue(), "118:118")

        -- Hidden while held (combat, the window closing): the hold is gone,
        -- nothing is committed.
        reset()
        ui.fire(frame, "OnMouseDown", "LeftButton")
        ui.slide(frame, 210)
        frame:Hide()
        T.check(p .. "hiding the frame clears the hold", slider:IsHeld() == false)
        T.eq(p .. "and commits nothing", #released, 0)
        frame:Show()
        ui.fire(frame, "OnMouseUp", "LeftButton")
        T.eq(p .. "a late mouse-up commits nothing either", #released, 0)
        slider:SetRange(117, 300, 190)
        T.eq(p .. "the next range puts the handle back", slider:GetValue(), 190)
        -- ...also when it is a parent that was hidden.
        ui.fire(frame, "OnMouseDown", "LeftButton")
        parent:Hide()
        T.check(p .. "a hidden parent clears the hold as well", slider:IsHeld() == false)
        parent:Show()
        slider:SetRange(117, 300, 225)
        T.eq(p .. "and the next range is applied", slider:GetValue(), 225)

        -- No room to move: disabled, and never an empty or inverted range.
        reset()
        slider:SetRange(300, 300, 300)
        T.check(p .. "no room: disabled", frame.enabled == false)
        T.check(p .. "no room: the frame still has a real range", frame.min < frame.max)
        T.eq(p .. "no room: the value is the end", slider:GetValue(), 300)
        slider:SetRange(300, 299, 300)
        T.check(p .. "inverted: disabled", frame.enabled == false)
        T.check(p .. "inverted: the frame still has a real range", frame.min < frame.max)
        T.check(p .. "no range ever reached the frame empty or inverted", rangesSound())
        ui.fire(frame, "OnMouseDown", "LeftButton")
        T.check(p .. "a disabled slider is not held by a press", slider:IsHeld() == false)
        slider:SetEnabled(true)
        T.check(p .. "it cannot be enabled without room", frame.enabled == false)
        slider:SetRange(117, 300, 225)
        T.check(p .. "room again: enabled again", frame.enabled == true)
        slider:SetEnabled(false)
        T.check(p .. "SetEnabled(false) disables", frame.enabled == false)
        slider:SetRange(117, 300, 225)
        T.check(p .. "and a new range does not enable it by itself", frame.enabled == false)
        slider:SetEnabled(true)
        T.check(p .. "SetEnabled(true) enables", frame.enabled == true)
        T.eq(p .. "none of that called a callback", calls(), " / ")

        -- Callbacks are optional.
        local bare = W.CreateSlider(parent, nil)
        bare:SetRange(1, 10, 5)
        ui.slide(bare.frame, 7)
        T.eq(p .. "works without callbacks", bare:GetValue(), 7)
    end)
end

for _, family in ipairs({ "forever", "classic" }) do
    T.section(family .. " tabs", function()
        local p = family .. " tabs: "
        local ui, W = load(family)
        local frame = CreateFrame("Frame", "TestWindow", UIParent)
        local picked = {}
        local tabs = W.CreateTabs(frame, { "Guide", "Steps", "Shopping" }, function(i) picked[#picked + 1] = i end)
        local template = family == "forever" and "PanelTabButtonTemplate" or "CharacterFrameTabButtonTemplate"
        T.eq(p .. "three tab buttons", #tabs.buttons, 3)
        T.eq(p .. "the family's template", tabs.buttons[1].template, template)
        T.eq(p .. "named <Frame>Tab<i>", tabs.buttons[2].name, "TestWindowTab2")
        T.eq(p .. "ids set", tabs.buttons[3]:GetID(), 3)
        T.eq(p .. "labels set", tabs.buttons[3].text, "Shopping")
        T.eq(p .. "tab 1 anchored under the window", tabs.buttons[1].points[1][3], "BOTTOMLEFT")
        T.eq(p .. "tab count stored on the window", frame.numTabs, 3)
        T.eq(p .. "tab 1 selected at first", tabs:GetSelected(), 1)
        T.eq(p .. "the stock helper was told", frame.selectedTab, 1)
        if family == "forever" then
            T.eq(p .. "only tab 1 is anchored by hand", #tabs.buttons[2].points, 0)
            T.eq(p .. "the stock helper anchors the rest", ui.tabCalls.setNumTabs, 1)
        else
            T.eq(p .. "each tab anchored by hand", #tabs.buttons[2].points, 1)
            T.eq(p .. "the anchoring helper is not relied on", ui.tabCalls.setNumTabs, 0)
        end
        ui.fire(tabs.buttons[3], "OnClick")
        T.eq(p .. "a click selects the tab", tabs:GetSelected(), 3)
        T.eq(p .. "and calls back once", table.concat(picked, ","), "3")
        ui.fire(tabs.buttons[3], "OnClick")
        T.eq(p .. "clicking the selected tab does nothing", table.concat(picked, ","), "3")
        tabs:Select(2)
        T.eq(p .. "Select does not call back", table.concat(picked, ","), "3")
        T.eq(p .. "Select moves the selection", frame.selectedTab, 2)

        -- A client without the stock helpers must not error (Classic branch).
        if family == "classic" then
            _G.PanelTemplates_SetTab, _G.PanelTemplates_TabResize = nil, nil
            local frame2 = CreateFrame("Frame", "TestWindowB", UIParent)
            local tabs2 = W.CreateTabs(frame2, { "A", "B" }, function() end)
            tabs2:Select(2)
            T.eq(p .. "works without the stock helpers", tabs2:GetSelected(), 2)
        end
    end)
end

T.section("controls", function()
    local ui, W = load("forever")
    local parent = CreateFrame("Frame", nil, UIParent)

    -- Button group
    local picked = {}
    local group = W.CreateButtonGroup(parent, {
        { text = "Cheapest", value = "cheapest", width = 72, tooltip = "Least gold" },
        { text = "Fastest", value = "fastest", width = 64 },
    }, function(v) picked[#picked + 1] = v end)
    T.eq("group: one stock button per option", group.buttons.cheapest.template, "UIPanelButtonTemplate")
    T.eq("group: explicit widths", group.buttons.cheapest.width, 72)
    T.eq("group: frame as wide as its buttons", group.frame.width, 136)
    group:SetSelected("cheapest")
    T.eq("group: the selected button is held pushed", group.buttons.cheapest.buttonState, "PUSHED")
    T.eq("group: the other is normal", group.buttons.fastest.buttonState, "NORMAL")
    T.eq("group: SetSelected does not call back", #picked, 0)
    ui.fire(group.buttons.fastest, "OnClick")
    T.eq("group: a click selects", group:GetSelected(), "fastest")
    T.eq("group: and calls back with the value", table.concat(picked, ","), "fastest")
    T.eq("group: the old one is released", group.buttons.cheapest.buttonState, "NORMAL")
    ui.fire(group.buttons.fastest, "OnClick")
    T.eq("group: clicking the selected one does not call back again", #picked, 1)
    T.eq("group: and it stays held", group.buttons.fastest.buttonState, "PUSHED")
    ui.fire(group.buttons.cheapest, "OnEnter")
    T.check("group: tooltip text", ui.tooltip:Text():find("Least gold", 1, true) ~= nil)

    -- The selected one must be unmistakable: full strength, highlight held,
    -- white text; the other one dimmed.
    T.eq("group: the selected button at full strength", group.buttons.fastest.alpha, 1)
    T.check("group: its highlight is held", group.buttons.fastest.highlightLocked == true)
    T.eq("group: its text is white", group.buttons.fastest.normalFont, "GameFontHighlight")
    T.eq("group: the other button is dimmed", group.buttons.cheapest.alpha, 0.55)
    T.check("group: without a held highlight", group.buttons.cheapest.highlightLocked == false)
    T.eq("group: and keeps the stock text colour", group.buttons.cheapest.normalFont, "GameFontNormal")
    group:SetSelected("cheapest")
    T.eq("group: the look follows the selection", group.buttons.cheapest.alpha .. "," .. group.buttons.fastest.alpha, "1,0.55")
    group:SetSelected("fastest")

    -- The stock button draws "pressed" by swapping its three art pieces, and
    -- puts the "up" art back on release and on show: the selected button is
    -- given the "down" art again after each.
    for _, button in ipairs(group.list) do
        for _, key in ipairs({ "Left", "Middle", "Right" }) do rawset(button, key, ui.newRegion("Texture", button)) end
    end
    group:SetSelected("fastest")
    T.eq("group: the selected button gets the pressed art", group.buttons.fastest.Left.texture, "Interface\\Buttons\\UI-Panel-Button-Down")
    T.eq("group: all three pieces", group.buttons.fastest.Right.texture, "Interface\\Buttons\\UI-Panel-Button-Down")
    T.eq("group: the other button gets the normal art", group.buttons.cheapest.Middle.texture, "Interface\\Buttons\\UI-Panel-Button-Up")
    group.buttons.fastest.Left.texture = "Interface\\Buttons\\UI-Panel-Button-Up"   -- what the template does on release
    ui.fire(group.buttons.fastest, "OnMouseUp")
    T.eq("group: pressed art back after the mouse is released", group.buttons.fastest.Left.texture, "Interface\\Buttons\\UI-Panel-Button-Down")
    group.buttons.fastest.Left.texture = "Interface\\Buttons\\UI-Panel-Button-Up"   -- and on show
    ui.fire(group.buttons.fastest, "OnShow")
    T.eq("group: pressed art back after the button is shown again", group.buttons.fastest.Left.texture, "Interface\\Buttons\\UI-Panel-Button-Down")
    ui.fire(group.buttons.cheapest, "OnMouseUp")
    T.eq("group: an unselected button keeps the normal art", group.buttons.cheapest.Left.texture, "Interface\\Buttons\\UI-Panel-Button-Up")

    -- Numeric input
    local commits = {}
    local input = W.CreateNumericInput(parent, "TestTarget", 44, 3, function(n)
        commits[#commits + 1] = n
        if n > 300 then return 300 end
    end)
    T.eq("input: stock input box", input.frame.template, "InputBoxTemplate")
    T.check("input: numbers only, no auto focus", input.frame.numeric == true and input.frame.autoFocus == false)
    T.eq("input: max letters", input.frame.maxLetters, 3)
    input:SetValue(300)
    T.eq("input: shows its value", input.frame.text, "300")
    input.frame.focused = true
    input.frame.text = "225"
    ui.fire(input.frame, "OnEnterPressed")
    T.eq("input: Enter commits the number", table.concat(commits, ","), "225")
    T.eq("input: value kept", input:GetValue(), 225)
    T.check("input: focus dropped", input.frame.focused == false)
    T.eq("input: losing focus after Enter does not commit twice", #commits, 1)
    input.frame.focused = true
    input.frame.text = "999"
    ui.fire(input.frame, "OnEnterPressed")
    T.eq("input: Enter commits again", commits[2], 999)
    T.eq("input: the corrected value is shown", input.frame.text, "300")
    -- Only Enter commits: half-typed digits are not a number the player chose.
    input.frame.focused = true
    input.frame.text = "12"
    ui.fire(input.frame, "OnEditFocusLost")
    T.eq("input: losing the keyboard commits nothing", #commits, 2)
    T.eq("input: and puts the value back", input.frame.text, "300")
    input.frame.focused = true
    input.frame.text = "12"
    ui.fire(input.frame, "OnEscapePressed")
    T.eq("input: Escape puts the value back", input.frame.text, "300")
    T.eq("input: and commits nothing", #commits, 2)
    T.check("input: and gives the keyboard up", input.frame.focused == false)
    input.frame.text = ""
    ui.fire(input.frame, "OnEnterPressed")
    T.eq("input: empty text restores the value", input.frame.text, "300")
    T.eq("input: and commits nothing either", #commits, 2)
    -- A value that arrives while the player types: the digits stay when asked
    -- for, the value is known all the same.
    input.frame.focused = true
    input.frame.text = "4"
    input:SetValue(250, true)
    T.eq("input: a value given while typing leaves the digits", input.frame.text, "4")
    T.eq("input: but it is the value", input:GetValue(), 250)
    input.frame.text = "250"
    ui.fire(input.frame, "OnEnterPressed")
    T.eq("input: typing that value changes nothing", #commits, 2)
    input.frame.focused = true
    input.frame.text = "4"
    input:SetValue(260, true)
    ui.fire(input.frame, "OnEditFocusLost")
    T.eq("input: leaving the box shows the value given meanwhile", input.frame.text, "260")
    input.frame.focused = false
    input:SetValue(270, true)
    T.eq("input: not typing: the value is shown at once", input.frame.text, "270")
    input.frame.focused = true
    input.frame.text = "4"
    input:SetValue(280)
    T.eq("input: a plain SetValue replaces what is typed", input.frame.text, "280")
    input.frame.focused = false

    -- Checkbox
    local changes = {}
    local box = W.CreateCheckbox(parent, "TestMargin", "With margin", function(c) changes[#changes + 1] = c end)
    T.eq("checkbox: stock check button", box.frame.template, "UICheckButtonTemplate")
    T.eq("checkbox: its own label", box.label.text, "With margin")
    T.check("checkbox: the label is not the template's", box.label ~= box.frame.Text)
    box:SetChecked(true)
    T.check("checkbox: SetChecked", box:GetChecked() == true)
    T.eq("checkbox: SetChecked does not call back", #changes, 0)
    box.frame.checked = false
    ui.fire(box.frame, "OnClick")
    T.check("checkbox: a click calls back with the new state", #changes == 1 and changes[1] == false)

    -- Search box
    local queries = {}
    local search = W.CreateSearchBox(parent, "TestSearch", "Search recipes...", function(t) queries[#queries + 1] = t end)
    T.eq("search: hint text", search.hint.text, "Search recipes...")
    search.frame.text = "wool"
    ui.fire(search.frame, "OnTextChanged", true)
    T.eq("search: typing calls back", queries[1], "wool")
    T.check("search: hint hidden, clear button shown", search.hint.shown == false and search.clear.shown == true)
    search:SetText("silk")
    T.eq("search: text set by code does not call back", #queries, 1)
    ui.fire(search.clear, "OnClick")
    T.eq("search: clear empties the box", search:GetText(), "")
    T.eq("search: and reports the empty query", queries[2], "")
    T.check("search: hint back", search.hint.shown == true)

    -- Resize bounds
    local modern = { SetResizeBounds = function(self, a, b, c, d) self.bounds = { a, b, c, d } end }
    W.SetResizeBounds(modern, 380, 300, 600, 800)
    T.eq("resize: the single call when the client has it", table.concat(modern.bounds, ","), "380,300,600,800")
    local old = { SetMinResize = function(self, a, b) self.min = { a, b } end,
                  SetMaxResize = function(self, a, b) self.max = { a, b } end }
    W.SetResizeBounds(old, 380, 300, 600, 800)
    T.eq("resize: the old pair otherwise", table.concat(old.min, ",") .. ";" .. table.concat(old.max, ","), "380,300;600,800")
end)

T.section("row list", function()
    local ui, W = load("forever")
    local parent = CreateFrame("Frame", nil, UIParent)
    local list = W.CreateRowList(parent, "TestList")
    list:SetWidth(380)
    T.eq("list: scroll frame template", list.frame.template, "UIPanelScrollFrameTemplate")
    T.check("list: content is the scroll child", list.frame.scrollChild == list.content)

    local clicks, buttonClicks = {}, 0
    local descs = {
        { kind = "line", lead = "143-165", text = "41x Gloves", right = "4g 97s", color = { 1, 0.5, 0.25 },
          bg = { 0.2, 0.2, 0.1, 0.5 }, hoverBg = { 0.3, 0.3, 0.2, 0.6 },
          onClick = function(b) clicks[#clicks + 1] = b end,
          tooltip = { { text = "41x Gloves", r = 1, g = 1, b = 1 }, { text = "Skill 143 to 165" } },
          button = { text = "Guide", width = 50, onClick = function() buttonClicks = buttonClicks + 1 end } },
        { kind = "cols", header = true, text = "Reagent", cols = { "Need", "Have", "Buy", "Cost" } },
        { kind = "cols", text = "Wool Cloth", icon = "icon", cols = { "123", "40", "83", "4g 15s" }, mark = "vendor",
          itemId = 2592, link = "|Hitem:2592|h[Wool Cloth]|h", indent = 8,
          colColors = { [3] = { 1, 0.4, 0.4 } }, tooltip = { { text = "Price: 5s each" } } },
        { kind = "sep" },
        { kind = "line", text = "Dimmed", alpha = 0.5, height = 24 },
    }
    list:Render(descs)
    T.eq("list: one row per descriptor", #list.rows, 5)
    local first, header, wool, sep, dim = list.rows[1], list.rows[2], list.rows[3], list.rows[4], list.rows[5]
    T.eq("line: lead text", first.lead.text, "143-165")
    T.eq("line: text", first.text.text, "41x Gloves")
    T.eq("line: right text", first.right.text, "4g 97s")
    T.eq("line: text colour", first.text.color[2], 0.5)
    T.eq("line: background", first.bg.colorTexture[1], 0.2)
    T.eq("line: default height", first.height, 20)
    T.eq("line: full width", first.width, 380)
    T.eq("line: button text", first.button.text, "Guide")
    ui.fire(first, "OnClick", "LeftButton")
    T.eq("line: click passes the mouse button", clicks[1], "LeftButton")
    ui.fire(first.button, "OnClick", "LeftButton")
    T.eq("line: the row's button has its own click", buttonClicks, 1)
    ui.fire(first, "OnEnter")
    T.eq("line: hover background", first.bg.colorTexture[1], 0.3)
    T.check("line: tooltip lines", ui.tooltip:Text() == "41x Gloves\nSkill 143 to 165", ui.tooltip:Text())
    ui.fire(first, "OnLeave")
    T.eq("line: background restored", first.bg.colorTexture[1], 0.2)

    T.eq("cols: header text", header.text.text, "Reagent")
    T.eq("cols: header columns", header.cols[4].text, "Cost")
    T.eq("cols: name", wool.text.text, "Wool Cloth")
    T.eq("cols: need / have / buy / cost", wool.cols[1].text .. "," .. wool.cols[2].text .. "," .. wool.cols[3].text .. "," .. wool.cols[4].text,
        "123,40,83,4g 15s")
    T.eq("cols: column colour", wool.cols[3].color[2], 0.4)
    T.eq("cols: mark", wool.mark.text, "vendor")
    T.eq("cols: indent narrows the row", wool.width, 372)
    ui.fire(wool, "OnEnter")
    T.eq("cols: item tooltip", ui.tooltip.itemId, 2592)
    T.check("cols: extra tooltip lines under the item", ui.tooltip:Text():find("Price: 5s each", 1, true) ~= nil)
    ui.shift = true
    ui.fire(wool, "OnClick", "LeftButton")
    T.eq("cols: shift-click links the item", ui.linked, "|Hitem:2592|h[Wool Cloth]|h")
    ui.shift = false

    T.eq("sep: default height", sep.height, 8)
    T.eq("dimmed row alpha", dim.alpha, 0.5)
    T.eq("explicit height", dim.height, 24)
    T.eq("rows stack downwards", dim.points[1][5], -(20 + 18 + 18 + 8))
    T.eq("content height covers the rows", list.content.height, 20 + 18 + 18 + 8 + 24 + 8)

    -- Reuse: a second render makes no new frames for the same shape.
    local made = #ui.frames
    list:Render(descs)
    T.eq("list: a second render reuses every row", #ui.frames, made)
    T.check("list: same frames in the same spots", list.rows[1] == first and list.rows[3] == wool)

    -- A released row drops its handlers and its button.
    list:Render({ { kind = "line", text = "Only" } })
    T.eq("list: fewer rows", #list.rows, 1)
    T.check("list: unused rows are hidden", wool.shown == false and dim.shown == false)
    T.check("list: released rows drop their click handler", dim.scripts.OnClick == nil)
    T.check("list: a reused row without a button hides it", list.rows[1].button.shown == false)
    T.check("list: no right text left over", list.rows[1].right.text == "")

    -- Wrapped text grows the row.
    list:Render({ { kind = "line", text = "long", wrap = true } })
    list.rows[1].text.stringHeight = 40
    list:Render({ { kind = "line", text = "long", wrap = true } })
    T.eq("list: a wrapped line is as tall as its text", list.rows[1].height, 46)

    -- A cols row with a button instead of a mark.
    list:Render({ { kind = "cols", text = "Bolt", cols = { "55", "0", "-", "" },
        button = { text = "I craft it", onClick = function() buttonClicks = buttonClicks + 1 end } } })
    T.eq("cols: button text", list.rows[1].button.text, "I craft it")
    T.eq("cols: no mark beside a button", list.rows[1].mark.text, "")
    ui.fire(list.rows[1].button, "OnClick", "RightButton")
    T.eq("cols: button click", buttonClicks, 2)

    list.frame.scroll = 120
    list:Render({ { kind = "line", text = "a" } })
    T.eq("list: scroll kept on a plain render", list.frame.scroll, 120)
    list:Render({ { kind = "line", text = "a" } }, true)
    T.eq("list: back to the top when asked", list.frame.scroll, 0)
end)

-- Where a column sits: its width and how far its right edge is from the
-- row's right edge.
local function column(row, i)
    local col = row.cols[i]
    local point = col.points[#col.points]
    return tostring(col.width) .. "@" .. tostring(-point[4])
end
-- How far the name's right edge is from the row's right edge.
local function nameEnd(row)
    local point = row.text.points[#row.text.points]
    return -point[4]
end

T.section("column layouts", function()
    local ui, W = load("forever")
    local list = W.CreateRowList(CreateFrame("Frame", nil, UIParent), "TestColumns")
    list:SetWidth(376)

    -- The reagent table: need / have / buy / cost, then the mark column.
    list:Render({
        { kind = "cols", header = true, text = "Reagent", cols = { "Need", "Have", "Buy", "Cost" } },
        { kind = "cols", text = "Wool Cloth", cols = { "123", "40", "83", "888g 88s 88c" }, mark = "vendor" },
    })
    local row = list.rows[2]
    T.eq("reagents: the cost column holds an amount to the copper", column(row, 4), "84@56")
    T.eq("reagents: buy", column(row, 3), "30@140")
    T.eq("reagents: have", column(row, 2), "30@170")
    T.eq("reagents: need", column(row, 1), "30@200")
    T.eq("reagents: the name ends where the numbers begin", nameEnd(row), 232)
    T.eq("reagents: the mark", row.mark.text, "vendor")
    T.eq("reagents: the mark starts inside its column", -row.mark.points[1][4], 52)

    -- The path list: skill range, crafts, cost; no mark column.
    local clicked
    list:Render({
        { kind = "cols", layout = "path", header = true, text = "Recipes", cols = { "skill", "crafts", "cost" } },
        { kind = "cols", layout = "path", text = "> Gloves", color = { 1, 0.5, 0.25 }, cols = { "143-160", "19", "108g 63s 28c" },
          colColors = { [3] = { 0.4, 1, 0.4 } }, onClick = function() clicked = true end },
    })
    local header, run = list.rows[1], list.rows[2]
    T.eq("path: a cols row", run.desc.layout, "path")
    T.eq("path: cost at the right edge", column(run, 3), "84@4")
    T.eq("path: crafts left of it", column(run, 2), "46@88")
    T.eq("path: skill range left of that", column(run, 1), "62@134")
    T.eq("path: texts", run.cols[1].text .. "," .. run.cols[2].text .. "," .. run.cols[3].text, "143-160,19,108g 63s 28c")
    T.check("path: the fourth column is not used", run.cols[4].shown == false)
    T.eq("path: no mark", run.mark.text, "")
    T.eq("path: the name ends where the columns begin", nameEnd(run), 198)
    T.eq("path: name", run.text.text, "> Gloves")
    T.eq("path: name colour", run.text.color[2], 0.5)
    T.eq("path: column colour", run.cols[3].color[1], 0.4)
    T.eq("path header: titles in the same columns", header.cols[1].text .. "," .. header.cols[3].text, "skill,cost")
    T.eq("path header: at the same places", column(header, 1) .. " " .. column(header, 3), "62@134 84@4")
    T.eq("path header: gold", header.text.color[2], 0.82)
    ui.fire(run, "OnClick", "LeftButton")
    T.check("path: a row is clickable", clicked == true)

    -- A reagent table without the mark column (inside an opened run).
    list:Render({
        { kind = "cols", layout = "nomark", header = true, text = "Reagent", cols = { "Need", "Have", "Buy", "Cost" } },
        { kind = "cols", layout = "nomark", text = "Heavy Scorpid Scale", cols = { "28", "0", "28", "3g 82s" } },
    })
    row = list.rows[2]
    T.eq("no mark column: cost at the right edge", column(row, 4), "84@4")
    T.eq("no mark column: need", column(row, 1), "30@148")
    T.eq("no mark column: the name gets the room", nameEnd(row), 180)

    -- A pooled row laid out one way is laid out again for the next.
    list:Render({ { kind = "cols", text = "Wool Cloth", cols = { "1", "2", "3", "4c" }, mark = "vendor" } })
    T.check("a reused row is the same frame", list.rows[1] == header)
    T.eq("a reused row takes the new layout", column(list.rows[1], 4), "84@56")
    T.check("and shows its fourth column again", list.rows[1].cols[4].shown ~= false)

    -- A row whose first columns are empty lets its text run over them.
    list:Render({
        { kind = "cols", text = "Charged Scorpid Bracers - auction house", cols = { "", "", "", "68s 63c" } },
        { kind = "cols", text = "Wool", cols = { "165", "", "", "" }, mark = "in list" },
    })
    T.eq("empty leading columns: the name runs up to the first one used", nameEnd(list.rows[1]), 142)
    T.eq("a first column in use: the name ends before it", nameEnd(list.rows[2]), 232)

    -- Nothing sits on anything else, at the narrowest, the default and the
    -- widest window (the list is the window's width less 44), and the
    -- reagent's name keeps a column worth reading.
    local function spans(r, rowWidth)
        -- { what, left, right } of each part, measured from the row's left edge
        local out = {}
        local nameLeft = r.text.points[1][4]
        out[#out + 1] = { "name", nameLeft, rowWidth - nameEnd(r) }
        for i, col in ipairs(r.cols) do
            if col.shown ~= false then
                local right = rowWidth + col.points[#col.points][4]
                out[#out + 1] = { "column " .. i, right - col.width, right }
            end
        end
        if r.button and r.button.shown then
            local right = rowWidth + r.button.points[#r.button.points][4]
            out[#out + 1] = { "button", right - r.button.width, right }
        elseif r.mark.text ~= "" then
            local left = rowWidth + r.mark.points[1][4]
            out[#out + 1] = { "mark", left, left + r.mark:GetStringWidth() }
        end
        return out
    end
    local function overlap(r, rowWidth)
        local parts = spans(r, rowWidth)
        table.sort(parts, function(a, b) return a[2] < b[2] end)
        for i, part in ipairs(parts) do
            if part[2] < 0 or part[3] > rowWidth then return part[1] .. " leaves the row" end
            if part[3] <= part[2] then return part[1] .. " has no width" end
            if parts[i + 1] and part[3] > parts[i + 1][2] then return part[1] .. " runs into " .. parts[i + 1][1] end
        end
        return nil
    end
    for _, window in ipairs({ 380, 420, 640 }) do
        local width = window - 44
        list:SetWidth(width)
        list:Render({
            { kind = "cols", header = true, text = "Reagent", cols = { "Need", "Have", "Buy", "Cost" } },
            { kind = "cols", icon = "icon", text = "Heavy Scorpid Scale", cols = { "1234", "1234", "1234", "888g 88s 88c" }, mark = "vendor" },
            { kind = "cols", icon = "icon", text = "Bolt of Runecloth", cols = { "55", "0", "-", "" },
              button = { text = "I craft it", onClick = function() end } },
            { kind = "cols", layout = "path", text = "> Charged Scorpid Bracers", cols = { "274-280", "100", "888g 88s 88c" } },
            { kind = "cols", layout = "nomark", indent = 14, icon = "icon", text = "Heavy Scorpid Scale", cols = { "28", "0", "28", "3g 82s" } },
        })
        local p = "window " .. window .. ": "
        for i, name in ipairs({ "header", "reagent with a mark", "reagent with a button", "path row", "run's reagent" }) do
            local r = list.rows[i]
            T.check(p .. name .. ": nothing overlaps", overlap(r, r.width) == nil, overlap(r, r.width))
        end
        local marked, button = list.rows[2], list.rows[3].button
        T.check(p .. "the craft / buy button stays inside the mark column",
            button.width <= 56 and -button.points[#button.points][4] + button.width <= 56, button.width)
        local name = spans(marked, marked.width)[1]
        T.check(p .. "a reagent's name keeps at least 80 wide", name[3] - name[2] >= 80, name[3] - name[2])
    end
    list:SetWidth(376)
    list:Render({ { kind = "cols", icon = "icon", text = "Heavy Scorpid Scale", cols = { "28", "0", "28", "3g 82s" }, mark = "vendor" } })
    local name = spans(list.rows[1], 376)[1]
    T.eq("default width: the reagent's name column", name[3] - name[2], 124)
end)

T.section("sub-lines", function()
    local ui, W = load("forever")
    local list = W.CreateRowList(CreateFrame("Frame", nil, UIParent), "TestSubLines")
    list:SetWidth(376)
    local used
    list:Render({
        { kind = "line", text = "A run" },
        { kind = "line", sub = true, text = "Learn first: trainer, 4s" },
        { kind = "line", sub = true, text = "or: Cape, +14s", color = { 1, 0.75, 0.3 },
          button = { text = "Use", width = 40, onClick = function() used = true end } },
        { kind = "line", sub = true, indent = 30, height = 22, text = "given" },
        { kind = "line", text = "The next run" },
    })
    local run, learn, alt, given, after = list.rows[1], list.rows[2], list.rows[3], list.rows[4], list.rows[5]
    T.eq("sub-line: lower than a row", learn.height, 16)
    T.eq("sub-line: indented", learn.points[1][4], 18)
    T.eq("sub-line: as wide as what is left", learn.width, 376 - 18)
    T.eq("sub-line: grey unless coloured", learn.text.color[1], 0.7)
    T.eq("sub-line: small font", learn.text.font, "GameFontHighlightSmall")
    T.eq("sub-line: its own colour when given", alt.text.color[2], 0.75)
    T.eq("sub-line: a button fits its height", alt.button.height, 16)
    ui.fire(alt.button, "OnClick", "LeftButton")
    T.check("sub-line: the button works", used == true)
    T.eq("sub-line: a given indent wins", given.points[1][4], 30)
    T.eq("sub-line: a given height wins", given.height, 22)
    T.eq("an ordinary line is unchanged", run.height .. "," .. run.points[1][4] .. "," .. run.text.color[1], "20,0,1")
    T.eq("rows stack under the sub-lines", after.points[1][5], -(20 + 16 + 16 + 22))
end)

-- Rows are pooled: the frame that drew one row draws another on the next
-- render. Nothing of what it showed before may be left on it.
T.section("a reused row shows nothing of its previous use", function()
    local ui, W = load("forever")
    local list = W.CreateRowList(CreateFrame("Frame", nil, UIParent), "TestReuse")
    list:SetWidth(376)
    local function nothing() end

    -- A line with everything on it, then a bare one.
    list:Render({ { kind = "line", sub = true, alpha = 0.5, icon = "icon", lead = "143-165", leadColor = { 0.2, 0.8, 0.8 },
        text = "rich", color = { 1, 0.5, 0.25 }, font = "GameFontNormalLarge", right = "4g 97s", rightColor = { 0.4, 1, 0.4 },
        wrap = true, bg = { 0.2, 0.2, 0.1, 0.5 }, hoverBg = { 0.3, 0.3, 0.2, 0.6 }, onClick = nothing,
        tooltip = { { text = "tip" } }, itemId = 2592,
        button = { text = "Use", width = 40, onClick = nothing }, button2 = { text = "Other", width = 50, onClick = nothing } } })
    local line = list.rows[1]
    T.check("fixture: the rich line shows all of it", line.icon.shown and line.lead.shown and line.bg.shown
        and line.button.shown and line.button2.shown and line.alpha == 0.5 and line.height == 16 and line.points[1][4] == 18)
    list:Render({ { kind = "line", text = "bare" } })
    T.check("line: the same frame", list.rows[1] == line)
    T.eq("line: text", line.text.text, "bare")
    T.eq("line: full strength again", line.alpha, 1)
    T.check("line: no icon", line.icon.shown == false)
    T.check("line: no lead text", line.lead.shown == false)
    T.check("line: no background", line.bg.shown == false)
    T.eq("line: no right-hand text", line.right.text, "")
    T.check("line: no button", line.button.shown == false)
    T.check("line: no second button", line.button2.shown == false)
    T.eq("line: an ordinary row's height again, not a sub-line's", line.height, 20)
    T.eq("line: not indented any more", line.points[1][4], 0)
    T.eq("line: as wide as the list again", line.width, 376)
    T.eq("line: white again, not the sub-line's grey or the old colour", table.concat(line.text.color, ","), "1,1,1")
    T.eq("line: the small font again", line.text.font, "GameFontHighlightSmall")
    T.check("line: not wrapping any more", line.text.wordWrap == false)
    T.check("line: no click left over", (function()
        local clicked = false
        list:Render({ { kind = "line", text = "clickable", onClick = function() clicked = true end } })
        list:Render({ { kind = "line", text = "bare" } })
        ui.fire(line, "OnClick", "LeftButton")
        return clicked == false
    end)())
    ui.fire(line, "OnEnter")
    T.check("line: no tooltip and no hover colour left over", ui.tooltip.itemId ~= 2592 and line.bg.shown == false)

    -- A reagent row with everything on it, then a path row in the same frame.
    list:Render({ { kind = "cols", alpha = 0.55, icon = "icon", text = "Wool Cloth", color = { 0.7, 0.7, 0.7 },
        cols = { "123", "40", "83", "4g 15s" }, colColors = { [2] = { 0.4, 1, 0.4 }, [4] = { 1, 0.5, 0 } },
        bg = { 0.12, 0.12, 0.12, 0.5 }, indent = 14, itemId = 2592,
        button = { text = "I craft it", onClick = nothing } } })
    local cols = list.rows[1]
    T.check("fixture: the rich reagent row shows all of it", cols.icon.shown and cols.bg.shown and cols.button.shown
        and cols.alpha == 0.55 and cols.cols[4].text == "4g 15s")
    list:Render({ { kind = "cols", layout = "path", text = "Gloves", cols = { "143-160", "19", "19s" } } })
    T.check("cols: the same frame", list.rows[1] == cols)
    T.eq("cols: full strength again", cols.alpha, 1)
    T.check("cols: no icon", cols.icon.shown == false)
    T.check("cols: no background", cols.bg.shown == false)
    T.check("cols: no button", cols.button.shown == false)
    T.check("cols: the column it does not use is empty and hidden", cols.cols[4].text == "" and cols.cols[4].shown == false)
    T.eq("cols: its columns are white again", table.concat(cols.cols[2].color, ","), "1,1,1")
    T.eq("cols: its name is white again", table.concat(cols.text.color, ","), "1,1,1")
    T.eq("cols: not indented any more", cols.points[1][4], 0)
    -- ...and a marked reagent row, then a path row.
    list:Render({ { kind = "cols", text = "Thread", cols = { "9", "0", "9", "9s" }, mark = "vendor" } })
    T.eq("fixture: the mark", cols.mark.text, "vendor")
    list:Render({ { kind = "cols", layout = "path", text = "Gloves", cols = { "143-160", "19", "19s" } } })
    T.eq("cols: no mark left over on a path row", cols.mark.text, "")
    list:Render({ { kind = "cols", text = "Thread", cols = { "9", "0", "9", "9s" }, mark = "vendor" } })
    list:Render({ { kind = "cols", layout = "nomark", text = "Thread", cols = { "9", "0", "9", "9s" } } })
    T.eq("cols: nor on a row of the table without a mark column", cols.mark.text, "")
    list:Render({ { kind = "cols", text = "Bolt", cols = { "5", "0", "-", "" }, button = { text = "I craft it", onClick = nothing } } })
    list:Render({ { kind = "cols", layout = "nomark", text = "Thread", cols = { "9", "0", "9", "9s" } } })
    T.check("cols: no button left over there either", cols.button.shown == false)
    -- A header, then a plain row: the header's font and gold are gone.
    list:Render({ { kind = "cols", header = true, text = "Reagent", cols = { "Need", "Have", "Buy", "Cost" } } })
    list:Render({ { kind = "cols", text = "Thread", cols = { "9", "0", "9", "9s" } } })
    T.eq("cols: a header's font is not left on a row", cols.text.font .. "," .. cols.cols[1].font, "GameFontHighlightSmall,GameFontHighlightSmall")
    T.eq("cols: nor its gold", table.concat(cols.cols[1].color, ","), "1,1,1")

    -- Only a line can be a sub-line: on a column row the mark changes nothing.
    list:Render({ { kind = "cols", sub = true, text = "Thread", cols = { "9", "0", "9", "9s" } } })
    T.eq("a column row marked as a sub-line keeps its height", cols.height, 18)
    T.eq("and is not indented", cols.points[1][4], 0)
end)

T.section("scroll bar only when something scrolls", function()
    local function rows(n)
        local out = {}
        for i = 1, n do out[i] = { kind = "line", text = "row " .. i } end
        return out
    end
    local ui, W = load("forever")
    local list = W.CreateRowList(CreateFrame("Frame", nil, UIParent), "TestScrollBar")
    list:SetWidth(376)
    list.frame.height = 400
    local bar = list.frame.ScrollBar
    T.check("the stock template is told its bar may hide", list.frame.scrollBarHideable ~= nil)
    T.check("hidden before anything is drawn", bar.shown == false)
    list:Render(rows(3))
    T.check("three rows in a tall list: no bar", bar.shown == false)
    list:Render(rows(60))
    T.check("sixty rows: the bar is there", bar.shown == true)
    list:Render(rows(3))
    T.check("back to three: hidden again", bar.shown == false)
    local calls = ui.scrollRangeCalls
    list:Render(rows(3))
    T.eq("the range is read once per render", ui.scrollRangeCalls, calls + 1)

    -- A client without the stock range handler keeps the bar as it was.
    ui, W = load("classic")
    _G.ScrollFrame_OnScrollRangeChanged = nil
    list = W.CreateRowList(CreateFrame("Frame", nil, UIParent), "TestScrollBarOld")
    list:SetWidth(376)
    list.frame.height = 400
    T.check("no handler: the frame is not marked", list.frame.scrollBarHideable == nil)
    list:Render(rows(3))
    T.check("no handler: the bar stays", list.frame.ScrollBar.shown == true)

    -- So does one whose scroll frame has no bar under the usual key.
    ui, W = load("classic")
    ui.noScrollBar = true
    list = W.CreateRowList(CreateFrame("Frame", nil, UIParent), "TestScrollBarNone")
    list:SetWidth(376)
    T.check("no bar key: the frame is not marked", list.frame.scrollBarHideable == nil)
    list:Render(rows(3))
    T.eq("no bar key: the handler is left alone", ui.scrollRangeCalls, 0)
end)

T.finish()
