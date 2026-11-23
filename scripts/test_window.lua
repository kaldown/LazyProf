-- scripts/test_window.lua
--
-- The LazyProf window: built once, docked beside the profession window; its
-- header (status, More options, target box and slider, receipt), the Path
-- and Shopping tabs, the notice state, the closed state, combat hide and
-- restore, planning mode. Driven on both client families with the fake UI.
--
-- Run from the addon root:  lua5.1 scripts/test_window.lua

package.path = "./?.lua;" .. package.path
local W = require("scripts.lib.window")
local fakeui = require("scripts.lib.fakeui")
local T = require("scripts.lib.check").new()

-- How far below the window's top a header block (or the list) starts.
local function top(frame)
    return -(frame.points[1][5] or 0)
end

-- The header's blocks, top down.
local BLOCKS = { "strip", "planRow", "targetRow", "receipt", "searchRow", "shopRow" }

-- The names of the blocks shown, in order - when each starts where the one
-- above it ends and the list starts below the last. Otherwise what is wrong.
local function stacked(window)
    local names, y = {}, nil
    for _, name in ipairs(BLOCKS) do
        local block = window[name]
        if block.shown then
            if y and top(block) ~= y then
                return name .. " starts at " .. top(block) .. ", the block above ends at " .. y
            end
            y = top(block) + block.height
            names[#names + 1] = name
        end
    end
    if y and top(window.list.frame) < y then
        return "the list starts at " .. top(window.list.frame) .. ", the header ends at " .. y
    end
    return table.concat(names, ",")
end

-- A run's row in the path list, as "name | skill,crafts,cost".
local function runRow(window, name)
    for _, row in ipairs(window.list.rows) do
        local d = row.desc
        if d.kind == "cols" and d.layout == "path" and d.text == name then
            return d.text .. " | " .. table.concat(d.cols, ",")
        end
    end
end

local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do
        if v == value then n = n + 1 end
    end
    return n
end

local function escapeCloses()
    for _, name in ipairs(UISpecialFrames) do
        if name == "LazyProfGuideWindow" then return true end
    end
    return false
end

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
        T.eq(p .. "it cannot be made narrower than 380 or lower than 440",
            frame.resizeBounds[1] .. "x" .. frame.resizeBounds[2], "380x440")

        if family == "forever" then
            T.eq(p .. "native frame art", frame.NineSlice and frame.NineSlice.layout, "ButtonFrameTemplateNoPortrait")
            T.check(p .. "controls sit above the border art", window.body.level > frame.NineSlice.level)
            T.check(p .. "no backdrop", frame.backdrop == nil)
        else
            T.check(p .. "tooltip-style backdrop", frame.backdrop ~= nil)
        end

        -- Header: status, the options switch, the target, the receipt
        T.eq(p .. "title", frame.title.text, "LazyProf - Tailoring")
        T.eq(p .. "status line", window.status.text, "Skill 143 / 300")
        T.eq(p .. "the options switch", window.moreBtn.text, "More options")
        T.check(p .. "the options strip is closed", not window.strip.shown)
        T.eq(p .. "target label", window.targetLabel.text, "Level to")
        T.eq(p .. "target box shows the target", window.targetInput.frame.text, "300")
        local slider = window.slider.frame
        T.eq(p .. "a slider", slider.ftype, "Slider")
        if family == "forever" then
            T.eq(p .. "the client's plain slider", slider.template, "MinimalSliderTemplate")
        else
            T.check(p .. "a plain slider frame", slider.template == nil)
        end
        T.eq(p .. "slider: from the real skill to the last cap", slider.min .. "-" .. slider.max, "143-300")
        T.eq(p .. "slider: at the target", slider.value, 300)
        T.eq(p .. "slider: end labels", window.sliderMin.text .. " " .. window.sliderMax.text, "143 300")
        local receipt = W.receiptTexts(window)
        T.eq(p .. "receipt: what is spent", receipt[1], "You spend | 0c | excluding gaps")
        T.eq(p .. "receipt: nothing else", #receipt, 1)
        T.eq(p .. "the header's blocks", stacked(window), "targetRow,receipt")

        -- Two tabs; the path list first
        T.eq(p .. "two tabs", #window.TABS, 2)
        T.eq(p .. "a tab button per tab", #window.tabs.buttons, 2)
        T.eq(p .. "their labels", window.tabs.buttons[1].text .. "," .. window.tabs.buttons[2].text, "Path,Shopping")
        T.eq(p .. "opens on the Path tab", window.tab, "path")
        local rows = W.rowTexts(window)
        T.eq(p .. "path: column titles", rows[1], "Recipes | skill,crafts,cost")
        T.eq(p .. "path: the run the player is on", rows[2], "> Gloves | 143-160,19,19s")
        T.eq(p .. "path: open, with its reagents", rows[3] .. " / " .. rows[4], "Reagent | Need,Have,Buy,Cost / MatGloves | 19,0,19,19s")
        T.eq(p .. "path: the next run", rows[6], "Shirt | 160-200,40,80s")
        T.eq(p .. "path: the gap", rows[7], "No recipe for 200-300: train elsewhere or missing data")
        T.eq(p .. "path: nothing more", #rows, 7)
        T.check(p .. "no search box without More options", not window.searchRow.shown)
        ui.fire(window.tabs.buttons[2], "OnClick")
        T.eq(p .. "a tab click switches", window.tab, "shopping")
        T.eq(p .. "shopping: the list", W.rowTexts(window)[1], "No reagents needed in this path.")
        T.check(p .. "no hide-owned box without More options", not window.shopRow.shown)
        ui.fire(window.tabs.buttons[1], "OnClick")
        T.eq(p .. "and back", window.tab, "path")

        -- The list ends above the resize grip in the bottom right corner, so
        -- the grip does not sit on the list's scroll-down button.
        local grip = window.resizeGrip
        local listBottom = window.list.frame.points[2]
        T.check(p .. "the grip is in the bottom right corner", grip.points[1][1] == "BOTTOMRIGHT" and grip.points[1][2] == 0
            and grip.points[1][3] == 0)
        T.check(p .. "the list is anchored to the bottom", listBottom[1] == "BOTTOMRIGHT")
        T.check(p .. "the list ends above the grip", listBottom[5] >= grip.height, tostring(listBottom[5]) .. " under " .. tostring(grip.height))
        T.check(p .. "the grip is no smaller than its icon", grip.height >= grip.icon.height and grip.width >= grip.icon.width)

        -- What the window no longer has
        T.check(p .. "no footer", window.footer1 == nil and window.footer2 == nil)
        T.check(p .. "no step navigation", window.nav == nil and window.prevBtn == nil and window.nextBtn == nil)
        T.check(p .. "no range dropdown", window.rangeDropdown == nil and window.rangeLabel == nil
            and ui.count(function(f) return f.name ~= nil and f.name:find("Range", 1, true) ~= nil end) == 0)
        T.check(p .. "no path bar", window.bar == nil)
        T.check(p .. "no total strip under the shopping list", window.shopStrip == nil and window.shopTotal == nil)

        -- The same on both families: moving the slider's handle plans
        -- nothing, letting it go plans once; the switch opens the strip.
        ui.fire(slider, "OnMouseDown", "LeftButton")
        ui.slide(slider, 200)
        T.eq(p .. "drag: the box follows", window.targetInput.frame.text, "200")
        T.eq(p .. "drag: nothing planned", #env.recalcs, 0)
        ui.fire(slider, "OnMouseUp", "LeftButton")
        T.eq(p .. "release: planned once", #env.recalcs, 1)
        T.eq(p .. "release: with the new target", env.targetArgs[2], 200)
        ui.fire(window.moreBtn, "OnClick")
        T.check(p .. "More options opens the strip", window.strip.shown and window.moreBtn.text == "Fewer options")
        local selling = family == "forever" and window.sellingDropdown.button.overrideText or window.sellingDropdown.frame.ddText
        T.eq(p .. "selling shows the setting", selling, "Vendor")
        T.eq(p .. "strategy shown selected", window.strategyGroup:GetSelected(), "cheapest")
        ui.fire(window.moreBtn, "OnClick")
        T.check(p .. "and closes it again", not window.strip.shown)

        -- A second update builds nothing new.
        window:Update(W.path())
        local made = #ui.frames
        window:Update(W.path())
        T.eq(p .. "a second update reuses every frame", #ui.frames, made)
    end)
end

T.section("receipt", function()
    local env = W.load("forever")
    local window = env.window
    env.account = { missing = { rows = {}, recipeRows = {}, buyTotal = 131000, recipeCosts = 12000 },
        reagents = 131000, recipes = 12000, spend = 143000, sale = 19000, net = 124000 }
    env.stockSaves = 31500
    local sale = { mode = "vendor", values = {}, sources = {} }
    window:Update(W.path({ sale = sale, complete = true, gaps = {} }))
    local lines = W.receiptTexts(window)
    T.eq("spend, with its two parts", lines[1], "You spend | 14g 30s | reagents 13g 10s + recipes 1g 20s")
    T.eq("what comes back", lines[2], "Back from selling | -1g 90s | crafts sold to a vendor")
    T.eq("the net, with what the stock saves", lines[3], "Net cost | 12g 40s | your own stock saves 3g 15s")
    T.eq("three lines", #lines, 3)
    local rows = window.receiptRows
    T.eq("money that comes back is green", rows[2].amount.color[1], 0.4)
    T.eq("amounts are right-aligned", rows[1].amount.justifyH, "RIGHT")
    T.check("notes wrap instead of being cut", rows[1].note.wordWrap == true)
    T.check("labels and amounts are never cut", rows[1].label.wordWrap == false and rows[1].amount.wordWrap == false)

    -- The amounts sit in one column, the notes in one column after it.
    local function right(region) local pt = region.points[#region.points]; return pt[4] end
    local function left(region) local pt = region.points[#region.points]; return pt[4] end
    T.check("amounts share a right edge", right(rows[1].amount) == right(rows[2].amount) and right(rows[2].amount) == right(rows[3].amount))
    T.check("notes share a left edge", left(rows[1].note) == left(rows[3].note))
    T.check("the notes start after the amounts", left(rows[1].note) > right(rows[1].amount))
    T.check("the amount column has room for an amount to the copper",
        right(rows[1].amount) - left(rows[1].label) >= rows[2].label:GetStringWidth() + 84)
    T.eq("a note is as wide as what is left of the window", rows[1].note.width, 420 - 12 - left(rows[1].note))

    -- An amount wider than the column makes the column wider: it is never
    -- drawn over the label, and the notes move right with it.
    local noteLeft, amountRight = left(rows[1].note), right(rows[1].amount)
    env.account.spend = 123456789012
    window:Refresh()
    T.eq("fixture: an amount wider than 84", rows[1].amount.text, "12345678g 90s 12c")
    local wide = rows[1].amount:GetStringWidth()
    T.check("fixture: by the test's measure", wide > 84, wide)
    T.eq("a wide amount: the column grows to hold it", right(rows[1].amount), amountRight + (wide - 84))
    T.check("a wide amount: it starts right of the widest label",
        right(rows[1].amount) - wide >= left(rows[2].label) + rows[2].label:GetStringWidth())
    T.eq("a wide amount: the notes move right with it", left(rows[1].note), noteLeft + (wide - 84))
    T.check("a wide amount: every amount still shares the right edge", right(rows[2].amount) == right(rows[1].amount))
    env.account.spend = 143000
    window:Refresh()
    T.eq("back to an ordinary amount: the column is 84 again", right(rows[1].amount), amountRight)

    -- A note that does not fit wraps under the note column: the block grows
    -- and the list moves down with it.
    local height, listTop = window.receipt.height, top(window.list.frame)
    rows[1].note.stringHeight = 40
    window:Layout()
    T.eq("a wrapped note makes the receipt taller", window.receipt.height, height + 26)
    T.eq("and the list starts lower", top(window.list.frame), listTop + 26)
    T.eq("the next line moves down too", top(rows[2].label) - top(rows[1].label), 42)
    rows[1].note.stringHeight = nil
    window:Layout()
    T.eq("back to one line each", window.receipt.height, height)

    -- At the minimum width the notes are narrower, never negative.
    window.frame.width = 380
    window:Layout()
    T.check("minimum width: the notes still have room", rows[1].note.width >= 60)
    T.eq("minimum width: blocks still stacked", stacked(window), "targetRow,receipt")
    window.frame.width = 420

    -- Lines that are only a note span the window.
    env.account = { missing = { rows = {}, recipeRows = {}, buyTotal = 5000, recipeCosts = 0 },
        reagents = 5000, recipes = 0, spend = 5000, sale = 0, net = 5000 }
    env.addon.db.profile.useMargin = true
    env.priceLines = { { text = "Prices: TSM 2", r = 0.6, g = 0.6, b = 0.6 },
        { text = "1 reagent has no price at all - scan the auction house (needs TSM or Auctionator).", r = 1, g = 0.5, b = 0, problem = true } }
    window:Update(W.path({ complete = true, gaps = {} }))
    lines = W.receiptTexts(window)
    T.eq("no sale counted: one amount", lines[1], "You spend | 50s")
    T.eq("what the stock saves gets its own line", lines[2], "Your own stock saves 3g 15s")
    T.eq("spare crafts are named", lines[3], "Includes 15% spare crafts")
    T.eq("a price problem is said in the receipt", lines[4],
        "1 reagent has no price at all - scan the auction house (needs TSM or Auctionator).")
    T.eq("in orange", rows[4].note.color[2], 0.5)
    T.eq("a note-only line starts at the left edge", left(rows[2].note), left(rows[1].label))
    T.eq("and is as wide as the window allows", rows[4].note.width, 420 - 24)
    T.check("its label and amount are hidden", rows[2].label.shown == false and rows[2].amount.shown == false)
    env.addon.db.profile.useMargin = false

    -- Nothing left to plan: no receipt, the target stays.
    window:Update(W.path({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 225, currentSkill = 225, targetSkill = 225 }))
    T.eq("target reached: no receipt lines", #W.receiptTexts(window), 0)
    T.check("target reached: the receipt takes no room", not window.receipt.shown)
    T.eq("target reached: the list says so", W.rowTexts(window)[1], "Target reached: skill 225, target 225.")
    T.check("target reached: the slider stays, so the target can be raised",
        window.targetRow.shown and window.slider.frame.enabled == true)
    T.eq("target reached: slider from the skill to the cap", window.slider.frame.min .. "-" .. window.slider.frame.max, "225-300")
end)

T.section("target", function()
    local env = W.load("forever")
    local window, ui = env.window, env.ui
    window:Update(W.path())
    local box, slider = window.targetInput.frame, window.slider
    local handle = slider.frame

    -- The box
    box.focused = true
    box.text = "225"
    ui.fire(box, "OnEnterPressed")
    T.eq("box: stored through the planner", table.concat({ env.targetArgs[1], env.targetArgs[2], env.targetArgs[3] }, ","), "tailoring,225,143")
    T.eq("box: a new path is asked for", env.recalcs[1], "target changed")
    T.eq("box: once", #env.recalcs, 1)
    T.eq("box: the slider follows", slider:GetValue(), 225)
    box.focused = true
    box.text = "100"
    ui.fire(box, "OnEnterPressed")
    T.eq("box: the corrected value is shown", box.text, "144")
    T.eq("box: and on the slider", slider:GetValue(), 144)
    box.focused = true
    box.text = "300"
    ui.fire(box, "OnEnterPressed")
    local before = #env.recalcs
    window:Update(W.path())
    box.focused = true
    box.text = "999"
    ui.fire(box, "OnEnterPressed")
    T.eq("box: a value that changes nothing does not recalculate", #env.recalcs, before)
    T.eq("box: and shows the cap", box.text, "300")

    -- The slider: dragging only rewrites the number in the box.
    window:Update(W.path())
    local recalcs, stored = #env.recalcs, count(env.calls, "target")
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 250)
    T.eq("drag: the box shows the number", box.text, "250")
    ui.slide(handle, 225)
    T.eq("drag: and follows", box.text, "225")
    T.eq("drag: nothing is planned", #env.recalcs, recalcs)
    T.eq("drag: nothing is stored", count(env.calls, "target"), stored)

    -- A redraw while the handle is held (a bag update, even a new path)
    -- leaves the slider and the box alone.
    window:Refresh()
    T.eq("held: a redraw leaves the handle", slider:GetValue(), 225)
    T.eq("held: and the box", box.text, "225")
    window:Update(W.path())
    T.eq("held: a new path leaves the handle too", slider:GetValue(), 225)
    T.eq("held: and the box", box.text, "225")
    T.eq("held: still nothing planned", #env.recalcs, recalcs)

    -- Letting go commits once.
    ui.fire(handle, "OnMouseUp", "LeftButton")
    T.eq("release: stored through the planner", table.concat({ env.targetArgs[1], env.targetArgs[2], env.targetArgs[3] }, ","), "tailoring,225,143")
    T.eq("release: stored once", count(env.calls, "target"), stored + 1)
    T.eq("release: planned once", #env.recalcs, recalcs + 1)
    T.eq("release: because the target changed", env.recalcs[#env.recalcs], "target changed")
    ui.fire(handle, "OnMouseUp", "LeftButton")
    T.eq("release: a second mouse-up does nothing", #env.recalcs, recalcs + 1)

    -- The planner answers with the new target.
    window:Update(W.path({ targetSkill = 225 }))
    T.eq("new path: the slider shows its target", slider:GetValue(), 225)
    T.eq("new path: so does the box", box.text, "225")

    -- Let go where it was: nothing to plan.
    recalcs = #env.recalcs
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 260)
    ui.slide(handle, 225)
    ui.fire(handle, "OnMouseUp", "LeftButton")
    T.eq("dragged away and back: nothing planned", #env.recalcs, recalcs)

    -- The left end is the real skill; the target cannot be below skill + 1.
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 143)
    T.eq("left end: the box shows it while dragging", box.text, "143")
    ui.fire(handle, "OnMouseUp", "LeftButton")
    T.eq("left end: the target in force is shown", box.text, "144")
    T.eq("left end: the handle goes there", slider:GetValue(), 144)
    T.eq("left end: planned once", #env.recalcs, recalcs + 1)
    -- ...also when the client still calls the handle dragged while its
    -- mouse-up script runs.
    window:Update(W.path({ targetSkill = 225 }))
    ui.fire(handle, "OnMouseDown", "LeftButton")
    handle.draggingThumb = true
    ui.slide(handle, 143)
    ui.fire(handle, "OnMouseUp", "LeftButton")
    handle.draggingThumb = false
    T.eq("left end, still called dragged inside the release: corrected all the same",
        box.text .. " " .. slider:GetValue(), "144 144")
    -- ...and when the box still has the keyboard from an earlier click: the
    -- slider was used last, so the box shows what it committed.
    window:Update(W.path({ targetSkill = 225 }))
    box.focused = true
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 143)
    ui.fire(handle, "OnMouseUp", "LeftButton")
    T.eq("left end with the box focused: corrected all the same", box.text .. " " .. slider:GetValue(), "144 144")
    box.focused = false

    -- The box is not overwritten while the player types in it.
    window:Update(W.path())
    box.focused = true
    box.text = "22"
    window:Refresh()
    T.eq("typing: a redraw leaves the typed digits", box.text, "22")
    recalcs, stored = #env.recalcs, count(env.calls, "target")
    box:ClearFocus()
    T.eq("typing: leaving the box puts the planned target back", box.text, "300")
    T.eq("typing: and stores nothing", count(env.calls, "target"), stored)
    T.eq("typing: and plans nothing", #env.recalcs, recalcs)

    -- Hidden while the handle is held (combat): the hold is gone, nothing is
    -- planned, and the next redraw puts the handle back.
    recalcs = #env.recalcs
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 200)
    ui.event("PLAYER_REGEN_DISABLED")
    ui.combat = true
    T.check("combat while held: the window hides", not window.frame.shown)
    T.check("combat while held: the hold is over", slider:IsHeld() == false)
    T.eq("combat while held: the handle is back at the target", slider:GetValue(), 300)
    T.eq("combat while held: and the box", box.text, "300")
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("combat over: the window is back", window.frame.shown)
    ui.fire(handle, "OnMouseUp", "LeftButton")
    T.eq("combat while held: nothing was planned, a late mouse-up included", #env.recalcs, recalcs)
    T.eq("combat over: still at the target", slider:GetValue() .. " " .. box.text, "300 300")

    -- No room to move: one point below the cap, and at the cap.
    window:Update(W.path({ actualSkill = 299, currentSkill = 299, steps = { W.step(W.SHIRT, 299, 300, 2, 400) }, gaps = {}, complete = true }))
    T.check("one point below the cap: the slider is off", handle.enabled == false)
    T.check("one point below the cap: still a real range", handle.min < handle.max)
    T.eq("one point below the cap: end labels", window.sliderMin.text .. " " .. window.sliderMax.text, "299 300")
    window:Update(W.path({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 }))
    T.check("at the cap: the slider is off", handle.enabled == false)
    T.check("at the cap: still a real range", handle.min < handle.max)
    T.eq("at the cap: end labels", window.sliderMin.text .. " " .. window.sliderMax.text, "300 300")
    T.eq("at the cap: the list says so", W.rowTexts(window)[1], "Nothing left: Tailoring is at its cap of 300.")
    window:Update(W.path())
    T.check("room again: the slider is on", handle.enabled == true)
end)

-- The target when things do not go by the book: a release the slider does
-- not hear, the window hidden and shown in the middle of a drag, half-typed
-- digits. The planner answers each stored target with its path at once, as
-- it does in the game.
T.section("target: unheard releases, shown again, half-typed", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    local stored = {}
    local setTarget = addon.Pathfinder.SetTargetSkill
    addon.Pathfinder.SetTargetSkill = function(self, key, value, ...)
        local target = setTarget(self, key, value, ...)
        stored[#stored + 1] = target
        return target
    end
    -- Each plan brings a path with the stored target and a cost of its own.
    addon.Recalculate = function(_, reason)
        env.recalcs[#env.recalcs + 1] = reason
        local target = addon.CharStore:Profession("tailoring").target or 300
        env.account = { missing = { rows = {}, recipeRows = {}, buyTotal = target * 100, recipeCosts = 0 },
            reagents = target * 100, recipes = 0, spend = target * 100, sale = 0, net = target * 100 }
        window:Update(W.path({ targetSkill = target, complete = true, gaps = {} }))
    end
    local function fresh()
        addon.CharStore:Profession("tailoring").target = nil
        env.account = nil
        stored, env.recalcs = {}, {}
        ui.release()
        window:Update(W.path({ complete = true, gaps = {} }))
    end
    fresh()
    local box, slider = window.targetInput.frame, window.slider
    local handle = slider.frame
    local function shown()
        return slider:GetValue() .. " " .. box.text .. " " .. tostring(W.receiptTexts(window)[1])
    end

    -- The button is let go outside the slider, which hears no mouse-up: the
    -- next redraw finds the hold over and commits it, once.
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 200)
    window:Refresh()
    T.eq("button down: a redraw leaves the drag alone", slider:GetValue() .. " " .. box.text .. " " .. #stored, "200 200 0")
    ui.release("LeftButton")
    T.eq("let go unheard: nothing yet", #stored, 0)
    window:Refresh()
    T.eq("let go unheard, then a redraw: stored once", table.concat(stored, ","), "200")
    T.eq("let go unheard: planned once", #env.recalcs, 1)
    T.check("let go unheard: no longer held", slider:IsHeld() == false)
    -- The redraw that found it draws the path the commit brought, not the
    -- one it started with.
    T.eq("let go unheard: handle, box and receipt show the new path", shown(), "200 200 You spend | 2g")
    T.eq("let go unheard: the slider's range is the new path's", window.target.value, 200)
    window:Refresh()
    ui.fire(handle, "OnMouseUp", "LeftButton")
    T.eq("let go unheard: nothing more on a second redraw or a late mouse-up", #stored .. " " .. #env.recalcs, "1 1")

    -- The mouse-up does arrive: one commit, a redraw adds none.
    fresh()
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 210)
    ui.fire(handle, "OnMouseUp", "LeftButton")
    window:Refresh()
    T.eq("mouse-up heard: stored once", table.concat(stored, ","), "210")
    T.eq("mouse-up heard: planned once", #env.recalcs, 1)
    T.eq("mouse-up heard: shown", shown(), "210 210 You spend | 2g 10s")

    -- A target typed after an unheard release wins: the drag came first and
    -- is committed first.
    fresh()
    ui.fire(handle, "OnMouseDown", "LeftButton")
    ui.slide(handle, 200)
    ui.release()
    box.focused = true
    box.text = "250"
    ui.fire(box, "OnEnterPressed")
    T.eq("unheard release, then a typed target: the drag first, then the typed one", table.concat(stored, ","), "200,250")
    T.eq("the typed target is the one in force", addon.CharStore:Profession("tailoring").target, 250)
    T.eq("and the one shown", shown(), "250 250 You spend | 2g 50s")
    T.check("the slider is free again", slider:IsHeld() == false)

    -- Hidden in the middle of a drag while the client still calls the handle
    -- dragged (so nothing can be put back yet); shown again: the handle and
    -- the box are at the planned target.
    fresh()
    ui.fire(handle, "OnMouseDown", "LeftButton")
    handle.draggingThumb = true
    ui.slide(handle, 180)
    ui.event("PLAYER_REGEN_DISABLED")
    ui.combat = true
    T.check("hidden mid-drag", not window.frame.shown)
    handle.draggingThumb = false
    ui.release()
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.check("shown again", window.frame.shown)
    T.eq("shown again: the handle and the box are back at the planned target", slider:GetValue() .. " " .. box.text, "300 300")
    T.eq("shown again: nothing was stored or planned", #stored .. " " .. #env.recalcs, "0 0")

    -- Half-typed digits are never a target: only Enter commits.
    fresh()
    box.focused = true
    box.text = "2"
    ui.event("PLAYER_REGEN_DISABLED")
    ui.combat = true
    box:ClearFocus()   -- a hidden box loses the keyboard
    ui.combat = false
    ui.event("PLAYER_REGEN_ENABLED")
    T.eq("half-typed, then combat: nothing stored", #stored, 0)
    T.eq("half-typed, then combat: the box shows the planned target again", box.text, "300")
    box.focused = true
    box.text = "25"
    ui.fire(box, "OnEscapePressed")
    T.eq("Escape: nothing stored, the planned target back", #stored .. " " .. box.text, "0 300")
    box.focused = true
    box.text = "250"
    ui.fire(box, "OnEnterPressed")
    T.eq("Enter: stored", table.concat(stored, ","), "250")
    T.eq("Enter: shown", shown(), "250 250 You spend | 2g 50s")

    -- A new path arrives while the box has the keyboard: the digits being
    -- typed stay, but the box knows the target that is now planned.
    fresh()
    box.focused = true
    box.text = "30"
    addon.CharStore:Profession("tailoring").target = 200
    window:Update(W.path({ targetSkill = 200, complete = true, gaps = {} }))
    T.eq("typing over a new path: the digits stay", box.text, "30")
    box.text = "200"
    ui.fire(box, "OnEnterPressed")
    T.eq("typing the target already planned stores nothing", #stored, 0)
    T.eq("and shows it", box.text, "200")
    box.focused = true
    box.text = "300"
    ui.fire(box, "OnEnterPressed")
    T.eq("typing the old target after that is a change", table.concat(stored, ","), "300")
    box.focused = true
    box.text = "31"
    addon.CharStore:Profession("tailoring").target = 220
    window:Update(W.path({ targetSkill = 220, complete = true, gaps = {} }))
    box:ClearFocus()
    T.eq("leaving the box after a new path: that path's target", box.text, "220")
end)

T.section("more options", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    local profile = addon.db.profile
    window:Update(W.path())

    -- Off by default: only how far, what it costs and the list.
    T.check("off by default", profile.showAdvanced == false and not window.strip.shown)
    T.check("off: no strategy buttons, spare crafts, selling or price line on screen",
        not window.strategyGroup.frame:IsVisible() and not window.marginBox.frame:IsVisible()
        and not window.sellingDropdown.frame:IsVisible() and not window.pricesBtn:IsVisible())
    T.check("off: no search box", not window.searchBox.frame:IsVisible())
    T.check("off: the view says so", window.view.advanced == false)

    ui.fire(window.moreBtn, "OnClick")
    T.check("on: remembered in the settings", profile.showAdvanced == true)
    T.check("on: the strip is shown", window.strip.shown)
    T.eq("on: the switch says how to go back", window.moreBtn.text, "Fewer options")
    T.check("on: the view says so", window.view.advanced == true)
    T.eq("on: the header's blocks", stacked(window), "strip,targetRow,receipt,searchRow")
    T.check("on: everything in the strip is on screen",
        window.strategyGroup.frame:IsVisible() and window.marginBox.frame:IsVisible()
        and window.sellingDropdown.frame:IsVisible() and window.pricesBtn:IsVisible())
    T.eq("on: an opened run gets its advanced line", W.rowTexts(window)[3], "orange until 150, then yellow; 1s per craft")

    -- The price line lives in the strip only.
    T.eq("price line", window.prices.text, "Prices: TSM 2")
    T.check("price line: part of the strip", window.pricesBtn.parent == window.strip)
    env.priceSummary = { total = 2, stale = 1, unpriced = 0, loading = 0 }
    env.priceLines = { { text = "Prices: Auctionator 2", r = 0.6, g = 0.6, b = 0.6 },
        { text = "Auctionator prices up to 5 days old", r = 1, g = 0.5, b = 0, problem = true } }
    window:Update(W.path())
    T.eq("price line: orange when stale", window.prices.color[2], 0.5)
    ui.fire(window.pricesBtn, "OnEnter")
    T.check("price line: tooltip lists the lines", ui.tooltip:Text():find("5 days old", 1, true) ~= nil)
    T.eq("a price problem is also said in the receipt", W.receiptTexts(window)[2], "Auctionator prices up to 5 days old")
    env.priceSummary, env.priceLines = nil, nil
    window:Update(W.path())

    -- Strategy
    T.eq("strategy shown selected", window.strategyGroup:GetSelected(), "cheapest")
    local before = #env.recalcs
    ui.fire(window.strategyGroup.buttons.fastest, "OnClick")
    T.eq("strategy: the setting changes", profile.strategy, "fastest")
    T.eq("strategy: a new path is asked for", env.recalcs[#env.recalcs], "strategy change")
    T.eq("strategy: once", #env.recalcs, before + 1)

    -- Spare crafts
    T.eq("spare crafts: the label carries the percentage", window.marginBox.label.text, "Spare crafts (15%)")
    T.check("spare crafts: unticked", window.marginBox:GetChecked() == false)
    before = #env.recalcs
    window.marginBox.frame.checked = true
    ui.fire(window.marginBox.frame, "OnClick")
    T.check("spare crafts: the setting changes", profile.useMargin == true)
    T.eq("spare crafts: no recalculation (recipes do not change)", #env.recalcs, before)
    T.eq("spare crafts: rows show the larger count", W.rowTexts(window)[2], "> Gloves | 143-160,22,22s")
    T.eq("spare crafts: the receipt says so", W.receiptTexts(window)[2], "Includes 15% spare crafts")
    profile.marginPercent = 20
    window:Refresh()
    T.eq("spare crafts: the label follows the setting", window.marginBox.label.text, "Spare crafts (20%)")
    profile.marginPercent = 15
    window.marginBox.frame.checked = false
    ui.fire(window.marginBox.frame, "OnClick")

    -- Selling
    T.eq("selling: shows the setting", window.sellingDropdown.button.overrideText, "Vendor")
    local root = fakeui.openMenu(window.sellingDropdown.button)
    local names, selected = {}, {}
    for _, radio in ipairs(root.radios) do
        names[#names + 1] = radio.text
        if radio.isSelected() then selected[#selected + 1] = radio.text end
    end
    T.eq("selling: three choices", table.concat(names, ","), "Vendor,Auction house,Do not count")
    T.eq("selling: the one in force is marked", table.concat(selected, ","), "Vendor")
    before = #env.recalcs
    root.radios[3].setSelected()
    T.eq("selling: the setting changes", profile.saleValueMode, "none")
    T.eq("selling: the dropdown says so", window.sellingDropdown.button.overrideText, "Do not count")
    T.eq("selling: a new path is asked for", env.recalcs[#env.recalcs], "sale value change")
    T.eq("selling: once", #env.recalcs, before + 1)
    fakeui.openMenu(window.sellingDropdown.button).radios[3].setSelected()
    T.eq("selling: picking the same again plans nothing", #env.recalcs, before + 1)
    fakeui.openMenu(window.sellingDropdown.button).radios[2].setSelected()
    T.eq("selling: auction house", profile.saleValueMode, "auction")

    -- Search: with More options, on the Path tab only.
    T.check("search box shown on the Path tab", window.searchRow.shown and window.searchBox.frame:IsVisible())
    window.searchBox.frame.text = "CA"
    ui.fire(window.searchBox.frame, "OnTextChanged", true)
    local rows = W.rowTexts(window)
    T.eq("search: results replace the list", rows[1], "Cape | Requires 100")
    T.eq("search: count line", rows[2], "1 result")
    ui.fire(window.list.rows[1], "OnClick", "LeftButton")
    T.eq("search: a result opens the recipe details", env.details and env.details.recipe.name, "Cape")
    ui.fire(window.tabs.buttons[2], "OnClick")
    T.check("search: no box on the Shopping tab", not window.searchRow.shown)
    T.check("hide-owned box shown on the Shopping tab", window.shopRow.shown and window.hideOwnedBox.frame:IsVisible())
    T.eq("shopping: the header's blocks", stacked(window), "strip,targetRow,receipt,shopRow")
    T.eq("shopping: the search does not reach its list", W.rowTexts(window)[1], "No reagents needed in this path.")
    ui.fire(window.tabs.buttons[1], "OnClick")
    T.eq("search: kept when coming back", W.rowTexts(window)[1], "Cape | Requires 100")

    -- Turned off with a search typed: the box is hidden, so the search must
    -- not act.
    ui.fire(window.moreBtn, "OnClick")
    T.check("off again: remembered", profile.showAdvanced == false)
    T.eq("off again: the switch", window.moreBtn.text, "More options")
    T.check("off again: strip and search box gone", not window.strip.shown and not window.searchRow.shown)
    T.eq("off again: the path is listed, not the search results", W.rowTexts(window)[1], "Recipes | skill,crafts,cost")
    T.eq("off again: the header's blocks", stacked(window), "targetRow,receipt")
    ui.fire(window.moreBtn, "OnClick")
    T.eq("on again: the search is back with its box", W.rowTexts(window)[1], "Cape | Requires 100")
    ui.fire(window.searchBox.clear, "OnClick")
    T.eq("search: clearing brings the path back", W.rowTexts(window)[1], "Recipes | skill,crafts,cost")

    -- The search belongs to the profession.
    window.searchBox.frame.text = "sh"
    ui.fire(window.searchBox.frame, "OnTextChanged", true)
    T.eq("search: typed for tailoring", W.rowTexts(window)[1], "Shirt | Requires 150")
    window:Update(W.path({ profession = "Alchemy", professionKey = "alchemy" }))
    T.eq("another profession: its own, empty search", window.searchBox:GetText(), "")
    T.eq("another profession: its path", W.rowTexts(window)[1], "Recipes | skill,crafts,cost")
    T.eq("another profession: title", window.frame.title.text, "LazyProf - Alchemy")
    window:Update(W.path())
    T.eq("back: the search typed for it", window.searchBox:GetText(), "sh")
    T.eq("back: and its results", W.rowTexts(window)[1], "Shirt | Requires 150")

    -- The setting is read when a window is built.
    local env2 = W.load("forever")
    env2.addon.db.profile.showAdvanced = true
    env2.window:Update(W.path())
    T.check("a new window opens with the options it was left with",
        env2.window.strip.shown and env2.window.moreBtn.text == "Fewer options")
end)

-- What More options shows depends on where the window is and what it has to
-- show; the boxes say what is saved.
T.section("more options: what shows where, and what is ticked", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    local profile = addon.db.profile
    profile.showAdvanced = true

    -- Docked: no "Plan from skill 1", which is a what-if of planning.
    window:Update(W.path())
    T.check("docked, More options on: the strip is there", window.strip.shown and window.strategyGroup.frame:IsVisible())
    T.check("docked: no \"Plan from skill 1\"", not window.fromOneBox.frame:IsVisible())

    -- A profession without recipe data: its notice, and nothing of the
    -- options, although they are switched on.
    window:ShowNotice("No recipe data for Engineering yet.")
    T.eq("notice with More options on: the notice", W.rowTexts(window)[1], "No recipe data for Engineering yet.")
    T.check("notice with More options on: no strip, no search, no hide-owned box, no switch",
        not window.strip.shown and not window.searchRow.shown and not window.shopRow.shown and not window.moreBtn.shown)
    T.eq("notice with More options on: no header block at all", stacked(window), "")
    ui.fire(window.tabs.buttons[2], "OnClick")
    T.check("notice on the Shopping tab: the same", not window.strip.shown and not window.shopRow.shown)
    ui.fire(window.tabs.buttons[1], "OnClick")

    -- The boxes are ticked from what is saved, each time the window is drawn.
    profile.useMargin = true
    addon.CharStore:Get().hideOwned = true
    window:Update(W.path())
    T.check("spare crafts: ticked from the setting", window.marginBox:GetChecked() == true)
    T.check("hide what I have: ticked from the character's choice", window.hideOwnedBox:GetChecked() == true)
    profile.useMargin = false
    addon.CharStore:Get().hideOwned = nil
    window:Refresh()
    T.check("spare crafts: unticked when the setting is off", window.marginBox:GetChecked() == false)
    T.check("hide what I have: unticked when the choice is gone", window.hideOwnedBox:GetChecked() == false)

    -- Planning: the what-if is offered, ticked from the plan it shows.
    env.open = false
    env.playerSkill, env.playerCap = 143, 150
    addon.CharStore:Get().planFromOne = { tailoring = true }
    window:OpenPlanning("tailoring")
    T.check("planning a profession the character has: \"Plan from skill 1\" is there", window.fromOneBox.frame:IsVisible())
    T.check("ticked, as that plan is from skill 1", window.fromOneBox:GetChecked() == true)
    addon.CharStore:Get().planFromOne = nil
    window:OpenPlanning("tailoring")
    T.check("unticked for a plan from the real skill", window.fromOneBox:GetChecked() == false)
    window:OpenPlanning("mining")
    T.eq("planning without recipe data, More options on: only the profession picker", stacked(window), "planRow")
    T.check("and no switch", not window.moreBtn.shown)

    -- A setting that is one for every path, changed in planning while a
    -- profession window is open: that profession is planned again as well.
    env.open = true
    addon.Professions.active = "tailoring"
    window:Update(W.path())             -- the open profession's path: kept, planning stays
    window:OpenPlanning("alchemy")
    local recalcs, plans = #env.recalcs, #env.planCalls
    ui.fire(window.strategyGroup.buttons.fastest, "OnClick")
    T.eq("strategy in planning, a profession window open: the open profession is planned again", #env.recalcs, recalcs + 1)
    T.eq("with the reason", env.recalcs[#env.recalcs], "strategy change")
    fakeui.openMenu(window.sellingDropdown.button).radios[3].setSelected()
    T.eq("selling in planning, a profession window open: the same", #env.recalcs, recalcs + 2)
    T.eq("with its reason", env.recalcs[#env.recalcs], "sale value change")
    T.eq("planning itself is left to that recalculation", #env.planCalls, plans)
    -- No profession window: only planning is planned again.
    env.open = false
    recalcs, plans = #env.recalcs, #env.planCalls
    ui.fire(window.strategyGroup.buttons.cheapest, "OnClick")
    fakeui.openMenu(window.sellingDropdown.button).radios[1].setSelected()
    T.eq("no profession window: the live planner is not asked", #env.recalcs, recalcs)
    T.eq("no profession window: planning is planned again, once each", #env.planCalls, plans + 2)
end)

-- The window is laid out again when it is shown: what was measured while it
-- was hidden may not hold on screen.
T.section("shown again: laid out and drawn again", function()
    local env = W.load("forever")
    local window, ui = env.window, env.ui
    env.account = { missing = { rows = {}, recipeRows = {}, buyTotal = 100, recipeCosts = 50 },
        reagents = 100, recipes = 50, spend = 150, sale = 0, net = 150 }
    window:Update(W.path({ complete = true, gaps = {} }))
    local frame = window.frame
    local height, listTop = window.receipt.height, top(window.list.frame)
    local draws = 0
    local render = window.list.Render
    window.list.Render = function(...)
        draws = draws + 1
        return render(...)
    end
    frame:Hide()
    -- On screen the note turns out to need three lines.
    window.receiptRows[1].note.stringHeight = 40
    T.eq("hidden: nothing is laid out", window.receipt.height, height)
    frame:Show()
    T.eq("shown: the receipt is measured again", window.receipt.height, height + 26)
    T.eq("shown: the list starts where the header now ends", top(window.list.frame), listTop + 26)
    T.eq("shown: the list is drawn again", draws, 1)
    frame:Show()
    T.eq("already shown: nothing is done twice", draws, 1)
    window.list.Render = render
end)

T.section("path tab", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    local VEST = W.recipe(4, "Vest", 150, 200, 210, 220)
    local alts = {
        { recipe = W.GLOVES, score = 1, color = "orange", expectedSkillups = 1, craftCost = 100 },
        { recipe = W.CAPE, score = 2, color = "orange", expectedSkillups = 1, craftCost = 300 },
    }
    local shirtAlts = {
        { recipe = W.SHIRT, score = 1, color = "orange", expectedSkillups = 1, craftCost = 200 },
        { recipe = VEST, score = 2, color = "orange", expectedSkillups = 1, craftCost = 200 },
    }
    local function path(extra)
        local p = W.path(extra)
        p.prices = { [101] = 100, [102] = 200, [103] = 300, [104] = 200 }
        if p.steps[1] then p.steps[1].alternatives = alts end
        if p.steps[3] then p.steps[3].alternatives = shirtAlts end
        return p
    end
    window:Update(path())

    -- The run the player is on is open until it is closed.
    T.check("the current run is open by default", W.findRow(window, "Other recipes for 143-160") ~= nil)
    T.check("nothing is stored for that", next(window.expanded) == nil)
    local made = #W.rowTexts(window)
    ui.fire(W.findRow(window, "> Gloves"), "OnClick", "LeftButton")
    T.check("a click closes it", W.findRow(window, "Other recipes for 143-160") == nil and #W.rowTexts(window) < made)
    window:Update(path())
    T.check("closed: kept over a new path", W.findRow(window, "Other recipes for 143-160") == nil)
    -- A skill-up moves the run's start; it is still the same run.
    window:Update(path({ currentSkill = 150, actualSkill = 150,
        steps = { W.step(W.GLOVES, 150, 160, 12, 1200, { alternatives = alts }), W.step(W.SHIRT, 160, 200, 40, 8000) } }))
    T.eq("closed: the run after a skill-up", W.rowTexts(window)[2], "> Gloves | 150-160,12,12s")
    T.check("closed: kept after the skill-up", W.findRow(window, "Other recipes") == nil)
    window:Update(path())
    ui.fire(W.findRow(window, "> Gloves"), "OnClick", "LeftButton")
    T.check("a second click opens it again", W.findRow(window, "Other recipes for 143-160") ~= nil)

    -- Any other run: a click opens it, another closes it.
    T.check("another run is closed by default", W.findRow(window, "MatShirt") == nil)
    ui.fire(W.findRow(window, "Shirt"), "OnClick", "LeftButton")
    T.check("a click opens it in place", W.findRow(window, "MatShirt") ~= nil)
    window:Refresh()
    T.check("open: kept over a redraw", W.findRow(window, "MatShirt") ~= nil)
    window:Update(path())
    T.check("open: kept over a new path", W.findRow(window, "MatShirt") ~= nil)

    -- What is open belongs to the profession.
    window:Update(path({ profession = "Alchemy", professionKey = "alchemy" }))
    T.check("another profession starts with its own rows closed", W.findRow(window, "MatShirt") == nil)
    window:Update(path())
    T.check("back: the row is open as it was left", W.findRow(window, "MatShirt") ~= nil)
    ui.fire(W.findRow(window, "Shirt"), "OnClick", "LeftButton")
    T.check("a second click closes it", W.findRow(window, "MatShirt") == nil)

    -- A closed run offers its closest alternative under its row.
    local inline = W.findRow(window, "or: Vest")
    T.check("the closest alternative is offered under the closed run", inline ~= nil and inline.desc.sub == true)
    T.eq("with a Use button", inline and inline.button.text, "Use")
    T.eq("drawn as a sub-line", inline and inline.height, 16)
    ui.fire(W.findRow(window, "Shirt"), "OnClick", "LeftButton")
    T.check("not while the run is open: the same recipe is listed inside", W.findRow(window, "or: Vest") == nil)
    ui.fire(W.findRow(window, "Shirt"), "OnClick", "LeftButton")

    -- Recipe details from an opened run.
    ui.fire(W.findButton(window, "Recipe details").button, "OnClick", "LeftButton")
    T.eq("recipe details of the opened run", env.details and env.details.recipe.name, "Gloves")

    -- Use: pin the recipe over the run's range and plan again at once.
    local useRow = W.findRow(window, "Cape")
    T.check("an alternative of the opened run with a Use button", useRow ~= nil and useRow.button.text == "Use")
    local before = #env.recalcs
    ui.fire(useRow.button, "OnClick", "LeftButton")
    local pins = addon.CharStore:Profession("tailoring").pins
    T.check("use: a pin over the run's exact range", #pins == 1 and pins[1].from == 143 and pins[1].to == 160 and pins[1].recipeId == 3)
    T.eq("use: planned again at once", env.recalcs[#env.recalcs], "recipe pinned")
    T.eq("use: once", #env.recalcs, before + 1)

    -- The planner answers with the pinned recipe in that range.
    local pinned = path()
    pinned.steps[1] = W.step(W.CAPE, 143, 150, 7, 2100, { alternatives = alts })
    pinned.steps[2] = W.step(W.CAPE, 150, 160, 12, 3600)
    pinned.totalCost = 13700
    window:Update(pinned)
    T.eq("use: the run is listed under its new recipe", W.rowTexts(window)[2], "> Cape | 143-160,19,57s")
    local resetRow = W.findRow(window, "Your choice")
    T.check("use: the pinned run offers Reset", resetRow ~= nil and resetRow.button.text == "Reset")
    T.check("use: the planner's own choice is now an alternative", W.findRow(window, "Gloves") ~= nil)

    before = #env.recalcs
    ui.fire(resetRow.button, "OnClick", "LeftButton")
    T.eq("reset: the pin is gone", #addon.CharStore:Profession("tailoring").pins, 0)
    T.eq("reset: planned again at once", env.recalcs[#env.recalcs], "pin removed")
    T.eq("reset: once", #env.recalcs, before + 1)
    window:Update(path())
    T.eq("reset: the planner's recipe is back", W.rowTexts(window)[2], "> Gloves | 143-160,19,19s")
    T.check("reset: no pinned line", W.findRow(window, "Your choice") == nil)

    -- Use from an opened run that is not the current one: it stays open
    -- under its new recipe.
    local vested = path()
    vested.steps[3] = W.step(VEST, 160, 200, 40, 8000, { alternatives = shirtAlts })
    ui.fire(W.findRow(window, "Shirt"), "OnClick", "LeftButton")
    local vestRow = W.findRow(window, "Vest")
    T.check("an opened run lists its alternatives", vestRow ~= nil and vestRow.desc.sub ~= true and vestRow.button.text == "Use")
    before = #env.recalcs
    ui.fire(vestRow.button, "OnClick", "LeftButton")
    pins = addon.CharStore:Profession("tailoring").pins
    T.check("use in an opened run: a pin over that run's range",
        #pins == 1 and pins[1].from == 160 and pins[1].to == 200 and pins[1].recipeId == 4)
    T.eq("use in an opened run: planned once", #env.recalcs, before + 1)
    window:Update(vested)
    T.eq("the run under its new recipe", runRow(window, "Vest"), "Vest | 160-200,40,80s")
    T.check("it is still open", W.findRow(window, "MatVest") ~= nil)
    ui.fire(W.findRow(window, "Your choice").button, "OnClick", "LeftButton")
    T.eq("reset there removes that pin", #addon.CharStore:Profession("tailoring").pins, 0)

    -- Use from the line under a closed run: the run stays closed.
    window:Update(path())
    T.check("the planner's recipe is back, open as it was", W.findRow(window, "MatShirt") ~= nil)
    ui.fire(W.findRow(window, "Shirt"), "OnClick", "LeftButton")
    ui.fire(W.findRow(window, "or: Vest").button, "OnClick", "LeftButton")
    T.eq("use under a closed run: a pin", #addon.CharStore:Profession("tailoring").pins, 1)
    window:Update(vested)
    T.check("use under a closed run: the run is listed", W.findRow(window, "Vest") ~= nil)
    T.check("use under a closed run: it stays closed", W.findRow(window, "MatVest") == nil)
    addon.Pins.RemoveAt(addon.CharStore:Profession("tailoring").pins, 160)

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
    T.check("alternatives: three listed, the rest behind Show all", showAll ~= nil and W.findRow(window, "Alt4") == nil)
    T.eq("alternatives: Recipe details on the same line", showAll and showAll.button.text, "Recipe details")
    ui.fire(showAll, "OnClick", "LeftButton")
    T.check("alternatives: Show all lists every one in place", W.findRow(window, "Alt6") ~= nil and W.findRow(window, "Show fewer") ~= nil)
    window:Update(many)
    T.check("alternatives: kept over a new path", W.findRow(window, "Alt6") ~= nil)
    ui.fire(W.findRow(window, "Show fewer"), "OnClick", "LeftButton")
    T.check("alternatives: Show fewer", W.findRow(window, "Alt6") == nil and W.findRow(window, "Show all 6") ~= nil)

    -- Stock: a redraw from the stored path takes it off.
    window:Update(path())
    window.path.inventory = { [101] = 19 }
    window:Refresh()
    T.eq("refresh: stock is taken off the run's cost", W.rowTexts(window)[2], "> Gloves | 143-160,19,0c")
end)

T.section("shopping tab", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    local function row(itemId, name, need, have, toBuy, extra)
        local r = { itemId = itemId, name = name, icon = "icon", need = need, have = have, inBags = have, sources = {},
            toBuy = toBuy, unitPrice = 100, cost = toBuy * 100, craftable = false, crafted = false, firstUsedAtSkill = 1 }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    -- The account of the whole path, as the planner works it out.
    local missing
    local function account()
        env.account = { missing = missing, reagents = missing.buyTotal, recipes = missing.recipeCosts,
            spend = missing.buyTotal + missing.recipeCosts, sale = 0, net = missing.buyTotal + missing.recipeCosts }
    end
    local function fresh()
        missing = {
            fromBank = { { itemId = 101, name = "Wool", icon = "icon", have = 40, missing = 40, purpose = "for bolts" } },
            fromMail = {}, fromAuctions = {}, fromGuildBank = {},
            fromAlts = { { itemId = 101, name = "Wool", icon = "icon", have = 20, missing = 20,
                characters = { { name = "Bankalt-Realm", count = 20 } } } },
            toCraft = {}, fromAH = {}, recipeCosts = 350,
            recipeRows = { { recipe = W.CAPE, name = "Cape", cost = 350, sourceInfo = { type = "vendor", cost = 350 } } },
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
        account()
    end
    fresh()
    window:Update(W.path())
    ui.fire(window.tabs.buttons[2], "OnClick")
    T.eq("shopping tab selected", window.tab, "shopping")
    local call = env.accountCalls[#env.accountCalls]
    T.eq("the list is the whole path's: every craft run", #call.steps, 2)
    T.eq("from the runs' quantities", call.steps[1].quantity, 19)
    T.check("with the path's stock and prices", call.inventory == window.path.inventory and call.prices == window.path.prices)
    T.check("the view's list is the account's", window.view.missing == missing)

    local rows = W.rowTexts(window)
    T.eq("collect first block", rows[1], "Collect first")
    T.eq("from bank, with its purpose", rows[2], "From bank | 40x Wool |cFF888888(for bolts)|r")
    T.eq("from alts, with the character", rows[3], "From alts | 20x Wool |cFF888888(Bankalt:20)|r")
    T.eq("table header", rows[5], "Reagent | Need,Have,Buy,Cost")
    T.eq("to buy, the dearest first", rows[6], "Wool | 260,100,160,1g 60s")
    T.eq("a vendor reagent", rows[7], "Thread | 96,12,84,84s")
    T.eq("the cheapest of those to buy", rows[8], "Bar | 5,0,5,5s")
    T.eq("a reagent with no price is last of them", rows[9], "Dust | 4,0,4,?")
    T.eq("then a crafted reagent: nothing to buy", rows[10], "Bolt | 55,0,-,")
    T.eq("its sub-reagent indented beneath", rows[11], "Wool | 165,,,")
    T.eq("then an owned reagent", rows[12], "Dye | 12,12,-,-")
    T.eq("the reagents total in the list", rows[13], "Reagents to buy | ,,,2g 49s")
    T.eq("the recipes to learn", rows[15], "Recipes to learn")
    T.eq("a recipe with where it comes from and its price", rows[16], "Cape - vendor | ,,,3s 50c")
    T.eq("the recipes total", rows[17], "Recipes | ,,,3s 50c")
    T.eq("vendor mark", W.findRow(window, "Thread").mark.text, "vendor")

    -- The receipt above it is the list added up.
    local receipt = W.receiptTexts(window)
    T.eq("receipt: the two totals of the list", receipt[1], "You spend | 2g 52s 50c | reagents 2g 49s + recipes 3s 50c (excluding gaps)")
    T.eq("receipt: a reagent without a price is said", receipt[2], "1 reagent on the list has no price - the amounts leave it out.")

    -- The craft / buy buttons and the hide-owned filter are advanced controls:
    -- without More options neither acts.
    local function hasButton(name)
        local button = W.findRow(window, name).button
        return button ~= nil and button.shown ~= false
    end
    T.check("no craft / buy button without More options", not hasButton("Bolt") and not hasButton("Bar"))
    T.check("no hide-owned box either", not window.shopRow.shown)
    addon.CharStore:Get().hideOwned = true
    window:Refresh()
    T.check("hide what I have does not act then", W.findRow(window, "Dye") ~= nil)
    addon.CharStore:Get().hideOwned = nil
    ui.fire(window.moreBtn, "OnClick")
    T.check("More options: the hide-owned box is there", window.shopRow.shown and window.hideOwnedBox.frame:IsVisible())
    T.eq("crafted: the button says so", W.findRow(window, "Bolt").button.text, "I craft it")
    T.eq("bought by choice: the button says so", W.findRow(window, "Bar").button.text, "I buy it")
    T.check("no button on a reagent the character cannot make", not hasButton("Thread"))

    -- Craft / buy choice: stored per character, redrawn at once, no new path.
    local recalcs, accounts = #env.recalcs, #env.accountCalls
    ui.fire(W.findRow(window, "Bolt").button, "OnClick", "LeftButton")
    T.eq("click on a crafted reagent chooses buy", addon.CharStore:Get().craftChoices[102], "buy")
    ui.fire(W.findRow(window, "Bar").button, "OnClick", "LeftButton")
    T.eq("click on a bought reagent chooses craft", addon.CharStore:Get().craftChoices[105], "craft")
    ui.fire(W.findRow(window, "Bar").button, "OnClick", "RightButton")
    T.check("right-click goes back to automatic", addon.CharStore:Get().craftChoices[105] == nil)
    T.eq("the path is not planned again", #env.recalcs, recalcs)
    T.eq("the list and the receipt are worked out again each time", #env.accountCalls, accounts + 3)

    -- Hide what I have
    ui.fire(W.findRow(window, "Thread"), "OnEnter")
    T.check("row tooltip: need, have and buy", ui.tooltip:Text():find("Need: 96 | Have: 12 | Buy: 84", 1, true) ~= nil, ui.tooltip:Text())
    window.hideOwnedBox.frame.checked = true
    ui.fire(window.hideOwnedBox.frame, "OnClick")
    T.check("hide what I have: owned rows go", W.findRow(window, "Dye") == nil)
    T.check("hide what I have: crafted rows stay", W.findRow(window, "Bolt") ~= nil)
    T.check("hide what I have: remembered for the character", addon.CharStore:Get().hideOwned == true)
    ui.fire(window.moreBtn, "OnClick")
    T.check("More options off: the filter stops acting with its box", W.findRow(window, "Dye") ~= nil)
    ui.fire(window.moreBtn, "OnClick")
    T.check("More options on: the saved choice is back", W.findRow(window, "Dye") == nil and window.hideOwnedBox:GetChecked())
    window.hideOwnedBox.frame.checked = false
    ui.fire(window.hideOwnedBox.frame, "OnClick")
    T.check("hide what I have: off again", W.findRow(window, "Dye") ~= nil)

    -- Spare crafts reach the list.
    addon.db.profile.useMargin = true
    window:Refresh()
    T.eq("spare crafts: the larger counts go to the list", env.accountCalls[#env.accountCalls].steps[1].quantity, 22)
    addon.db.profile.useMargin = false

    -- Nothing to buy
    missing = { fromBank = {}, fromMail = {}, fromAuctions = {}, fromGuildBank = {}, fromAlts = {}, toCraft = {}, fromAH = {},
        recipeCosts = 0, recipeRows = {}, rows = { row(104, "Dye", 12, 12, 0) }, buyTotal = 0 }
    account()
    window:Render()
    T.eq("no reagent left to buy says so", W.rowTexts(window)[1], "No reagents left to buy.")
    T.eq("and the receipt is at nothing", W.receiptTexts(window)[1], "You spend | 0c | excluding gaps")
    missing.rows = {}
    window:Render()
    T.eq("no reagents at all", W.rowTexts(window)[1], "No reagents needed in this path.")

    -- A stock change redraws the list.
    fresh()
    local before = #env.accountCalls
    window.path.inventory = { [101] = 1 }
    window:Refresh()
    T.eq("stock refresh works the list out again", #env.accountCalls, before + 1)

    -- The merchant panel buys from the whole path's list.
    env.stock, env.stockSources = { [101] = 7 }, { [101] = { bags = 7 } }
    env.stockMeta = { remembered = true, bankSeenAt = 5, alts = {} }
    local merchantRows, name = window:MerchantRows()
    T.check("merchant rows: the stock's age is refreshed with the stock", window.shoppingPath.stockMeta == env.stockMeta)
    env.stockMeta = nil
    T.check("merchant rows: the whole path's shopping rows", merchantRows == missing.rows)
    T.eq("merchant rows: named after the profession", name, "Tailoring")
    T.eq("merchant rows: every craft run", #env.accountCalls[#env.accountCalls].steps, 2)
    T.check("merchant rows: from the stock as it is now", env.accountCalls[#env.accountCalls].inventory == env.stock)
end)

-- The receipt is built from the shopping list of the whole path, so every
-- view carries the account of it (what is spent, what comes back, the net).
T.section("the view carries the account", function()
    local env = W.load("forever")
    local window, addon = env.window, env.addon

    -- The merchant panel's list needs no frame, and there is none before a
    -- path was shown.
    T.check("no path shown yet: no merchant rows", window:MerchantRows() == nil)
    window.mode = "live"
    window:SetPath(W.path())
    local early, earlyName = window:MerchantRows()
    T.check("a path was taken: its rows, with no frame built", type(early) == "table" and earlyName == "Tailoring" and window.frame == nil)
    window:SetPath(nil)
    window.mode = nil

    env.account = { missing = { rows = {}, recipeRows = {}, buyTotal = 5000, recipeCosts = 300 },
        reagents = 5000, recipes = 300, spend = 5300, sale = 450, net = 4850 }
    env.stockSaves = 1200
    env.saleLoading = 2
    local sale = { mode = "vendor", values = { [1] = 45 }, sources = { [1] = "vendor" }, rank = {}, loading = 5, loadingItems = {} }
    local path = W.path({ sale = sale, inventory = { [101] = 3 }, sourceBreakdown = { [101] = { bags = 3 } } })
    window:Update(path)

    local before, savings = #env.accountCalls, #env.savingCalls
    window:Refresh()
    T.eq("worked out once per redraw", #env.accountCalls, before + 1)
    T.eq("and what the stock saves once", #env.savingCalls, savings + 1)
    local view, call, saving = window.view, env.accountCalls[#env.accountCalls], env.savingCalls[#env.savingCalls]
    T.eq("from every craft run of the path", #call.steps, 2)
    T.eq("with the runs' quantities", call.steps[1].quantity, 19)
    T.check("with the path's stock, where it is, its prices and what its crafts sell for",
        call.inventory == path.inventory and call.breakdown == path.sourceBreakdown
        and call.prices == path.prices and call.saleValues == sale.values)
    T.eq("the view carries it", view.account.spend, 5300)
    T.eq("the net with it", view.account.net, 4850)
    T.eq("and what the owned stock saves", view.account.stockSaves, 1200)
    T.check("its shopping list is the view's", view.missing == view.account.missing)
    T.check("the saving is asked for the same steps, prices and amount",
        saving.steps == call.steps and saving.prices == path.prices and saving.spend == 5300)
    T.check("the path's sale values are on the view", view.sale == sale)
    T.eq("with how many are still loading now, not when the path was built", view.saleLoading, 2)
    T.eq("more options are off by default", view.advanced, false)
    addon.db.profile.showAdvanced = true
    window:Refresh()
    T.eq("more options follow the setting", window.view.advanced, true)
    addon.db.profile.showAdvanced = false
    T.check("no range is left on the view", view.bracket == nil and view.rangeStages == nil and view.rangeLabel == nil
        and view.selectedStage == nil)

    addon.db.profile.useMargin = true
    window:Refresh()
    T.eq("margin: the larger counts are accounted", env.accountCalls[#env.accountCalls].steps[1].quantity, 22)
    addon.db.profile.useMargin = false

    -- The arrow tooltip's view of the open profession has it too.
    addon.Pathfinder.currentPath = path
    before = #env.accountCalls
    local live = window:LiveView()
    T.eq("the arrow tooltip's view: worked out once", #env.accountCalls, before + 1)
    T.check("and carried, with the sale values", live.account.net == 4850 and live.account.stockSaves == 1200
        and live.sale == sale and live.saleLoading == 2)
    T.check("it does not share the window's opened rows", live.expanded ~= window.expanded and next(live.expanded) == nil)

    -- A path planned without sale values: none are handed on.
    window:Update(W.path())
    T.check("no sale values: nothing counted as sold",
        env.accountCalls[#env.accountCalls].saleValues == nil and window.view.sale == nil)
    T.eq("what is still loading is counted now, whatever the path carries", window.view.saleLoading, 2)

    -- No path, no account.
    T.check("no path: no account", window:BuildView(nil, "live").account == nil)
end)

T.section("states", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon

    -- The setting that turns the window off.
    addon.db.profile.openWithProfession = false
    window:Update(W.path())
    T.check("turned off: not built, not shown", window.frame == nil)
    T.check("turned off: the path is still kept for the shopping list", window.path ~= nil)
    addon.db.profile.openWithProfession = true

    window:Update(W.path())
    local frame = window.frame

    -- Notice
    window:ShowNotice("No recipe data for Engineering yet.")
    T.check("notice: shown", frame.shown and frame.showsNotice == true)
    T.eq("notice: one row with the text", W.rowTexts(window)[1], "No recipe data for Engineering yet.")
    T.check("notice: nothing of the header is left", not window.moreBtn.shown and not window.strip.shown
        and not window.targetRow.shown and not window.receipt.shown and not window.searchRow.shown and not window.shopRow.shown)
    T.eq("notice: plain title", frame.title.text, "LazyProf")
    T.eq("notice: no status", window.status.text, "")
    T.eq("notice: no receipt", #W.receiptTexts(window), 0)
    T.eq("notice: the list starts right under the title", stacked(window), "")
    window:Update(W.path())
    T.check("a path replaces the notice", window.targetRow.shown and window.receipt.shown and window.moreBtn.shown
        and frame.showsNotice == nil)

    -- The next recipe is unlearned and the profession window hides unlearned
    -- recipes: its run, open because the player is on it, says so.
    env.hidden = true
    local unlearned = W.recipe(9, "Boots", 100, 150, 160, 170, { unlearned = true, sourceInfo = { type = "trainer", cost = 100 } })
    local function unlearnedPath()
        return W.path({ steps = { W.step(unlearned, 143, 160, 19, 2000) }, gaps = {}, totalCost = 2000,
            prices = { [109] = 100 } })
    end
    window:Update(unlearnedPath())
    local rows = W.rowTexts(window)
    T.eq("the run that is next", rows[2], "> Boots | 143-160,19,19s")
    T.eq("what has to be done first, under it", rows[3], "Learn first: trainer, 1s")
    T.check("that line is a sub-line", window.list.rows[3].desc.sub == true)
    T.check("the filter hint is in the opened run", W.findRow(window, "hides unlearned recipes") ~= nil)
    env.hidden = false
    window:Update(unlearnedPath())
    T.check("no hint when the filter shows unlearned recipes", W.findRow(window, "hides unlearned recipes") == nil)
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

    -- A size saved by a build that allowed a smaller window is raised to the
    -- minimum when the window takes it.
    addon.db.profile.panelSizes.guide = { width = 400, height = 360 }
    env.shell:ResetClosed()
    window.sized = nil
    window:Update(W.path())
    T.eq("a saved size under the minimum: the height is raised", frame.height, 440)
    T.eq("a saved size under the minimum: the width it had is kept", frame.width, 400)
    addon.db.profile.panelSizes.guide = { width = 300, height = 700 }
    window.sized = nil
    window:Update(W.path())
    T.eq("a saved width under the minimum is raised too", frame.width .. "x" .. frame.height, "380x700")
    addon.db.profile.panelSizes.guide = nil
    window.sized = nil
    -- Docked beside a low profession window, the default height is the minimum.
    env.anchor.height = 300
    window:Update(W.path())
    T.eq("a low profession window: the window is as tall as its minimum", frame.height, 440)
    env.anchor.height = 500
    window.sized = nil
    window:Update(W.path())

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
    window:SelectTab("shopping", true)
    T.eq("tab chosen by the player is remembered for the character",
        addon.CharStore:Get().lastTab, "shopping")
    addon.CharStore:Get().lastTab = "no-such-tab"
    window:SelectTab(addon.CharStore:Get().lastTab)
    T.eq("an unknown saved tab falls back to the first", window.tab, "path")

    -- Nothing left
    window:Update(W.path({ steps = {}, gaps = {}, totalCost = 0, nothingLeft = true, actualSkill = 300, currentSkill = 300 }))
    T.eq("nothing left: message instead of rows", W.rowTexts(window)[1], "Nothing left: Tailoring is at its cap of 300.")
end)

-- The tabs "Guide" and "Steps" became "Path": a tab saved under an old name
-- opens it.
for _, saved in ipairs({ "guide", "steps", "shopping" }) do
    T.section("saved tab " .. saved, function()
        local env = W.load("forever")
        env.addon.CharStore:Get().lastTab = saved
        env.window:Update(W.path())
        T.eq("saved '" .. saved .. "' opens", env.window.tab, saved == "shopping" and "shopping" or "path")
        T.eq("with its tab button selected", env.window.tabs:GetSelected(), saved == "shopping" and 2 or 1)
    end)
end

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

    -- Close the run the player is on, so the list is one row per step.
    ui.fire(W.findRow(window, "> Gloves"), "OnClick", "LeftButton")
    local rows = W.rowTexts(window)
    T.eq("craft up to the cap", rows[2], "> Gloves | 143-150,7,7s")
    T.eq("the rank step at the cap, a thin row of its own", rows[3], "Train the next rank before 150")
    T.eq("the crossing fragment starts the next run", rows[4], "Gloves | 150-152,3,3s")
    T.eq("the run of a recipe still to learn costs its reagents only", rows[5], "Boots | 152-225,73,73s")
    T.eq("learning it is a line under the run, with the fee", rows[6], "Learn first: vendor, 15s")
    T.check("as a sub-line", window.list.rows[6].desc.sub == true and window.list.rows[6].height == 16)
    T.eq("the next cap", rows[7], "Train the next rank before 225")
    T.eq("the run after it", rows[8], "Boots | 225-300,75,75s")
    T.eq("nothing else", #rows, 8)

    -- The rank row's tooltip is the rank sentence.
    ui.fire(W.findRow(window, "Train the next rank before 150"), "OnEnter")
    T.check("rank row: the cap the client reports is called yours", ui.tooltip:Text():find(
        "Your cap is 150. Train the next rank at a Tailoring trainer before you reach 150.", 1, true) ~= nil, ui.tooltip:Text())
    ui.fire(W.findRow(window, "Train the next rank before 225"), "OnEnter")
    T.check("rank row: a later cap is not", ui.tooltip:Text():find(
        "Skill cap 225: train the next rank at a Tailoring trainer before you reach 225.", 1, true) ~= nil, ui.tooltip:Text())

    -- An opened run of a recipe still to learn says how to learn it.
    ui.fire(W.findRow(window, "Boots"), "OnClick", "LeftButton")
    T.check("learn: source kind", W.findRow(window, "Sold by a vendor.") ~= nil)
    T.check("learn: fee", W.findRow(window, "Cost: 15s") ~= nil)
    T.check("learn: required skill", W.findRow(window, "Requires skill 150") ~= nil)
    ui.fire(W.findButton(window, "Recipe details").button, "OnClick", "LeftButton")
    T.eq("learn: recipe details offered", env.details.recipe.name, "Boots")
    ui.fire(W.findRow(window, "Boots"), "OnClick", "LeftButton")

    -- Cap already at the top: no rank steps.
    env.cap = 300
    window:Update(path())
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
    T.check("planning: profession picker shown without More options", window.planRow.shown
        and window.professionDropdown.frame:IsVisible() and not window.strip.shown)
    T.eq("planning: picker names the profession", window.professionDropdown.button.overrideText, "Tailoring")
    T.eq("planning: the header's blocks", stacked(window), "planRow,targetRow,receipt")
    T.eq("planning: the path is the planner's for that profession", env.planCalls[1].key, "tailoring")
    T.eq("planning: tabs work as when docked", W.rowTexts(window)[1], "Recipes | skill,crafts,cost")
    T.eq("planning: a profession not learned is planned from 1", window.slider.frame.min .. "-" .. window.slider.frame.max, "1-300")

    -- The picker lists professions that have data and opens the chosen one.
    local root = fakeui.openMenu(window.professionDropdown.button)
    local names = {}
    for _, radio in ipairs(root.radios) do names[#names + 1] = radio.text end
    T.eq("picker: professions with recipe data, by name", table.concat(names, ","), "Alchemy,Tailoring")
    root.radios[1].setSelected()
    T.eq("picker: another profession is planned", env.planCalls[#env.planCalls].key, "alchemy")
    T.eq("picker: and shown", frame.title.text, "LazyProf - Alchemy")

    -- "Plan from skill 1" is an advanced control: behind More options, and
    -- only for a profession the character has.
    T.check("what-if: not on screen without More options", not window.fromOneBox.frame:IsVisible())
    ui.fire(window.moreBtn, "OnClick")
    T.eq("planning with More options: the header's blocks", stacked(window), "strip,planRow,targetRow,receipt,searchRow")
    T.check("what-if: none for a profession not learned", not window.fromOneBox.frame:IsVisible())
    env.playerSkill, env.playerCap = 143, 150
    window:OpenPlanning("tailoring")
    T.eq("learned: status with the cap the client reports", window.status.text, "Skill 143 / 150")
    T.check("learned: what-if offered, off", window.fromOneBox.frame:IsVisible() and not window.fromOneBox:GetChecked())
    T.eq("learned: the slider starts at the real skill", window.slider.frame.min, 143)
    window.fromOneBox.frame.checked = true
    ui.fire(window.fromOneBox.frame, "OnClick")
    T.check("what-if: remembered for the character and profession", addon.CharStore:Get().planFromOne.tailoring == true)
    T.check("what-if: planned again from 1", env.planCalls[#env.planCalls].opts.planFromOne == true)
    T.eq("what-if: status says so", window.status.text, "Skill 143 / 150 - planned from skill 1")
    T.eq("what-if: the slider still starts at the real skill", window.slider.frame.min, 143)
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
    ui.fire(window.slider.frame, "OnMouseDown", "LeftButton")
    ui.slide(window.slider.frame, 200)
    T.eq("slider: dragging plans nothing", #env.planCalls, plans + 1)
    ui.fire(window.slider.frame, "OnMouseUp", "LeftButton")
    T.eq("slider: letting go plans planning again", #env.planCalls, plans + 2)
    ui.fire(window.strategyGroup.buttons.fastest, "OnClick")
    T.eq("strategy: planning is planned again", #env.planCalls, plans + 3)
    fakeui.openMenu(window.sellingDropdown.button).radios[3].setSelected()
    T.eq("selling: planning is planned again", #env.planCalls, plans + 4)
    T.eq("none of them asked the live planner", #env.recalcs, recalcs)
    ui.fire(window.moreBtn, "OnClick")

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
    -- The whole interface hidden (the frame itself stays "shown"): planning is kept.
    ui.fire(frame, "OnHide")
    T.check("hiding the whole interface does not close planning", window.planning ~= nil)
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
    T.check("no data: the picker stays usable", window.planRow.shown and window.professionDropdown.frame:IsVisible())
    T.check("no data: nothing else of the header is left", not window.moreBtn.shown and not window.strip.shown
        and not window.targetRow.shown and not window.receipt.shown)
    T.eq("no data: the header's blocks", stacked(window), "planRow")
    window:OpenPlanning("tailoring")
    T.check("a profession with data brings them back", window.targetRow.shown and window.targetInput.frame:IsVisible())

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
    local boots = W.recipe(9, "Boots", 150, 200, 210, 220, { unlearned = true, sourceInfo = { type = "trainer", cost = 250, costSeen = true } })
    addon.Professions.registry = { tailoring = { name = "Tailoring", recipes = { boots, W.GLOVES } } }
    local function path()
        return W.path({
            steps = { W.step(W.GLOVES, 143, 150, 7, 700), W.step(boots, 150, 225, 75, 7750), W.step(boots, 225, 300, 75, 7500) },
            gaps = {}, totalCost = 15950, complete = true, prices = { [101] = 100, [109] = 100 },
        })
    end
    local function rankTooltip()
        ui.fire(W.findRow(window, "Train the next rank before 150"), "OnEnter")
        return ui.tooltip:Text()
    end
    window:Update(path())
    -- Open the run of the recipe still to learn.
    ui.fire(W.findRow(window, "Boots"), "OnClick", "LeftButton")

    -- Nothing remembered: nobody is named.
    T.check("rank row: no trainer named before any visit", rankTooltip():find("trainers you have visited", 1, true) == nil)
    T.check("the line under the run names the fee", W.findRow(window, "Learn first: trainer, 2s 50c") ~= nil)
    T.check("opened run: no trainer named before any visit", W.findRow(window, "Trainers you visited") == nil)
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
    T.check("opened run: the label", W.findRow(window, "Trainers you visited that teach it:") ~= nil)
    T.check("opened run: the trainer that listed the recipe, with where the player stood",
        W.findRow(window, "Georgio Bolero - Stormwind City (53, 81)") ~= nil)
    T.check("opened run: a trainer that did not list it is not named", W.findRow(window, "Sellandus") == nil)
    T.check("opened run: the other faction's trainer is not named", W.findRow(window, "Magar") == nil)

    local tip = rankTooltip()
    T.check("rank row: the label does not promise the rank",
        tip:find("Tailoring trainers you have visited (not every trainer teaches every rank):", 1, true) ~= nil, tip)
    T.check("rank row: both visited trainers of the faction", tip:find("Georgio Bolero", 1, true) ~= nil
        and tip:find("Sellandus - Stormwind City (44, 77)", 1, true) ~= nil and tip:find("Magar", 1, true) == nil, tip)

    -- The VANILLA profile never names a trainer on a learn step.
    _G.CraftLib = { GetActiveProfile = function() return "VANILLA" end }
    Memory:Record({ name = "Era Trainer", npcId = 5, zone = "Ironforge", faction = "Alliance" },
        { { name = "Boots", cost = 250, state = "available" } })
    window:Refresh()
    T.check("VANILLA: the opened run names no trainer", W.findRow(window, "Trainers you visited") == nil
        and W.findRow(window, "Era Trainer") == nil)
    T.check("VANILLA: the line under the run names no source", W.findRow(window, "Learn the recipe first") ~= nil
        and W.findRow(window, "Learn first: trainer") == nil)
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

T.section("docking and planning order", function()
    local env = W.load("forever")
    local window, ui, addon = env.window, env.ui, env.addon
    addon.Professions.active = "tailoring"
    window:Update(W.path())
    local frame = window.frame

    -- Resizing lays the header out again and keeps the spot the frame was sized at.
    local noteWidth = function() return window.receiptRows[1].note.width end
    env.account = { missing = { rows = {}, recipeRows = {}, buyTotal = 100, recipeCosts = 50 },
        reagents = 100, recipes = 50, spend = 150, sale = 0, net = 150 }
    window:Update(W.path())
    local before = noteWidth()
    frame.width, frame.height, frame.left, frame.top = 600, 600, 120, 880
    ui.fire(window.resizeGrip, "OnMouseUp")
    T.eq("resize: the receipt's notes get the new room", noteWidth(), before + 180)
    T.eq("resize: the list follows", window.list.width, 600 - 44)
    T.eq("resize: the spot is saved with the size", addon.db.profile.panelPositions.guide.x, 120)
    env.shell:ResetPositions()
    T.eq("reset: the header follows the default width again", noteWidth(), before)

    -- Planning the profession whose window is open: its own path follows too.
    env.playerSkill, env.playerCap = 143, 300
    window:OpenPlanning("tailoring")
    local recalcs, plans = #env.recalcs, #env.planCalls
    window.targetInput.frame.focused = true
    window.targetInput.frame.text = "225"
    ui.fire(window.targetInput.frame, "OnEnterPressed")
    T.eq("planning the open profession: its live path is planned again", env.recalcs[#env.recalcs], "target changed")
    T.eq("once", #env.recalcs, recalcs + 1)
    window:OpenPlanning("alchemy")
    recalcs, plans = #env.recalcs, #env.planCalls
    window.targetInput.frame.focused = true
    window.targetInput.frame.text = "226"
    ui.fire(window.targetInput.frame, "OnEnterPressed")
    T.eq("planning another profession: only planning is planned again", #env.recalcs, recalcs)
    T.eq("planning another profession: planned", #env.planCalls, plans + 1)
    ui.fire(frame.closeBtn, "OnClick")
    env.shell:ResetClosed()

    -- A profession window opening over planning: nothing changes until its
    -- path arrives; then the window docks.
    env.open = false
    window:OpenPlanning("alchemy")
    env.open = true
    window:OnProfessionOpened()
    T.eq("opened over planning: still planning until the path arrives", window.mode, "planning")
    window:Refresh()
    T.eq("a redraw in between still shows planning", frame.title.text, "LazyProf - Alchemy")
    T.check("with its profession picker", window.planRow.shown)
    window:Update(W.path())
    T.eq("the path arrived: docked", window.mode, "live")
    T.eq("docked on the open profession", frame.title.text, "LazyProf - Tailoring")

    -- The docked window is closed with its button; the planning view that was
    -- set aside still comes back when the profession window closes.
    ui.fire(frame.closeBtn, "OnClick")
    T.check("docked window closed by the player", not frame.shown and frame.userClosed == true)
    env.open = false
    window:OnProfessionClosed()
    T.check("the planning view set aside is shown again", frame.shown and window.mode == "planning")
    T.eq("on its profession", frame.title.text, "LazyProf - Alchemy")
    T.check("and can be closed with Escape", escapeCloses())

    -- A profession window that closes before its path arrived leaves planning alone.
    env.open = true
    window:OnProfessionOpened()
    env.open = false
    window:OnProfessionClosed()
    T.check("opened and closed before a path: planning untouched", frame.shown and window.mode == "planning")
    env.open = true
    window:Update(W.path())
    T.eq("a late path does not dock a window whose profession is gone", window.mode, "planning")

    -- A profession without data docks with its notice.
    window:OnProfessionOpened()
    window:HideLive()
    T.eq("no path yet for the opened profession: planning stays", window.mode, "planning")
    window:ShowNotice("No recipe data for Engineering yet.")
    T.eq("its notice docks the window", window.mode, "live")
    T.eq("and is shown", W.rowTexts(window)[1], "No recipe data for Engineering yet.")
end)

T.finish()
