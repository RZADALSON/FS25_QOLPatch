-- FS25_MegaPatch: dynamiczny rynek paliw + cena IBC diesel
--
-- W grze bazowej diesel ma stala cene (maps_fillTypes.xml: DIESEL 1.50/l, DEF 0.90/l) skalowana tylko
-- ustawieniem trudnosci ekonomicznej. Ten modul dodaje mnoznik rynkowy:
--   cena = cena_bazowa_gry(ustawienia) * sezon * exp(x) * (1 + szok)
--   x    - proces powrotu do sredniej (Ornstein-Uhlenbeck), aktualizowany co godzine gry
--   szok - rzadkie skoki cen (kryzysy/spadki), wygasajace w ciagu kilku-kilkunastu dni
--   sezon - lekko drozej w szczycie zniw, taniej zima
-- Zmiennosc i limity zaleza od trudnosci ekonomicznej (latwy = stabilniej, trudny = wieksze wahania).

MPFuelMarket = {}
local MPFuelMarket_mt = Class(MPFuelMarket)

MPFuelMarket.MODULE = "fuel"

-- udzial paliwa w ruchu rynku ropy (1 = pelny)
MPFuelMarket.FUELS = {
    DIESEL = 1.0,
    DEF = 0.35,
    METHANE = 0.6,
}

MPFuelMarket.DIFFICULTY = {
    [1] = {sigma = 0.010, shockScale = 0.6, min = 0.82, max = 1.25},
    [2] = {sigma = 0.016, shockScale = 1.0, min = 0.72, max = 1.40},
    [3] = {sigma = 0.024, shockScale = 1.4, min = 0.65, max = 1.60},
}

MPFuelMarket.REVERSION_PER_DAY = 0.10
MPFuelMarket.SHOCK_CHANCE_PER_DAY = 0.02
MPFuelMarket.SHOCK_DECAY_PER_DAY = 0.12
MPFuelMarket.SEASON_AMPLITUDE = 0.04
MPFuelMarket.SEASON_PEAK_PERIOD = 6 -- ~sierpien (1 = wczesna wiosna)

-- IBC: kaucja/koszt pojemnika UN (nowy IBC 1000 l na palecie stalowej ~ 180-250 EUR)
MPFuelMarket.IBC_CONTAINER_PRICE = 210
MPFuelMarket.IBC_CAPACITY = 1000

function MPFuelMarket.new(megaPatch)
    local self = setmetatable({}, MPFuelMarket_mt)
    self.megaPatch = megaPatch
    self.x = 0
    self.shock = 0
    self.factor = 1
    self.lastDayPrice = nil
    self.factors = {}
    self.ibcStoreItems = {}
    self.isEnabled = true
    return self
end

function MPFuelMarket:loadMap()
    MPFuelMarket.instance = self
    self:resolveFillTypes()
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
        g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    end
end

function MPFuelMarket:delete()
    g_messageCenter:unsubscribeAll(self)
    MPFuelMarket.instance = nil
end

function MPFuelMarket:resolveFillTypes()
    self.fillTypeWeights = {}
    for name, weight in pairs(MPFuelMarket.FUELS) do
        local index = g_fillTypeManager:getFillTypeIndexByName(name)
        if index ~= nil then
            self.fillTypeWeights[index] = weight
        end
    end
end

function MPFuelMarket:onStartMission()
    self:findIBCStoreItems()
    self:recalculate()
    if self.lastDayPrice == nil then
        self.lastDayPrice = self:getDieselPrice()
    end
end

function MPFuelMarket:findIBCStoreItems()
    self.ibcStoreItems = {}
    local modDir = string.lower(MegaPatch.MOD_DIR)
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        local fn = storeItem.xmlFilename ~= nil and string.lower(storeItem.xmlFilename) or ""
        if string.find(fn, "ibcdiesel.xml", 1, true) ~= nil and (storeItem.customEnvironment == MegaPatch.MOD_NAME or string.find(fn, modDir, 1, true) ~= nil) then
            storeItem.megaPatchIBC = true
            table.insert(self.ibcStoreItems, storeItem)
        end
    end
end

function MPFuelMarket:getSeasonFactor()
    local period = MPUtil.getCurrentPeriod()
    local phase = 2 * math.pi * (period - MPFuelMarket.SEASON_PEAK_PERIOD) / 12
    return 1 + MPFuelMarket.SEASON_AMPLITUDE * math.cos(phase)
