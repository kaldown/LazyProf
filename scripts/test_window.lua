-- scripts/test_window.lua
--
-- The LazyProf window: built once, docked beside the profession window, its
-- header controls, the Steps tab, the notice state, the closed state, combat
-- hide and restore. Driven on both client families with the fake UI.
--
-- Run from the addon root:  lua5.1 scripts/test_window.lua

package.path = "./?.lua;" .. package.path
local W = require("scripts.lib.window")
local fakeui = require("scripts.lib.fakeui")
local T = require("scripts.lib.check").new()

for _, family in ipairs({ "forever", "classic" }) do
    T.section(family .. " shell", function()
        local p = family .. ": "
        local env = W.load(family)
        local window, ui = env.window, env.ui

        T.check(p .. "no frame before the first path", window.frame == nil)
        window:Update(W.path())
        local frame = window.frame
        T.check(p .. "the window is built and shown", frame ~= nil and frame.shown)
        T.eq(p .. "it has a global name (tabs, layout tools)", frame.name, "LazyProfGuideWindow")
        local pt = frame.points[#frame.points]
        T.check(p .. "docked: TOPLEFT to the profession window's TOPRIGHT",
            pt[1] == "TOPLEFT" and pt[2] == env.anchor and pt[3] == "TOPRIGHT")
        T.eq(p .. "at the client's panel offset", pt[4], family == "forever" and 65 or 10)
        T.eq(p .. "default width", frame.width, 420)
        T.eq(p .. "as tall as the profession window", frame.height, 500)
        T.check(p .. "resizable and clamped to the screen", frame.resizable == true)

        if family == "forever" then
            T.eq(p .. "native frame art", frame.NineSlice and frame.NineSlice.layout, "ButtonFrameTemplateNoPortrait")
            T.check(p .. "controls sit above the border art", window.body.level > frame.NineSlice.level)
            T.check(p .. "no backdrop", frame.backdrop == nil)
        else
            T.check(p .. "tooltip-style backdrop", frame.backdrop ~= nil)
        end

        -- Header
        T.eq(p .. "title", frame.title.text, "LazyProf - Tailoring")
        T.eq(p .. "status line", window.status.text, "Skill 143 / 150")
        T.eq(p .. "price line", window.prices.text, "Prices: TSM 2")
        T.eq(p .. "target box shows the target", window.targetInput.frame.text, "300")
        T.eq(p .. "strategy shown selected", window.strategyGroup:GetSelected(), "cheapest")
        T.check(p .. "margin unticked", window.marginBox:GetChecked() == false)
        local rangeText = family == "forever" and window.rangeDropdown.button.overrideText or window.rangeDropdown.frame.ddText
        T.eq(p .. "range shows the current range", rangeText, "Current (75-150)")
        T.eq(p .. "footer totals", window.footer1.text,
            "This range: 19s   |cFF888888||r   Whole path (excluding gaps): 99s (you pay 99s)")
        T.eq(p .. "no margin line", window.footer2.text, "")

        -- Steps tab
        T.eq(p .. "one tab for now", #window.tabs.buttons, #window.TABS)
        local rows = W.rowTexts(window)
        T.eq(p .. "the current range's stage", rows[1], "> 143-160 | |cFF888888craft|r  19x Gloves | 19s")
        T.eq(p .. "only that stage", #rows, 1)
        T.check(p .. "search box shown on the Steps tab", window.searchBox.frame.shown)

        -- A second update builds nothing new.
        local made = #ui.frames
        window:Update(W.path())
        T.eq(p .. "a second update reuses every frame", #ui.frames, made)
    end)
end

T.section("controls", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    window:Update(W.path())

    -- Range
    local root = fakeui.openMenu(window.rangeDropdown.button)
    T.eq("range: current, four ranges, full path", #root.radios, 6)
    root.radios[6].setSelected()
    T.eq("range: full path chosen", window.rangeDropdown.button.overrideText, "Full path")
    T.eq("range: all stages listed", #W.rowTexts(window), 3)
    T.eq("range: footer drops the range part", window.footer1.text, "Whole path (excluding gaps): 99s (you pay 99s)")
    T.eq("range: the shopping list is told", env.calls[#env.calls], "shopping")
    T.eq("range: no recalculation", #env.recalcs, 0)

    -- Expand
    ui.fire(W.findRow(window, "19x Gloves"), "OnClick", "LeftButton")
    local rows = W.rowTexts(window)
    T.eq("expand: header and reagent rows follow the stage", rows[2] .. " / " .. rows[3], "Reagent | Need,Have,Buy,Cost / MatGloves | 19,0,19,19s")
    window:Update(W.path())
    T.eq("expand: kept across a new path of the same profession", #W.rowTexts(window), 5)
    T.eq("range: kept too", window.rangeDropdown.button.overrideText, "Full path")
    ui.fire(W.findRow(window, "19x Gloves"), "OnClick", "LeftButton")
    T.eq("expand: a second click closes it", #W.rowTexts(window), 3)

    -- Target
    window.targetInput.frame.focused = true
    window.targetInput.frame.text = "225"
    ui.fire(window.targetInput.frame, "OnEnterPressed")
    T.eq("target: stored through the planner", table.concat({ env.targetArgs[1], env.targetArgs[2], env.targetArgs[3] }, ","), "tailoring,225,143")
    T.eq("target: a new path is asked for", env.recalcs[1], "target changed")
    window.targetInput.frame.focused = true
    window.targetInput.frame.text = "100"
    ui.fire(window.targetInput.frame, "OnEnterPressed")
    T.eq("target: the corrected value is shown", window.targetInput.frame.text, "144")
    window.targetInput.frame.focused = true
    window.targetInput.frame.text = "300"
    ui.fire(window.targetInput.frame, "OnEnterPressed")
    local before = #env.recalcs
    window:Update(W.path())
    window.targetInput.frame.focused = true
    window.targetInput.frame.text = "999"
    ui.fire(window.targetInput.frame, "OnEnterPressed")
    T.eq("target: a value that changes nothing does not recalculate", #env.recalcs, before)
    T.eq("target: and shows the cap", window.targetInput.frame.text, "300")

    -- Strategy
    before = #env.recalcs
    ui.fire(window.strategyGroup.buttons.fastest, "OnClick")
    T.eq("strategy: the setting changes", addon.db.profile.strategy, "fastest")
    T.eq("strategy: a new path is asked for", env.recalcs[#env.recalcs], "strategy change")
    T.eq("strategy: once", #env.recalcs, before + 1)

    -- Margin
    before = #env.recalcs
    window.marginBox.frame.checked = true
    ui.fire(window.marginBox.frame, "OnClick")
    T.check("margin: the setting changes", addon.db.profile.useMargin == true)
    T.eq("margin: no recalculation (recipes do not change)", #env.recalcs, before)
    T.eq("margin: rows show the larger count", W.rowTexts(window)[1], "> 143-160 | |cFF888888craft|r  22x Gloves | 22s")
    T.check("margin: footer gets its second line", window.footer2.text:find("With 15% margin", 1, true) ~= nil, window.footer2.text)
    T.eq("margin: the shopping list is told", env.calls[#env.calls], "shopping")

    -- Search
    window.searchBox.frame.text = "CA"
    ui.fire(window.searchBox.frame, "OnTextChanged", true)
    rows = W.rowTexts(window)
    T.eq("search: results replace the list", rows[1], "Cape | Requires 100")
    T.eq("search: count line", rows[2], "1 result")
    ui.fire(window.list.rows[1], "OnClick", "LeftButton")
    T.eq("search: a result opens the recipe details", env.details and env.details.recipe.name, "Cape")
    ui.fire(window.searchBox.clear, "OnClick")
    T.eq("search: clearing brings the steps back", #W.rowTexts(window), 3)

    -- Another profession starts clean.
    window.searchBox.frame.text = "x"
    ui.fire(window.searchBox.frame, "OnTextChanged", true)
    window:Update(W.path({ profession = "Alchemy", professionKey = "alchemy" }))
    T.eq("another profession: range back to current", window.rangeDropdown.button.overrideText, "Current (75-150)")
    T.eq("another profession: search cleared", window.searchBox:GetText(), "")
    T.eq("another profession: title", window.frame.title.text, "LazyProf - Alchemy")

    -- Prices tooltip and colour
    env.priceSummary = { total = 2, stale = 1, unpriced = 0, loading = 0 }
    env.priceLines = { { text = "Prices: Auctionator 2", r = 0.6, g = 0.6, b = 0.6 }, { text = "Auctionator prices up to 5 days old", r = 1, g = 0.5, b = 0 } }
    window:Update(W.path())
    T.eq("prices: orange when stale", window.prices.color[2], 0.5)
    ui.fire(window.pricesBtn, "OnEnter")
    T.check("prices: tooltip lists the lines", ui.tooltip:Text():find("5 days old", 1, true) ~= nil)
end)

T.section("states", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon

    -- Shopping steps are available before any frame exists.
    window.mode = "live"
    window:SetPath(W.path())
    local steps, name = window:ShoppingSteps()
    T.check("shopping steps without a frame", window.frame == nil and #steps == 1 and steps[1].quantity == 19)
    T.eq("with the range's name", name, "75-150")
    T.check("no path: no shopping steps", (function() window:SetPath(nil); return window:ShoppingSteps() end)() == nil)

    -- The setting that turns the window off.
    addon.db.profile.showMilestonePanel = false
    window:Update(W.path())
    T.check("turned off: not built, not shown", window.frame == nil)
    T.check("turned off: the path is still kept for the shopping list", window.path ~= nil)
    addon.db.profile.showMilestonePanel = true

    window:Update(W.path())
    local frame = window.frame

    -- Notice
    window:ShowNotice("No recipe data for Engineering yet.")
    T.check("notice: shown", frame.shown and frame.showsNotice == true)
    T.eq("notice: one row with the text", W.rowTexts(window)[1], "No recipe data for Engineering yet.")
    T.check("notice: controls hidden", window.controls.shown == false and window.searchBox.frame.shown == false)
    T.eq("notice: plain title", frame.title.text, "LazyProf")
    T.eq("notice: no totals", window.footer1.text, "")
    window:Update(W.path())
    T.check("a path replaces the notice", window.controls.shown == true and frame.showsNotice == nil)

    -- Filter hint
    env.hidden = true
    local unlearned = W.recipe(9, "Boots", 100, 150, 160, 170, { unlearned = true, sourceInfo = { type = "trainer", cost = 100 } })
    window:Update(W.path({ steps = { W.step(unlearned, 143, 160, 19, 1900) }, gaps = {}, totalCost = 1900 }))
    T.eq("filter hint row comes first", W.rowTexts(window)[1], "Next recipe is not learned yet - learn it from Any Tailoring Trainer")
    ui.fire(window.list.rows[1], "OnClick", "LeftButton")
    T.eq("hint click opens the recipe details", env.details and env.details.recipe.name, "Boots")
    env.hidden = false
    window:Update(W.path())

    -- Close button: stays closed until the profession window reopens.
    ui.fire(frame.closeBtn, "OnClick")
    T.check("close: hidden", not frame.shown and frame.userClosed == true)
    window:Update(W.path())
    T.check("close: an update does not bring it back", not frame.shown)
    env.shell:ResetClosed()
    window:Update(W.path())
    T.check("close: shown again after the profession window reopened", frame.shown)

    -- Profession window closed.
    window:OnProfessionClosed()
    T.check("profession closed: hidden", not frame.shown)
    window:Update(W.path())

    -- Combat
    ui.combat = true
    ui.event("PLAYER_REGEN_DISABLED")
    T.check("combat: hidden", not frame.shown)
    window:Update(W.path())
    T.check("combat: an update during combat does not show it", not frame.shown)
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("combat over: shown again", frame.shown)

    ui.combat = true
    ui.event("PLAYER_REGEN_DISABLED")
    env.open = false
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("combat over, profession window gone: stays hidden", not frame.shown)
    env.open = true
    window:Update(W.path())

    ui.fire(frame.closeBtn, "OnClick")
    ui.combat = true
    ui.event("PLAYER_REGEN_DISABLED")
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("combat over, closed by the player: stays closed", not frame.shown)
    env.shell:ResetClosed()
    window:Update(W.path())

    -- Refresh after a stock change redraws from the stored path.
    window.path.inventory = { [101] = 19 }
    window:Refresh()
    T.eq("refresh: stock is taken off", W.rowTexts(window)[1], "> 143-160 | |cFF888888craft|r  19x Gloves | 0c")

    -- Size and reset
    frame.width, frame.height = 500, 600
    ui.fire(window.resizeGrip, "OnMouseUp")
    T.eq("resize: size saved", addon.db.profile.panelSizes.guide.width, 500)
    T.eq("resize: rows follow the new width", window.list.width, 500 - 44)
    frame.left, frame.top = 300, 700
    ui.fire(frame, "OnDragStop")
    T.eq("drag: position saved", addon.db.profile.panelPositions.guide.x, 300)
    env.shell:ResetPositions()
    T.check("reset: saved spot and size forgotten",
        addon.db.profile.panelPositions.guide == nil and addon.db.profile.panelSizes.guide == nil)
    T.eq("reset: default width back", frame.width, 420)
    local pt = frame.points[#frame.points]
    T.check("reset: docked again", pt[2] == env.anchor)

    -- Tab memory
    window:SelectTab("steps", true)
    T.eq("tab chosen by the player is remembered for the character",
        addon.CharStore:Get().lastTab, "steps")
    addon.CharStore:Get().lastTab = "no-such-tab"
    window:SelectTab(addon.CharStore:Get().lastTab)
    T.eq("an unknown saved tab falls back to the first", window.tab, window.TABS[1].key)

    -- Nothing left
    window:Update(W.path({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 }))
    T.eq("nothing left: message instead of rows", W.rowTexts(window)[1], "Nothing left: Tailoring is at its cap of 300.")
end)

T.finish()
