-- Boundary test: client APIs may only appear inside the client adapter
-- (Core/Client/) and the widget layer (Modules/UI/Widgets/), a few only in
-- the adapter, and calls that do not exist on WoW Forever may only appear in
-- Classic-only code. Strips `--` comments, then fails listing file:line for
-- every forbidden name.
-- Also: the events of the stock memory are each registered in one place.
-- Run from the repo root: lua5.1 scripts/test_boundaries.lua

local FORBIDDEN = {
    "TradeSkillFrame", "GetTradeSkill", "GetNumTradeSkills", "TradeSkillSkill",
    "TradeSkillListScrollFrame", "FauxScrollFrame", "UIDropDownMenu",
    "GetNumSkillLines", "GetSkillLineInfo", "C_TradeSkillUI", "ProfessionsFrame",
    "C_Item.GetItemInfo",
    -- Merchant window and calls (the adapter's MerchantItems / BuyFromMerchant / Money)
    "MerchantFrame", "GetMerchant", "BuyMerchantItem",
    -- Trainer window calls and the map (the adapter's TrainerInfo / TrainerServices)
    "GetTrainer", "GetNumTrainerServices", "IsTradeskillTrainer", "BuyTrainerService", "ClassTrainerFrame",
    "C_Map", "GetRealZoneText", "GetSubZoneText",
    -- Bags and the bank (the adapter's BagContents / BankContents / IsBankOpen),
    -- and the locks of their slots (the adapter's MoveInFlight / BagContents)
    "C_Container", "GetContainerItemInfo", "GetContainerNumSlots", "C_Bank", "BANKFRAME", "BANK_TABS_CHANGED",
    "isLocked", "ITEM_LOCK",
    -- The world a character belongs to and the server clock (the adapter's
    -- CharacterIdentity / Now): a realm name is no stable key on every client
    "C_GameRules", "GetCurrentRegion", "GetRealmName", "GetServerTime",
    -- Which container is which and which bank is which, the client's way of
    -- writing a full name, the game's own Self-Found flag and its error
    -- handler (the adapter's BagContents / BankKindOfBag / CharacterIdentity /
    -- IsSelfFoundCharacter / ShowError)
    "Enum.BagIndex", "Enum.BankType", "NameUtil", "C_PlayerInfo", "geterrorhandler",
}

local EXEMPT_DIRS = { "Core/Client/", "Modules/UI/Widgets/" }

-- Calls that only the client adapter may make: not the widget layer either.
-- The client's own count of an item (the adapter's ClientItemCounts, which
-- only /lp diag stock may ask until it is known whether that count sees a
-- closed bank), as a field of C_Item and as the global of older clients, and
-- whether crafts may take reagents from the bank (printed by the adapter's
-- stock dump only).
local ADAPTER_DIR = "Core/Client/"
local ADAPTER_ONLY = { "C_Item.GetItemCount", "ReagentsFromBankAllowed" }
local ADAPTER_ONLY_BARE = { "GetItemCount" }

local function strip_comment(line)
    -- Good enough for this codebase: drop from the first `--` outside a string.
    local out, quote, i = {}, nil, 1
    while i <= #line do
        local c = line:sub(i, i)
        if quote then
            if c == "\\" then
                out[#out + 1] = line:sub(i, i + 1); i = i + 1
            elseif c == quote then
                quote = nil; out[#out + 1] = c
            else
                out[#out + 1] = c
            end
        elseif c == '"' or c == "'" then
            quote = c; out[#out + 1] = c
        elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
            break
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

-- A call of a global function by its bare name (not a method or a field of
-- some table, which may share the name: CraftLib:GetProfessions()).
local function hasBareCall(line, name)
    local init = 1
    while true do
        local s, e = line:find(name .. "%(", init)
        if not s then return false end
        local prev = s > 1 and line:sub(s - 1, s - 1) or ""
        if not prev:match("[%.:%w_]") then return true end
        init = e + 1
    end
end

-- The checks of the adapter-only calls must see a use and nothing else: a
-- method of the same name (Inventory:GetItemCount reads the bags) is none.
local function adapterOnlyUse(line)
    for _, name in ipairs(ADAPTER_ONLY) do
        if line:find(name, 1, true) then return name end
    end
    for _, name in ipairs(ADAPTER_ONLY_BARE) do
        if hasBareCall(line, name) then return name .. "(" end
    end
    return nil
end
local selfCheck = {
    { "local n = C_Item.GetItemCount(itemId, true, false, false, true)", "C_Item.GetItemCount" },
    { "if ReagentsFromBankAllowed() then", "ReagentsFromBankAllowed" },
    { "local n = GetItemCount(itemId, true)", "GetItemCount(" },
    { "function Inventory:GetItemCount(itemId)", nil },
    { "local have = LazyProf.Inventory:GetItemCount(2589)", nil },
    { "local have = Inventory.GetItemCount(Inventory, 2589)", nil },
}
for _, case in ipairs(selfCheck) do
    assert(adapterOnlyUse(case[1]) == case[2], "the adapter-only check reads '" .. case[1] .. "' wrong: "
        .. tostring(adapterOnlyUse(case[1])))
end

local function hasBareGetItemInfo(line)
    return hasBareCall(line, "GetItemInfo")
end

-- Global calls WoW Forever does not have (their C_Item / C_Container forms
-- are the ones to use there).
local FOREVER_BARE_FORBIDDEN = { "GetItemInfo", "GetContainerItemInfo", "GetContainerNumSlots" }

-- Client globals that may only be called inside the adapter: the character's
-- professions (spell-book list on WoW Forever) and money.
local BARE_FORBIDDEN = { "GetProfessions", "GetProfessionInfo", "GetMoney" }

local function exempt(path)
    for _, d in ipairs(EXEMPT_DIRS) do
        if path:sub(1, #d) == d then return true end
    end
    return false
end

local p = io.popen("find Core Modules Professions -name '*.lua' | sort")
local files = {}
for f in p:lines() do files[#files + 1] = f end
p:close()
assert(#files > 0, "no Lua files found (run from the repo root)")

-- The addon object has one handler per event: a second registration of an
-- event silently replaces the first. So each event of the stock memory is
-- registered in exactly one place: the bank window's events and logout in the
-- client adapter (logout once in each adapter - one of the two loads), the
-- two bag events in Core/Init.lua, which passes them on to the scanner.
-- [event] = { [file] = how often it is registered there }; anywhere else: never.
local REGISTERED_IN = {
    PLAYER_LOGOUT = { ["Core/Client/Classic.lua"] = 1, ["Core/Client/Forever.lua"] = 1 },
    BANKFRAME_OPENED = { ["Core/Client/Forever.lua"] = 1 },
    BANKFRAME_CLOSED = { ["Core/Client/Forever.lua"] = 1 },
    BANK_TABS_CHANGED = { ["Core/Client/Forever.lua"] = 1 },
    BAG_UPDATE = { ["Core/Init.lua"] = 1 },
    BAG_UPDATE_DELAYED = { ["Core/Init.lua"] = 1 },
}

local offenders = {}

local registered = {}   -- [event] = { [file] = count }
for _, path in ipairs(files) do
    for raw in io.lines(path) do
        for event in strip_comment(raw):gmatch("RegisterEvent%s*%(%s*[\"']([%w_]+)[\"']") do
            if REGISTERED_IN[event] then
                registered[event] = registered[event] or {}
                registered[event][path] = (registered[event][path] or 0) + 1
            end
        end
    end
end
for event, expected in pairs(REGISTERED_IN) do
    local found = registered[event] or {}
    for path, count in pairs(found) do
        if (expected[path] or 0) ~= count then
            offenders[#offenders + 1] = string.format("%s: %s is registered %d time(s) here, expected %d", path, event, count,
                expected[path] or 0)
        end
    end
    for path, count in pairs(expected) do
        if found[path] == nil then
            offenders[#offenders + 1] = string.format("%s: %s is not registered here, expected %d time(s)", path, event, count)
        end
    end
end
table.sort(offenders)

for _, path in ipairs(files) do
    if path:sub(1, #ADAPTER_DIR) ~= ADAPTER_DIR then
        local n = 0
        for raw in io.lines(path) do
            n = n + 1
            local name = adapterOnlyUse(strip_comment(raw))
            if name then
                offenders[#offenders + 1] = string.format("%s:%d: %s (only the client adapter may use it)", path, n, name)
            end
        end
    end
end

for _, path in ipairs(files) do
    if not exempt(path) then
        local n = 0
        for raw in io.lines(path) do
            n = n + 1
            local line = strip_comment(raw)
            for _, name in ipairs(FORBIDDEN) do
                if line:find(name, 1, true) then
                    offenders[#offenders + 1] = string.format("%s:%d: %s", path, n, name)
                end
            end
            if hasBareGetItemInfo(line) then
                offenders[#offenders + 1] = string.format("%s:%d: GetItemInfo(", path, n)
            end
            for _, name in ipairs(BARE_FORBIDDEN) do
                if hasBareCall(line, name) then
                    offenders[#offenders + 1] = string.format("%s:%d: %s(", path, n, name)
                end
            end
        end
    end
end

-- Forever runs the shared code too, so no file may use the legacy UI calls
-- or the global item-info and container calls (C_Item / C_Container instead)
-- - except the Classic adapter and the Classic section of the dropdown widget, which only
-- run on Classic clients. That section runs from the "-- Classic ---" line to
-- the "-- Forever ---" line of Modules/UI/Widgets/Dropdown.lua.
local FOREVER_FORBIDDEN = {
    "UIDropDownMenu", "EasyMenu", "FauxScrollFrame", "HybridScrollFrame",
    "InterfaceOptions", "OnTooltipSetItem", "ShowUIPanel", "HideUIPanel",
}
local CLASSIC_ONLY_FILE = "Core/Client/Classic.lua"
local DROPDOWN_FILE = "Modules/UI/Widgets/Dropdown.lua"
local CLASSIC_SECTION_START = "^%-%- Classic %-%-%-"
local CLASSIC_SECTION_END = "^%-%- Forever %-%-%-"

local sawDropdown, sectionStarts, sectionEnds = false, 0, 0
for _, path in ipairs(files) do
    if path ~= CLASSIC_ONLY_FILE then
        local isDropdown = path == DROPDOWN_FILE
        local inClassicSection = false
        local n = 0
        for raw in io.lines(path) do
            n = n + 1
            if isDropdown then
                sawDropdown = true
                if raw:match(CLASSIC_SECTION_START) then
                    inClassicSection = true
                    sectionStarts = sectionStarts + 1
                elseif raw:match(CLASSIC_SECTION_END) then
                    inClassicSection = false
                    sectionEnds = sectionEnds + 1
                end
            end
            if not inClassicSection then
                local line = strip_comment(raw)
                for _, name in ipairs(FOREVER_FORBIDDEN) do
                    if line:find(name, 1, true) then
                        offenders[#offenders + 1] = string.format("%s:%d: %s (not on Forever)", path, n, name)
                    end
                end
                -- Outside the exempt directories the general check above already reports them.
                if exempt(path) then
                    for _, name in ipairs(FOREVER_BARE_FORBIDDEN) do
                        if hasBareCall(line, name) then
                            offenders[#offenders + 1] = string.format("%s:%d: %s( (not on Forever)", path, n, name)
                        end
                    end
                end
            end
        end
    end
end
local sawForever = false
for _, path in ipairs(files) do
    if path == "Core/Client/Forever.lua" then sawForever = true end
end
if not sawForever then
    offenders[#offenders + 1] = "Core/Client/Forever.lua: missing"
end
-- The allowance must stay a bounded section: both markers, once each.
if not sawDropdown then
    offenders[#offenders + 1] = DROPDOWN_FILE .. ": missing"
elseif sectionStarts ~= 1 or sectionEnds ~= 1 then
    offenders[#offenders + 1] = string.format("%s: expected one Classic and one Forever section marker (got %d, %d)",
        DROPDOWN_FILE, sectionStarts, sectionEnds)
end

if #offenders > 0 then
    for _, o in ipairs(offenders) do print(o) end
    print(string.format("FAIL: %d forbidden client-API use(s) (outside the adapter, or a call that does not exist on Forever) "
        .. "or event registration(s) out of place", #offenders))
    os.exit(1)
end
print(string.format("boundaries: OK (%d files scanned)", #files))
