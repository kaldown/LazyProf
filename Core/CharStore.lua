-- Core/CharStore.lua
-- Planner data that belongs to one character: target skill and pinned recipes
-- per profession, craft-or-buy choices, the last tab used.
--
-- It is stored account-wide under the character's GUID
-- (LazyProfDB.global.characters[guid]) instead of in the per-character part of
-- the saved variables, because that part is keyed by character and realm name
-- and a realm name is not a stable key on every client (WoW Forever reports a
-- shard name there). A GUID is stable on all of them.
--
--   CharStore:Get()               this character's table
--   CharStore:Profession(key)     { target = number|nil, pins = { {from, to, recipeId}, ... } }
--
-- Before the GUID or the database exists (very early in loading) both return
-- a working table that is simply not saved.
local ADDON_NAME, LazyProf = ...

local CharStore = {}
LazyProf.CharStore = CharStore

local function NewCharacter()
    return {
        professions = {},     -- [profKey] = { target, pins }
        craftChoices = {},    -- [itemId] = "craft" | "buy" (absent: automatic)
    }
end

-- Used while nothing can be saved yet; dropped as soon as a real table exists.
local unsaved = nil

function CharStore:Get()
    local global = LazyProf.db and LazyProf.db.global
    local guid = UnitGUID and UnitGUID("player")
    if not (global and guid) then
        unsaved = unsaved or NewCharacter()
        return unsaved
    end
    global.characters = global.characters or {}
    local record = global.characters[guid]
    if not record then
        record = NewCharacter()
        global.characters[guid] = record
    end
    -- Saved tables written by an older build may miss a field.
    record.professions = record.professions or {}
    record.craftChoices = record.craftChoices or {}
    return record
end

function CharStore:Profession(profKey)
    local professions = self:Get().professions
    local record = professions[profKey]
    if not record then
        record = { pins = {} }
        professions[profKey] = record
    end
    record.pins = record.pins or {}
    return record
end
