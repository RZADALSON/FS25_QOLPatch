-- FS25_MegaPatch: network events (multiplayer + local)
-- Kazdy modul synchronizuje stan jedna paczka danych (tabela -> string), a klienci wysylaja zadania do serwera.

MPSerializer = {}

local function esc(s)
    return (s:gsub("[%%;=|{}]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function MPSerializer.encode(value)
    local t = type(value)
    if t == "number" then
        return "n" .. string.format("%.6f", value)
    elseif t == "boolean" then
        return value and "b1" or "b0"
    elseif t == "string" then
        return "s" .. esc(value)
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(value) do
            local vt = type(v)
            if vt == "number" or vt == "boolean" or vt == "string" or vt == "table" then
                table.insert(parts, MPSerializer.encode(k) .. "=" .. MPSerializer.encode(v))
            end
        end
        return "{" .. table.concat(parts, ";") .. "}"
    end
    return "b0"
end

-- returns value, nextPos
local function decodeAt(str, pos)
    local tag = string.sub(str, pos, pos)
    if tag == "{" then
        local result = {}
        pos = pos + 1
        if string.sub(str, pos, pos) == "}" then
            return result, pos + 1
        end
        while pos <= #str do
            local key, value
            key, pos = decodeAt(str, pos)
            -- skip '='
            pos = pos + 1
            value, pos = decodeAt(str, pos)
            if key ~= nil then
                result[key] = value
            end
            local c = string.sub(str, pos, pos)
            pos = pos + 1
            if c == "}" then
                break
            end
        end
        return result, pos
    end
    local stop = pos + 1
    while stop <= #str do
        local c = string.sub(str, stop, stop)
        if c == ";" or c == "=" or c == "}" then
            break
        end
        stop = stop + 1
    end
    local raw = string.sub(str, pos + 1, stop - 1)
    if tag == "n" then
        return tonumber(raw), stop
    elseif tag == "b" then
        return raw == "1", stop
    elseif tag == "s" then
        return unesc(raw), stop
    end
    return nil, stop
end

function MPSerializer.decode(str)
    if str == nil or str == "" then
        return nil
    end
    local ok, value = pcall(decodeAt, str, 1)
    if ok then
        return value
    end
    Logging.warning("[MegaPatch] Failed to decode network payload")
    return nil
end

local function writeLongString(streamId, str)
    local len = #str
    local chunks = math.ceil(len / 30000)
    streamWriteUInt16(streamId, chunks)
    for i = 1, chunks do
        streamWriteString(streamId, string.sub(str, (i - 1) * 30000 + 1, i * 30000))
    end
end

local function readLongString(streamId)
    local chunks = streamReadUInt16(streamId)
    local parts = {}
    for i = 1, chunks do
        parts[i] = streamReadString(streamId)
    end
    return table.concat(parts)
end

local function getModule(name)
    if MegaPatch == nil then
        return nil
    end
    return MegaPatch[name]
end

---------------------------------------------------------------------------------------------------
-- Server -> clients: full state of one module
MPStateSyncEvent = {}
local MPStateSyncEvent_mt = Class(MPStateSyncEvent, Event)
InitEventClass(MPStateSyncEvent, "MPStateSyncEvent")

function MPStateSyncEvent.emptyNew()
    return Event.new(MPStateSyncEvent_mt)
end

function MPStateSyncEvent.new(moduleName, state)
    local self = MPStateSyncEvent.emptyNew()
    self.moduleName = moduleName
    self.payload = MPSerializer.encode(state or {})
    return self
end

function MPStateSyncEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.moduleName)
    writeLongString(streamId, self.payload)
end

function MPStateSyncEvent:readStream(streamId, connection)
    self.moduleName = streamReadString(streamId)
    self.payload = readLongString(streamId)
    self:run(connection)
end

function MPStateSyncEvent:run(connection)
    if connection:getIsServer() then
        local m = getModule(self.moduleName)
        local state = MPSerializer.decode(self.payload)
        if m ~= nil and m.applyState ~= nil and state ~= nil then
            m:applyState(state)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Client -> server: request an action
MPRequestEvent = {}
local MPRequestEvent_mt = Class(MPRequestEvent, Event)
InitEventClass(MPRequestEvent, "MPRequestEvent")

function MPRequestEvent.emptyNew()
    return Event.new(MPRequestEvent_mt)
end

function MPRequestEvent.new(moduleName, action, data)
    local self = MPRequestEvent.emptyNew()
    self.moduleName = moduleName
    self.action = action
    self.payload = MPSerializer.encode(data or {})
    return self
end

function MPRequestEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.moduleName)
    streamWriteString(streamId, self.action)
    writeLongString(streamId, self.payload)
end

function MPRequestEvent:readStream(streamId, connection)
    self.moduleName = streamReadString(streamId)
    self.action = streamReadString(streamId)
    self.payload = readLongString(streamId)
    self:run(connection)
end

function MPRequestEvent:run(connection)
    if not connection:getIsServer() then
        local m = getModule(self.moduleName)
        if m ~= nil and m.onRequest ~= nil then
            local farmId = MPUtil.getFarmIdForConnection(connection)
            m:onRequest(self.action, MPSerializer.decode(self.payload) or {}, farmId, connection)
        end
    end
end

-- Send a request; on server/singleplayer it is executed directly.
function MPRequestEvent.sendRequest(moduleName, action, data)
    if g_currentMission:getIsServer() then
        local m = getModule(moduleName)
        if m ~= nil then
            m:onRequest(action, data or {}, MPUtil.getLocalFarmId(), nil)
        end
    else
        g_client:getServerConnection():sendEvent(MPRequestEvent.new(moduleName, action, data))
    end
end

---------------------------------------------------------------------------------------------------
-- Server -> clients: notification for one farm
MPNotifyEvent = {}
local MPNotifyEvent_mt = Class(MPNotifyEvent, Event)
InitEventClass(MPNotifyEvent, "MPNotifyEvent")

function MPNotifyEvent.emptyNew()
    return Event.new(MPNotifyEvent_mt)
end

function MPNotifyEvent.new(farmId, notificationType, key, args)
    local self = MPNotifyEvent.emptyNew()
    self.farmId = farmId
    self.notificationType = notificationType or 1
    self.key = key
    self.payload = MPSerializer.encode(args or {})
    return self
end

function MPNotifyEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteUInt8(streamId, self.notificationType)
    streamWriteString(streamId, self.key)
    streamWriteString(streamId, self.payload)
end

function MPNotifyEvent:readStream(streamId, connection)
    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.notificationType = streamReadUInt8(streamId)
    self.key = streamReadString(streamId)
    self.payload = streamReadString(streamId)
    self:run(connection)
end

function MPNotifyEvent:run(connection)
    if connection:getIsServer() and MPUtil.getLocalFarmId() == self.farmId then
        local args = MPSerializer.decode(self.payload) or {}
        -- decoded tables have numeric keys, rebuild ordered list
        local list = {}
        for i = 1, 8 do
            if args[i] ~= nil then
                list[i] = args[i]
            end
        end
        MPUtil.showNotification(self.notificationType, self.key, list)
    end
end

---------------------------------------------------------------------------------------------------
-- helper for modules: broadcast state to all clients
function MPStateSyncEvent.broadcast(moduleName, state)
    if g_server ~= nil and g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer then
        g_server:broadcastEvent(MPStateSyncEvent.new(moduleName, state), false)
    end
end
