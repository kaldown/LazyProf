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
        "Modules/UI/Widgets/Tabs.lua",
        "Modules/UI/Widgets/RowList.lua",
    }) do
        assert(loadfile(path))("LazyProf", addon)
    end
    return ui, addon.Widgets
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
    ui.fire(input.frame, "OnEditFocusLost")
    T.eq("input: focus lost commits", commits[2], 999)
    T.eq("input: the corrected value is shown", input.frame.text, "300")
    input.frame.focused = true
    input.frame.text = "12"
    ui.fire(input.frame, "OnEscapePressed")
    T.eq("input: Escape puts the value back", input.frame.text, "300")
    T.eq("input: and commits nothing", #commits, 2)
    input.frame.text = ""
    ui.fire(input.frame, "OnEnterPressed")
    T.eq("input: empty text restores the value", input.frame.text, "300")

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

T.finish()
