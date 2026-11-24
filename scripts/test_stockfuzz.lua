-- scripts/test_stockfuzz.lua
--
-- A seeded random walk through bank visits, checked against a model of what
-- the character really owns. The client is scripts/lib/stockworld.lua driving
-- the real WoW Forever adapter, the scanner and the stock memory; this file
-- adds a true world (carried bags, character bank, account bank, a second
-- character), a simulated client whose unknown behaviours are switches, a
-- random player, and the checks:
--   I1  a scan never counts more of an item than is owned
--   I2  two seconds after the last event no bank is left out or short without
--       the scan's third return - and the Shopping tab - saying so
--   I3  on a well-behaved client an open bank is right, and without a doubt
--       mark, two seconds after the last event
--   I4  on a well-behaved client a visit that ends half a second or more
--       after its last move (the moment the client showed it) leaves no
--       doubt mark
--   I5  nothing raises and nothing reaches the game's error handler
-- A failing walk is cut down to the shortest sequence that still fails and
-- can be written out as a script that needs only scripts/lib/stockworld.lua.
-- The walks are seeded by a generator of this file's own: a run is the same
-- on every machine and every time.
--
-- Run from the addon root:  lua5.1 scripts/test_stockfuzz.lua
-- By default it runs three fixed samples of client configurations and
-- players (a few seconds; see the end of this file) and checks everything.
-- Environment:
--   STOCKFUZZ_MODE    suite (default): every check on the samples
--                     campaign: many walks, results as tables (kinds,
--                       signatures, marginals per switch, visits)
--                     shrink: cut one failing walk down, write it as a script
--   STOCKFUZZ_STEPS   player actions per walk (120; campaign and shrink: 300)
--   STOCKFUZZ_SEEDS   "first-last": seeds per switch combination (campaign)
--   STOCKFUZZ_COMBOS  "all" | "wb" (well-behaved clients) | "i/n" (every n-th
--                     combination from the i-th) | one combination's key
--   STOCKFUZZ_WHERE   "switch=value,..." keeps the combinations that fit
--   STOCKFUZZ_HABITS  player habits to switch off, comma separated (HABITS)
--   STOCKFUZZ_ALSO    habits to switch on that the default player does not
--                     have, because what follows from them is decided (ALSO)
--   STOCKFUZZ_OUT     directory for campaign tables and shrunk scripts
--   STOCKFUZZ_TAG     name prefix of the campaign's tables
--   shrink: STOCKFUZZ_COMBOS (a key), STOCKFUZZ_SEED, STOCKFUZZ_KIND, and
--     optionally STOCKFUZZ_CAUSE (part of the cause; all of it with
--     STOCKFUZZ_CAUSE_EXACT=1), STOCKFUZZ_MS (least duration), STOCKFUZZ_NAME
--   STOCKFUZZ_MUTANT  a file to load in place of Modules/Inventory/Scanner.lua:
--                     shows whether the checks notice a scanner with a rule
--                     taken out (any mode)
--
-- Kinds of failure (the suite's checks are made of them):
--   I1.settled.own|alt   counted more than owned two quiet seconds after the last event
--   I1.latent.<bank>     a counted bank is remembered with more than it holds (settled)
--   I1.multi|frame|mid   counted more than owned: at the end of two or more frames /
--                        of one frame / only between two events of a frame.
--                        I1h.*: the same while the client itself shows the item in
--                        two containers (a move half reported); not a check
--   I1t.own              over for more than a frame within one visit, gone again
--   I2.stale.<bank>      a counted bank is remembered with less than it holds (settled)
--   I2.pending|unsaid|noline|uncounted   a bank left out, and the scan's third return
--                        or the Shopping tab does not say so (settled)
--   I2.alt               the other character's bank is in doubt and left out, and the
--                        scan's third return or the Shopping tab does not name it
--   I3.count|doubt       a well-behaved client: an open bank wrong or in doubt after two
--                        quiet seconds (I3x.*: the same on any other client)
--   careful.*, hasty.*   any of these kinds in the samples of a careful player
--   I3.stuck, I4.blindmark   a bank this character may not view is in doubt
--   I4.nuisance|glance|afterclose   a well-behaved client: a doubt mark after a visit
--                        that ended 0.5 s or more after its last move / in which
--                        nothing was moved / after a change of the bags in the
--                        second after the close that was no rise of an item a
--                        remembered bank holds
--   I5.error|handler     a Lua error, or a message to the game's error handler
--
-- KNOWN (below) lists the kinds of failure the suite still shows on the code
-- as it stands, each with a sentence saying what is wrong. They are printed
-- with every run and do not fail it; one that no walk shows any more does.

package.path = "./?.lua;" .. package.path
local T = require("scripts.lib.check").new()
local World = require("scripts.lib.stockworld")

-- A login loads the addon's files again; their compiled chunks are kept, so
-- a walk with many logins parses each file once. Calling a chunk again makes
-- new upvalues: every session still starts with fresh module state.
-- STOCKFUZZ_MUTANT=<file>: that file is loaded in the scanner's place - to
-- see that the checks notice a scanner with a rule taken out.
local realLoadfile, chunks = loadfile, {}
local MUTANT = os.getenv("STOCKFUZZ_MUTANT")
function loadfile(path)
    local chunk = chunks[path]
    if not chunk then
        local err
        chunk, err = realLoadfile((MUTANT and path == "Modules/Inventory/Scanner.lua") and MUTANT or path)
        if not chunk then return nil, err end
        chunks[path] = chunk
    end
    return chunk
end

World.install()
-- This file steps whole frames itself (see Frame below): a timer is due a
-- millisecond after it was asked for at the earliest, so it can never run in
-- the frame that asked for it, and it runs in the first frame at or after
-- its mark - as in the game, where GetTime() is the same all through a frame.
World.FRAME = 0.001

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

-- ===========================================================================
-- Switches: what is not known about the client. Every combination is a
-- client configuration.
-- ===========================================================================
local SWITCHES = {
    -- 1. inside the close notice the bank is ...
    { "closeRead", { "readable", "refused", "empty", "noslots" } },
    -- 2. of a move between a bank and the carried bags, the update that comes first
    { "order", { "bank", "bag" } },
    --    the two updates come in one frame, both containers changed before
    --    the first ("same") or each with its own update ("split"); or frames
    --    apart, each container changed with its own update ("apart") or both
    --    with the first, the second update merely late ("late")
    { "spread", { "same", "split", "apart", "late" } },
    --    how long after the click: the same or the next frame / up to 0.3 s / up to 1 s
    { "latency", { "none", "short", "long" } },
    -- 3. the client empties the bank's containers and says so before the close notice
    { "letgo", { false, true } },
    -- 4. at the opening the items are all there / come later / partly there;
    --    "Silent": no bag update when they arrive
    { "open", { "all", "late", "lateSilent", "partial", "partialSilent" } },
    -- 5. BAG_UPDATE_DELAYED comes in the frame of its updates / a frame later / never
    { "delayed", { "same", "next", "never" } },
    -- 6. bag updates of carried bags that change nothing, at any time
    { "idle", { false, true } },
}

local function ComboCount()
    local n = 1
    for _, switch in ipairs(SWITCHES) do n = n * #switch[2] end
    return n
end

local function Combo(index)
    local cfg, rest = {}, index
    for _, switch in ipairs(SWITCHES) do
        local values = switch[2]
        cfg[switch[1]] = values[rest % #values + 1]
        rest = floor(rest / #values)
    end
    cfg.index = index
    return cfg
end

local function Key(cfg)
    local parts = {}
    for _, switch in ipairs(SWITCHES) do
        local value = cfg[switch[1]]
        if value == true then value = switch[1] elseif value == false then value = "no" .. switch[1] end
        parts[#parts + 1] = tostring(value)
    end
    return table.concat(parts, "/")
end

local function ComboByKey(key)
    for index = 0, ComboCount() - 1 do
        local cfg = Combo(index)
        if Key(cfg) == key then return cfg end
    end
    return nil
end

-- Readable at the close, nothing late, the items there at the opening.
local function WellBehaved(cfg)
    return cfg.closeRead == "readable" and not cfg.letgo and cfg.open == "all" and cfg.latency ~= "long"
        and (cfg.spread == "same" or cfg.spread == "split")
end

-- Player habits a campaign can switch off, to look past a failure that is
-- already understood (STOCKFUZZ_HABITS names the ones to switch off; a
-- replay and the shrinking keep to them too):
--   logoutMidMove     log out or reload while the answer of a move is on its way
--   closeMidMove      close the bank while the answer of a move is on its way
--   bankToBank        move items between the character bank and the account bank
--   emptyBags         let the carried bags become completely empty (off: a
--                     soulbound stone stays in the backpack's first slot)
--   afterCloseChange  loot, craft or shuffle the bags in the second after a close
--   logoutAfterClose  log out or reload in the second after a close
--   quickVisit        do something within two seconds of opening the bank
local HABITS = { logoutMidMove = true, closeMidMove = true, afterCloseChange = true, quickVisit = true,
                 bankToBank = true, emptyBags = true, logoutAfterClose = true }

-- Decided behaviour: what the bank's rules accept on purpose. The test is
-- told each by name - a habit the default player does not have, a kind of
-- failure that is counted and printed but is no check, a class of clients a
-- check leaves out - never by loosening a check without a word.
--
-- Habits the default player does not have (STOCKFUZZ_ALSO names the ones to
-- switch on, comma separated, to see what follows from them):
--   logoutMidBankMove  log out or reload while the answer of a move between
--                      the character bank and the account bank is on its
--                      way. No carried bag changes, so neither that session
--                      nor a later one can tell that the two remembered
--                      banks are behind.
--   emptyBagsLogout    empty the carried bags completely and log out within
--                      the two seconds before they are saved. Completely
--                      empty bags are not trusted at logout (nothing says
--                      the client still holds the bags then), so the
--                      character's record keeps the bags as last saved.
--   leaveEarly         on a client that shows a bank only partly when its
--                      window opens: end the visit before the look two
--                      seconds after the opening has read the whole bank. A
--                      visit that ends earlier keeps the partial read (the
--                      client's own bank window could not draw such a bank).
-- Kinds and classes:
--   "+rise" visits     in the second after a close a carried count rises for
--                      an item a bank of the visit is remembered to hold:
--                      that bank is marked, also when it was loot or a craft
--                      (see NoteChange). The check "a change of the bags in
--                      the second after the close leaves no mark" is for
--                      counts that fall and for items no remembered bank
--                      holds.
--   I1h.*              while the client itself shows an item in two
--                      containers (a move half reported), a scan counts it
--                      twice.
--   letgo clients      a client that empties the bank's containers and
--                      reports that before the close notice ends every
--                      visit in doubt: an emptied bank cannot be told from
--                      one the client let go of. The "no doubt mark after an
--                      unhurried visit" checks are for well-behaved clients
--                      (WellBehaved above), which do not do that.
-- Not modelled at all: a clock that runs backwards; a client that reports
-- the answer of a move for the carried bag alone once the bank is closed and
-- takes longer for it than the rules watch (a second for a carried bag).
local ALSO = { logoutMidBankMove = false, emptyBagsLogout = false, leaveEarly = false }
local DEFAULT_HABITS = {}
for name, value in pairs(HABITS) do DEFAULT_HABITS[name] = value end
for name, value in pairs(ALSO) do DEFAULT_HABITS[name] = value end

-- ===========================================================================
-- Known failures: kinds of failure (or the first part of a kind) the default
-- run still shows, each with what is wrong. A check whose failures are all on
-- this list is printed as KNOWN and passes; an entry that no walk of the run
-- shows any more fails the run, so the list cannot outlive what it describes.
-- ===========================================================================
local KNOWN = {
    { "I1.settled.own", "A stack is taken out of the account bank and the session ends before the answer is heard; the other"
        .. " character plays before the first one returns. It counts the account bank as it was remembered, with the stack"
        .. " (the first character's remembered bags are without it, so the sum is right - but not the bank)." },
    { "I1.latent.account", "The account bank stays remembered with that stack until a character reads it again (the case of"
        .. " I1.settled.own)." },
    { "I1.multi.own", "The same, for as long as the other character is logged in (the case of I1.settled.own)." },
    { "I1.settled.alt", "A stack is put into the account bank and the session ends before the answer is heard; the other"
        .. " character plays before the first one returns. It counts the first one's bags as they were remembered, with the"
        .. " stack, and - once it has read the account bank itself - the stack in the account bank as well." },
    { "I1.multi.alt", "The same, for as long as the other character is logged in (the case of I1.settled.alt)." },
    { "I2.stale.account", "The account bank is remembered without the stack that was put into it (the case of I1.settled.alt)"
        .. " and nothing says so." },
    { "I3.stuck.account", "The account bank is in doubt for a character that may not view it, so no visit of its own takes"
        .. " the mark away. The mark is another character's, set after a visit of its own that left the bank uncertain." },
    { "careful.I3.stuck.account", "The same in the sample of a careful player (the case of I3.stuck.account)." },
}

-- ===========================================================================
-- A small generator of its own, so that a seed means the same walk on every
-- machine (math.random is the C library's).
-- ===========================================================================
local function Rng(seed)
    local state = seed % 2147483647
    if state <= 0 then state = state + 2147483646 end
    local rng = {}
    local function nextValue()
        state = (state * 48271) % 2147483647
        return state
    end
    for _ = 1, 5 do nextValue() end
    function rng.int(lo, hi) return lo + nextValue() % (hi - lo + 1) end
    function rng.chance(p) return nextValue() / 2147483647 < p end
    function rng.pick(list) return list[rng.int(1, #list)] end
    return rng
end

-- ===========================================================================
-- The world
-- ===========================================================================
local LINEN, SILK, ORE, STONE = 2589, 4306, 2770, 6948
local ITEMS = { LINEN, SILK, ORE }        -- STONE is always soulbound
local ALL_ITEMS = { LINEN, SILK, ORE, STONE }
local MAX_STACK = 20
local BACKPACK, BAG, TAB1, TAB2, ACCOUNT_TAB = 0, 1, 6, 7, 15
local GUID = { A = "Player-4444-000000AA", B = "Player-4444-000000BB" }
local NAME = { A = "Main Goldtooth", B = "Alt Goldtooth" }
local WORLD_KEY = "eu-pvp"
local SETTLE = 2000                       -- ms without an event: settled

local function KindOf(container)
    if container >= 6 and container <= 14 then return "character" end
    if container >= 15 and container <= 23 then return "account" end
    return nil
end

local function CopyItem(item)
    return item and { id = item.id, n = item.n, bound = item.bound } or nil
end

local function CopyContainer(container)
    local copy = { slots = container.slots }
    for index = 1, container.slots do copy[index] = CopyItem(container[index]) end
    return copy
end

local function CopyInit(init)
    local copy = { chars = {}, account = {} }
    for who, char in pairs(init.chars) do
        local c = { bags = {}, bank = {}, view = char.view }
        for id, container in pairs(char.bags) do c.bags[id] = CopyContainer(container) end
        for id, container in pairs(char.bank) do c.bank[id] = CopyContainer(container) end
        copy.chars[who] = c
    end
    for id, container in pairs(init.account) do copy.account[id] = CopyContainer(container) end
    return copy
end

local function AddCounts(into, container, sendableOnly)
    for index = 1, container.slots do
        local item = container[index]
        if item and not (sendableOnly and item.bound) then
            into[item.id] = (into[item.id] or 0) + item.n
        end
    end
end

-- A random world: two characters (the second one mostly), few slots, few
-- items, banks that are often empty.
local function RandomInit(rng)
    local function fill(container, stacks, allowBound)
        for _ = 1, stacks do
            local index = rng.int(1, container.slots)
            if not container[index] then
                if allowBound and rng.chance(0.2) then
                    container[index] = { id = STONE, n = 1, bound = true }
                else
                    container[index] = { id = rng.pick(ITEMS), n = rng.int(1, MAX_STACK) }
                end
            end
        end
        return container
    end
    local init = { chars = {}, account = {} }
    local function char()
        local c = { bags = {}, bank = {}, view = not rng.chance(0.12) }
        c.bags[BACKPACK] = fill({ slots = 6 }, rng.int(0, 4), true)
        c.bags[BAG] = fill({ slots = 4 }, rng.int(0, 2), false)
        c.bank[TAB1] = fill({ slots = 6 }, rng.chance(0.25) and 0 or rng.int(1, 4), true)
        if rng.chance(0.2) then c.bank[TAB2] = fill({ slots = 4 }, rng.int(0, 2), false) end
        return c
    end
    init.chars.A = char()
    if rng.chance(0.75) then init.chars.B = char() end
    if rng.chance(0.85) then
        init.account[ACCOUNT_TAB] = fill({ slots = 5 }, rng.chance(0.5) and 0 or rng.int(1, 3), false)
    end
    return init
end

-- ===========================================================================
-- One walk: the simulated client, the player's actions, the checks.
-- ===========================================================================
local S          -- the walk in progress
local cfg        -- its client configuration

local function Emit(line)
    if S.trace then S.trace[#S.trace + 1] = line end
end

local function Violate(kind, detail, extra)
    local v = { kind = kind, step = S.step, at = S.now, detail = detail, cause = (extra and extra.cause) or S.cause or "?" }
    if extra then for k, value in pairs(extra) do if v[k] == nil then v[k] = value end end end
    S.violations[#S.violations + 1] = v
    if S.trace and S.wanted and not S.traceEnd and S.wanted(v) then
        S.traceEnd = #S.trace
        S.found = v
        S.foundBanks = S.bankTruths and S.bankTruths() or nil
    end
    return v
end

local function Me() return S.chars[S.cur] end
local function OtherName() return S.cur == "A" and "B" or "A" end

local function TruthOf(container)
    if container <= 5 then return Me().bags[container] end
    if container <= 14 then return Me().bank[container] end
    return S.account[container]
end

-- What the client's calls return for a container: what it holds of it
-- (S.shown), less what the bank's state hides.
local function PushView(container)
    local src = S.shown[container]
    local kind = KindOf(container)
    local mask = kind and S.mask[kind] or (S.bagsHidden and "empty" or "full")
    local view
    if src then
        if mask == "noslots" then
            view = { slots = 0 }
        else
            view = { slots = src.slots }
            if mask ~= "empty" then
                local arrived = mask == "partial" and S.arrived[container] or nil
                for index = 1, src.slots do
                    local item = src[index]
                    if item and (not arrived or arrived[index]) then
                        view[index] = World.slot(item.id, item.n, item.bound)
                    end
                end
            end
        end
    end
    World.containers[container] = view
    if S.trace then
        if not view then
            Emit("World.containers[" .. container .. "] = nil")
        else
            local parts = { "slots = " .. view.slots }
            for index = 1, view.slots do
                local item = view[index]
                if item then
                    parts[#parts + 1] = "[" .. index .. "] = slot(" .. item.itemID .. ", " .. item.stackCount
                        .. (item.isBound and ", true)" or ")")
                end
            end
            Emit("World.containers[" .. container .. "] = { " .. table.concat(parts, ", ") .. " }")
        end
    end
end

local function PushBank()
    local me = Me()
    local tabs0 = { { ID = TAB1 } }
    if me.bank[TAB2] then tabs0[2] = { ID = TAB2 } end
    local tabs2 = {}
    if S.account[ACCOUNT_TAB] then tabs2[1] = { ID = ACCOUNT_TAB } end
    local view0, view2 = not S.refused, (me.view and not S.refused) and true or false
    World.bank = { [0] = { tabs = tabs0, canView = view0 }, [2] = { tabs = tabs2, canView = view2 } }
    if S.trace then
        local function ids(tabs)
            local out = {}
            for _, tab in ipairs(tabs) do out[#out + 1] = "{ ID = " .. tab.ID .. " }" end
            return "{ " .. table.concat(out, ", ") .. " }"
        end
        Emit("World.bank = { [0] = { tabs = " .. ids(tabs0) .. ", canView = " .. tostring(view0) .. " }, [2] = { tabs = "
            .. ids(tabs2) .. ", canView = " .. tostring(view2) .. " } }")
    end
end

local function BankContainers(kind)
    if kind == "character" then
        return Me().bank[TAB2] and { TAB1, TAB2 } or { TAB1 }
    end
    return S.account[ACCOUNT_TAB] and { ACCOUNT_TAB } or {}
end

local function PushBankViews()
    for _, kind in ipairs({ "character", "account" }) do
        for _, container in ipairs(BankContainers(kind)) do PushView(container) end
    end
end

-- Checks ---------------------------------------------------------------------

local function Truths()
    local me, other = Me(), S.chars[OtherName()]
    local own, alt, shown = {}, {}, {}
    for _, container in pairs(me.bags) do AddCounts(own, container) end
    for _, container in pairs(me.bank) do AddCounts(own, container) end
    for _, container in pairs(S.account) do AddCounts(own, container) end
    if other then
        for _, container in pairs(other.bags) do AddCounts(alt, container, true) end
        for _, container in pairs(other.bank) do AddCounts(alt, container, true) end
    end
    for _, container in pairs(S.shown) do AddCounts(shown, container) end
    return own, alt, shown
end

local function Literal(counts)
    local parts = {}
    for _, id in ipairs(ALL_ITEMS) do
        if counts[id] then parts[#parts + 1] = "[" .. id .. "] = " .. counts[id] end
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function Guard(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Violate("I5.error", what .. ": " .. tostring(err)) end
    if #World.errors > S.errorsSeen then
        Violate("I5.handler", World.errors[#World.errors])
        S.errorsSeen = #World.errors
    end
end

-- The lines the Shopping tab starts with, as the window would draw them from
-- `meta`: its first two rows (one for the character's banks, one for alts).
local function ShoppingLine(meta)
    local addon = S.addon
    if not addon.GuideViews then
        for _, path in ipairs({ "Core/Utils.lua", "Modules/Guide/Text.lua", "Modules/Guide/Views.lua" }) do
            assert(loadfile(path))("LazyProf", addon)
        end
    end
    local rows = addon.GuideViews.Shopping({ path = {}, missing = { rows = {} }, stockMeta = meta, now = World.serverTime })
    return (rows[1] and tostring(rows[1].text) or "") .. "\n" .. (rows[2] and tostring(rows[2].text) or "")
end

-- remembered against true: "none" (nothing remembered), "eq", "high", "low", "mixed"
local function Compare(remembered, truth)
    if not remembered then return "none" end
    local high, low = false, false
    for _, id in ipairs(ALL_ITEMS) do
        local r, t = remembered[id] or 0, truth[id] or 0
        if r > t then high = true elseif r < t then low = true end
    end
    if high and low then return "mixed" end
    return high and "high" or (low and "low" or "eq")
end

local function BankTruth(kind, who)
    local truth = {}
    if kind == "character" then
        for _, container in pairs(S.chars[who or S.cur].bank) do AddCounts(truth, container) end
    else
        for _, container in pairs(S.account) do AddCounts(truth, container) end
    end
    return truth
end

local function Remembered(kind, who)
    local memory = S.addon.StockMemory
    if kind == "character" then return memory:OwnBank(GUID[who or S.cur]) end
    return memory:AccountBank(WORLD_KEY)
end

-- For a shrunk script: what the two banks really hold now, as literals.
local function BankTruthLiterals()
    return { character = Literal(BankTruth("character")), account = Literal(BankTruth("account")), guid = GUID[S.cur] }
end

local function Viewable(kind)
    if kind == "character" then return true end
    return Me().view and S.account[ACCOUNT_TAB] ~= nil
end

local function InFlight()
    local n = 0
    for _, d in ipairs(S.queue) do
        if d.kind == "upd" then n = n + 1 end
    end
    return n
end

-- Is the answer of a move between the character bank and the account bank
-- on its way?
local function InFlightAcrossBanks()
    for _, d in ipairs(S.queue) do
        if d.kind == "upd" and (d.across or (d.chain and d.chain.across)) then return true end
    end
    return false
end

-- What a visit left behind, judged once: at the first settled moment after
-- its close, at the next opening or at logout, whichever comes first.
local function JudgeVisit(v)
    if not v or v.judged then return end
    v.judged = true
    local _, _, charDoubt = Remembered("character", v.who)
    local _, _, accountDoubt = Remembered("account")
    local ended = (v.marks.character > 0 and charDoubt == true) or (v.marks.account > 0 and accountDoubt == true)
    local class
    if v.moves == 0 then class = "glance"
    elseif v.hurried then class = "hurried"
    else class = "unhurried" end
    if v.afterRise then class = class .. "+rise" elseif v.after then class = class .. "+after" end
    local stat = S.stats.visits[class] or { n = 0, doubt = 0 }
    S.stats.visits[class] = stat
    stat.n = stat.n + 1
    if ended then
        stat.doubt = stat.doubt + 1
        -- Was the mark needed? Not when what is remembered is what is there.
        local needed = false
        if v.marks.character > 0 and charDoubt and Compare(Remembered("character", v.who), BankTruth("character", v.who)) ~= "eq" then needed = true end
        if v.marks.account > 0 and accountDoubt and Compare(Remembered("account"), BankTruth("account")) ~= "eq" then needed = true end
        if needed then S.stats.doubtNeeded = S.stats.doubtNeeded + 1 else S.stats.doubtIdle = S.stats.doubtIdle + 1 end
        if WellBehaved(cfg) then
            local detail = string.format("visit of %d ms, %d changes, closed %s ms after the last one; marks: character=%s account=%s",
                v.closeMs - v.openMs, v.moves, tostring(v.lastMoveMs and (v.closeMs - v.lastMoveMs) or "-"),
                tostring(v.marks.character > 0 and charDoubt), tostring(v.marks.account > 0 and accountDoubt))
            if class == "unhurried" then Violate("I4.nuisance", detail, { cause = v.cause })
            elseif class == "glance" then Violate("I4.glance", detail, { cause = v.cause })
            elseif class == "unhurried+after" or class == "glance+after" then Violate("I4.afterclose", detail, { cause = v.cause }) end
        end
    end
end

local function Cause()
    local parts = { S.op or "?" }
    parts[#parts + 1] = S.bankOpen and "open" or "closed"
    if InFlight() > 0 then parts[#parts + 1] = "inflight" end
    if S.closeMs and not S.bankOpen and S.now - S.closeMs <= 1000 then parts[#parts + 1] = "watch" end
    if S.now - S.loginMs < 3000 then parts[#parts + 1] = "fresh" end
    return table.concat(parts, ",")
end

local function FinishEpisode(e, how)
    local class = e.sightings == 0 and "mid" or (e.sightings == 1 and "frame" or "multi")
    local kind = (e.inherent and "I1h." or "I1.") .. class .. "." .. e.part
    local detail = string.format("item %d: counted %d, owned %d (over by %d at most) for %d ms, seen at %d frame(s), ended by %s",
        e.id, e.scan, e.truth, e.max, e.t1 - e.t0, e.sightings, how)
    Violate(kind, detail, { cause = e.cause, ms = e.t1 - e.t0 })
    local stat = S.stats.episodes
    stat[kind] = (stat[kind] or 0) + 1
    if e.t1 - e.t0 > (S.stats.longest[kind] or -1) then S.stats.longest[kind] = e.t1 - e.t0 end
    -- Over, and gone again without ever having been seen settled: how long?
    if not e.settled and how == "a later scan" and e.sightings >= 2 and e.visit ~= nil and e.visit == S.visit then
        Violate((e.inherent and "I1ht." or "I1t.") .. e.part, detail, { cause = e.cause, ms = e.t1 - e.t0 })
    end
end

local function Track(level, part, id, scan, truth, inherent)
    local key = part .. id
    local e = S.episodes[key]
    if scan <= truth then
        if e then
            FinishEpisode(e, "a later scan")
            S.episodes[key] = nil
        end
        return
    end
    if not e then
        e = { part = part, id = id, t0 = S.now, sightings = 0, lastFrame = -1, inherent = true, max = 0, cause = Cause(),
              visit = S.visit }
        S.episodes[key] = e
    end
    e.t1, e.scan, e.truth = S.now, scan, truth
    e.max = max(e.max, scan - truth)
    if not inherent then e.inherent = false end
    if level ~= "mid" and e.lastFrame ~= S.frameNo then
        e.sightings = e.sightings + 1
        e.lastFrame = S.frameNo
    end
    if level == "settled" and not e.settled then
        e.settled = true
        Violate("I1.settled." .. part, string.format("item %d: counted %d, owned %d, %d ms after the last event (over since %d ms)",
            id, scan, truth, S.now - S.lastEvent, S.now - e.t0), { cause = e.cause })
    end
end

local function SettledChecks(meta)
    local wb = WellBehaved(cfg)
    for _, kind in ipairs({ "character", "account" }) do
        local items, _, doubt = Remembered(kind)
        local truth = BankTruth(kind)
        local relation = Compare(items, truth)
        local own = kind == "character"
        local metaDoubt = meta[own and "bankInDoubt" or "accountInDoubt"]
        local pending = meta[own and "bankPending" or "accountPending"]
        local counted = meta[own and "bankSeenAt" or "accountSeenAt"] ~= nil
        local cause = Cause()
        if items and doubt and not metaDoubt then
            Violate("I2.unsaid." .. kind, "the remembered bank is in doubt and the scan's third return does not say so", { cause = cause })
        end
        if metaDoubt then
            S.stats.doubtSettled = S.stats.doubtSettled + 1
            local line = ShoppingLine(meta)
            local named = own and (line:find("Your bank is not counted", 1, true) or line:find("Your bank and the account bank are not counted", 1, true))
                or (not own and (line:find("The account bank is not counted", 1, true)
                    or line:find("Your bank and the account bank are not counted", 1, true)))
            if not named then
                Violate("I2.noline." .. kind, "in doubt, and the Shopping tab starts with: " .. line, { cause = cause })
            end
        end
        if pending then
            Violate("I2.pending." .. kind, "left out as being read again, " .. (S.now - S.lastEvent) .. " ms after the last event (no line is shown for that)", { cause = cause })
        end
        if items and not doubt and not pending then
            if not counted then
                Violate("I2.uncounted." .. kind, "remembered, not in doubt, and yet not counted", { cause = cause })
            end
            if relation == "high" or relation == "mixed" then
                Violate("I1.latent." .. kind, "counted, and what is remembered holds more than the bank: remembered "
                    .. Literal(items) .. ", in the bank " .. Literal(truth), { cause = cause })
            end
            if relation == "low" or relation == "mixed" then
                Violate("I2.stale." .. kind, "counted without a word, and what is remembered holds less than the bank: remembered "
                    .. Literal(items) .. ", in the bank " .. Literal(truth), { cause = cause })
            end
        end
        if not items and next(truth) ~= nil and Viewable(kind) and (own and Me().visited or (not own and Me().visited)) then
            S.stats.unseen = S.stats.unseen + 1
        end
        -- I3: the bank has been open for two seconds and more, and all is quiet.
        if S.bankOpen and S.now - S.openMs >= SETTLE and Viewable(kind) then
            local prefix = wb and "I3." or "I3x."
            S.stats.healChecks = S.stats.healChecks + 1
            if relation ~= "eq" then
                Violate(prefix .. "count." .. kind, "open for " .. (S.now - S.openMs) .. " ms: remembered "
                    .. (items and Literal(items) or "nothing") .. ", in the bank " .. Literal(truth), { cause = cause })
            end
            if doubt then
                Violate(prefix .. "doubt." .. kind, "open for " .. (S.now - S.openMs) .. " ms and still in doubt", { cause = cause })
            end
        end
        -- A bank this character may not view cannot be read by its visits:
        -- a doubt mark on it stays whatever the character does.
        if S.bankOpen and S.now - S.openMs >= SETTLE and not Viewable(kind) and doubt then
            Violate("I3.stuck." .. kind, "in doubt, and this character's visit (open for " .. (S.now - S.openMs)
                .. " ms) cannot read that bank to take the mark away", { cause = cause })
        end
    end
    -- An alt's bank that is in doubt is left out too: the scan's third
    -- return names the alt, and the Shopping tab has a line for it.
    local other = S.chars[OtherName()]
    if other then
        local items, _, doubt = Remembered("character", OtherName())
        if items and doubt then
            local name, named = NAME[OtherName()], false
            for _, listed in ipairs(meta.altBanksInDoubt or {}) do
                if listed == name then named = true end
            end
            if not named then
                Violate("I2.alt", "the other character's bank is in doubt and left out; the scan's third return does not name it", { cause = Cause() })
            elseif not ShoppingLine(meta):find("The bank of " .. name .. " is not counted", 1, true) then
                Violate("I2.alt", "the other character's bank is in doubt and left out; the Shopping tab starts with: "
                    .. ShoppingLine(meta), { cause = Cause() })
            end
        elseif meta.altBanksInDoubt ~= nil then
            Violate("I2.alt", "the scan names an alt whose bank is not in doubt", { cause = Cause() })
        end
    elseif meta.altBanksInDoubt ~= nil then
        Violate("I2.alt", "the scan names an alt, and there is no other character", { cause = Cause() })
    end
    -- The model itself: with nothing on its way the client shows the truth.
    if InFlight() == 0 then
        for container, shown in pairs(S.shown) do
            local truth = TruthOf(container)
            if truth and (not KindOf(container) or S.bankOpen) then
                for index = 1, shown.slots do
                    local a, b = shown[index], truth[index]
                    if (a and a.n or 0) ~= (b and b.n or 0) or (a and a.id) ~= (b and b.id) then
                        error("model: container " .. container .. " slot " .. index .. " shows what is not there")
                    end
                end
            end
        end
    end
    if S.lastVisit and not S.bankOpen then JudgeVisit(S.lastVisit) end
end

-- A scan past the frame cache, and what it says against the truth.
-- level: "mid" (between two events of a frame), "frame" (a frame's events
-- and timers are through), "step" (the same, for the density that scans only
-- in frames the player acted in), "settled".
local function Observe(level)
    if not S.addon then return end
    local density = S.density
    if level == "mid" and density ~= "event" then return end
    if level == "frame" and density == "step" then return end
    if level == "step" and density ~= "step" then return end
    S.stats.scans = S.stats.scans + 1
    local inventory = S.addon.Inventory
    local ok, combined, breakdown, meta = pcall(function()
        inventory:InvalidateCache()
        return inventory:ScanAll()
    end)
    local own, alt, shown = Truths()
    if S.trace then
        Emit("obs(\"" .. level .. "\", " .. Literal(own) .. ", " .. Literal(alt) .. ")")
    end
    if not ok then
        Violate("I5.error", "scan: " .. tostring(combined))
        return
    end
    if #World.errors > S.errorsSeen then
        Violate("I5.handler", World.errors[#World.errors])
        S.errorsSeen = #World.errors
    end
    for _, id in ipairs(ALL_ITEMS) do
        local where = breakdown[id]
        local ownScan, altScan = 0, 0
        if where then
            ownScan = (where.bags or 0) + (where.bank or 0)
            for _, sources in pairs(where.alts or {}) do
                altScan = altScan + (sources.bags or 0) + (sources.bank or 0)
            end
        end
        if (combined[id] or 0) ~= ownScan + altScan then
            Violate("sanity.sum", "item " .. id .. ": the total is not the sum of its sources")
        end
        Track(level, "own", id, ownScan, own[id] or 0, ownScan <= (shown[id] or 0))
        Track(level, "alt", id, altScan, alt[id] or 0, false)
    end
    if level == "settled" then
        S.stats.settled = S.stats.settled + 1
        if type(meta) ~= "table" then
            Violate("sanity.meta", "no third return")
        else
            SettledChecks(meta)
        end
    end
    if level ~= "mid" then
        -- While something is over, look again on the very next frame (three
        -- times at most): that tells one frame from longer.
        if next(S.episodes) ~= nil and density ~= "step" and S.follows < 3 then
            S.followUp = true
            S.follows = S.follows + 1
        else
            S.followUp = false
            if next(S.episodes) == nil then S.follows = 0 end
        end
    end
end

-- Events ---------------------------------------------------------------------

local function Touched()
    S.lastEvent = S.now
    S.settleChecked = false
    S.activity = true
end

local function Fire(name, arg)
    if S.trace then
        Emit(arg ~= nil and ("ev(\"" .. name .. "\", " .. tostring(arg) .. ")") or ("ev(\"" .. name .. "\")"))
    end
    Guard(name, World.event, S.addon, name, arg)
    Touched()
    Observe("mid")
end

local function BagUpdate(container)
    Emit("upd(" .. container .. ")")
    Guard("BAG_UPDATE", World.bagUpdate, S.addon, container)
    if not KindOf(container) then S.lastBagUpdateMs = S.now end
    S.updatesSince = S.updatesSince + 1
    Touched()
    Observe("mid")
end

local function DelayedEvent()
    Emit("delayed()")
    Guard("BAG_UPDATE_DELAYED", World.bagUpdateDelayed, S.addon)
    Touched()
    Observe("mid")
end

local Process

local function Enqueue(d)
    S.seq = S.seq + 1
    d.seq = S.seq
    d.epoch = S.epoch
    if d.at <= S.now and S.flushed then
        Process(d)
        return
    end
    local queue = S.queue
    local index = #queue + 1
    while index > 1 and queue[index - 1].at > d.at do
        queue[index] = queue[index - 1]
        index = index - 1
    end
    queue[index] = d
end

-- The batch of bag updates just delivered is complete (switch 5).
local function BatchEnd()
    if S.updatesSince == 0 then return end
    S.updatesSince = 0
    if cfg.delayed == "same" then
        DelayedEvent()
    elseif cfg.delayed == "next" then
        Enqueue({ at = S.now + 1, kind = "delayed" })
    end
end

local function Dirty(container, index, delta)
    local key = container * 100 + index
    S.dirty[key] = (S.dirty[key] or 0) + delta
end

Process = function(d)
    if d.kind == "upd" then
        local touched = {}
        for _, set in ipairs(d.sets or {}) do
            -- A bank's part of a move whose answer comes after the bank was
            -- opened again: the opening has shown it already.
            if not (KindOf(set.c) and d.epoch ~= S.epoch) then
                if S.shown[set.c] then
                    S.shown[set.c][set.s] = CopyItem(set.item)
                    touched[set.c] = true
                end
                Dirty(set.c, set.s, -1)
            end
        end
        for container in pairs(touched) do PushView(container) end
        -- The client shows the move now: a visit is judged by how long
        -- after this it ended (see CloseNotice).
        if S.visit and d.epoch == S.epoch then S.visit.lastMoveMs = S.now end
        for _ = 1, d.rep or 1 do BagUpdate(d.c) end
        if d.chain then
            d.chain.at = S.now + d.chainGap
            local chain = d.chain
            d.chain = nil
            Enqueue(chain)
            chain.epoch = d.epoch
        end
    elseif d.kind == "delayed" then
        DelayedEvent()
        S.updatesSince = 0
    elseif d.kind == "idle" then
        BagUpdate(d.c)
    elseif d.kind == "arrive" then
        -- The bank's items are all there now (switch 4).
        if d.epoch == S.epoch and S.bankOpen and S.mask[d.bank] ~= "full" then
            S.mask[d.bank] = "full"
            for _, container in ipairs(BankContainers(d.bank)) do
                S.arrived[container] = nil
                PushView(container)
            end
            if d.ev then
                for _, container in ipairs(BankContainers(d.bank)) do BagUpdate(container) end
            end
        end
    elseif d.kind == "bags" then
        -- The carried bags' items are there now (after a login).
        if S.bagsHidden then
            S.bagsHidden = false
            for container in pairs(Me().bags) do PushView(container) end
            for container in pairs(Me().bags) do
                if d.ev then BagUpdate(container) end
            end
        end
    end
end

-- Frames ---------------------------------------------------------------------
-- Time is whole milliseconds. A frame is a moment; GetTime() is the same all
-- through it. Each frame runs the timers that are due (never one asked for
-- in this frame) and delivers what the client has for it, in the order the
-- acting step says (tf: timers first). The player's actions happen inside a
-- frame too, before or after its deliveries (pos).

local function SetClock()
    World.time = S.now / 1000
    World.serverTime = S.serverBase + floor(S.now / 1000)
end

local function RunTimers()
    local timers = World.timers
    if #timers == 0 then return end
    local pass, rest
    for index = 1, #timers do
        local timer = timers[index]
        if timer.due <= World.time + 1e-9 then
            pass = pass or {}
            pass[#pass + 1] = timer
        else
            rest = rest or {}
            rest[#rest + 1] = timer
        end
    end
    if not pass then return end
    World.timers = rest or {}
    Emit("timers()")
    for _, timer in ipairs(pass) do
        Guard("timer", timer.fn)
        S.activity = true
    end
    Observe("mid")
end

local function DeliverDue()
    local queue = S.queue
    while queue[1] and queue[1].at <= S.now do
        Process(table.remove(queue, 1))
    end
    BatchEnd()
end

local function Flush(timersFirst)
    if S.flushed then return end
    S.flushed = true
    if timersFirst then RunTimers() end
    DeliverDue()
    if not timersFirst then RunTimers() end
end

local function EndFrame(timersFirst)
    Flush(timersFirst)
    BatchEnd()
    if S.activity or S.followUp then
        S.activity = false
        Observe("frame")
    end
    if not S.settleChecked and S.now - S.lastEvent >= SETTLE and #S.queue == 0 then
        S.settleChecked = true
        Observe("settled")
    end
end

local function NewFrame(at)
    S.now = at
    S.frameNo = S.frameNo + 1
    S.flushed = false
    S.stats.frames = S.stats.frames + 1
    SetClock()
    Emit("at(" .. at .. ")")
end

-- Move the clock on by dt ms in frames of fm ms; the frame at the end stays
-- open for the next action. Frames in which nothing can happen are skipped:
-- they lie on the same grid either way.
local function Advance(dt, fm, timersFirst)
    local target = S.now + dt
    while true do
        local nextAt = target
        local first = S.queue[1]
        if first and first.at < nextAt then nextAt = first.at end
        for _, timer in ipairs(World.timers) do
            local due = timer.due * 1000
            if due < nextAt then nextAt = due end
        end
        if not S.settleChecked and #S.queue == 0 and S.lastEvent + SETTLE < nextAt then nextAt = S.lastEvent + SETTLE end
        if S.followUp then nextAt = S.now end
        local frames = max(1, ceil((nextAt - S.now) / fm - 1e-9))
        local at = S.now + frames * fm
        if at >= target then
            NewFrame(target)
            return
        end
        NewFrame(at)
        EndFrame(timersFirst)
    end
end

-- Sessions -------------------------------------------------------------------

local function Login(who, a)
    S.cur = who
    local me = Me()
    World.guid, World.name, World.faction = GUID[who], NAME[who], "Horde"
    Emit("World.guid, World.name = \"" .. GUID[who] .. "\", \"" .. NAME[who] .. "\"")
    S.shown, S.dirty, S.queue, S.arrived = {}, {}, {}, {}
    S.mask = { character = "empty", account = "empty" }
    S.bankOpen, S.refused, S.epoch = false, false, S.epoch + 1
    S.bagsHidden = (a.bagsLate or 0) > 0
    World.containers = {}
    Emit("World.containers = {}")
    for container, truth in pairs(me.bags) do S.shown[container] = CopyContainer(truth) end
    for container, truth in pairs(me.bank) do S.shown[container] = CopyContainer(truth) end
    for container, truth in pairs(S.account) do S.shown[container] = CopyContainer(truth) end
    for _, container in ipairs({ BACKPACK, BAG, TAB1, TAB2, ACCOUNT_TAB }) do
        if S.shown[container] then PushView(container) end
    end
    PushBank()
    Emit("login(" .. tostring(S.init) .. ")")
    local ok, err = pcall(function()
        S.addon = World.login(S.saved, { init = S.init })
        if S.init then S.addon:OnEnable() end
    end)
    if not ok then
        Violate("I5.error", "login: " .. tostring(err))
        error("the session could not start: " .. tostring(err))
    end
    -- Which doubt marks are set, and during or after which visit.
    local memory = S.addon.StockMemory
    local markBank, markAccount = memory.MarkBankDoubt, memory.MarkAccountBankDoubt
    memory.MarkBankDoubt = function(self, guid)
        local new = markBank(self, guid)
        local v = S.visit or S.lastVisit
        if new and v then v.marks.character = v.marks.character + 1 end
        return new
    end
    memory.MarkAccountBankDoubt = function(self, world)
        local new = markAccount(self, world)
        local v = S.visit or S.lastVisit
        if new and v then v.marks.account = v.marks.account + 1 end
        if new and not Me().view then
            Violate("I4.blindmark.account", "the account bank was marked in doubt by a character that may not view it"
                .. " (and so cannot have changed it, and cannot read it to take the mark away)", { cause = Cause() })
        end
        return new
    end
    S.visit, S.lastVisit, S.closeMs = nil, nil, nil
    S.lastArrival = nil
    S.loginMs = S.now
    S.updatesSince = 0
    S.sessions = S.sessions + 1
    Touched()
    if S.bagsHidden then
        Enqueue({ at = S.now + a.bagsLate, kind = "bags", ev = true })
    elseif a.loginUpd then
        for _, container in ipairs({ BACKPACK, BAG }) do BagUpdate(container) end
    end
end

-- The player's actions --------------------------------------------------------

local function Usable(container, index)
    local truth = TruthOf(container)
    if not truth or index > truth.slots then return false end
    if (S.dirty[container * 100 + index] or 0) ~= 0 then return false end
    local kind = KindOf(container)
    if kind then
        if not S.bankOpen then return false end
        if kind == "account" and not Me().view then return false end
        local mask = S.mask[kind]
        if mask == "full" then return true end
        if mask == "partial" then
            local arrived = S.arrived[container]
            return (arrived and arrived[index]) and true or false
        end
        return false
    end
    return not S.bagsHidden
end

-- What the client shows of the carried bags, item by item.
local function ShownBags()
    local counts = {}
    for container in pairs(Me().bags) do
        if S.shown[container] then AddCounts(counts, S.shown[container]) end
    end
    return counts
end

-- The player changed what the character holds: for judging the visit.
-- counts: the carried bags hold other counts afterwards (loot, a craft), in
-- the second after a close. Call it after the change.
-- Decided: a carried count that rises in that second for an item a bank of
-- the visit is remembered to hold marks that bank - the rules cannot tell
-- it from the answer of a last withdrawal, also when it was loot or a craft.
-- Such a visit is filed as "+rise" and is no failure; any other change of
-- the bags in that second ("+after": a count that fell, an item no
-- remembered bank holds) must leave no mark.
local function NoteChange(counts)
    local v = S.visit
    if v then
        v.moves = v.moves + 1
        v.lastMoveMs = S.now
    elseif counts and S.lastVisit and S.closeMs and S.now - S.closeMs <= 1000 then
        local last = S.lastVisit
        local now, rose = ShownBags(), false
        for _, kind in ipairs({ "character", "account" }) do
            local held = Remembered(kind, last.who)
            for _, id in ipairs(ALL_ITEMS) do
                if (now[id] or 0) > ((last.bagsAtClose or {})[id] or 0) and held and (held[id] or 0) > 0 then rose = true end
            end
        end
        if rose then last.afterRise = true else last.after = true end
    end
end

-- When the answer of a move asked for now arrives: `lat` ms from now, never
-- before the answer of an earlier move (the server answers in order), and -
-- with its second update `gap` ms behind the first - never more than a
-- second from now. An answer is handled in the first frame at or after its
-- time, so the latest time is a frame (33 ms at most here) short of the
-- second: whatever closes after the click, the answer is heard within a
-- second of it. Returns the first update's time and the gap in force.
local LATEST = 1000 - 40
local function Arrival(lat, gap)
    local at = max(S.now + lat, S.lastArrival or 0)
    if at > S.now + LATEST then at = S.now + LATEST end
    gap = min(gap or 0, S.now + LATEST - at)
    S.lastArrival = at + gap
    return at, gap
end

local OPS = {}

function OPS.wait() end

function OPS.scan()
    local density = S.density
    S.density = "step"
    Observe("step")
    S.density = density
end

-- Move n of what is in (sc, ss) to (dc, ds): onto an empty slot, onto a stack
-- of the same item, or - a whole stack onto another item - swapped. The true
-- world changes at the click; the client hears of it later (switch 2).
function OPS.move(a)
    if not Usable(a.sc, a.ss) or not Usable(a.dc, a.ds) then return end
    if a.sc == a.dc and a.ss == a.ds then return end
    if not S.habits.bankToBank and KindOf(a.sc) and KindOf(a.dc) and KindOf(a.sc) ~= KindOf(a.dc) then return end
    if not S.habits.emptyBags and ((a.sc == BACKPACK and a.ss == 1) or (a.dc == BACKPACK and a.ds == 1)) then return end
    if not S.habits.afterCloseChange and not S.bankOpen and S.closeMs and S.now - S.closeMs <= 1100 then return end
    local from, to = TruthOf(a.sc), TruthOf(a.dc)
    local item, target = from[a.ss], to[a.ds]
    if not item then return end
    local n = min(a.n, item.n)
    if item.bound and KindOf(a.dc) == "account" then return end
    if not target then
        to[a.ds] = { id = item.id, n = n, bound = item.bound }
        item.n = item.n - n
        if item.n == 0 then from[a.ss] = nil end
    elseif target.id == item.id and (target.bound or false) == (item.bound or false) then
        local room = min(n, MAX_STACK - target.n)
        if room <= 0 then return end
        target.n = target.n + room
        item.n = item.n - room
        if item.n == 0 then from[a.ss] = nil end
    else
        if n < item.n then return end
        if target.bound and KindOf(a.sc) == "account" then return end
        from[a.ss], to[a.ds] = target, item
    end
    NoteChange()
    local srcSet = { c = a.sc, s = a.ss, item = CopyItem(from[a.ss]) }
    local dstSet = { c = a.dc, s = a.ds, item = CopyItem(to[a.ds]) }
    Dirty(a.sc, a.ss, 1)
    Dirty(a.dc, a.ds, 1)
    local at, gap = Arrival(a.lat, a.gap)
    if a.sc == a.dc then
        Enqueue({ at = at, kind = "upd", c = a.sc, sets = { srcSet, dstSet } })
        return
    end
    local firstSet, secondSet = srcSet, dstSet
    if a.first == "dst" then firstSet, secondSet = dstSet, srcSet end
    local across = KindOf(a.sc) ~= nil and KindOf(a.dc) ~= nil and KindOf(a.sc) ~= KindOf(a.dc)
    local d1 = { at = at, kind = "upd", c = firstSet.c, sets = { firstSet }, across = across }
    local d2 = { at = at, kind = "upd", c = secondSet.c, sets = { secondSet }, across = across }
    if a.atomic then
        d1.sets, d2.sets = { firstSet, secondSet }, {}
    end
    if gap > 0 then
        d1.chain, d1.chainGap = d2, gap
        Enqueue(d1)
    else
        Enqueue(d1)
        Enqueue(d2)
    end
end

-- Sort a container: its stacks merged and put in order, told in one frame by
-- several bag updates.
function OPS.sort(a)
    local truth = TruthOf(a.c)
    if not truth then return end
    if not S.habits.emptyBags and a.c == BACKPACK then return end
    local stacks = {}
    for index = 1, truth.slots do
        if not Usable(a.c, index) then return end
        local item = truth[index]
        if item then
            local merged = false
            for _, stack in ipairs(stacks) do
                if stack.id == item.id and (stack.bound or false) == (item.bound or false) and stack.n < MAX_STACK then
                    local room = min(item.n, MAX_STACK - stack.n)
                    stack.n = stack.n + room
                    if item.n > room then stacks[#stacks + 1] = { id = item.id, n = item.n - room, bound = item.bound } end
                    merged = true
                    break
                end
            end
            if not merged then stacks[#stacks + 1] = CopyItem(item) end
        end
    end
    table.sort(stacks, function(x, y)
        if x.id ~= y.id then return x.id < y.id end
        return x.n > y.n
    end)
    local sets = {}
    for index = 1, truth.slots do
        local before, after = truth[index], stacks[index]
        if (before and before.id) ~= (after and after.id) or (before and before.n) ~= (after and after.n) then
            truth[index] = CopyItem(after)
            sets[#sets + 1] = { c = a.c, s = index, item = CopyItem(after) }
            Dirty(a.c, index, 1)
        end
    end
    if #sets == 0 then return end
    NoteChange()
    Enqueue({ at = (Arrival(a.lat, 0)), kind = "upd", c = a.c, sets = sets, rep = a.rep })
end

-- Put n of an item into the carried bags, at once (the client's answer and
-- the truth are the same thing here). Returns the container it went into.
local function IntoBags(id, n)
    local me = Me()
    for _, container in ipairs({ BACKPACK, BAG }) do
        local truth = me.bags[container]
        for index = 1, truth.slots do
            local item = truth[index]
            if item and item.id == id and not item.bound and item.n + n <= MAX_STACK and Usable(container, index) then
                item.n = item.n + n
                S.shown[container][index] = CopyItem(item)
                return container
            end
        end
    end
    for _, container in ipairs({ BACKPACK, BAG }) do
        local truth = me.bags[container]
        for index = 1, truth.slots do
            if not truth[index] and Usable(container, index) then
                truth[index] = { id = id, n = n }
                S.shown[container][index] = CopyItem(truth[index])
                return container
            end
        end
    end
    return nil
end

function OPS.loot(a)
    if S.bagsHidden then return end
    if not S.habits.afterCloseChange and not S.bankOpen and S.closeMs and S.now - S.closeMs <= 1100 then return end
    local container = IntoBags(a.id, a.n)
    if not container then return end
    NoteChange(true)
    PushView(container)
    BagUpdate(container)
end

-- Craft: n of an item leave the carried bags, and one of another may come.
function OPS.craft(a)
    if S.bagsHidden then return end
    if not S.habits.afterCloseChange and not S.bankOpen and S.closeMs and S.now - S.closeMs <= 1100 then return end
    local me = Me()
    local changed = {}
    for _, container in ipairs({ BACKPACK, BAG }) do
        local truth = me.bags[container]
        for index = 1, truth.slots do
            local item = truth[index]
            if item and item.id == a.id and not item.bound and Usable(container, index) and not next(changed) then
                local n = min(a.n, item.n)
                item.n = item.n - n
                if item.n == 0 then truth[index] = nil end
                S.shown[container][index] = CopyItem(truth[index])
                changed[container] = true
            end
        end
    end
    if not next(changed) then return end
    if a.makes then
        local container = IntoBags(a.makes, 1)
        if container then changed[container] = true end
    end
    NoteChange(true)
    for _, container in ipairs({ BACKPACK, BAG }) do
        if changed[container] then PushView(container) end
    end
    for _, container in ipairs({ BACKPACK, BAG }) do
        if changed[container] then BagUpdate(container) end
    end
end

-- A bag update of a carried bag that changes nothing (switch 6).
function OPS.idle(a)
    if not cfg.idle then return end
    for _ = 1, a.rep or 1 do BagUpdate(a.c) end
end

function OPS.zone()
    if not cfg.idle or S.bankOpen then return end
    BagUpdate(BACKPACK)
    BagUpdate(BAG)
end

-- A tab is bought at the banker: the character bank's second, or the account
-- bank's first. That changes the bank (its slot count), so for judging the
-- visit it counts like a move: a visit closed right after it was hurried.
function OPS.buytab(a)
    if not S.bankOpen then return end
    local me = Me()
    if a.kind == "character" then
        if me.bank[TAB2] then return end
        NoteChange()
        me.bank[TAB2] = { slots = 4 }
        S.shown[TAB2] = { slots = 4 }
        PushBank()
        PushView(TAB2)
        Fire("BANK_TABS_CHANGED", 0)
    else
        if S.account[ACCOUNT_TAB] or not me.view then return end
        NoteChange()
        S.account[ACCOUNT_TAB] = { slots = 5 }
        S.shown[ACCOUNT_TAB] = { slots = 5 }
        PushBank()
        PushView(ACCOUNT_TAB)
        Fire("BANK_TABS_CHANGED", 2)
    end
end

local function Hash(seed, a, b)
    return (seed * 7919 + a * 104729 + b * 1299709) % 2147483647
end

function OPS.open(a)
    if S.bankOpen then return end
    -- The server answers in order: the answer of a move asked for earlier
    -- cannot come after the bank's contents of this opening.
    while S.queue[1] do Process(table.remove(S.queue, 1)) end
    BatchEnd()
    local me = Me()
    S.bankOpen, S.openMs, S.refused = true, S.now, false
    S.epoch = S.epoch + 1
    me.visited = true
    -- The opening shows the bank as it is; a bank's part of an answer still
    -- on its way is void.
    for _, kind in ipairs({ "character", "account" }) do
        for _, container in ipairs(BankContainers(kind)) do
            S.shown[container] = CopyContainer(TruthOf(container))
            for index = 1, S.shown[container].slots do S.dirty[container * 100 + index] = nil end
        end
    end
    local mode = cfg.open
    for _, kind in ipairs({ "character", "account" }) do
        if mode == "all" then
            S.mask[kind] = "full"
        else
            local partial = mode == "partial" or mode == "partialSilent"
            S.mask[kind] = partial and "partial" or "empty"
            if partial then
                for _, container in ipairs(BankContainers(kind)) do
                    local arrived = {}
                    for index = 1, S.shown[container].slots do
                        arrived[index] = Hash(a.pseed or 1, container, index) % 2 == 0
                    end
                    S.arrived[container] = arrived
                end
            end
            Enqueue({ at = S.now + (kind == "character" and a.arrive1 or a.arrive2), kind = "arrive", bank = kind,
                      ev = (mode == "late" or mode == "partial") })
        end
    end
    PushBank()
    PushBankViews()
    -- A mark set while the opening is handled is the last visit's (the
    -- comparison its close left due): that visit is judged with it, the new
    -- one begins after.
    S.visit = nil
    Fire("BANKFRAME_OPENED")
    JudgeVisit(S.lastVisit)
    S.visit = { who = S.cur, openMs = S.now, moves = 0, marks = { character = 0, account = 0 }, cause = "visit" }
end

-- What the client does to the bank around its closing notice (switches 3 and
-- 1), then the notice itself (event: nil at a logout that sends none).
local function CloseNotice(a, event)
    local v = S.visit
    v.closeMs = S.now
    v.bagsAtClose = ShownBags()
    v.inflight = InFlight()
    -- Hurried: the window is closed while the answer of a move is still on
    -- its way, or less than half a second after the client showed the last
    -- move (its answer arrived - with a server that takes 0.3 s that is later
    -- than the click, and an emptied bank needs two looks 0.2 s apart from
    -- there before it is believed empty).
    v.hurried = (v.lastMoveMs ~= nil and S.now - v.lastMoveMs < 500) or v.inflight > 0
    v.cause = (v.moves == 0 and "glance" or (v.hurried and "hurried" or "unhurried")) .. (v.inflight > 0 and ",inflight" or "")
        .. (S.now - v.openMs < SETTLE and ",short" or "")
    if cfg.letgo then
        S.mask.character, S.mask.account = "empty", "empty"
        PushBankViews()
        for _, kind in ipairs({ "character", "account" }) do
            for _, container in ipairs(BankContainers(kind)) do BagUpdate(container) end
        end
        if a.letgoBatch then BatchEnd() end
    end
    if cfg.closeRead == "refused" then
        S.refused = true
        PushBank()
    elseif cfg.closeRead == "empty" then
        S.mask.character, S.mask.account = "empty", "empty"
        PushBankViews()
    elseif cfg.closeRead == "noslots" then
        S.mask.character, S.mask.account = "noslots", "noslots"
        PushBankViews()
    end
    if event then
        Fire(event)
        if a.twice then Fire(event) end
    end
    S.bankOpen, S.closeMs = false, S.now
    S.lastVisit, S.visit = v, nil
    S.mask.character, S.mask.account = "empty", "empty"
    S.arrived = {}
    if not event then return end
    S.refused = false
    PushBank()
    PushBankViews()
end

-- leaveEarly (see ALSO): the visit would end before the whole of a partly
-- shown bank has been read.
local function LeavesEarly(a)
    if S.habits.leaveEarly or a.tail or not S.bankOpen then return false end
    if cfg.open ~= "partial" and cfg.open ~= "partialSilent" then return false end
    return S.now - S.openMs < 2100 or S.mask.character == "partial" or S.mask.account == "partial"
end

function OPS.close(a)
    if not S.bankOpen then return end
    if not S.habits.closeMidMove and InFlight() > 0 and not a.tail then return end
    if LeavesEarly(a) then return end
    if cfg.idle and a.idleBefore then BagUpdate(BACKPACK) end
    CloseNotice(a, "BANKFRAME_CLOSED")
    if cfg.idle and a.idleAfter then
        if a.idleAfter == 0 then BagUpdate(BACKPACK) else Enqueue({ at = S.now + a.idleAfter, kind = "idle", c = BACKPACK }) end
    end
end

-- Log out (or reload), then log in again: as the same character or the other.
function OPS.logout(a)
    if not S.habits.logoutMidMove and InFlight() > 0 and not a.tail then return end
    if not S.habits.logoutMidBankMove and InFlightAcrossBanks() and not a.tail then return end
    if LeavesEarly(a) then return end
    -- emptyBagsLogout (see ALSO): the bags hold nothing and their save is
    -- still waiting.
    if not S.habits.emptyBagsLogout and not a.tail and next(ShownBags()) == nil
            and S.lastBagUpdateMs and S.now - S.lastBagUpdateMs < 2100 then
        return
    end
    if not S.habits.logoutAfterClose and not S.bankOpen and S.closeMs and S.now - S.closeMs <= 1100 and not a.tail then return end
    if S.bankOpen then
        CloseNotice(a, a.closeFirst and "BANKFRAME_CLOSED" or nil)
    end
    if cfg.idle and a.idle then
        BagUpdate(BACKPACK)
        BagUpdate(BAG)
    end
    Fire("PLAYER_LOGOUT")
    if a.twice then
        if S.init then
            Emit("shutdown()")
            Guard("OnDatabaseShutdown", S.addon.OnDatabaseShutdown, S.addon)
        else
            Fire("PLAYER_LOGOUT")
        end
    end
    JudgeVisit(S.lastVisit)
    for key, e in pairs(S.episodes) do
        FinishEpisode(e, "the logout")
        S.episodes[key] = nil
    end
    S.followUp, S.follows = false, 0
    local who = S.cur
    if a.next == "other" and S.chars[OtherName()] then who = OtherName() end
    NewFrame(S.now + max(16, a.away or 3000))
    S.flushed = true
    Login(who, a)
end

-- One action: in the open frame, before or after that frame's deliveries and
-- timers; then the clock moves on by a.dt (0: the next action is in this
-- very frame).
local function Exec(a)
    S.step = S.step + 1
    S.op = a.op
    S.cause = nil
    if S.trace then Emit("-- [" .. S.step .. "] " .. a.text) end
    if a.pos ~= "before" then Flush(a.tf) end
    S.cause = Cause()
    OPS[a.op](a)
    if S.flushed then BatchEnd() end
    if (a.dt or 0) > 0 then
        EndFrame(a.tf)
        Observe("step")
        Advance(a.dt, a.fm or 16, a.tf)
    end
end

-- The player --------------------------------------------------------------------

local function Timing(a, rng)
    if cfg.latency == "none" then
        a.lat = rng.chance(0.6) and 0 or rng.pick({ 8, 16, 33 })
    elseif cfg.latency == "short" then
        a.lat = rng.int(20, 300)
    else
        a.lat = rng.chance(0.25) and rng.int(20, 300) or rng.int(300, 1000)
    end
    if cfg.spread == "apart" or cfg.spread == "late" then
        a.gap = rng.chance(0.7) and rng.pick({ 1, 16, 33, 50 }) or rng.int(60, 200)
    else
        a.gap = 0
    end
    if a.lat + a.gap > LATEST then a.lat = LATEST - a.gap end
    a.atomic = cfg.spread == "same" or cfg.spread == "late"
end

local CLASS = { bags = { BACKPACK, BAG }, char = { TAB1, TAB2 }, acct = { ACCOUNT_TAB } }

local function GenMove(rng, fromClass, toClass, habits)
    local sources = {}
    if not habits.bankToBank and fromClass ~= toClass and fromClass ~= "bags" and toClass ~= "bags" then return nil end
    for _, container in ipairs(CLASS[fromClass]) do
        local truth = TruthOf(container)
        if truth then
            for index = 1, truth.slots do
                local pinned = not habits.emptyBags and container == BACKPACK and index == 1
                if truth[index] and Usable(container, index) and not pinned then sources[#sources + 1] = { container, index } end
            end
        end
    end
    if #sources == 0 then return nil end
    local src = rng.pick(sources)
    local item = TruthOf(src[1])[src[2]]
    local targets = {}
    for _, container in ipairs(CLASS[toClass]) do
        local truth = TruthOf(container)
        if truth then
            for index = 1, truth.slots do
                local pinned = not habits.emptyBags and container == BACKPACK and index == 1
                if Usable(container, index) and not (container == src[1] and index == src[2]) and not pinned then
                    local there = truth[index]
                    if not there or (there.id == item.id and there.n < MAX_STACK) or rng.chance(0.1) then
                        targets[#targets + 1] = { container, index }
                    end
                end
            end
        end
    end
    if #targets == 0 then return nil end
    local dst = rng.pick(targets)
    local n = item.n
    if n > 1 and rng.chance(0.4) then n = rng.int(1, n - 1) end
    local a = { op = "move", sc = src[1], ss = src[2], dc = dst[1], ds = dst[2], n = n }
    Timing(a, rng)
    local srcBank, dstBank = KindOf(a.sc) ~= nil, KindOf(a.dc) ~= nil
    if srcBank ~= dstBank then
        a.first = ((cfg.order == "bank") == srcBank) and "src" or "dst"
    else
        a.first = rng.chance(0.5) and "src" or "dst"
    end
    return a
end

local BOUNDARY_WAITS = { 199, 200, 201, 499, 500, 501, 999, 1000, 1001, 1999, 2000, 2001 }

local function GenWait(rng)
    local ms
    if rng.chance(0.12) then
        ms = rng.pick(BOUNDARY_WAITS)
    else
        ms = rng.pick({ 16, 100, 100, 300, 300, 1000, 1000, 3000, 3000 })
    end
    return { op = "wait", dt = ms }
end

local function GenLogout(rng)
    local other = rng.chance(0.5)
    return { op = "logout", next = other and "other" or "same", closeFirst = rng.chance(0.5), twice = rng.chance(0.3),
             idle = rng.chance(0.5), away = other and rng.pick({ 5000, 60000, 3600000, 10800000 }) or rng.int(2000, 6000),
             loginUpd = rng.chance(0.7), bagsLate = rng.chance(0.15) and rng.int(100, 1500) or 0,
             letgoBatch = rng.chance(0.5) }
end

local function GenAction(rng, habits)
    local a
    local roll = rng.int(1, 1000)
    local hurry = S.hurry
    S.hurry = false
    if S.bankOpen then
        local canClose = habits.closeMidMove or InFlight() == 0
        local canLogout = habits.logoutMidMove or InFlight() == 0
        if hurry and canClose and rng.chance(0.45) then
            roll = 500
        end
        if roll <= 430 then
            local pick = rng.int(1, 100)
            if pick <= 33 then a = GenMove(rng, "bags", "char", habits)
            elseif pick <= 66 then a = GenMove(rng, "char", "bags", habits)
            elseif pick <= 76 then a = GenMove(rng, "char", "acct", habits)
            elseif pick <= 84 then a = GenMove(rng, "acct", "char", habits)
            elseif pick <= 90 then a = GenMove(rng, "bags", "acct", habits)
            elseif pick <= 95 then a = GenMove(rng, "acct", "bags", habits)
            elseif pick <= 98 then a = GenMove(rng, "char", "char", habits)
            else a = GenMove(rng, "bags", "bags", habits) end
        elseif roll <= 465 then
            a = { op = "sort", c = rng.pick(habits.emptyBags and { TAB1, TAB1, BACKPACK, ACCOUNT_TAB } or { TAB1, ACCOUNT_TAB }),
                  rep = rng.int(1, 4) }
            Timing(a, rng)
        elseif roll <= 650 then
            if canClose then
                a = { op = "close", twice = rng.chance(0.1), idleBefore = rng.chance(0.3),
                      idleAfter = rng.chance(0.4) and rng.pick({ 0, 0, 16, 100, 400, 900, 1000 }) or nil,
                      letgoBatch = rng.chance(0.5) }
            end
        elseif roll <= 790 then
            a = GenWait(rng)
        elseif roll <= 830 then
            a = { op = "loot", id = rng.pick(ITEMS), n = rng.int(1, 5) }
        elseif roll <= 880 then
            a = { op = "craft", id = rng.pick(ITEMS), n = rng.int(1, 3), makes = rng.chance(0.5) and rng.pick(ITEMS) or nil }
        elseif roll <= 900 then
            a = { op = "buytab", kind = rng.chance(0.6) and "character" or "account" }
        elseif roll <= 925 then
            if canLogout then a = GenLogout(rng) end
        elseif roll <= 965 then
            if cfg.idle then a = { op = "idle", c = rng.pick({ BACKPACK, BAG }), rep = rng.int(1, 2) } end
        else
            a = { op = "scan" }
        end
    else
        local canLogout = habits.logoutMidMove or InFlight() == 0
        local watch = S.closeMs and S.now - S.closeMs <= 1100
        local canChange = habits.afterCloseChange or not watch
        if roll <= 330 then
            a = { op = "open", arrive1 = rng.int(100, 1500), arrive2 = rng.int(100, 1500), pseed = rng.int(1, 100000) }
        elseif roll <= 430 then
            if canChange then a = { op = "loot", id = rng.pick(ITEMS), n = rng.int(1, 5) } end
        elseif roll <= 510 then
            if canChange then
                a = { op = "craft", id = rng.pick(ITEMS), n = rng.int(1, 3), makes = rng.chance(0.5) and rng.pick(ITEMS) or nil }
            end
        elseif roll <= 570 then
            if canChange then a = GenMove(rng, "bags", "bags", habits) end
        elseif roll <= 800 then
            a = GenWait(rng)
        elseif roll <= 850 then
            if canLogout then a = GenLogout(rng) end
        elseif roll <= 920 then
            if cfg.idle then
                a = rng.chance(0.5) and { op = "zone" } or { op = "idle", c = rng.pick({ BACKPACK, BAG }), rep = rng.int(1, 2) }
            end
        else
            a = { op = "scan" }
        end
    end
    a = a or GenWait(rng)
    a.pos = rng.chance(0.25) and "before" or "after"
    a.fm = rng.pick({ 8, 16, 16, 16, 20, 33 })
    a.tf = rng.chance(0.5)
    if a.dt == nil then
        local roll2 = rng.int(1, 100)
        if a.op == "open" then
            if not habits.quickVisit then a.dt = rng.int(2100, 3500)
            elseif roll2 <= 10 then a.dt = 0
            elseif roll2 <= 20 then a.dt = a.fm
            elseif roll2 <= 40 then a.dt = rng.int(50, 250)
            elseif roll2 <= 70 then a.dt = rng.int(300, 800)
            else a.dt = rng.int(1000, 2500) end
        elseif a.op == "logout" then
            a.dt = rng.pick({ 100, 1000, 2500, 3000, 3000 })
        else
            if roll2 <= 33 then a.dt = 0
            elseif roll2 <= 55 then a.dt = a.fm
            elseif roll2 <= 80 then a.dt = rng.int(50, 250)
            else a.dt = rng.int(300, 800) end
        end
    end
    if S.bankOpen and (a.op == "move" or a.op == "sort" or a.op == "craft" or a.op == "loot") and a.dt <= 33 then
        S.hurry = true
    end
    return a
end

local CONTAINER_NAME = { [BACKPACK] = "backpack", [BAG] = "bag 1", [TAB1] = "bank tab 6", [TAB2] = "bank tab 7", [ACCOUNT_TAB] = "account tab 15" }

local function Describe(a)
    local text
    if a.op == "move" then
        text = string.format("move %d from %s slot %d to %s slot %d (answer after %d ms, %s first%s%s)", a.n,
            CONTAINER_NAME[a.sc], a.ss, CONTAINER_NAME[a.dc], a.ds, a.lat,
            a.first == "src" and "the source's update" or "the target's update",
            a.gap > 0 and (", the other " .. a.gap .. " ms later") or ", both in one frame",
            a.atomic and ", both containers changed with the first" or "")
    elseif a.op == "sort" then
        text = string.format("sort %s (answer after %d ms, %d updates)", CONTAINER_NAME[a.c], a.lat, a.rep or 1)
    elseif a.op == "loot" then
        text = string.format("loot %d of item %d", a.n, a.id)
    elseif a.op == "craft" then
        text = string.format("craft: %d of item %d used%s", a.n, a.id, a.makes and (", one of item " .. a.makes .. " made") or "")
    elseif a.op == "open" then
        text = "open the bank"
    elseif a.op == "close" then
        text = "close the bank" .. (a.twice and " (the notice comes twice)" or "")
    elseif a.op == "logout" then
        text = "log out" .. (a.closeFirst and "" or " (no close notice)") .. ", log in as " .. (a.next == "other" and "the other character" or "the same character")
            .. " " .. tostring(a.away) .. " ms later"
    elseif a.op == "buytab" then
        text = "buy a tab: " .. a.kind
    elseif a.op == "idle" then
        text = "the client sends an idle update of " .. CONTAINER_NAME[a.c]
    elseif a.op == "zone" then
        text = "zone change: idle updates of the carried bags"
    else
        text = a.op
    end
    return text .. (a.pos == "before" and " [before this frame's deliveries]" or "")
        .. ((a.dt or 0) > 0 and ("; then " .. a.dt .. " ms") or "; next action in the same frame")
end

-- A shrunk walk in one line, for sorting many of them into heaps.
local function Skeleton(actions)
    local CLASS_OF = { [BACKPACK] = "bags", [BAG] = "bags", [TAB1] = "char", [TAB2] = "char", [ACCOUNT_TAB] = "acct" }
    local parts = {}
    for _, a in ipairs(actions) do
        local name = a.op
        if a.op == "move" then
            name = "mv(" .. CLASS_OF[a.sc] .. ">" .. CLASS_OF[a.dc] .. (a.lat > 0 and ",lat" or "") .. (a.gap > 0 and ",gap" or "") .. ")"
        elseif a.op == "logout" then
            name = "logout(" .. a.next .. (a.closeFirst and "" or ",noclose") .. ")"
        elseif a.op == "sort" then
            name = "sort(" .. CLASS_OF[a.c] .. ")"
        elseif a.op == "buytab" then
            name = "buytab(" .. a.kind .. ")"
        end
        local dt = a.dt or 0
        local wait = dt == 0 and "" or (dt <= 33 and "+f" or (dt < 200 and "+s" or (dt < 500 and "+m" or (dt < 2000 and "+l" or "+L"))))
        if a.op == "wait" then name = "" end
        parts[#parts + 1] = name .. wait
    end
    return table.concat(parts, " ")
end

-- The standard ending of every walk: let things settle, close, settle, log
-- in again as the same character and then as the other one - so that what
-- lasts is seen.
local TAIL = {
    { op = "wait", dt = 3000 },
    { op = "close", dt = 3000 },
    { op = "logout", next = "same", closeFirst = true, away = 3000, loginUpd = true, dt = 3000 },
    { op = "logout", next = "other", closeFirst = true, away = 5000, loginUpd = true, dt = 3000 },
    { op = "wait", dt = 100 },
}
for _, a in ipairs(TAIL) do a.tail = true end

local function NewWalk(config, init, opts)
    cfg = config
    World.reset()
    S = {
        chars = nil, account = nil, cur = "A",
        now = 1000, frameNo = 0, flushed = true, serverBase = 20000 * 86400 + 3600,
        queue = {}, seq = 0, epoch = 0, dirty = {}, shown = {}, arrived = {}, mask = {},
        saved = {}, violations = {}, episodes = {}, step = 0, sessions = 0,
        lastEvent = 1000, settleChecked = false, activity = false, followUp = false, follows = 0,
        updatesSince = 0, errorsSeen = 0, loginMs = 1000,
        density = opts.density or "frame", init = opts.init or false, habits = opts.habits or DEFAULT_HABITS,
        trace = opts.trace and {} or nil, wanted = opts.wanted,
        stats = { scans = 0, frames = 0, visits = {}, episodes = {}, longest = {}, doubtNeeded = 0, doubtIdle = 0,
                  doubtSettled = 0, unseen = 0, healChecks = 0, settled = 0 },
    }
    local world = CopyInit(init)
    S.chars, S.account = world.chars, world.account
    S.bankTruths = BankTruthLiterals
    SetClock()
    Emit("at(1000)")
    Login("A", { loginUpd = true })
    S.activity = true
end

local function EndWalk()
    for _, a in ipairs(TAIL) do
        a.text = a.text or Describe(a)
        Exec(a)
    end
    EndFrame(true)
    JudgeVisit(S.lastVisit)
    for key, e in pairs(S.episodes) do
        FinishEpisode(e, "the end of the walk")
        S.episodes[key] = nil
    end
    S.stats.steps = S.step
end

-- A walk of `steps` random actions. Returns the walk (violations, stats) and
-- the actions, which Replay runs again.
local function Walk(config, seed, steps, opts)
    local rng = Rng(seed)
    local init = RandomInit(rng)
    opts = opts or {}
    if opts.habits and not opts.habits.emptyBags then
        for _, char in pairs(init.chars) do
            char.bags[BACKPACK][1] = { id = STONE, n = 1, bound = true }
        end
    end
    opts.density = opts.density or ({ "frame", "event", "step" })[seed % 3 + 1]
    if opts.init == nil then opts.init = seed % 4 == 0 end
    local habits = opts.habits or DEFAULT_HABITS
    NewWalk(config, init, opts)
    local actions = {}
    for _ = 1, steps do
        local a = GenAction(rng, habits)
        a.text = Describe(a)
        actions[#actions + 1] = a
        Exec(a)
    end
    EndWalk()
    return S, actions, init, opts
end

local function Replay(config, init, actions, opts)
    NewWalk(config, init, opts)
    for _, a in ipairs(actions) do
        a.text = Describe(a)
        Exec(a)
    end
    EndWalk()
    return S
end

-- ===========================================================================
-- Shrinking
-- ===========================================================================
local function Fails(config, init, actions, opts, wanted)
    local ok, walk = pcall(Replay, config, init, actions, { density = opts.density, init = opts.init, habits = opts.habits })
    if not ok then return nil end
    for _, v in ipairs(walk.violations) do
        if wanted(v) then return v end
    end
    return nil
end

local function CopyAction(a)
    local copy = {}
    for k, value in pairs(a) do copy[k] = value end
    return copy
end

local function ShrinkOnce(config, init, actions, opts, wanted)
    -- 1. Whole actions, in halves, quarters, ... ones.
    local chunks = 2
    while #actions >= 1 do
        local size = ceil(#actions / chunks)
        local reduced = false
        local start = 1
        while start <= #actions do
            local candidate = {}
            for index, a in ipairs(actions) do
                if index < start or index >= start + size then candidate[#candidate + 1] = a end
            end
            if #candidate < #actions and Fails(config, init, candidate, opts, wanted) then
                actions = candidate
                chunks = max(chunks - 1, 2)
                reduced = true
                break
            end
            start = start + size
        end
        if not reduced then
            if size <= 1 then break end
            chunks = min(chunks * 2, #actions)
        end
    end
    -- 2. Each action's parameters towards the plain case.
    local SIMPLER = {
        dt = { 0, 16, 100, 300, 500, 1000, 2000, 3000 }, lat = { 0, 16, 100, 300 }, gap = { 0, 1, 16 },
        away = { 3000 }, bagsLate = { 0 }, rep = { 1 }, fm = { 16 },
    }
    local FLAGS = { twice = false, idleBefore = false, idle = false, atomic = true, tf = true, letgoBatch = false, closeFirst = true,
                    loginUpd = true }
    local changed = true
    while changed do
        changed = false
        for index = 1, #actions do
            local a = actions[index]
            local function try(key, value)
                if a[key] == nil or a[key] == value then return false end
                local candidate = {}
                for i, other in ipairs(actions) do candidate[i] = other end
                candidate[index] = CopyAction(a)
                candidate[index][key] = value
                if Fails(config, init, candidate, opts, wanted) then
                    actions = candidate
                    a = candidate[index]
                    changed = true
                    return true
                end
                return false
            end
            for key, values in pairs(SIMPLER) do
                for _, value in ipairs(values) do
                    if type(a[key]) == "number" and value < a[key] and try(key, value) then break end
                end
            end
            for key, value in pairs(FLAGS) do try(key, value) end
            if a.pos == "before" then try("pos", "after") end
            if a.idleAfter ~= nil then
                local candidate = {}
                for i, other in ipairs(actions) do candidate[i] = other end
                candidate[index] = CopyAction(a)
                candidate[index].idleAfter = nil
                if Fails(config, init, candidate, opts, wanted) then actions = candidate; changed = true end
            end
        end
    end
    -- 3. The world: stacks out, the second tab out, the other character out.
    local function tryInit(change)
        local candidate = CopyInit(init)
        if change(candidate) == false then return end
        if Fails(config, candidate, actions, opts, wanted) then init = candidate end
    end
    tryInit(function(w) if not w.chars.B then return false end w.chars.B = nil end)
    for _, who in ipairs({ "A", "B" }) do
        for _, part in ipairs({ "bags", "bank" }) do
            for _, container in ipairs({ BACKPACK, BAG, TAB1, TAB2 }) do
                for index = 1, 6 do
                    tryInit(function(w)
                        local c = w.chars[who] and w.chars[who][part][container]
                        if not c or not c[index] then return false end
                        c[index] = nil
                    end)
                end
            end
        end
        tryInit(function(w)
            local c = w.chars[who]
            if not c or not c.bank[TAB2] then return false end
            c.bank[TAB2] = nil
        end)
    end
    for index = 1, 5 do
        tryInit(function(w)
            local c = w.account[ACCOUNT_TAB]
            if not c or not c[index] then return false end
            c[index] = nil
        end)
    end
    return actions, init
end

local function WorldSize(init)
    local n = 0
    for _, char in pairs(init.chars) do
        n = n + 1
        for _, part in ipairs({ "bags", "bank" }) do
            for _, container in pairs(char[part]) do
                n = n + 1
                for index = 1, container.slots do if container[index] then n = n + 1 end end
            end
        end
    end
    for _, container in pairs(init.account) do
        for index = 1, container.slots do if container[index] then n = n + 1 end end
    end
    return n
end

-- Until nothing gets smaller: a smaller world makes more actions idle, and
-- fewer actions make more of the world idle.
local function Shrink(config, init, actions, opts, wanted)
    while true do
        local before, world = #actions, WorldSize(init)
        actions, init = ShrinkOnce(config, init, actions, opts, wanted)
        if #actions >= before and WorldSize(init) >= world then return actions, init end
    end
end

-- A shrunk failure as a script of its own: it needs scripts/lib/stockworld.lua
-- and nothing of this file.
local SCRIPT_HEAD = [[
-- %s
--
-- Found by the random walk (test_stockfuzz.lua) and cut down to the shortest
-- sequence that still shows it. It drives the real WoW Forever adapter, the
-- scanner and the stock memory through scripts/lib/stockworld.lua.
--   client configuration: %s
--   scans: %s; Core/Init.lua loaded: %s
--   what it shows: %s
--     %s
-- Run from the addon root:  lua5.1 %s
-- It prints every scan that counts more than is owned, then the state at
-- the end (the scan, the visit as /lp diag stock tells it, what is
-- remembered of each bank against what it holds), and exits with 1 when the
-- failure shows (0 when it does not).

package.path = "./?.lua;" .. package.path
local World = require("scripts.lib.stockworld")
World.install()
World.FRAME = 0.001          -- a timer is due a millisecond after the ask at the earliest: never in the same frame
World.reset()
local slot = World.slot
local saved, addon = {}, nil
local over, failures = 0, {}

-- A frame at `ms` (whole milliseconds since the client started).
local function at(ms)
    World.time = ms / 1000
    World.serverTime = 20000 * 86400 + 3600 + math.floor(ms / 1000)
end
-- The timers that are due in this frame, in the order they were asked for.
local function timers()
    local pass, rest = {}, {}
    for _, timer in ipairs(World.timers) do
        if timer.due <= World.time + 1e-9 then pass[#pass + 1] = timer else rest[#rest + 1] = timer end
    end
    World.timers = rest
    for _, timer in ipairs(pass) do timer.fn() end
end
local function login(init)
    addon = World.login(saved, { init = init })
    if init then addon:OnEnable() end
end
local function ev(name, arg) World.event(addon, name, arg) end
local function upd(bag) World.bagUpdate(addon, bag) end
local function delayed() World.bagUpdateDelayed(addon) end
local function shutdown() addon:OnDatabaseShutdown() end
local ITEMS = { 2589, 4306, 2770, 6948 }
-- A scan past the frame cache, against what is really owned (own: bags +
-- bank + account bank of this character; alt: what the other one could send).
local function obs(level, own, alt)
    addon.Inventory:InvalidateCache()
    local combined, breakdown, meta = addon.Inventory:ScanAll()
    for _, id in ipairs(ITEMS) do
        local where = breakdown[id] or {}
        local mine, others = (where.bags or 0) + (where.bank or 0), 0
        for _, sources in pairs(where.alts or {}) do others = others + (sources.bags or 0) + (sources.bank or 0) end
        if mine > (own[id] or 0) then
            over = over + 1
            print(string.format("t=%%.3f  OVER   item %%d: counted %%d (bags %%d + banks %%d), owned %%d   [%%s]", World.time, id, mine,
                where.bags or 0, where.bank or 0, own[id] or 0, level))
        end
        if others > (alt[id] or 0) then
            over = over + 1
            print(string.format("t=%%.3f  OVER   item %%d on the other character: counted %%d, it has %%d   [%%s]", World.time, id, others,
                alt[id] or 0, level))
        end
    end
    return combined, breakdown, meta
end
-- What is remembered of a bank against what it really holds: "right",
-- "more" (it would be counted twice), "less" or "nothing remembered"; and
-- whether it carries the doubt mark.
local function bank(kind, guid, truth)
    local items, _, doubt
    if kind == "character" then items, _, doubt = addon.StockMemory:OwnBank(guid) else items, _, doubt = addon.StockMemory:AccountBank("eu-pvp") end
    local verdict = "right"
    if not items then
        verdict = "nothing remembered"
    else
        for _, id in ipairs(ITEMS) do
            local r, t = items[id] or 0, truth[id] or 0
            if r > t then verdict = "more" elseif r < t and verdict ~= "more" then verdict = "less" end
        end
    end
    local parts = {}
    for _, id in ipairs(ITEMS) do
        if (items and items[id]) or truth[id] then parts[#parts + 1] = id .. ": remembered " .. tostring(items and items[id] or 0) .. ", there " .. tostring(truth[id] or 0) end
    end
    print("          " .. kind .. " bank: " .. verdict .. (doubt and ", IN DOUBT" or "") .. "  { " .. table.concat(parts, "; ") .. " }")
    return verdict, doubt
end
local function state(label)
    addon.Inventory:InvalidateCache()
    local combined, breakdown, meta = addon.Inventory:ScanAll()
    local parts = {}
    for _, id in ipairs(ITEMS) do
        if combined[id] then parts[#parts + 1] = id .. "=" .. combined[id] end
    end
    print(string.format("t=%%.3f  %%s: scan { %%s }  bankInDoubt=%%s accountInDoubt=%%s bankPending=%%s accountPending=%%s", World.time, label,
        table.concat(parts, ", "), tostring(meta.bankInDoubt), tostring(meta.accountInDoubt), tostring(meta.bankPending),
        tostring(meta.accountPending)))
    local lines = {}
    addon.Inventory:RunDiagnostic(lines)
    for _, line in ipairs(lines) do
        if line:find("^bank visit") or line:find("^after the close") or line:find("^character:") or line:find("^account bank:") then
            print("          " .. line)
        end
    end
end

]]

local function WriteScript(path, title, config, opts, v, trace, traceEnd)
    local file = assert(io.open(path, "w"))
    file:write(string.format(SCRIPT_HEAD, title, Key(config), opts.density, tostring(opts.init), v.kind,
        tostring(v.detail), path))
    for index = 1, traceEnd do
        file:write(trace[index], "\n")
    end
    file:write("\nstate(\"at the end\")\n")
    local banks = S.foundBanks
    if banks then
        file:write("local characterIs, characterDoubt = bank(\"character\", \"" .. banks.guid .. "\", " .. banks.character .. ")\n")
        file:write("local accountIs, accountDoubt = bank(\"account\", nil, " .. banks.account .. ")\n")
    else
        file:write("local characterIs, characterDoubt, accountIs, accountDoubt\n")
    end
    file:write(string.format("print(%q)\n", "found by the walk: " .. v.kind .. " - " .. tostring(v.detail)))
    file:write("if #World.errors > 0 then print(\"handed to the error handler: \" .. World.errors[1]) end\n")
    -- What shows the failure, by its kind.
    local kind, shown = v.kind, "over > 0"
    local which = kind:match("%.(%a+)$")
    local is = (which == "account") and "accountIs" or "characterIs"
    local doubt = (which == "account") and "accountDoubt" or "characterDoubt"
    if kind:find("^I2%.stale") or kind:find("^I3x?%.count") then
        shown = "(" .. is .. " == \"less\" or " .. is .. " == \"nothing remembered\" or " .. is .. " == \"more\") and not " .. doubt
    elseif kind:find("^I1%.latent") then
        shown = is .. " == \"more\" and not " .. doubt
    elseif kind:find("^I4%.") or kind:find("^I3x?%.doubt") or kind:find("^I3%.stuck") then
        shown = "characterDoubt or accountDoubt"
    elseif kind:find("^I2%.alt") or kind:find("^I2%.") then
        shown = "true"
    elseif kind:find("^I5%.") then
        shown = "#World.errors > 0"
    end
    file:write("local shown = " .. shown .. "\n")
    file:write("print(over > 0 and (over .. \" scan(s) counted more than is owned\") or \"no scan counted more than is owned\")\n")
    file:write("print(shown and \"REPRODUCED\" or \"not reproduced\")\n")
    file:write("os.exit((shown or #World.errors > 0) and 1 or 0)\n")
    file:close()
end

-- ===========================================================================
-- Modes
-- ===========================================================================
local MODE = os.getenv("STOCKFUZZ_MODE") or "suite"
local OUT = os.getenv("STOCKFUZZ_OUT")

local function Habits()
    local habits = {}
    for k, value in pairs(DEFAULT_HABITS) do habits[k] = value end
    for name in (os.getenv("STOCKFUZZ_HABITS") or ""):gmatch("[^,]+") do
        habits[name] = false
    end
    for name in (os.getenv("STOCKFUZZ_ALSO") or ""):gmatch("[^,]+") do
        habits[name] = true
    end
    return habits
end

local function SeedOf(index, seed)
    return (index * 7919 + seed * 104729 + 12345) % 2147483647
end

local function Combos()
    local which = os.getenv("STOCKFUZZ_COMBOS") or "all"
    local list = {}
    local every, from = which:match("^(%d+)/(%d+)$")
    -- STOCKFUZZ_WHERE: "switch=value,switch=value" keeps the combinations that have them all
    local where = {}
    for name, value in (os.getenv("STOCKFUZZ_WHERE") or ""):gmatch("(%w+)=(%w+)") do
        where[name] = value
    end
    for index = 0, ComboCount() - 1 do
        local config = Combo(index)
        local fits = true
        for name, value in pairs(where) do
            if tostring(config[name]) ~= value then fits = false end
        end
        if not fits then
            -- left out
        elseif which == "all" then
            list[#list + 1] = config
        elseif which == "wb" then
            if WellBehaved(config) then list[#list + 1] = config end
        elseif every then
            if index % tonumber(from) == tonumber(every) then list[#list + 1] = config end
        elseif Key(config) == which then
            list[#list + 1] = config
        end
    end
    return list
end

local function Signature(v)
    return v.kind .. " @ " .. tostring(v.cause)
end

if MODE == "campaign" then
    local first, last = (os.getenv("STOCKFUZZ_SEEDS") or "1-1"):match("^(%d+)-(%d+)$")
    first, last = tonumber(first), tonumber(last)
    local steps = tonumber(os.getenv("STOCKFUZZ_STEPS") or "300")
    local habits = Habits()
    local combos = Combos()
    local kinds, signatures, visits = {}, {}, {}
    local marginal, marginalWalks = {}, {}      -- [kind][switch=value] = walks with it; [switch=value] = walks
    local totals = { walks = 0, steps = 0, scans = 0, frames = 0, sessions = 0, crashed = 0, settled = 0, healChecks = 0, visits = 0 }
    local started = os.clock()
    for _, config in ipairs(combos) do
        local key = Key(config)
        for seed = first, last do
            local ok, walk = pcall(Walk, config, SeedOf(config.index, seed), steps, { habits = habits })
            if not ok then
                totals.crashed = totals.crashed + 1
                print("CRASH " .. key .. " seed " .. seed .. ": " .. tostring(walk))
            else
                totals.walks = totals.walks + 1
                totals.steps = totals.steps + walk.stats.steps
                totals.scans = totals.scans + walk.stats.scans
                totals.frames = totals.frames + walk.stats.frames
                totals.sessions = totals.sessions + walk.sessions
                totals.settled = totals.settled + walk.stats.settled
                totals.healChecks = totals.healChecks + walk.stats.healChecks
                for _, counts in pairs(walk.stats.visits) do totals.visits = totals.visits + counts.n end
                local seen = {}
                for _, switch in ipairs(SWITCHES) do
                    local cell = switch[1] .. "=" .. tostring(config[switch[1]])
                    marginalWalks[cell] = (marginalWalks[cell] or 0) + 1
                end
                for _, v in ipairs(walk.violations) do
                    local kind = kinds[v.kind]
                    if not kind then
                        kind = { n = 0, walks = 0, wb = 0, longest = 0 }
                        kinds[v.kind] = kind
                    end
                    kind.n = kind.n + 1
                    if v.ms then
                        -- how long it lasted: up to a frame, 0.25 s, 1 s, 2.5 s, longer
                        local bucket = v.ms <= 33 and 1 or (v.ms <= 250 and 2 or (v.ms <= 1000 and 3 or (v.ms <= 2500 and 4 or 5)))
                        kind.lasted = kind.lasted or { 0, 0, 0, 0, 0 }
                        kind.lasted[bucket] = kind.lasted[bucket] + 1
                    end
                    if v.ms and v.ms > kind.longest then
                        kind.longest = v.ms
                        kind.longestAt = key .. "\t" .. seed .. "\t" .. v.step .. "\t" .. tostring(v.cause) .. "\t" .. tostring(v.detail)
                    end
                    if not seen[v.kind] then
                        seen[v.kind] = true
                        kind.walks = kind.walks + 1
                        if WellBehaved(config) then kind.wb = kind.wb + 1 end
                        local row = marginal[v.kind] or {}
                        marginal[v.kind] = row
                        for _, switch in ipairs(SWITCHES) do
                            local cell = switch[1] .. "=" .. tostring(config[switch[1]])
                            row[cell] = (row[cell] or 0) + 1
                        end
                    end
                    local sig = Signature(v)
                    local entry = signatures[sig]
                    if not entry then
                        entry = { n = 0, key = key, seed = seed, step = v.step, detail = v.detail, wb = 0, combos = {} , ncombos = 0 }
                        signatures[sig] = entry
                    end
                    entry.n = entry.n + 1
                    if not entry.combos[key] then
                        entry.combos[key] = true
                        entry.ncombos = entry.ncombos + 1
                        if WellBehaved(config) then entry.wb = entry.wb + 1 end
                    end
                    -- Prefer an example from a well-behaved client, then a short one.
                    if (WellBehaved(config) and not entry.wbExample) then
                        entry.wbExample = true
                        entry.key, entry.seed, entry.step, entry.detail = key, seed, v.step, v.detail
                    end
                end
                local stat = visits[key]
                if not stat then
                    stat = {}
                    visits[key] = stat
                end
                for class, counts in pairs(walk.stats.visits) do
                    local s = stat[class] or { n = 0, doubt = 0 }
                    stat[class] = s
                    s.n = s.n + counts.n
                    s.doubt = s.doubt + counts.doubt
                end
                stat.needed = (stat.needed or 0) + walk.stats.doubtNeeded
                stat.idle = (stat.idle or 0) + walk.stats.doubtIdle
            end
        end
    end
    local tag = os.getenv("STOCKFUZZ_TAG") or "campaign"
    local function out(name)
        return OUT and assert(io.open(OUT .. "/" .. tag .. "." .. name, "w")) or io.stdout
    end
    local f = out("totals.txt")
    f:write(string.format("combos=%d seeds=%d-%d steps/walk=%d walks=%d steps=%d scans=%d frames=%d sessions=%d visits=%d settled=%d healChecks=%d crashed=%d seconds=%.1f habits_off=%s\n",
        #combos, first, last, steps, totals.walks, totals.steps, totals.scans, totals.frames, totals.sessions, totals.visits,
        totals.settled, totals.healChecks, totals.crashed, os.clock() - started, os.getenv("STOCKFUZZ_HABITS") or "-"))
    if f ~= io.stdout then f:close() end
    f = out("kinds.tsv")
    local names = {}
    for kind in pairs(kinds) do names[#names + 1] = kind end
    table.sort(names)
    for _, kind in ipairs(names) do
        local k = kinds[kind]
        f:write(string.format("%s\t%d\t%d\t%d\t%d\t%s\n", kind, k.n, k.walks, k.wb, k.longest, k.longestAt or ""))
    end
    if f ~= io.stdout then f:close() end
    f = out("lasted.tsv")
    f:write("kind\t<=33ms\t<=250ms\t<=1s\t<=2.5s\tlonger\n")
    for _, kind in ipairs(names) do
        local l = kinds[kind].lasted
        if l then f:write(string.format("%s\t%d\t%d\t%d\t%d\t%d\n", kind, l[1], l[2], l[3], l[4], l[5])) end
    end
    if f ~= io.stdout then f:close() end
    f = out("marginals.tsv")
    for _, kind in ipairs(names) do
        for _, switch in ipairs(SWITCHES) do
            for _, value in ipairs(switch[2]) do
                local cell = switch[1] .. "=" .. tostring(value)
                f:write(string.format("%s\t%s\t%d\t%d\n", kind, cell, marginal[kind][cell] or 0, marginalWalks[cell] or 0))
            end
        end
    end
    if f ~= io.stdout then f:close() end
    f = out("signatures.tsv")
    names = {}
    for sig in pairs(signatures) do names[#names + 1] = sig end
    table.sort(names)
    for _, sig in ipairs(names) do
        local e = signatures[sig]
        f:write(string.format("%s\t%d\t%d\t%d\t%s\t%d\t%d\t%s\n", sig, e.n, e.ncombos, e.wb, e.key, e.seed, e.step, tostring(e.detail)))
    end
    if f ~= io.stdout then f:close() end
    f = out("visits.tsv")
    names = {}
    for key in pairs(visits) do names[#names + 1] = key end
    table.sort(names)
    for _, key in ipairs(names) do
        local stat = visits[key]
        local parts = { key }
        for _, class in ipairs({ "glance", "glance+after", "glance+rise", "unhurried", "unhurried+after", "unhurried+rise",
                                 "hurried", "hurried+after", "hurried+rise" }) do
            local s = stat[class] or { n = 0, doubt = 0 }
            parts[#parts + 1] = s.n
            parts[#parts + 1] = s.doubt
        end
        parts[#parts + 1] = stat.needed or 0
        parts[#parts + 1] = stat.idle or 0
        f:write(table.concat(parts, "\t"), "\n")
    end
    if f ~= io.stdout then f:close() end
    os.exit(0)
end

if MODE == "shrink" then
    local config = assert(ComboByKey(os.getenv("STOCKFUZZ_COMBOS") or ""), "STOCKFUZZ_COMBOS must be one combination's key")
    local seed = tonumber(os.getenv("STOCKFUZZ_SEED") or "1")
    local steps = tonumber(os.getenv("STOCKFUZZ_STEPS") or "300")
    local kind = assert(os.getenv("STOCKFUZZ_KIND"), "STOCKFUZZ_KIND")
    local cause = os.getenv("STOCKFUZZ_CAUSE")
    local name = os.getenv("STOCKFUZZ_NAME") or kind:gsub("%.", "_")
    local habits = Habits()
    local least = tonumber(os.getenv("STOCKFUZZ_MS") or "")
    local exact = os.getenv("STOCKFUZZ_CAUSE_EXACT") == "1"
    local function wanted(v)
        return v.kind == kind and (not least or (v.ms or 0) >= least)
            and (not cause or (exact and tostring(v.cause) == cause) or (not exact and tostring(v.cause):find(cause, 1, true) ~= nil))
    end
    local walk, actions, init, opts = Walk(config, SeedOf(config.index, seed), steps, { habits = habits })
    local hit
    for _, v in ipairs(walk.violations) do
        if wanted(v) then hit = v break end
    end
    if not hit then
        print("that walk has no such failure")
        os.exit(2)
    end
    -- Nothing after the step that showed it is needed.
    local cut = {}
    for index = 1, min(hit.step, #actions) do cut[index] = actions[index] end
    if not Fails(config, init, cut, opts, wanted) then cut = actions end
    local shrunkActions, shrunkInit = Shrink(config, init, cut, opts, wanted)
    local final = Replay(config, shrunkInit, shrunkActions, { density = opts.density, init = opts.init, habits = opts.habits,
                                                               trace = true, wanted = wanted })
    local v = final.found
    print("kind: " .. kind .. "   client: " .. Key(config) .. "   scans: " .. opts.density .. "   init: " .. tostring(opts.init))
    print("skeleton: " .. kind .. " | " .. Skeleton(shrunkActions))
    print("shrunk from " .. #cut .. " to " .. #shrunkActions .. " actions:")
    for index, a in ipairs(shrunkActions) do print(string.format("  %2d. %s", index, a.text)) end
    if not v then
        print("the shrunk walk lost the failure while tracing (a defect of this test)")
        os.exit(3)
    end
    print("what it shows: " .. tostring(v.detail) .. "  [" .. tostring(v.cause) .. "]")
    if OUT then
        local path = OUT .. "/repro_" .. name .. ".lua"
        WriteScript(path, "Reproduction: " .. kind, config, opts, v, final.trace, final.traceEnd or #final.trace)
        print("script: " .. path)
    end
    os.exit(0)
end

-- ===========================================================================
-- The suite: three fixed samples of client configurations, seeds and players.
-- ===========================================================================
local steps = tonumber(os.getenv("STOCKFUZZ_STEPS") or "120")
local found, examples = {}, {}
local walks, totalSteps, scans = 0, 0, 0

-- One walk; its failures are added to `found` under their kinds (those that
-- `keep` lets through, when it is given; a string from it files the failure
-- under that name).
local function run(config, seed, habits, keep)
    local ok, walk = pcall(Walk, config, SeedOf(config.index, seed), steps, { habits = habits })
    walks = walks + 1
    if not ok then
        found["walk"] = (found["walk"] or 0) + 1
        examples["walk"] = examples["walk"] or (Key(config) .. " seed " .. seed .. ": " .. tostring(walk))
        return
    end
    totalSteps = totalSteps + walk.stats.steps
    scans = scans + walk.stats.scans
    for _, v in ipairs(walk.violations) do
        local kept = not keep or keep(v.kind, config)
        if kept then
            local kind = type(kept) == "string" and kept or v.kind
            found[kind] = (found[kind] or 0) + 1
            examples[kind] = examples[kind]
                or (Key(config) .. " seed " .. seed .. " step " .. v.step .. ": " .. tostring(v.detail) .. " [" .. tostring(v.cause) .. "]")
        end
    end
end

-- The entry of KNOWN that covers a kind of failure, if any.
local shown = {}
local function KnownEntry(kind)
    for _, entry in ipairs(KNOWN) do
        if kind:sub(1, #entry[1]) == entry[1] then return entry end
    end
    return nil
end

-- A check: no failure of the kinds that begin with one of the prefixes. Kinds
-- on the KNOWN list are printed with what is wrong and do not fail it.
local function none(label, ...)
    local n, example = 0, nil
    local kinds = {}
    for kind in pairs(found) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    for _, prefix in ipairs({ ... }) do
        for _, kind in ipairs(kinds) do
            if kind:sub(1, #prefix) == prefix then
                local entry = KnownEntry(kind)
                if entry then
                    if not shown[entry] then
                        shown[entry] = true
                        print("KNOWN: " .. entry[1] .. " (" .. found[kind] .. " time(s)): " .. entry[2])
                    end
                else
                    n = n + found[kind]
                    example = example or (kind .. " - " .. examples[kind])
                end
            end
        end
    end
    T.check(label, n == 0, n > 0 and (n .. " time(s); first: " .. example) or nil)
end

-- Every entry of KNOWN must still show: one that does not has been put right
-- and is to be taken off the list.
local function knownStillShow()
    for _, entry in ipairs(KNOWN) do
        T.check("known failure still shows: " .. entry[1], shown[entry] == true,
            "no walk shows it any more: take it off the KNOWN list")
    end
end

local function startsWith(kind, ...)
    for _, prefix in ipairs({ ... }) do
        if kind:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- The clock of the walks is the game's: a timer never runs in the frame
-- that asked for it, whoever asked (an event or another timer), and runs in
-- the first frame at or after its mark.
do
    NewWalk(Combo(0), { chars = { A = { bags = { [BACKPACK] = { slots = 6 }, [BAG] = { slots = 4 } }, bank = { [TAB1] = { slots = 6 } }, view = true } },
                        account = {} }, { density = "step" })
    World.timers = {}
    local ran = {}
    C_Timer.After(0, function()
        ran[#ran + 1] = S.now
        C_Timer.After(0, function() ran[#ran + 1] = S.now end)
    end)
    C_Timer.After(0.2, function() ran[#ran + 1] = -S.now end)
    local asked = S.now
    RunTimers()
    local sameFrame = #ran
    NewFrame(asked + 1)
    RunTimers()
    local nextFrame = #ran == 1 and ran[1] == asked + 1
    RunTimers()
    local notTwice = #ran == 1
    NewFrame(asked + 8)
    RunTimers()
    local chained = #ran == 2 and ran[2] == asked + 8
    NewFrame(asked + 199)
    RunTimers()
    local early = #ran
    NewFrame(asked + 205)
    RunTimers()
    T.check("the clock: a timer never runs in the frame that asked for it, and runs in the first frame at or after its mark",
        sameFrame == 0 and nextFrame and notTwice and chained and early == 2 and #ran == 3 and ran[3] == -(asked + 205),
        table.concat(ran, ","))
end

-- Sample 1, any player: every well-behaved client twice, every 41st and every
-- 61st of the others once.
for index = 0, ComboCount() - 1 do
    local config = Combo(index)
    if WellBehaved(config) then
        run(config, 1)
        run(config, 2)
    elseif index % 41 == 0 or index % 61 == 0 then
        run(config, 1)
    end
end

-- Sample 2, a careful player: one who does not log out or close while an
-- answer is on its way, does not move items between the two banks and always
-- carries something - on clients that change both containers of a move
-- before the first of its updates. Its failures are filed under "careful.":
-- nothing on the KNOWN list is expected of it.
local careful = {}
for name, value in pairs(DEFAULT_HABITS) do careful[name] = value end
careful.logoutMidMove, careful.closeMidMove, careful.bankToBank, careful.emptyBags = false, false, false, false
local CHECKED = { "sanity.", "I1.settled.", "I1.latent.", "I1.multi.", "I1.frame.", "I1.mid.", "I2.", "I3.", "I3x.", "I4.", "I5." }
do
    local n = 0
    for index = 0, ComboCount() - 1 do
        local config = Combo(index)
        if config.spread == "same" or config.spread == "late" then
            n = n + 1
            if n % 23 == 0 then
                run(config, 2, careful, function(kind) return startsWith(kind, unpack(CHECKED)) and ("careful." .. kind) end)
            end
        end
    end
end

-- Sample 3, the same player, but one who closes the bank while an answer is
-- on its way (and then leaves the bags alone and stays logged in for a
-- second) - on clients with both updates of a move in one frame. Filed
-- under "hasty.".
local hasty = {}
for name, value in pairs(careful) do hasty[name] = value end
hasty.closeMidMove, hasty.afterCloseChange, hasty.logoutAfterClose = true, false, false
do
    local n = 0
    for index = 0, ComboCount() - 1 do
        local config = Combo(index)
        if config.spread == "same" then
            n = n + 1
            if n % 19 == 0 then
                run(config, 3, hasty, function(kind) return startsWith(kind, unpack(CHECKED)) and ("hasty." .. kind) end)
            end
        end
    end
end

print(string.format("%d walks, %d actions, %d scans", walks, totalSteps, scans))
do
    local kinds = {}
    for kind in pairs(found) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    for _, kind in ipairs(kinds) do print(string.format("  %-22s %5d   %s", kind, found[kind], examples[kind])) end
end
none("the walks themselves ran through (the model holds)", "walk", "sanity.")
none("I1: no scan counts more than is owned once things have settled", "I1.settled.")
none("I1: no counted bank holds more than is in it once things have settled", "I1.latent.")
none("I1: no scan counts more than is owned for longer than a frame (the client itself not showing the item twice)", "I1.multi.")
none("I1: no scan counts more than is owned at the end of a frame", "I1.frame.")
none("I1: no scan counts more than is owned between two events of a frame", "I1.mid.")
none("I2: no counted bank is short without a word once things have settled", "I2.stale.", "I2.uncounted.")
none("I2: a bank in doubt is named by the scan and has its line on the Shopping tab", "I2.unsaid.", "I2.noline.")
none("I2: no bank is still left out as \"being read\" two seconds after the last event", "I2.pending.")
none("I2: an alt's bank that is left out is named too", "I2.alt")
none("I3: on a well-behaved client an open bank is right and without doubt after two quiet seconds", "I3.count.", "I3.doubt.")
none("I3: and on every other client", "I3x.")
none("I3: no bank is left in doubt that the character's own visit cannot read", "I3.stuck.", "I4.blindmark.")
none("I4: on a well-behaved client an unhurried visit leaves no doubt mark", "I4.nuisance", "I4.glance")
none("I4: nor does a change of the bags in the second after its close", "I4.afterclose")
none("I5: nothing raises, nothing reaches the error handler", "I5.")
none("a careful player (no close or logout while an answer is on its way, no move between the two banks, always something"
    .. " carried), both containers of a move changed before its first update: every check holds", "careful.")
none("the same player closing the bank before the answer of a move, both updates in one frame: every check holds", "hasty.")
knownStillShow()
T.finish()