end

function MPFuelMarket:getLimits()
    return MPFuelMarket.DIFFICULTY[MPUtil.getEconomicDifficulty()] or MPFuelMarket.DIFFICULTY[2]
end

function MPFuelMarket:recalculate()
    local cfg = self:getLimits()
    local f = self:getSeasonFactor() * math.exp(self.x) * (1 + self.shock)
    self.factor = MPUtil.clamp(f, cfg.min, cfg.max)
    self:applyFactor()
end

function MPFuelMarket:applyFactor()
    self.factors = {}
    for index, weight in pairs(self.fillTypeWeights or {}) do
        self.factors[index] = 1 + weight * (self.factor - 1)
    end
    self:updateIBCPrices()
end

function MPFuelMarket:getFactor(fillTypeIndex)
    if not self.isEnabled then
        return 1
    end
    return self.factors[fillTypeIndex] or 1
end

-- aktualna cena diesla za litr (z ustawieniami gry i rynkiem)
function MPFuelMarket:getDieselPrice()
    local em = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if em == nil then
        return 1.5
    end
    return em:getPricePerLiter(FillType.DIESEL) or 1.5
end

function MPFuelMarket:getIBCPrice()
    local price = MPFuelMarket.IBC_CONTAINER_PRICE + MPFuelMarket.IBC_CAPACITY * self:getDieselPrice()
    return math.floor(price + 0.5)
end

function MPFuelMarket:updateIBCPrices()
    if #self.ibcStoreItems == 0 or g_currentMission == nil or g_currentMission.economyManager == nil then
        return
    end
    local price = self:getIBCPrice()
    for _, storeItem in ipairs(self.ibcStoreItems) do
        storeItem.price = price
    end
end

-- krok symulacji, dtDays w dniach gry
function MPFuelMarket:step(dtDays)
    local cfg = self:getLimits()
    -- powrot do sredniej + szum
    self.x = self.x - MPFuelMarket.REVERSION_PER_DAY * self.x * dtDays + cfg.sigma * math.sqrt(dtDays) * MPUtil.randomNormal()
    self.x = MPUtil.clamp(self.x, -0.4, 0.4)

    -- wygaszanie szoku
    self.shock = self.shock * math.exp(-MPFuelMarket.SHOCK_DECAY_PER_DAY * dtDays)
    if math.abs(self.shock) < 0.001 then
        self.shock = 0
    end

    -- nowy szok rynkowy (60% szans ze w gore - kryzysy sa czestsze niz nagle spadki)
    if math.random() < MPFuelMarket.SHOCK_CHANCE_PER_DAY * dtDays then
        local size = (0.06 + math.random() * 0.12) * cfg.shockScale
        if math.random() < 0.4 then
            size = -size * 0.7
        end
        self.shock = MPUtil.clamp(self.shock + size, -0.3, 0.5)
    end

    self:recalculate()
end

function MPFuelMarket:onHourChanged()
    if not g_currentMission:getIsServer() then
        return
    end
    -- przy krotkich miesiacach (np. 1 dzien/miesiac) rynek porusza sie szybciej, zeby w skali roku gry
    -- bylo widac realne wahania
    local daysPerPeriod = MPUtil.getDaysPerPeriod()
    local timeScale = MPUtil.clamp(3 / daysPerPeriod, 1, 3)
    self:step(timeScale / 24)
    MPStateSyncEvent.broadcast(MPFuelMarket.MODULE, self:getState(false))
end

function MPFuelMarket:onDayChanged()
    if not g_currentMission:getIsServer() then
        return
    end
    local price = self:getDieselPrice()
    local prev = self.lastDayPrice or price
    self.lastDayPrice = price
    local state = self:getState(true)
    state.prev = prev
    self:showDailyNotification(price, prev)
    MPStateSyncEvent.broadcast(MPFuelMarket.MODULE, state)
end

