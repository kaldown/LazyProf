-- scripts/test_trainers.lua
--
-- Remembered trainers: which profession trainers the character has visited,
-- which recipes each one listed and the fees they charged. Nothing is shipped
-- and nothing is guessed; the memory is empty until a trainer is visited.
--
-- Run from the addon root:  lua5.1 scripts/test_trainers.lua

package.path = "./?.lua;" .. package.path
local harness = require("scripts.lib.harness")
local T = require("scripts.lib.check").new()

harness.stubWow({ interface = 16001, camelot = true })
local LazyProf = harness.loadLazyProf({
    "Core/Constants.lua",
    "Core/Utils.lua",
    "Core/Config.lua",
    "Modules/Recipes/Availability.lua",
    "Modules/Guide/Text.lua",
    "Modules/Guide/TrainerMemory.lua",
})
local Memory = LazyProf.TrainerMemory
LazyProf.db.global = { characters = {} }
_G.CraftLib = { GetActiveProfile = function() return "FOREVER" end }
-- The clock is the client adapter's; the global is never read from here.
LazyProf.Client = { Now = function() return 5000 end }
_G.GetServerTime = function() error("the server clock is read through the client adapter") end

local function recipe(id, name) return { id = id, name = name, source = { type = "trainer" }, reagents = {} } end
LazyProf.Professions = { registry = {
    tailoring = { name = "Tailoring", recipes = { recipe(1, "Linen Cloak"), recipe(2, "Woolen Cape"), recipe(3, "Silk Robe") } },
    alchemy = { name = "Alchemy", recipes = { recipe(11, "Minor Healing Potion"), recipe(12, "Elixir of Wisdom") } },
} }

local function info(extra)
    local i = { name = "Georgio Bolero", npcId = 1346, zone = "Stormwind City", subZone = "Mage Quarter",
                mapId = 84, x = 0.5312, y = 0.8124, faction = "Alliance" }
    for k, v in pairs(extra or {}) do i[k] = v end
    return i
end
local function service(name, cost, state) return { name = name, cost = cost, state = state or "available" } end

