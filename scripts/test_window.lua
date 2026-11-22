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
        T.eq(p .. "status line", window.status.text, "Skill 143 / 300")
        T.eq(p .. "price line", window.prices.text, "Prices: TSM 2")
        T.eq(p .. "target box shows the target", window.targetInput.frame.text, "300")
        T.eq(p .. "strategy shown selected", window.strategyGroup:GetSelected(), "cheapest")
        T.check(p .. "margin unticked", window.marginBox:GetChecked() == false)
        local rangeText = family == "forever" and window.rangeDropdown.button.overrideText or window.rangeDropdown.frame.ddText
        T.eq(p .. "range shows the current range", rangeText, "Current (75-150)")
        T.eq(p .. "footer totals", window.footer1.text,
            "This range: 19s   |cFF888888||r   Whole path (excluding gaps): 99s (you pay 99s)")
        T.eq(p .. "no margin line", window.footer2.text, "")

        -- Tabs: opens on Guide; Steps is the second tab
        T.eq(p .. "a tab button per tab", #window.tabs.buttons, #window.TABS)
        T.eq(p .. "opens on the Guide tab", window.tab, "guide")
        T.eq(p .. "the card of the current step", W.rowTexts(window)[1], "Step 1 of 3 - craft (current step)")
        T.check(p .. "step navigation shown on the Guide tab", window.nav.shown and not window.searchBox.frame.shown)
        ui.fire(window.tabs.buttons[2], "OnClick")
        T.eq(p .. "a tab click switches", window.tab, "steps")
        T.check(p .. "navigation hidden on the Steps tab", not window.nav.shown)
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
    window:SelectTab("steps")

    -- Range
    local root = fakeui.openMenu(window.rangeDropdown.button)
    T.eq("range: current, four ranges, full path", #root.radios, 6)
    root.radios[6].setSelected()
    T.eq("range: full path chosen", window.rangeDropdown.button.overrideText, "Full path")
    T.eq("range: all stages listed", #W.rowTexts(window), 3)
    T.eq("range: footer drops the range part", window.footer1.text, "Whole path (excluding gaps): 99s (you pay 99s)")
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
    addon.db.profile.openWithProfession = false
    window:Update(W.path())
    T.check("turned off: not built, not shown", window.frame == nil)
    T.check("turned off: the path is still kept for the shopping list", window.path ~= nil)
    addon.db.profile.openWithProfession = true

    window:Update(W.path())
    window:SelectTab("steps")
    local frame = window.frame

    -- Notice
    window:ShowNotice("No recipe data for Engineering yet.")
    T.check("notice: shown", frame.shown and frame.showsNotice == true)
    T.eq("notice: one row with the text", W.rowTexts(window)[1], "No recipe data for Engineering yet.")
    T.check("notice: controls hidden", window.controls.shown == false and window.searchBox.frame.shown == false
        and window.nav.shown == false)
    T.eq("notice: plain title", frame.title.text, "LazyProf")
    T.eq("notice: no totals", window.footer1.text, "")
    window:Update(W.path())
    T.check("a path replaces the notice", window.controls.shown == true and frame.showsNotice == nil)

    -- The next recipe is unlearned and the profession window hides unlearned
    -- recipes: its learn step says so.
    env.hidden = true
    local unlearned = W.recipe(9, "Boots", 100, 150, 160, 170, { unlearned = true, sourceInfo = { type = "trainer", cost = 100 } })
    window:Update(W.path({ steps = { W.step(unlearned, 143, 160, 19, 2000) }, gaps = {}, totalCost = 2000 }))
    window:SelectTab("guide")
    local card = W.rowTexts(window)
    T.eq("the learn step is the current one", card[1], "Step 1 of 2 - learn (current step)")
    T.check("the filter hint is on its card", W.findRow(window, "hides unlearned recipes") ~= nil)
    env.hidden = false
    window:Update(W.path({ steps = { W.step(unlearned, 143, 160, 19, 2000) }, gaps = {}, totalCost = 2000 }))
    T.check("no hint when the filter shows unlearned recipes", W.findRow(window, "hides unlearned recipes") == nil)
    window:Update(W.path())
    window:SelectTab("steps")

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

T.section("guide tab", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    local alts = {
        { recipe = W.GLOVES, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = W.CAPE, score = 2, color = "orange", expectedSkillups = 1, craftCost = 300 },
    }
    local function path(extra)
        local p = W.path(extra)
        if p.steps[1] then p.steps[1].alternatives = alts end
        return p
    end
    window:Update(path())

    -- Path bar
    local bar = window.bar
    T.eq("bar: the done block and one segment per stage", #bar.shown, 4)
    T.eq("bar: end labels", bar.startLabel.text .. "-" .. bar.endLabel.text, "1-300")
    T.eq("bar: marker label", bar.markerLabel.text, "143")
    local barWidth = 420 - 28
    T.eq("bar: a segment's width follows its share of the path", bar.shown[2].width, (160 - 143) / 299 * barWidth)
    T.check("bar: the shown stage is marked", bar.shown[2].mark.shown == true and bar.shown[3].mark.shown == false)
    ui.fire(bar.shown[3], "OnEnter")
    T.check("bar: hover shows the stage", ui.tooltip:Text():find("40x Shirt", 1, true) ~= nil, ui.tooltip:Text())
    ui.fire(bar.shown[3], "OnClick")
    T.eq("bar: a click opens that stage on the Guide tab", W.rowTexts(window)[1], "Step 2 of 3 - craft")
    T.check("bar: the mark moves", bar.shown[3].mark.shown == true and bar.shown[2].mark.shown == false)
    ui.fire(bar.shown[1], "OnClick")
    T.eq("bar: the done block opens nothing", W.rowTexts(window)[1], "Step 2 of 3 - craft")

    -- Navigation
    T.check("nav: away from the current step, all three work",
        window.prevBtn.enabled and window.nextBtn.enabled and window.currentBtn.enabled)
    ui.fire(window.nextBtn, "OnClick")
    T.eq("nav: Next", W.rowTexts(window)[1], "Step 3 of 3 - gap")
    T.check("nav: no Next on the last step, no recipe on a gap", not window.nextBtn.enabled and not window.recipeBtn.enabled)
    ui.fire(window.prevBtn, "OnClick")
    T.eq("nav: Prev", W.rowTexts(window)[1], "Step 2 of 3 - craft")
    ui.fire(window.recipeBtn, "OnClick")
    T.eq("nav: Recipe details opens the shown step's recipe", env.details.recipe.name, "Shirt")
    ui.fire(window.currentBtn, "OnClick")
    T.eq("nav: Current step", W.rowTexts(window)[1], "Step 1 of 3 - craft (current step)")
    T.check("nav: on the current step, Current step and Prev are off", not window.currentBtn.enabled and not window.prevBtn.enabled)

    -- A browsed stage stays shown when a new path arrives.
    ui.fire(window.nextBtn, "OnClick")
    window:Update(path())
    T.eq("selection kept across a new path", W.rowTexts(window)[1], "Step 2 of 3 - craft")
    -- ...and follows the current step again once that stage is gone.
    window:Update(path({ currentSkill = 200, actualSkill = 200, steps = {}, totalCost = 0 }))
    T.eq("selection falls back to the current step", W.rowTexts(window)[1], "Step 1 of 1 - gap (current step)")
    window:Update(path())
    ui.fire(window.currentBtn, "OnClick")

    -- Use this: pin over the stage's range and plan again at once.
    local useRow = W.findRow(window, "Cape")
    T.check("an alternative row with a Use this button", useRow ~= nil and useRow.button.text == "Use this")
    local before = #env.recalcs
    ui.fire(useRow.button, "OnClick", "LeftButton")
    local pins = addon.CharStore:Profession("tailoring").pins
    T.check("use: a pin over the stage's exact range", #pins == 1 and pins[1].from == 143 and pins[1].to == 160 and pins[1].recipeId == 3)
    T.eq("use: planned again at once", env.recalcs[#env.recalcs], "recipe pinned")
    T.eq("use: once", #env.recalcs, before + 1)

    -- The planner answers with the pinned recipe in that range.
    local pinned = path()
    pinned.steps[1] = W.step(W.CAPE, 143, 150, 7, 2100, { alternatives = alts })
    pinned.steps[2] = W.step(W.CAPE, 150, 160, 12, 3600)
    pinned.totalCost = 13700
    window:Update(pinned)
    local rows = W.rowTexts(window)
    T.eq("use: the stage is shown under its new recipe", rows[2], "19x Cape | 143 to 160")
    local resetRow = W.findRow(window, "Pinned:")
    T.check("use: the pinned stage offers Reset", resetRow ~= nil and resetRow.button.text == "Reset")
    T.check("use: the planner's own choice is now an alternative", W.findRow(window, "Gloves") ~= nil)

    before = #env.recalcs
    ui.fire(resetRow.button, "OnClick", "LeftButton")
    T.eq("reset: the pin is gone", #addon.CharStore:Profession("tailoring").pins, 0)
    T.eq("reset: planned again at once", env.recalcs[#env.recalcs], "pin removed")
    T.eq("reset: once", #env.recalcs, before + 1)
    window:Update(path())
    T.eq("reset: the planner's recipe is back", W.rowTexts(window)[2], "19x Gloves | 143 to 160")
    T.check("reset: no pinned line", W.findRow(window, "Pinned:") == nil)

    -- Steps tab: the Guide button of a row opens that stage.
    window:SelectTab("steps")
    window.rangeSel = "all"
    window:Render()
    local shirt = W.findRow(window, "40x Shirt")
    ui.fire(shirt.button, "OnClick", "LeftButton")
    T.eq("steps: a row's Guide button switches to the Guide tab", window.tab, "guide")
    T.eq("steps: on that stage", W.rowTexts(window)[2], "40x Shirt | 160 to 200")

    -- The range does not cut the Guide tab: the next rows cross into the next range.
    window.rangeSel = nil
    ui.fire(window.currentBtn, "OnClick")
    rows = W.rowTexts(window)
    T.eq("guide: next rows reach past the current range", rows[#rows - 1], "160-200 | |cFF888888craft|r  40x Shirt | 80s")

    -- Show all
    local many = path()
    local list = {}
    for i = 1, 6 do
        list[i] = { recipe = W.recipe(20 + i, "Alt" .. i, 100, 150, 160, 170), score = i, color = "orange", expectedSkillups = 1, craftCost = 100 }
    end
    many.steps[1].alternatives = list
    many.prices = setmetatable({}, { __index = function() return 100 end })
    window:Update(many)
    local showAll = W.findRow(window, "Show all 6")
    T.check("alternatives: three shown, the rest behind Show all", showAll ~= nil and W.findRow(window, "Alt4") == nil)
    ui.fire(showAll, "OnClick", "LeftButton")
    T.check("alternatives: Show all expands in place", W.findRow(window, "Alt6") ~= nil and W.findRow(window, "Show fewer") ~= nil)
    ui.fire(window.nextBtn, "OnClick")
    ui.fire(window.prevBtn, "OnClick")
    T.check("alternatives: collapsed again after moving to another step", W.findRow(window, "Alt6") == nil)
end)

T.section("shopping tab", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    -- The planner's shopping list, as the window asks for it.
    local asked = {}
    local function row(itemId, name, need, have, toBuy, extra)
        local r = { itemId = itemId, name = name, icon = "icon", need = need, have = have, inBags = have, sources = {},
            toBuy = toBuy, unitPrice = 100, cost = toBuy * 100, craftable = false, crafted = false, firstUsedAtSkill = 1 }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    local missing
    addon.Pathfinder.CalculateMissingMaterials = function(_, steps, inventory, breakdown, prices)
        asked[#asked + 1] = { steps = steps, inventory = inventory, prices = prices }
        return missing
    end
    local function fresh()
        missing = {
            fromBank = { { itemId = 101, name = "Wool", icon = "icon", have = 40, missing = 40, purpose = "for bolts" } },
            fromMail = {}, fromAuctions = {}, fromGuildBank = {},
            fromAlts = { { itemId = 101, name = "Wool", icon = "icon", have = 20, missing = 20,
                characters = { { name = "Bankalt-Realm", count = 20 } } } },
            toCraft = {}, fromAH = {}, recipeCosts = 350,
            rows = {
                row(101, "Wool", 260, 100, 160),
                row(102, "Bolt", 55, 0, 0, { craftable = true, crafted = true, craftRecipeName = "Bolt of Wool", craftQuantity = 55,
                    children = { { itemId = 101, name = "Wool", need = 165 } } }),
                row(103, "Thread", 96, 12, 84, { isVendor = true, priceSource = "Vendor", craftable = false }),
                row(104, "Dye", 12, 12, 0),
                row(105, "Bar", 5, 0, 5, { craftable = true, choice = "buy" }),
                row(106, "Dust", 4, 0, 4, { unpriced = true, unitPrice = nil, cost = 0 }),
            },
            buyTotal = 16000 + 8400 + 500,
        }
    end
    fresh()
    window:Update(W.path())
    T.eq("the shopping list is not worked out for other tabs", #asked, 0)
    ui.fire(window.tabs.buttons[3], "OnClick")
    T.eq("shopping tab selected", window.tab, "shopping")
    T.eq("worked out for the shopping tab", #asked, 1)
    T.eq("from the stage quantities of the chosen range", asked[1].steps[1].quantity, 19)
    T.check("with the path's stock and prices", asked[1].inventory == window.path.inventory and asked[1].prices == window.path.prices)
    T.check("navigation and search hidden, the total strip shown",
        not window.nav.shown and not window.searchBox.frame.shown and window.shopStrip.shown)

    local rows = W.rowTexts(window)
    T.eq("collect first block", rows[1], "Collect first")
    T.eq("from bank, with its purpose", rows[2], "From bank | 40x Wool |cFF888888(for bolts)|r")
    T.eq("from alts, with the character", rows[3], "From alts | 20x Wool |cFF888888(Bankalt:20)|r")
    T.eq("table header", rows[5], "Reagent | Need,Have,Buy,Cost")
    T.eq("a reagent to buy", rows[6], "Wool | 260,100,160,1g 60s")
    T.eq("a crafted reagent: nothing to buy", rows[7], "Bolt | 55,0,-,")
    T.eq("its sub-reagent indented beneath", rows[8], "Wool | 165,,,")
    T.eq("a vendor reagent", rows[9], "Thread | 96,12,84,84s")
    T.eq("an owned reagent", rows[10], "Dye | 12,12,-,-")
    T.eq("a reagent with no price", rows[12], "Dust | 4,0,4,?")
    T.eq("vendor mark", W.findRow(window, "Thread").mark.text, "vendor")
    T.eq("crafted: the button says so", W.findRow(window, "Bolt").button.text, "I craft it")
    T.eq("bought by choice: the button says so", W.findRow(window, "Bar").button.text, "I buy it")
    T.check("no button on a reagent the character cannot make", not W.findRow(window, "Thread").button
        or W.findRow(window, "Thread").button.shown == false)
    T.eq("total under the table", window.shopTotal.text, "To buy: 2g 49s  |cFF888888+ 3s 50c recipes|r")

    -- Craft / buy choice: stored per character, redrawn at once, no new path.
    local recalcs = #env.recalcs
    ui.fire(W.findRow(window, "Bolt").button, "OnClick", "LeftButton")
    T.eq("click on a crafted reagent chooses buy", addon.CharStore:Get().craftChoices[102], "buy")
    ui.fire(W.findRow(window, "Bar").button, "OnClick", "LeftButton")
    T.eq("click on a bought reagent chooses craft", addon.CharStore:Get().craftChoices[105], "craft")
    ui.fire(W.findRow(window, "Bar").button, "OnClick", "RightButton")
    T.check("right-click goes back to automatic", addon.CharStore:Get().craftChoices[105] == nil)
    T.eq("the path is not planned again", #env.recalcs, recalcs)
    T.check("the list is worked out again", #asked > 1)

    -- Hide what I have
    ui.fire(W.findRow(window, "Thread"), "OnEnter")
    T.check("row tooltip: need, have and buy", ui.tooltip:Text():find("Need: 96 | Have: 12 | Buy: 84", 1, true) ~= nil, ui.tooltip:Text())
    window.hideOwnedBox.frame.checked = true
    ui.fire(window.hideOwnedBox.frame, "OnClick")
    T.check("hide what I have: owned rows go", W.findRow(window, "Dye") == nil)
    T.check("hide what I have: crafted rows stay", W.findRow(window, "Bolt") ~= nil)
    T.check("hide what I have: remembered for the character", addon.CharStore:Get().hideOwned == true)
    window.hideOwnedBox.frame.checked = false
    ui.fire(window.hideOwnedBox.frame, "OnClick")
    T.check("hide what I have: off again", W.findRow(window, "Dye") ~= nil)

    -- Range and margin reach the shopping list.
    local root = fakeui.openMenu(window.rangeDropdown.button)
    root.radios[6].setSelected()
    T.eq("full path: every craft stage's quantity", #asked[#asked].steps, 2)
    window.marginBox.frame.checked = true
    ui.fire(window.marginBox.frame, "OnClick")
    T.eq("margin: the larger counts go to the shopping list", asked[#asked].steps[1].quantity, 22)

    -- Nothing to buy
    missing = { fromBank = {}, fromMail = {}, fromAuctions = {}, fromGuildBank = {}, fromAlts = {}, toCraft = {}, fromAH = {},
        recipeCosts = 0, rows = { row(104, "Dye", 12, 12, 0) }, buyTotal = 0 }
    window:Render()
    T.eq("nothing to buy says so", W.rowTexts(window)[1], "Nothing left to buy.")
    T.eq("zero total", window.shopTotal.text, "To buy: 0c")
    missing.rows = {}
    window:Render()
    T.eq("no reagents at all", W.rowTexts(window)[1], "No reagents needed in this path.")

    -- A stock change redraws the list.
    fresh()
    local before = #asked
    window.path.inventory = { [101] = 1 }
    window:Refresh()
    T.eq("stock refresh works the list out again", #asked, before + 1)
end)

T.section("learn and rank steps", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    env.cap = 150
    local boots = W.recipe(9, "Boots", 150, 200, 210, 220, { unlearned = true, sourceInfo = { type = "vendor", cost = 1500 } })
    local function path()
        return W.path({
            steps = { W.step(W.GLOVES, 143, 150, 7, 700), W.step(W.GLOVES, 150, 152, 3, 300),
                      W.step(boots, 152, 225, 73, 73 * 100 + 1500), W.step(boots, 225, 300, 75, 7500) },
            gaps = {}, totalCost = 700 + 300 + 8800 + 7500, complete = true,
            prices = { [101] = 100, [109] = 100 },
        })
    end
    window:Update(path())
    T.eq("status shows the live cap", window.status.text, "Skill 143 / 150")

    window:SelectTab("steps")
    window.rangeSel = "all"
    window:Render()
    local rows = W.rowTexts(window)
    T.eq("steps: craft up to the cap", rows[1], "> 143-150 | |cFF888888craft|r  7x Gloves | 7s")
    T.eq("steps: the rank step at the cap", rows[2], "150 | |cFF888888train|r  Train the next rank before 150")
    T.eq("steps: the crossing fragment starts the next stage", rows[3], "150-152 | |cFF888888craft|r  3x Gloves | 3s")
    T.eq("steps: the learn step, with its fee", rows[4], "152 | |cFF888888learn|r  Boots - vendor | 15s")
    T.eq("steps: the craft stage costs its reagents only", rows[5], "152-225 | |cFF888888craft|r  73x Boots | 73s")
    T.eq("steps: the next cap", rows[6], "225 | |cFF888888train|r  Train the next rank before 225")
    T.eq("footer: fees stay in the totals", window.footer1.text, "Whole path: 1g 73s (you pay 1g 73s)")

    -- The bar gets a tick per rank still to train.
    local ticks = 0
    for _ in ipairs(window.bar.model.ticks) do ticks = ticks + 1 end
    T.eq("bar: a tick per rank step", ticks, 2)

    -- Rank card
    ui.fire(W.findRow(window, "Train the next rank before 150"), "OnClick", "LeftButton")
    T.eq("a rank row opens its card", window.tab, "guide")
    rows = W.rowTexts(window)
    T.eq("rank card header", rows[1], "Step 2 of 7 - train")
    T.eq("rank card title", rows[2], "Train the next rank | before 150")
    T.eq("rank card: the cap the client reports is called yours", rows[3],
        "Your cap is 150. Train the next rank at a Tailoring trainer before you reach 150.")
    T.check("rank card: no recipe to show", not window.recipeBtn.enabled)

    -- Learn card
    ui.fire(window.nextBtn, "OnClick")
    ui.fire(window.nextBtn, "OnClick")
    rows = W.rowTexts(window)
    T.eq("learn card header", rows[1], "Step 4 of 7 - learn")
    T.eq("learn card title", rows[2], "Learn Boots | at 152")
    T.eq("learn card: source kind", rows[3], "Sold by a vendor.")
    T.eq("learn card: fee", rows[4], "Cost: 15s")
    T.eq("learn card: required skill", rows[5], "Requires skill 150")
    T.check("learn card: recipe details offered", window.recipeBtn.enabled)
    ui.fire(window.list.rows[2], "OnClick", "LeftButton")
    T.eq("learn card: the title opens the recipe details", env.details.recipe.name, "Boots")

    -- A later cap is not called "your cap".
    ui.fire(window.nextBtn, "OnClick")
    ui.fire(window.nextBtn, "OnClick")
    rows = W.rowTexts(window)
    T.eq("later rank card", rows[3], "Skill cap 225: train the next rank at a Tailoring trainer before you reach 225.")

    -- Cap already at the top: no rank steps.
    env.cap = 300
    window:Update(path())
    window:SelectTab("steps")
    T.check("cap trained: no rank rows", W.findRow(window, "Train the next rank") == nil)
    -- Cap unknown: no rank steps either, and no cap in the status line.
    env.cap = nil
    window:Update(path())
    T.check("cap unknown: no rank rows", W.findRow(window, "Train the next rank") == nil)
    T.eq("cap unknown: status without a cap", window.status.text, "Skill 143")
end)

T.section("planning mode", function()
    local env = W.load("forever", { "Modules/UI/ProfessionBrowser.lua" })
    local window, ui, addon = env.window, env.ui, env.addon
    local function escapeCloses()
        for _, name in ipairs(UISpecialFrames) do
            if name == "LazyProfGuideWindow" then return true end
        end
        return false
    end
    local function anchoredTo(frame)
        local pt = window.frame.points[#window.frame.points]
        return pt and pt[2] == frame
    end

    -- Opened with no profession window: undocked, on any profession.
    env.open = false
    window:OpenPlanning("tailoring")
    local frame = window.frame
    T.check("planning: shown", frame ~= nil and frame.shown)
    T.eq("planning: mode", window.mode, "planning")
    T.check("planning: not docked to the profession window", anchoredTo(UIParent))
    T.check("planning: Escape closes it", escapeCloses())
    T.eq("planning: title", frame.title.text, "LazyProf - Tailoring")
    T.eq("planning: status of a profession not learned", window.status.text, "Not learned yet - planned from skill 1")
    T.check("planning: profession picker shown", window.planRow.shown)
    T.eq("planning: picker names the profession", window.professionDropdown.button.overrideText, "Tailoring")
    T.check("planning: no what-if for a profession not learned", not window.fromOneBox.frame.shown)
    T.eq("planning: the path is the planner's for that profession", env.planCalls[1].key, "tailoring")
    T.eq("planning: tabs work as when docked", W.rowTexts(window)[1], "Step 1 of 7 - train (current step)")

    -- The picker lists professions that have data and opens the chosen one.
    local root = fakeui.openMenu(window.professionDropdown.button)
    local names = {}
    for _, radio in ipairs(root.radios) do names[#names + 1] = radio.text end
    T.eq("picker: professions with recipe data, by name", table.concat(names, ","), "Alchemy,Tailoring")
    root.radios[1].setSelected()
    T.eq("picker: another profession is planned", env.planCalls[#env.planCalls].key, "alchemy")
    T.eq("picker: and shown", frame.title.text, "LazyProf - Alchemy")

    -- A profession the character has: planned from the real skill, what-if offered.
    env.playerSkill, env.playerCap = 143, 150
    window:OpenPlanning("tailoring")
    T.eq("learned: status with the cap the client reports", window.status.text, "Skill 143 / 150")
    T.check("learned: what-if offered, off", window.fromOneBox.frame.shown and not window.fromOneBox:GetChecked())
    window.fromOneBox.frame.checked = true
    ui.fire(window.fromOneBox.frame, "OnClick")
    T.check("what-if: remembered for the character and profession", addon.CharStore:Get().planFromOne.tailoring == true)
    T.check("what-if: planned again from 1", env.planCalls[#env.planCalls].opts.planFromOne == true)
    T.eq("what-if: status says so", window.status.text, "Skill 143 / 150 - planned from skill 1")
    window.fromOneBox.frame.checked = false
    ui.fire(window.fromOneBox.frame, "OnClick")
    T.check("what-if: off again", env.planCalls[#env.planCalls].opts.planFromOne == false)

    -- Header controls plan the shown profession, not the open one.
    local plans, recalcs = #env.planCalls, #env.recalcs
    window.targetInput.frame.focused = true
    window.targetInput.frame.text = "225"
    ui.fire(window.targetInput.frame, "OnEnterPressed")
    T.eq("target: planning is planned again", #env.planCalls, plans + 1)
    T.eq("target: the live planner is not asked", #env.recalcs, recalcs)
    ui.fire(window.strategyGroup.buttons.fastest, "OnClick")
    T.eq("strategy: planning is planned again", #env.planCalls, plans + 2)

    -- Its own saved spot.
    frame.left, frame.top = 500, 800
    ui.fire(frame, "OnDragStop")
    T.check("planning keeps its own saved spot", addon.db.profile.panelPositions.guidePlanning ~= nil
        and addon.db.profile.panelPositions.guide == nil)

    -- A profession window opens: the window docks; when it closes, planning is back.
    env.open = true
    window:OnProfessionOpened()
    window:Update(W.path({ profession = "Alchemy", professionKey = "alchemy" }))
    T.eq("dock: live mode", window.mode, "live")
    T.eq("dock: shows the open profession", frame.title.text, "LazyProf - Alchemy")
    T.check("dock: beside the profession window", anchoredTo(env.anchor))
    T.check("dock: Escape no longer closes it", not escapeCloses())
    T.check("dock: no profession picker", not window.planRow.shown)
    env.open = false
    window:OnProfessionClosed()
    T.eq("undock: back to planning", window.mode, "planning")
    T.eq("undock: on the profession it had", frame.title.text, "LazyProf - Tailoring")
    T.check("undock: shown, undocked, Escape closes again", frame.shown and escapeCloses())
    T.check("undock: at its own saved spot", frame.points[#frame.points][4] == 500)

    -- Planning opened on top of an open profession window stays put.
    env.open = true
    window:Update(W.path())
    T.eq("on top: a live path does not take the window", window.mode, "planning")
    T.check("on top: but is kept", window.livePath ~= nil)
    window:OnProfessionClosed()
    T.check("on top: closing the profession window leaves planning", frame.shown and window.mode == "planning")

    -- Closing planning.
    env.open = false
    ui.fire(frame.closeBtn, "OnClick")
    T.check("close button: hidden, no planning view left", not frame.shown and window.planning == nil)
    T.check("close button: Escape entry removed", not escapeCloses())
    T.check("closing planning closes its recipe details", env.calls[#env.calls] == "detailsHide")
    window:OpenPlanning("tailoring")
    T.check("reopened after a close", frame.shown)
    frame:Hide()   -- what Escape does
    T.check("Escape closes planning", window.planning == nil and window.mode ~= "planning")

    -- Closing planning while a profession window is open: the window is that
    -- window's again, closed until it is opened again.
    env.open = true
    window:Update(W.path())
    window:OpenPlanning("alchemy")
    ui.fire(frame.closeBtn, "OnClick")
    T.check("closed over an open profession window: hidden", not frame.shown and window.mode == "live")
    window:Update(W.path())
    T.check("and stays closed on the next live update", not frame.shown)
    env.shell:ResetClosed()
    window:Update(W.path())
    T.check("until the profession window is opened again", frame.shown and anchoredTo(env.anchor))
    window:OnProfessionClosed()
    T.check("no planning to return to: hidden", not frame.shown)

    -- Combat
    env.open = false
    window:OpenPlanning("tailoring")
    ui.event("PLAYER_REGEN_DISABLED")
    ui.combat = true
    T.check("combat: planning hides but is not closed", not frame.shown and window.planning ~= nil)
    T.check("combat: counts as shown for the panels it owns", window:IsPlanningShown())
    window:OpenPlanning("alchemy")
    T.eq("combat: cannot be opened on another profession", window.planning.profKey, "tailoring")
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("combat over: planning is back", frame.shown and window.mode == "planning")

    -- A profession with no recipe data.
    window:OpenPlanning("mining")
    T.eq("no data: says so", W.rowTexts(window)[1], "No recipe data for Mining yet.")
    T.check("no data: the picker stays usable", window.planRow.shown and window.controls.shown)
    T.check("no data: the path controls are hidden", not window.targetInput.frame.shown and not window.bar.frame.shown)
    window:OpenPlanning("tailoring")
    T.check("a profession with data brings them back", window.targetInput.frame.shown)

    -- A live recalculation plans the planning view again; a stock change reaches it.
    plans = #env.planCalls
    window:RefreshPlanning("setting changed")
    T.eq("refresh: planned again", #env.planCalls, plans + 1)
    T.check("the planning path is exposed for stock refreshes", window:PlanningPath() == window.path)

    -- "Open with the profession window" off: planning is not set aside.
    addon.db.profile.openWithProfession = false
    env.open = true
    window:OnProfessionOpened()
    window:Update(W.path())
    T.check("setting off: planning stays when a profession window opens", frame.shown and window.mode == "planning")
    addon.db.profile.openWithProfession = true
    ui.fire(frame.closeBtn, "OnClick")
    env.open = false
    window:OnProfessionClosed()

    -- The profession browser opens planning.
    addon.ProfessionBrowser:Initialize()
    local browserRow = ui.find(function(f) return f.ftype == "Button" and f.parent == addon.ProfessionBrowser.frame
        and f.scripts.OnClick ~= nil end)
    T.check("browser: has a clickable profession row", browserRow ~= nil)
    ui.fire(browserRow, "OnClick")
    T.check("browser: a click opens planning in the window", frame.shown and window.mode == "planning")
end)

T.section("visited trainers", function()
    local env = W.load("forever", { "Modules/Guide/TrainerMemory.lua" })
    local window, ui, addon = env.window, env.ui, env.addon
    env.cap = 150
    _G.CraftLib = { GetActiveProfile = function() return "FOREVER" end }
    _G.GetServerTime = function() return 1 end
    local boots = W.recipe(9, "Boots", 150, 200, 210, 220, { unlearned = true, sourceInfo = { type = "trainer", cost = 250, costSeen = true } })
    addon.Professions.registry = { tailoring = { name = "Tailoring", recipes = { boots, W.GLOVES } } }
    local function path()
        return W.path({
            steps = { W.step(W.GLOVES, 143, 150, 7, 700), W.step(boots, 150, 225, 75, 7750), W.step(boots, 225, 300, 75, 7500) },
            gaps = {}, totalCost = 15950, complete = true, prices = { [101] = 100, [109] = 100 },
        })
    end
    window:Update(path())
    window:SelectTab("steps")
    window.rangeSel = "all"
    window:Render()

    -- Nothing remembered: the cards name nobody.
    ui.fire(W.findRow(window, "Train the next rank before 150"), "OnClick", "LeftButton")
    T.check("rank card: no trainer named before any visit", W.findRow(window, "trainers you have visited") == nil)
    ui.fire(window.nextBtn, "OnClick")
    T.eq("learn card", W.rowTexts(window)[2], "Learn Boots | at 150")
    T.check("learn card: no trainer named before any visit", W.findRow(window, "Trainers you visited") == nil)
    T.check("a remembered fee says where it comes from", W.findRow(window, "Cost: 2s 50c (as charged at a trainer you visited)") ~= nil)

    -- Two visits: one trainer listed Boots, the other did not.
    local Memory = addon.TrainerMemory
    Memory:Record({ name = "Georgio Bolero", npcId = 1346, zone = "Stormwind City", mapId = 84, x = 0.53, y = 0.81, faction = "Alliance" },
        { { name = "Boots", cost = 250, state = "available" }, { name = "Gloves", cost = 10, state = "used" } })
    Memory:Record({ name = "Sellandus", npcId = 1103, zone = "Stormwind City", mapId = 84, x = 0.44, y = 0.77, faction = "Alliance" },
        { { name = "Gloves", cost = 10, state = "available" } })
    Memory:Record({ name = "Magar", npcId = 3363, zone = "Orgrimmar", mapId = 85, x = 0.6, y = 0.5, faction = "Horde" },
        { { name = "Boots", cost = 250, state = "available" } })
    window:Refresh()
    T.check("learn card: the label", W.findRow(window, "Trainers you visited that teach it:") ~= nil)
    T.check("learn card: the trainer that listed the recipe, with where the player stood",
        W.findRow(window, "Georgio Bolero - Stormwind City (53, 81)") ~= nil)
    T.check("learn card: a trainer that did not list it is not named", W.findRow(window, "Sellandus") == nil)
    T.check("learn card: the other faction's trainer is not named", W.findRow(window, "Magar") == nil)

    ui.fire(window.prevBtn, "OnClick")
    T.check("rank card: the label does not promise the rank",
        W.findRow(window, "Tailoring trainers you have visited (not every trainer teaches every rank):") ~= nil)
    T.check("rank card: both visited trainers of the faction", W.findRow(window, "Georgio Bolero") ~= nil
        and W.findRow(window, "Sellandus - Stormwind City (44, 77)") ~= nil and W.findRow(window, "Magar") == nil)

    -- The VANILLA profile never names a trainer on a learn step.
    _G.CraftLib = { GetActiveProfile = function() return "VANILLA" end }
    Memory:Record({ name = "Era Trainer", npcId = 5, zone = "Ironforge", faction = "Alliance" },
        { { name = "Boots", cost = 250, state = "available" } })
    window:Refresh()
    ui.fire(window.nextBtn, "OnClick")
    T.check("VANILLA: the learn card names no trainer", W.findRow(window, "Trainers you visited") == nil
        and W.findRow(window, "Era Trainer") == nil)
    _G.CraftLib = nil

    -- A visit refreshes a shown window.
    _G.CraftLib = { GetActiveProfile = function() return "FOREVER" end }
    addon.Client.TrainerInfo = function()
        return { name = "New Trainer", npcId = 9, zone = "Darnassus", faction = "Alliance" }
    end
    addon.Client.TrainerServices = function() return { { name = "Boots", cost = 250, state = "available" } } end
    Memory:Capture()
    T.check("a trainer visit shows up in the open window at once", W.findRow(window, "New Trainer - Darnassus") ~= nil)
    addon.Client.TrainerInfo = function() return nil end
    T.check("no profession trainer open: capture does nothing", pcall(Memory.Capture, Memory))
    _G.CraftLib = nil
end)

T.finish()
