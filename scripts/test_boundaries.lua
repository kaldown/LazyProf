-- Boundary test: client APIs may only appear inside the client adapter
-- (Core/Client/) and the widget layer (Modules/UI/Widgets/). Strips `--`
-- comments, then fails listing file:line for every forbidden name.
-- Run from the repo root: lua5.1 scripts/test_boundaries.lua

local FORBIDDEN = {
    "TradeSkillFrame", "GetTradeSkill", "GetNumTradeSkills", "TradeSkillSkill",
    "TradeSkillListScrollFrame", "FauxScrollFrame", "UIDropDownMenu",
    "GetNumSkillLines", "GetSkillLineInfo", "C_TradeSkillUI", "ProfessionsFrame",
    "C_Item.GetItemInfo",
}

local EXEMPT_DIRS = { "Core/Client/", "Modules/UI/Widgets/" }

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

local function hasBareGetItemInfo(line)
    local init = 1
    while true do
        local s, e = line:find("GetItemInfo%(", init)
        if not s then return false end
        local prev = s > 1 and line:sub(s - 1, s - 1) or ""
        if not prev:match("[%.:%w_]") then return true end
        init = e + 1
    end
end

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

local offenders = {}
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
        end
    end
end

-- The Forever adapter uses only Forever APIs: none of the legacy UI calls,
-- and never the global item-info call (C_Item.GetItemInfo instead).
local FOREVER_FILE = "Core/Client/Forever.lua"
local FOREVER_FORBIDDEN = {
    "UIDropDownMenu", "EasyMenu", "FauxScrollFrame", "HybridScrollFrame",
    "InterfaceOptions", "OnTooltipSetItem", "ShowUIPanel", "HideUIPanel",
}
local foreverFile = io.open(FOREVER_FILE, "r")
if not foreverFile then
    offenders[#offenders + 1] = FOREVER_FILE .. ": missing"
else
    foreverFile:close()
    local n = 0
    for raw in io.lines(FOREVER_FILE) do
        n = n + 1
        local line = strip_comment(raw)
        for _, name in ipairs(FOREVER_FORBIDDEN) do
            if line:find(name, 1, true) then
                offenders[#offenders + 1] = string.format("%s:%d: %s", FOREVER_FILE, n, name)
            end
        end
        if hasBareGetItemInfo(line) then
            offenders[#offenders + 1] = string.format("%s:%d: GetItemInfo(", FOREVER_FILE, n)
        end
    end
end

if #offenders > 0 then
    for _, o in ipairs(offenders) do print(o) end
    print(string.format("FAIL: %d forbidden client-API use(s) (outside the adapter, or a legacy call in the Forever adapter)", #offenders))
    os.exit(1)
end
print(string.format("boundaries: OK (%d files scanned)", #files))