T.section("record", function()
    T.check("defaults declare the stores", type(LazyProf.defaults.global.trainers) == "table"
        and type(LazyProf.defaults.global.trainerFees) == "table")
    T.eq("nothing known at first", #Memory:Trainers("tailoring"), 0)
    T.check("no fee known", Memory:Fee(1) == nil)

    local profKey, added = Memory:Record(info(), {
        service("Tailoring (Journeyman)", 500),      -- a rank, not a recipe
        service("Linen Cloak", 50),
        service("Woolen Cape", 300),
        service("Silk Robe", 0, "used"),             -- already known: no fee shown
        service("Minor Healing Potion", 999),        -- another profession's recipe name (ignored for the match)
    })
    T.eq("the profession is the one most of its services belong to", profKey, "tailoring")
    T.check("something new was recorded", added == true)
    local list = Memory:Trainers("tailoring")
    T.eq("one trainer remembered", #list, 1)
    local t = list[1]
    T.eq("name", t.name, "Georgio Bolero")
    T.eq("zone", t.zone, "Stormwind City")
    T.eq("map id", t.mapId, 84)
    T.eq("position: where the player stood", string.format("%.2f %.2f", t.x, t.y), "0.53 0.81")
    T.eq("faction", t.faction, "Alliance")
    T.eq("when", t.seen, 5000)
    T.check("which recipes it listed", t.teaches[1] and t.teaches[2] and t.teaches[3] and not t.teaches[11])
    T.eq("fees remembered per recipe", Memory:Fee(1), 50)
    T.eq("another fee", Memory:Fee(2), 300)
    T.check("no fee for a service that showed none", Memory:Fee(3) == nil)
    T.check("a rank service is not a recipe: no fee stored for anything else", Memory:Fee(11) == nil)
    T.check("stored under the client profile", LazyProf.db.global.trainers.FOREVER.tailoring ~= nil
        and LazyProf.db.global.trainerFees.FOREVER[1] == 50)

    profKey, added = Memory:Record(info(), { service("Linen Cloak", 50), service("Woolen Cape", 300) })
    T.check("the same visit again records nothing new", profKey == "tailoring" and added == false)
    T.eq("still one trainer", #Memory:Trainers("tailoring"), 1)
    profKey, added = Memory:Record(info(), { service("Linen Cloak", 45) })
    T.check("a changed fee replaces the old one", added == true and Memory:Fee(1) == 45)
    T.check("recipes seen earlier are kept", Memory:Trainers("tailoring")[1].teaches[2] == true)

    -- A second trainer, another profession.
    Memory:Record(info({ name = "Alchemist Mallory", npcId = 1215, zone = "Elwynn Forest" }),
        { service("Minor Healing Potion", 10), service("Elixir of Wisdom", 100) })
    T.eq("another profession has its own list", Memory:Trainers("alchemy")[1].name, "Alchemist Mallory")
    T.eq("tailoring list untouched", #Memory:Trainers("tailoring"), 1)

    -- A recipe's trainers: only those that listed it.
    Memory:Record(info({ name = "Sellandus", npcId = 1103, zone = "Stormwind City" }), { service("Linen Cloak", 50) })
    local forCape, forCloak = Memory:Trainers("tailoring", 2), Memory:Trainers("tailoring", 1)
    T.eq("trainers for a recipe: only the ones that listed it", #forCape, 1)
    T.eq("both listed the cloak, by name", forCloak[1].name .. "," .. forCloak[2].name, "Georgio Bolero,Sellandus")
    T.eq("another faction's trainers are left out", #Memory:Trainers("tailoring", 1, "Horde"), 0)
    T.eq("the character's faction keeps them", #Memory:Trainers("tailoring", 1, "Alliance"), 2)
end)

T.section("what is not recorded", function()
    local before = #Memory:Trainers("tailoring")
    local profKey = Memory:Record(info({ name = "Class Trainer" }), { service("Fireball", 100), service("Frostbolt", 100) })
    T.check("a trainer none of whose services is a known recipe is not a profession trainer", profKey == nil)
    T.check("no trainer info: nothing recorded", Memory:Record(nil, { service("Linen Cloak", 50) }) == nil)
    T.check("no services: nothing recorded", Memory:Record(info(), {}) == nil)

    -- The name could not be read (a secret value): fees yes, the trainer no.
    local nameless = info({ zone = "Somewhere" })
    nameless.name, nameless.npcId = nil, nil
    local key = Memory:Record(nameless, { service("Silk Robe", 700) })
    T.eq("no readable name: the profession is still found", key, "tailoring")
    T.eq("no readable name: the fee is remembered", Memory:Fee(3), 700)
    T.eq("no readable name: no trainer entry", #Memory:Trainers("tailoring"), before)

    -- No position (inside an instance): the trainer is kept without one.
    local deep = info({ name = "Deep Trainer", npcId = 77 })
    deep.mapId, deep.x, deep.y = nil, nil, nil
    Memory:Record(deep, { service("Linen Cloak", 50) })
    local found
    for _, t in ipairs(Memory:Trainers("tailoring")) do if t.name == "Deep Trainer" then found = t end end
    T.check("no position: kept, without coordinates", found ~= nil and found.x == nil)

    local saved = LazyProf.db.global
    LazyProf.db.global = nil
    T.check("no database yet: nothing breaks", Memory:Record(info(), { service("Linen Cloak", 50) }) == nil
        and Memory:Fee(1) == nil and #Memory:Trainers("tailoring") == 0)
    LazyProf.db.global = saved
end)

T.section("fee use and text", function()
    local Avail = LazyProf.RecipeAvailability
    local r = { id = 2, name = "Woolen Cape", learned = false, source = { type = "trainer", npcName = "Any Tailoring Trainer" } }
    local ok, src = Avail:IsRecipeAvailableUncached(r)
    T.check("a trainer recipe without a shipped fee takes the remembered one", ok and src.cost == 300 and src.costSeen == true,
        src and tostring(src.cost))
    r.source.trainingCost = 250
    ok, src = Avail:IsRecipeAvailableUncached(r)
    T.check("a shipped fee wins", src.cost == 250 and not src.costSeen)
    local unknown = { id = 999, name = "Other", learned = false, source = { type = "trainer" } }
    ok, src = Avail:IsRecipeAvailableUncached(unknown)
    T.check("no fee known anywhere: none", ok and src.cost == nil)

    local Text = LazyProf.GuideText
    local stage = { kind = "learn", recipe = { id = 2, name = "Woolen Cape", skillRequired = 75 },
        sourceInfo = { type = "trainer", cost = 300, costSeen = true }, fee = 300, at = 75 }
    local lines = Text.LearnLines(stage, "FOREVER", "Tailoring")
    T.eq("a remembered fee says where it comes from", lines[2].text, "Cost: 3s (as charged at a trainer you visited)")

    T.eq("trainer line with coordinates", Text.TrainerLine({ name = "Georgio Bolero", zone = "Stormwind City", x = 0.5312, y = 0.8124 }),
        "Georgio Bolero - Stormwind City (53, 81)")
    T.eq("trainer line without coordinates", Text.TrainerLine({ name = "Deep Trainer", zone = "Somewhere" }), "Deep Trainer - Somewhere")
    T.eq("trainer line without a zone", Text.TrainerLine({ name = "Nameless Place Trainer" }), "Nameless Place Trainer")

    local counts = Memory:Counts()
    T.check("counts for the diagnostic", counts.trainers >= 4 and counts.fees >= 4, counts.trainers .. "/" .. counts.fees)
end)

T.finish()
