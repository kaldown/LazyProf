-- Modules/Guide/TrainerMemory.lua
-- Profession trainers the player has visited, and the fees they charged.
--
-- No recipe data on any client says who teaches what or where, so nothing
-- like that is shipped or guessed. Instead, when a profession trainer's
-- window is open, LazyProf remembers:
--   the trainer: name, zone, map id, where the player stood, the player's
--     faction, and which of the profession's recipes the trainer listed;
--   the fee of each listed recipe.
-- Learn and rank steps then show "trainers you have visited", and a
-- remembered fee is used as a recipe's training cost where the recipe data
-- has none. The memory is account-wide, kept per client profile
-- (LazyProfDB.global.trainers / trainerFees), and empty until a trainer is
-- visited.
--
-- Reading the trainer window is the client adapter's job
-- (Client:TrainerInfo / TrainerServices); it is implemented for WoW Forever
-- only, the other clients report nothing. This file is pure.
local ADDON_NAME, LazyProf = ...
local Utils = LazyProf.Utils

local TrainerMemory = {}
LazyProf.TrainerMemory = TrainerMemory

local function Profile()
    return Utils.GetActiveProfile() or "UNKNOWN"
end

-- The saved tables of this client profile (nil before the database exists).
local function Stores()
    local global = LazyProf.db and LazyProf.db.global
    if not global then return nil, nil end
    global.trainers = global.trainers or {}
    global.trainerFees = global.trainerFees or {}
    local profile = Profile()
    global.trainers[profile] = global.trainers[profile] or {}
    global.trainerFees[profile] = global.trainerFees[profile] or {}
    return global.trainers[profile], global.trainerFees[profile]
end

-- Recipe name -> recipe id, per profession (built once per registry).
local nameIndex, indexedRegistry = nil, nil
local function NameIndex()
    local registry = LazyProf.Professions and LazyProf.Professions.registry
    if not registry then return {} end
    if nameIndex and indexedRegistry == registry then return nameIndex end
    nameIndex, indexedRegistry = {}, registry
    for profKey, prof in pairs(registry) do
        local names = {}
        for _, recipe in ipairs(prof.recipes or {}) do
            if recipe.name then names[recipe.name] = recipe.id end
        end
        nameIndex[profKey] = names
    end
    return nameIndex
end

-- Remember an open trainer window.
--   info: Client:TrainerInfo() - { name, npcId, zone, subZone, mapId, x, y, faction };
--         name is nil when the client would not give it out (it is then not stored)
--   services: Client:TrainerServices() - { { name, cost, state }, ... }
-- The profession is the one most of the services' names are recipes of; a
-- trainer with no such service is not a profession trainer for LazyProf.
-- Returns the profession key (nil when nothing was recorded) and whether
-- anything new was stored.
function TrainerMemory:Record(info, services)
    local trainers, fees = Stores()
    if not (trainers and info and services and #services > 0) then return nil, false end

    local index = NameIndex()
    local bestKey, bestCount = nil, 0
    for profKey, names in pairs(index) do
        local count = 0
        for _, service in ipairs(services) do
            if service.name and names[service.name] then count = count + 1 end
        end
        if count > bestCount or (count == bestCount and count > 0 and profKey < bestKey) then
            bestKey, bestCount = profKey, count
        end
    end
    if not bestKey then return nil, false end

    local added = false
    local names = index[bestKey]
    local listed = {}
    for _, service in ipairs(services) do
        local recipeId = service.name and names[service.name]
        if recipeId then
            listed[recipeId] = true
            if type(service.cost) == "number" and service.cost > 0 and fees[recipeId] ~= service.cost then
                fees[recipeId] = service.cost
                added = true
            end
        end
    end

    -- The trainer itself, only under a name the client gave out.
    if info.name then
        trainers[bestKey] = trainers[bestKey] or {}
        local key = info.npcId and tostring(info.npcId) or info.name
        local entry = trainers[bestKey][key]
        if not entry then
            entry = { teaches = {} }
            trainers[bestKey][key] = entry
            added = true
        end
        entry.name = info.name
        entry.zone = info.zone
        entry.subZone = info.subZone
        entry.mapId = info.mapId
        entry.x, entry.y = info.x, info.y
        entry.faction = info.faction
        entry.seen = GetServerTime and GetServerTime() or entry.seen
        for recipeId in pairs(listed) do
            if not entry.teaches[recipeId] then
                entry.teaches[recipeId] = true
                added = true
            end
        end
    end
    return bestKey, added
end

-- The fee a visited trainer charged for a recipe (copper), nil when unknown.
function TrainerMemory:Fee(recipeId)
    local _, fees = Stores()
    return fees and fees[recipeId] or nil
end

-- Visited trainers of a profession, by name. recipeId: only those that
-- listed that recipe. faction: only those visited by a character of that
-- faction.
function TrainerMemory:Trainers(profKey, recipeId, faction)
    local trainers = Stores()
    local list = {}
    for _, entry in pairs(trainers and trainers[profKey] or {}) do
        local teaches = (recipeId == nil) or (entry.teaches and entry.teaches[recipeId])
        local sameSide = (faction == nil) or (entry.faction == nil) or (entry.faction == faction)
        if teaches and sameSide then
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    return list
end

-- How much is remembered for this client profile (for /lp diag trainer).
function TrainerMemory:Counts()
    local trainers, fees = Stores()
    local counts = { trainers = 0, fees = 0, professions = 0 }
    for _, byTrainer in pairs(trainers or {}) do
        counts.professions = counts.professions + 1
        for _ in pairs(byTrainer) do counts.trainers = counts.trainers + 1 end
    end
    for _ in pairs(fees or {}) do counts.fees = counts.fees + 1 end
    return counts
end

-- Capture ---------------------------------------------------------------------

-- Listen to the trainer window (through the client adapter).
function TrainerMemory:Initialize()
    LazyProf.Client:StartTrainer({
        onShow = function() self:Capture() end,
        onUpdate = function() self:Capture() end,
        onClose = function() end,
    })
end

-- Read the open trainer window and remember it.
function TrainerMemory:Capture()
    local Client = LazyProf.Client
    local info = Client:TrainerInfo()
    if not info then return end
    local profKey, added = self:Record(info, Client:TrainerServices())
    if profKey and added then
        LazyProf:Debug("professions", "Trainer remembered for " .. tostring(profKey))
        -- A window that is showing learn or rank steps can now name the trainer.
        if LazyProf.GuideWindow then
            LazyProf.GuideWindow:Refresh()
        end
    end
end
