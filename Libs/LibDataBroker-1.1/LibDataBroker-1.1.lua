--[[
LibDataBroker-1.1 - A data broker library for WoW addons
Standard implementation for minimap button data objects
]]

assert(LibStub, "LibDataBroker-1.1 requires LibStub")

local MAJOR, MINOR = "LibDataBroker-1.1", 4
local lib, oldminor = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.attributestorage = lib.attributestorage or {}
lib.namestorage = lib.namestorage or {}
lib.proxystorage = lib.proxystorage or {}

local attributestorage = lib.attributestorage
local namestorage = lib.namestorage
local proxystorage = lib.proxystorage
local callbacks = lib.callbacks

local function Getter(self, key)
    return attributestorage[self] and attributestorage[self][key]
end

local function Setter(self, key, value)
    if not attributestorage[self] then
        attributestorage[self] = {}
    end
    if attributestorage[self][key] == value then
        return
    end
    attributestorage[self][key] = value
    local name = namestorage[self]
    if name then
        callbacks:Fire("LibDataBroker_AttributeChanged", name, key, value, self)
        callbacks:Fire("LibDataBroker_AttributeChanged_" .. name, name, key, value, self)
        callbacks:Fire("LibDataBroker_AttributeChanged_" .. name .. "_" .. key, name, key, value, self)
        callbacks:Fire("LibDataBroker_AttributeChanged__" .. key, name, key, value, self)
    end
end

local mt = {
    __index = Getter,
    __newindex = Setter,
}

function lib:NewDataObject(name, dataobj)
    if proxystorage[name] then
        return
    end

    if dataobj then
        assert(type(dataobj) == "table", "Invalid dataobj, expected table, got " .. type(dataobj))
    end

    local proxy = setmetatable(dataobj or {}, mt)
    proxystorage[name] = proxy
    namestorage[proxy] = name
    attributestorage[proxy] = {}

    -- Move existing keys to attributestorage
    for k, v in pairs(proxy) do
        rawset(proxy, k, nil)
        proxy[k] = v
    end

    callbacks:Fire("LibDataBroker_DataObjectCreated", name, proxy)
    return proxy
end

function lib:DataObjectIterator()
    return pairs(proxystorage)
end

function lib:GetDataObjectByName(dataobjectname)
    return proxystorage[dataobjectname]
end

function lib:GetNameByDataObject(dataobject)
    return namestorage[dataobject]
end