function MPFuelMarket:showDailyNotification(price, prev)
    if not g_currentMission:getIsClient() then
        return
    end
    local change = prev > 0 and (price / prev - 1) * 100 or 0
    if math.abs(change) < 0.5 then
        return
    end
    local key = change > 0 and "megaPatch_fuel_priceUp" or "megaPatch_fuel_priceDown"
    local text = MPUtil.getText(key, g_i18n:formatMoney(price, 2, true, true), string.format("%.1f", math.abs(change)), g_i18n:formatMoney(self:getIBCPrice(), 0, true, true))
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
end

function MPFuelMarket:getState(notify)
    return {x = self.x, shock = self.shock, factor = self.factor, notify = notify == true}
end

function MPFuelMarket:applyState(state)
    self.x = state.x or self.x
    self.shock = state.shock or self.shock
    self.factor = state.factor or self.factor
    self:applyFactor()
    if state.notify and state.prev ~= nil then
        self:showDailyNotification(self:getDieselPrice(), state.prev)
    end
end

function MPFuelMarket:sendInitialClientState(connection)
    connection:sendEvent(MPStateSyncEvent.new(MPFuelMarket.MODULE, self:getState(false)))
end

function MPFuelMarket:onRequest(action, data, farmId, connection)
end

function MPFuelMarket:loadFromXMLFile(xmlFile, key)
    self.x = xmlFile:getFloat(key .. ".fuelMarket#x", 0)
    self.shock = xmlFile:getFloat(key .. ".fuelMarket#shock", 0)
    self.lastDayPrice = xmlFile:getFloat(key .. ".fuelMarket#lastDayPrice")
end

function MPFuelMarket:saveToXMLFile(xmlFile, key)
    xmlFile:setFloat(key .. ".fuelMarket#x", self.x)
    xmlFile:setFloat(key .. ".fuelMarket#shock", self.shock)
    xmlFile:setFloat(key .. ".fuelMarket#factor", self.factor)
    if self.lastDayPrice ~= nil then
        xmlFile:setFloat(key .. ".fuelMarket#lastDayPrice", self.lastDayPrice)
    end
end

function MPFuelMarket:consoleFuelInfo()
    local cfg = self:getLimits()
    return string.format("Diesel %.3f/l | mnoznik %.3f (sezon %.3f, x %.3f, szok %.3f) | zakres %.2f-%.2f | IBC %d",
        self:getDieselPrice(), self.factor, self:getSeasonFactor(), self.x, self.shock, cfg.min, cfg.max, self:getIBCPrice())
end

function MPFuelMarket:consoleFuelSetFactor(value)
    if not g_currentMission:getIsServer() then
        return "Tylko na serwerze"
    end
    local f = tonumber(value)
    if f == nil or f <= 0 then
        return "Uzycie: mpFuelSetFactor 1.2"
    end
    self.shock = 0
    self.x = math.log(f / self:getSeasonFactor())
    self:recalculate()
    MPStateSyncEvent.broadcast(MPFuelMarket.MODULE, self:getState(false))
    return self:consoleFuelInfo()
end

---------------------------------------------------------------------------------------------------
-- hooks

local function getPricePerLiter(em, superFunc, fillTypeIndex, ...)
    local price = superFunc(em, fillTypeIndex, ...)
    local market = MPFuelMarket.instance
    if market ~= nil and price ~= nil and fillTypeIndex ~= nil then
        return price * market:getFactor(fillTypeIndex)
    end
    return price
end

local function getCostPerLiter(em, superFunc, fillTypeIndex, ...)
    local price = superFunc(em, fillTypeIndex, ...)
    local market = MPFuelMarket.instance
    if market ~= nil and type(price) == "number" and fillTypeIndex ~= nil then
        return price * market:getFactor(fillTypeIndex)
    end
    return price
end

local function getBuyPrice(em, superFunc, storeItem, ...)
    local market = MPFuelMarket.instance
    if market ~= nil and storeItem ~= nil and storeItem.megaPatchIBC then
        return market:getIBCPrice()
    end
    return superFunc(em, storeItem, ...)
end

function MPFuelMarket.installHooks()
    EconomyManager.getPricePerLiter = Utils.overwrittenFunction(EconomyManager.getPricePerLiter, getPricePerLiter)
    EconomyManager.getCostPerLiter = Utils.overwrittenFunction(EconomyManager.getCostPerLiter, getCostPerLiter)
    EconomyManager.getBuyPrice = Utils.overwrittenFunction(EconomyManager.getBuyPrice, getBuyPrice)
end
