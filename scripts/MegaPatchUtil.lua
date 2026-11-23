-- FS25_MegaPatch: helpers shared by all modules

MPUtil = {}

function MPUtil.getText(key, ...)
    local text = g_i18n:getText(key, MegaPatch.MOD_NAME)
    if select("#", ...) > 0 then
        return string.format(text, ...)
    end
    return text
end

function MPUtil.formatMoney(value)
    return g_i18n:formatMoney(value or 0, 0, true, true)
end

function MPUtil.getEconomicDifficulty()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local diff = info ~= nil and tonumber(info.economicDifficulty) or 2
    return math.max(1, math.min(3, diff or 2))
end

function MPUtil.getDaysPerPeriod()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    return (env ~= nil and env.daysPerPeriod) or 1
end

function MPUtil.getCurrentPeriod()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    return (env ~= nil and env.currentPeriod) or 1
end

function MPUtil.getFarmMoney(farmId)
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm.money or 0
end

function MPUtil.moneyType(name, fallback)
    return MoneyType[name] or MoneyType[fallback or "OTHER"] or MoneyType.OTHER
end

-- server only
function MPUtil.addMoney(amount, farmId, moneyTypeName)
    if amount == 0 or farmId == nil then
        return
    end
    g_currentMission:addMoney(amount, farmId, MPUtil.moneyType(moneyTypeName), true, true)
end

function MPUtil.getLocalFarmId()
    if g_currentMission == nil then
        return FarmManager.SPECTATOR_FARM_ID
    end
    return g_currentMission:getFarmId()
end

-- farmId of the user behind a network connection (server side)
function MPUtil.getFarmIdForConnection(connection)
    if connection == nil or (connection.getIsLocal ~= nil and connection:getIsLocal()) then
        return MPUtil.getLocalFarmId()
    end
    local userManager = g_currentMission.userManager
    if userManager ~= nil then
        local user = userManager:getUserByConnection(connection)
        if user ~= nil then
            local farm = g_farmManager:getFarmByUserId(user:getId())
            if farm ~= nil then
                return farm.farmId
            end
        end
    end
    return FarmManager.SPECTATOR_FARM_ID
end

function MPUtil.getVehicleUniqueId(vehicle)
    if vehicle == nil then
        return nil
    end
    if vehicle.getUniqueId ~= nil then
        return vehicle:getUniqueId()
    end
    return vehicle.uniqueId
end

-- Sieciowe ID obiektu: wspolne dla serwera i klientow (uniqueId pojazdu NIE jest przesylany
-- do klientow - kazdy klient ma wlasne). Do komunikacji klient <-> serwer uzywamy tego ID.
function MPUtil.getNetId(object)
    if object == nil or NetworkUtil == nil or NetworkUtil.getObjectId == nil then
        return nil
    end
    return NetworkUtil.getObjectId(object)
end

function MPUtil.getObjectByNetId(id)
    id = tonumber(id)
    if id == nil or NetworkUtil == nil or NetworkUtil.getObject == nil then
        return nil
    end
    return NetworkUtil.getObject(id)
end

-- serwer: pojazd z danych zadania klienta ({oid = sieciowe ID, uid = uniqueId jako zapas w grze jednoosobowej})
function MPUtil.resolveVehicle(data)
    local vehicle = MPUtil.getObjectByNetId(data.oid)
    if vehicle ~= nil and (vehicle.rootNode == nil or vehicle.isDeleted or vehicle.markedForDeletion) then
        vehicle = nil
    end
    if vehicle == nil and data.uid ~= nil then
        vehicle = MPUtil.getVehicleByUniqueId(data.uid)
    end
    return vehicle
end

function MPUtil.getVehicleByUniqueId(uid)
    if uid == nil or g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return nil
    end
    local vehicle = g_currentMission.vehicleSystem:getVehicleByUniqueId(uid)
    if vehicle ~= nil and not vehicle.markedForDeletion then
        return vehicle
    end
    return nil
end

function MPUtil.getVehicleName(vehicle)
    if vehicle.getFullName ~= nil then
        return vehicle:getFullName()
    end
    return vehicle.typeDesc or "?"
end

-- Notification shown to every player of a farm. Server side; money values passed as numbers
-- are formatted on each client in its own currency.
function MPUtil.notifyFarm(farmId, notificationType, key, ...)
    local args = {...}
    if g_currentMission:getIsClient() and MPUtil.getLocalFarmId() == farmId then
        MPUtil.showNotification(notificationType, key, args)
    end
    if g_server ~= nil and g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer then
        g_server:broadcastEvent(MPNotifyEvent.new(farmId, notificationType, key, args), false)
    end
end

-- Komunikat tylko dla gracza, ktory wyslal zadanie (connection == nil -> gracz lokalny / host). Serwer.
function MPUtil.notifyConnection(connection, farmId, notificationType, key, ...)
    local args = {...}
    if connection == nil or (connection.getIsLocal ~= nil and connection:getIsLocal()) then
        if g_currentMission:getIsClient() then
            MPUtil.showNotification(notificationType, key, args)
        end
    else
        connection:sendEvent(MPNotifyEvent.new(farmId, notificationType, key, args))
    end
end

function MPUtil.showNotification(notificationType, key, args)
    local formatted = {}
    for i, v in ipairs(args) do
        if type(v) == "number" then
            formatted[i] = MPUtil.formatMoney(v)
        else
            formatted[i] = tostring(v)
        end
    end
    local text = MPUtil.getText(key, unpack(formatted))
    -- typ 4: komunikat budowy - migajacy napis, gdy gracz ma otwarty tryb budowy
    if notificationType == 4 then
        if MPConstructionTools ~= nil and MPConstructionTools.isConstructionOpen() and g_currentMission.showBlinkingWarning ~= nil then
            g_currentMission:showBlinkingWarning(text, 2500)
            return
        end
        notificationType = 1
    end
    local nType = FSBaseMission.INGAME_NOTIFICATION_INFO
    if notificationType == 2 then
        nType = FSBaseMission.INGAME_NOTIFICATION_CRITICAL
    elseif notificationType == 3 then
        nType = FSBaseMission.INGAME_NOTIFICATION_OK
    end
    g_currentMission:addIngameNotification(nType, text)
end

function MPUtil.annuity(principal, aprYear, months)
    if months <= 0 then
        return principal
    end
    local r = aprYear / 12
    if r <= 0 then
        return principal / months
    end
    return principal * r / (1 - (1 + r) ^ (-months))
end

function MPUtil.randomNormal()
    local u1 = math.max(math.random(), 1e-9)
    local u2 = math.random()
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

function MPUtil.clamp(v, a, b)
    return math.max(a, math.min(b, v))
end
