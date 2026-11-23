-- FS25_MegaPatch: korzystanie z fabryk bez kupowania (przerob uslugowy)
--
-- Fabryki na mapie, ktore mozna kupic (olejarnia, piekarnia, tartak...), maja teraz druga opcje:
-- "Korzystaj bez kupowania". Fabryka dziala jak Twoja (dostawy, menu produkcji, odbior produktow),
-- ale nie placisz ceny zakupu ani kosztow stalych utrzymania. Placisz tylko oplate (podatek)
-- od wartosci tego, co fabryka faktycznie przerobila: oplata = stawka% * wartosc rynkowa produktow.
--
-- Stawka jest liczona osobno dla kazdej fabryki tak, zeby przy typowym wykorzystaniu (20% mocy)
-- suma oplat po 10 latach gry zrownala sie z cena zakupu - czyli przy dluzszym/intensywniejszym
-- korzystaniu kupno wychodzi taniej, a na start (malo pieniedzy) wynajem jest oplacalny.
-- W kazdej chwili mozna fabryke wykupic (pelna cena) albo zakonczyc umowe (zawartosc magazynu przepada).

MPProductionRental = {}
local MPProductionRental_mt = Class(MPProductionRental)

MPProductionRental.MODULE = "production"
MPProductionRental.BREAK_EVEN_YEARS = 10
MPProductionRental.REFERENCE_UTILIZATION = 0.20
MPProductionRental.MIN_RATE = 0.01
-- typowy przerob nie wiekszy niz 25% ceny fabryki miesiecznie (chroni przed fabrykami z map/modow
-- o nierealnej mocy, np. 500 000 l/h - wtedy stawka liczy sie wzgledem ceny, a nie mocy)
MPProductionRental.TYPICAL_MONTHLY_CAP = 0.25
MPProductionRental.MAX_RATE = 0.60

function MPProductionRental.new(megaPatch)
    local self = setmetatable({}, MPProductionRental_mt)
    self.megaPatch = megaPatch
    self.rentals = {}       -- [placeableUid] = {farmId, rate, price, feesTotal, valueTotal, monthFee, lastMonthFee, months, pendingFee, name}
    self.listeners = {}
    self.missionStarted = false
    return self
end

function MPProductionRental:loadMap()
    MPProductionRental.instance = self
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
    end
end

function MPProductionRental:delete()
    g_messageCenter:unsubscribeAll(self)
    for uid, _ in pairs(self.rentals) do
        local pp = self:getProductionPoint(uid)
        if pp ~= nil then
            self:restoreProductionPoint(pp)
        end
    end
    MPProductionRental.instance = nil
end

function MPProductionRental:addChangeListener(func, target)
    self.listeners[target] = func
end

function MPProductionRental:removeChangeListener(target)
    self.listeners[target] = nil
end

function MPProductionRental:notifyListeners()
    for target, func in pairs(self.listeners) do
        func(target)
    end
end

function MPProductionRental:raiseChanged()
    MPStateSyncEvent.broadcast(MPProductionRental.MODULE, self:getState())
    self:notifyListeners()
end

---------------------------------------------------------------------------------------------------
-- fabryki

function MPProductionRental.getPlaceableUid(pp)
    local placeable = pp ~= nil and pp.owningPlaceable or nil
    if placeable == nil then
        return nil
    end
    if placeable.getUniqueId ~= nil then
        return placeable:getUniqueId()
    end
    return placeable.uniqueId
end

function MPProductionRental:getAllProductionPoints()
    local pcm = g_currentMission.productionChainManager
    return pcm ~= nil and pcm.productionPoints or {}
end

function MPProductionRental:getProductionPoint(uid)
    for _, pp in ipairs(self:getAllProductionPoints()) do
        if MPProductionRental.getPlaceableUid(pp) == uid then
            return pp
        end
    end
    return nil
end

-- dane zadania klient -> serwer: uniqueId (zgodny dla fabryk z mapy) + sieciowe ID (zawsze zgodne)
function MPProductionRental.getRequestData(pp)
    return {uid = MPProductionRental.getPlaceableUid(pp), oid = MPUtil.getNetId(pp ~= nil and pp.owningPlaceable or nil)}
end

function MPProductionRental:resolveProductionPoint(data)
    local placeable = MPUtil.getObjectByNetId(data.oid)
    if placeable ~= nil then
        for _, pp in ipairs(self:getAllProductionPoints()) do
            if pp.owningPlaceable == placeable then
                return pp
            end
        end
    end
    return self:getProductionPoint(data.uid)
end

-- Zmiana wlasciciela fabryki BEZ przejmowania dzialki pod nia (wynajem nie daje ziemi).
-- Dzialki, ktorych to dotyczy, trafiaja do stanu wysylanego klientom (landFix).
function MPProductionRental:setOwnerKeepLand(pp, farmId)
    local placeable = pp.owningPlaceable
    local farmlandId = placeable.getFarmlandId ~= nil and placeable:getFarmlandId() or nil
    local buys = placeable.buysFarmland
    placeable.buysFarmland = false
    placeable:setOwnerFarmId(farmId)
    placeable.buysFarmland = buys
    if buys and farmlandId ~= nil and farmlandId > 0 then
        self.landFix = self.landFix or {}
        self.landFix[farmlandId] = true
    end
end

function MPProductionRental.getName(pp)
    if pp.getName ~= nil then
        return pp:getName()
    end
    return pp.name or "?"
end

-- cena zakupu tak jak liczy ja gra przy kupnie (z ziemia, jesli budynek ja kupuje)
function MPProductionRental:getBuyPrice(pp, farmId)
    local placeable = pp.owningPlaceable
    local storeItem = g_storeManager:getItemByXMLFilename(placeable.configFileName)
    local price = (storeItem ~= nil and g_currentMission.economyManager:getBuyPrice(storeItem)) or placeable:getPrice() or 0
    if placeable.buysFarmland and placeable.getFarmlandId ~= nil then
        local farmlandId = placeable:getFarmlandId()
        local farmland = g_farmlandManager:getFarmlandById(farmlandId)
        if farmland ~= nil and g_farmlandManager:getFarmlandOwner(farmlandId) ~= farmId then
            price = price + farmland.price * (placeable.buysFarmlandPriceScale or 1)
        end
    end
    return price
end

local function getCyclesPerMonth(production)
    if production.cyclesPerMonth ~= nil then
        return production.cyclesPerMonth
    elseif production.cyclesPerHour ~= nil then
        return production.cyclesPerHour * 24
    elseif production.cyclesPerMinute ~= nil then
        return production.cyclesPerMinute * 60 * 24
    end
    return 0
end

local function getPricePerLiter(fillType)
    local em = g_currentMission.economyManager
    return (em ~= nil and em:getPricePerLiter(fillType)) or 0
end

function MPProductionRental.getOutputValuePerCycle(production)
    local value = 0
    for _, output in ipairs(production.outputs or {}) do
        value = value + (output.amount or 0) * getPricePerLiter(output.type)
    end
    return value
end

-- maksymalna wartosc produkcji w miesiacu gry przy 100% wykorzystania
function MPProductionRental:getMaxMonthlyValue(pp)
    local best, sum = 0, 0
    for _, production in ipairs(pp.productions or {}) do
        local v = getCyclesPerMonth(production) * MPProductionRental.getOutputValuePerCycle(production)
        best = math.max(best, v)
        sum = sum + v
    end
    if pp.sharedThroughputCapacity == false then
        return sum
    end
    return best
end

-- wartosc produkcji w miesiacu przy typowym uzyciu
function MPProductionRental:getTypicalMonthlyValue(pp, price)
    local maxMonthly = self:getMaxMonthlyValue(pp)
    local typical = maxMonthly * MPProductionRental.REFERENCE_UTILIZATION
    if price > 0 then
        typical = math.min(typical, price * MPProductionRental.TYPICAL_MONTHLY_CAP)
    end
    return typical, maxMonthly
end

function MPProductionRental:calculateRate(pp, price)
    local typical = self:getTypicalMonthlyValue(pp, price)
    if typical <= 0 then
        return MPProductionRental.MAX_RATE
    end
    local months = MPProductionRental.BREAK_EVEN_YEARS * 12
    return MPUtil.clamp(price / (months * typical), MPProductionRental.MIN_RATE, MPProductionRental.MAX_RATE)
end

function MPProductionRental:getOffer(pp, farmId)
    local price = self:getBuyPrice(pp, farmId)
    local rate = self:calculateRate(pp, price)
    local typical, maxMonthly = self:getTypicalMonthlyValue(pp, price)
    return {
        price = price, rate = rate, maxMonthly = maxMonthly,
        feeAtReference = rate * typical,
        feeAtFull = rate * math.min(maxMonthly, typical / MPProductionRental.REFERENCE_UTILIZATION)
    }
end

function MPProductionRental:isRentable(pp)
    return pp ~= nil and pp.owningPlaceable ~= nil and pp:getOwnerFarmId() == AccessHandler.EVERYONE
        and (pp.isFinalized ~= false) and MPProductionRental.getPlaceableUid(pp) ~= nil
end

function MPProductionRental:getRental(pp)
    local uid = MPProductionRental.getPlaceableUid(pp)
    return uid ~= nil and self.rentals[uid] or nil, uid
end

---------------------------------------------------------------------------------------------------
-- stan fabryki w trakcie wynajmu: bez kosztow stalych, pomiar przerobu

local COST_FIELDS = {"costsPerActiveMonth", "costsPerActiveHour", "costsPerActiveMinute"}

function MPProductionRental:applyRentalToProductionPoint(pp, rental)
    pp.megaPatchRental = rental
    if pp.storage ~= nil then
        pp.storage.megaPatchProductionPoint = pp
    end
    for _, production in ipairs(pp.productions or {}) do
        if production.megaPatchOrigCosts == nil then
            production.megaPatchOrigCosts = {}
            for _, f in ipairs(COST_FIELDS) do
                if production[f] ~= nil then
                    production.megaPatchOrigCosts[f] = production[f]
                    production[f] = 0
                end
            end
        end
    end
    pp.productionCostsToClaim = 0
    self:buildConsumptionMap(pp)
end

function MPProductionRental:restoreProductionPoint(pp)
    pp.megaPatchRental = nil
    pp.megaPatchConsumption = nil
    if pp.storage ~= nil then
        pp.storage.megaPatchProductionPoint = nil
    end
    for _, production in ipairs(pp.productions or {}) do
        if production.megaPatchOrigCosts ~= nil then
            for f, v in pairs(production.megaPatchOrigCosts) do
                production[f] = v
            end
            production.megaPatchOrigCosts = nil
        end
    end
end

-- glowny skladnik receptury (pierwszy input) -> wartosc produktow na jednostke zuzycia
function MPProductionRental:buildConsumptionMap(pp)
    local map = {}
    for _, production in ipairs(pp.productions or {}) do
        local primary = production.inputs ~= nil and production.inputs[1] or nil
        if primary ~= nil and primary.type ~= nil and (primary.amount or 0) > 0 then
            map[primary.type] = map[primary.type] or {}
            table.insert(map[primary.type], {production = production, amount = primary.amount})
        end
    end
    pp.megaPatchConsumption = map
end

-- server: z magazynu fabryki ubylo 'amount' surowca 'fillType' (=przerob)
function MPProductionRental:onInputConsumed(pp, fillType, amount)
    local rental = pp.megaPatchRental
    local entries = pp.megaPatchConsumption ~= nil and pp.megaPatchConsumption[fillType] or nil
    if rental == nil or entries == nil or amount <= 0 then
        return
    end
    local active = {}
    for _, production in ipairs(pp.activeProductions or {}) do
        active[production] = true
    end
    local candidates = {}
    for _, e in ipairs(entries) do
        if active[e.production] then
            table.insert(candidates, e)
        end
    end
    if #candidates == 0 then
        candidates = entries
    end
    local value = 0
    for _, e in ipairs(candidates) do
        value = value + (amount / e.amount) * MPProductionRental.getOutputValuePerCycle(e.production)
    end
    value = value / #candidates
    rental.valueTotal = rental.valueTotal + value
    rental.pendingFee = rental.pendingFee + value * rental.rate
end

function MPProductionRental:onHourChanged()
    local changed = false
    for uid, rental in pairs(self.rentals) do
        local pp = self:getProductionPoint(uid)
        if pp ~= nil then
            pp.productionCostsToClaim = 0
        end
        if rental.pendingFee >= 1 then
            local fee = math.floor(rental.pendingFee)
            rental.pendingFee = rental.pendingFee - fee
            rental.feesTotal = rental.feesTotal + fee
            rental.monthFee = rental.monthFee + fee
            MPUtil.addMoney(-fee, rental.farmId, "PRODUCTION_COSTS")
            changed = true
        end
    end
    if changed then
        self:raiseChanged()
    end
end

function MPProductionRental:onPeriodChanged()
    for _, rental in pairs(self.rentals) do
        rental.lastMonthFee = rental.monthFee
        rental.monthFee = 0
        rental.months = rental.months + 1
        -- srednia krocząca (12 mies.) do szacowania progu oplacalnosci
        rental.avgMonthFee = (rental.avgMonthFee or rental.lastMonthFee) * 11 / 12 + rental.lastMonthFee / 12
    end
    self:raiseChanged()
end

function MPProductionRental:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end
    for uid, rental in pairs(self.rentals) do
        local pp = rental.megaPatchPP
        if pp ~= nil and pp.productionCostsToClaim ~= nil and pp.productionCostsToClaim > 0 then
            pp.productionCostsToClaim = 0
        end
    end
end

---------------------------------------------------------------------------------------------------
-- akcje

function MPProductionRental:onRequest(action, data, farmId, connection)
    if not g_currentMission:getIsServer() then
        return
    end
    local pp = self:resolveProductionPoint(data)
    if pp == nil then
        return
    end
    if action == "rent" then
        self:startRental(pp, farmId)
    elseif action == "end" then
        self:endRental(pp, farmId)
    elseif action == "buy" then
        self:buyRented(pp, farmId)
    end
end

function MPProductionRental:startRental(pp, farmId)
    if not self:isRentable(pp) or farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false
    end
    local uid = MPProductionRental.getPlaceableUid(pp)
    local offer = self:getOffer(pp, farmId)
    local rental = {
        farmId = farmId, rate = offer.rate, price = offer.price, name = MPProductionRental.getName(pp),
        feesTotal = 0, valueTotal = 0, monthFee = 0, lastMonthFee = 0, months = 0, pendingFee = 0
    }
    self.rentals[uid] = rental
    self:setOwnerKeepLand(pp, farmId)
    self:applyRentalToProductionPoint(pp, rental)
    rental.megaPatchPP = pp
    MPUtil.notifyFarm(farmId, 3, "megaPatch_prod_started", rental.name, string.format("%.1f", rental.rate * 100))
    self:raiseChanged()
    return true
end

function MPProductionRental:endRental(pp, farmId)
    local rental, uid = self:getRental(pp)
    if rental == nil or rental.farmId ~= farmId then
        return false
    end
    if rental.pendingFee > 0 then
        MPUtil.addMoney(-math.ceil(rental.pendingFee), farmId, "PRODUCTION_COSTS")
    end
    self.rentals[uid] = nil
    self:restoreProductionPoint(pp)
    self:setOwnerKeepLand(pp, AccessHandler.EVERYONE)
    MPUtil.notifyFarm(farmId, 1, "megaPatch_prod_ended", rental.name)
    self:raiseChanged()
    return true
end

function MPProductionRental:buyRented(pp, farmId)
    local rental, uid = self:getRental(pp)
    if rental == nil or rental.farmId ~= farmId then
        return false
    end
    local price = self:getBuyPrice(pp, farmId)
    local total = price + math.ceil(rental.pendingFee)
    if MPUtil.getFarmMoney(farmId) < total then
        MPUtil.notifyFarm(farmId, 2, "megaPatch_finance_notEnoughMoney", total)
        return false
    end
    MPUtil.addMoney(-math.ceil(rental.pendingFee), farmId, "PRODUCTION_COSTS")
    MPUtil.addMoney(-price, farmId, "SHOP_PROPERTY_BUY")
    local placeable = pp.owningPlaceable
    if placeable.buysFarmland and placeable.getFarmlandId ~= nil then
        local farmlandId = placeable:getFarmlandId()
        if farmlandId ~= nil and g_farmlandManager:getFarmlandOwner(farmlandId) ~= farmId then
            g_farmlandManager:setLandOwnership(farmlandId, farmId)
            self.landFix = self.landFix or {}
            self.landFix[farmlandId] = true
        end
    end
    self.rentals[uid] = nil
    self:restoreProductionPoint(pp)
    MPUtil.notifyFarm(farmId, 3, "megaPatch_prod_bought", rental.name, price)
    self:raiseChanged()
    return true
end

---------------------------------------------------------------------------------------------------
-- dane dla GUI

function MPProductionRental:getEntries(farmId)
    local rented, available, owned = {}, {}, {}
    for _, pp in ipairs(self:getAllProductionPoints()) do
        local rental = self:getRental(pp)
        if rental ~= nil then
            if rental.farmId == farmId then
                table.insert(rented, {pp = pp, rental = rental})
            end
        elseif self:isRentable(pp) then
            table.insert(available, {pp = pp, offer = self:getOffer(pp, farmId)})
        elseif pp:getOwnerFarmId() == farmId then
            table.insert(owned, {pp = pp, owned = true})
        end
    end
    local byName = function(a, b) return MPProductionRental.getName(a.pp) < MPProductionRental.getName(b.pp) end
    table.sort(rented, byName)
    table.sort(available, byName)
    table.sort(owned, byName)
    return rented, available, owned
end

function MPProductionRental.getPosition(pp)
    local placeable = pp.owningPlaceable
    local node = placeable ~= nil and placeable.rootNode or nil
    if node ~= nil and node ~= 0 then
        local x, y, z = getWorldTranslation(node)
        return x, y, z
    end
    return nil
end

-- odleglosc od gracza w metrach
function MPProductionRental.getDistance(pp)
    local x, _, z = MPProductionRental.getPosition(pp)
    if x == nil or g_localPlayer == nil or g_localPlayer.getPosition == nil then
        return nil
    end
    local px, _, pz = g_localPlayer:getPosition()
    if px == nil then
        return nil
    end
    return math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
end

function MPProductionRental.formatDistance(d)
    if d == nil then
        return ""
    end
    if d >= 1000 then
        return string.format("%.1f km", d / 1000)
    end
    return string.format("%d m", math.floor(d))
end

-- ustawia znacznik celu na mapie (strzalka na minimapie / mapie)
function MPProductionRental.showOnMap(pp)
    local placeable = pp.owningPlaceable
    local hotspot = nil
    if placeable ~= nil and placeable.getHotspot ~= nil then
        hotspot = placeable:getHotspot(1)
    end
    local name = MPProductionRental.getName(pp)
    local dist = MPProductionRental.formatDistance(MPProductionRental.getDistance(pp))
    if hotspot ~= nil and g_currentMission.setMapTargetHotspot ~= nil then
        g_currentMission:setMapTargetHotspot(hotspot)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, MPUtil.getText("megaPatch_prod_mapMarked", name, dist))
        return true
    end
    local x, _, z = MPProductionRental.getPosition(pp)
    if x ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, MPUtil.getText("megaPatch_prod_mapCoords", name, string.format("%d / %d", x, z), dist))
    end
    return false
end

-- opis fabryki: produkty i odleglosc
function MPProductionRental.getDetails(pp, rental)
    local lines = {MPProductionRental.getName(pp)}
    local dist = MPProductionRental.formatDistance(MPProductionRental.getDistance(pp))
    if dist ~= "" then
        table.insert(lines, MPUtil.getText("megaPatch_ui_distance", dist))
    end
    local seen, products = {}, {}
    for _, production in ipairs(pp.productions or {}) do
        for _, output in ipairs(production.outputs or {}) do
            local ft = g_fillTypeManager:getFillTypeByIndex(output.type)
            if ft ~= nil and not seen[ft.index] then
                seen[ft.index] = true
                table.insert(products, ft.title)
            end
        end
    end
    if #products > 0 then
        table.insert(lines, "")
        table.insert(lines, MPUtil.getText("megaPatch_ui_products"))
        for i = 1, math.min(#products, 7) do
            table.insert(lines, "  - " .. products[i])
        end
        if #products > 7 then
            table.insert(lines, "  ...")
        end
    end
    if rental ~= nil then
        table.insert(lines, "")
        table.insert(lines, MPUtil.getText("megaPatch_prod_colFeesTotal") .. ": " .. MPUtil.formatMoney(rental.feesTotal or 0))
    end
    return table.concat(lines, "\n")
end

function MPProductionRental.getImage(pp)
    local placeable = pp.owningPlaceable
    local storeItem = placeable ~= nil and g_storeManager:getItemByXMLFilename(placeable.configFileName) or nil
    return storeItem ~= nil and storeItem.imageFilename or nil
end

-- szacowana liczba lat do momentu, gdy oplaty przekrocza cene zakupu (przy obecnym tempie)
function MPProductionRental:getBreakEvenYears(rental)
    local monthly = rental.avgMonthFee or rental.lastMonthFee or 0
    if monthly <= 0 then
        monthly = rental.monthFee
    end
    if monthly <= 0 then
        return nil
    end
    local remaining = math.max(0, rental.price - rental.feesTotal)
    return (remaining / monthly) / 12 + rental.months / 12
end

---------------------------------------------------------------------------------------------------
-- start / stan / zapis

function MPProductionRental:onStartMission()
    self.missionStarted = true
    if not g_currentMission:getIsServer() then
        return
    end
    for uid, rental in pairs(self.rentals) do
        local pp = self:getProductionPoint(uid)
        if pp == nil then
            Logging.warning("[MegaPatch] Rented production point '%s' not found - rental removed", tostring(uid))
            self.rentals[uid] = nil
        else
            if pp:getOwnerFarmId() ~= rental.farmId then
                self:setOwnerKeepLand(pp, rental.farmId)
            end
            self:applyRentalToProductionPoint(pp, rental)
            rental.megaPatchPP = pp
        end
    end
    self:raiseChanged()
end

function MPProductionRental:getState()
    local rentals = {}
    for uid, r in pairs(self.rentals) do
        rentals[uid] = {
            farmId = r.farmId, rate = r.rate, price = r.price, name = r.name, feesTotal = r.feesTotal,
            valueTotal = r.valueTotal, monthFee = r.monthFee, lastMonthFee = r.lastMonthFee,
            months = r.months, pendingFee = r.pendingFee, avgMonthFee = r.avgMonthFee
        }
    end
    -- prawdziwy wlasciciel dzialek pod wynajmowanymi fabrykami (klient po zmianie wlasciciela
    -- fabryki ustawia je u siebie blednie)
    local land = {}
    for farmlandId, _ in pairs(self.landFix or {}) do
        land[farmlandId] = g_farmlandManager:getFarmlandOwner(farmlandId) or 0
    end
    return {rentals = rentals, land = land}
end

function MPProductionRental:applyState(state)
    -- klient: tylko dane do wyswietlenia + blokada sprzedazy
    for _, pp in ipairs(self:getAllProductionPoints()) do
        pp.megaPatchRental = nil
    end
    self.rentals = state.rentals or {}
    for uid, rental in pairs(self.rentals) do
        local pp = self:getProductionPoint(uid)
        if pp ~= nil then
            pp.megaPatchRental = rental
        end
    end
    if not g_currentMission:getIsServer() then
        for farmlandId, owner in pairs(state.land or {}) do
            farmlandId, owner = tonumber(farmlandId), tonumber(owner)
            if farmlandId ~= nil and owner ~= nil and g_farmlandManager:getFarmlandOwner(farmlandId) ~= owner then
                g_farmlandManager:setLandOwnership(farmlandId, owner)
            end
        end
    end
    self:notifyListeners()
end

function MPProductionRental:sendInitialClientState(connection)
    connection:sendEvent(MPStateSyncEvent.new(MPProductionRental.MODULE, self:getState()))
end

local RENTAL_FLOATS = {"rate", "price", "feesTotal", "valueTotal", "monthFee", "lastMonthFee", "pendingFee", "avgMonthFee"}

function MPProductionRental:loadFromXMLFile(xmlFile, key)
    self.rentals = {}
    local i = 0
    while true do
        local k = string.format("%s.production.rental(%d)", key, i)
        if not xmlFile:hasProperty(k) then
            break
        end
        local uid = xmlFile:getString(k .. "#uid")
        if uid ~= nil then
            local r = {farmId = xmlFile:getInt(k .. "#farmId", 1), months = xmlFile:getInt(k .. "#months", 0), name = xmlFile:getString(k .. "#name", "?")}
            for _, f in ipairs(RENTAL_FLOATS) do
                r[f] = xmlFile:getFloat(k .. "#" .. f, 0)
            end
            self.rentals[uid] = r
        end
        i = i + 1
    end
end

function MPProductionRental:saveToXMLFile(xmlFile, key)
    local i = 0
    for uid, r in pairs(self.rentals) do
        local k = string.format("%s.production.rental(%d)", key, i)
        xmlFile:setString(k .. "#uid", uid)
        xmlFile:setInt(k .. "#farmId", r.farmId)
        xmlFile:setInt(k .. "#months", r.months or 0)
        xmlFile:setString(k .. "#name", r.name or "?")
        for _, f in ipairs(RENTAL_FLOATS) do
            xmlFile:setFloat(k .. "#" .. f, r[f] or 0)
        end
        i = i + 1
    end
end

function MPProductionRental:consoleInfo()
    local lines = {}
    for uid, r in pairs(self.rentals) do
        table.insert(lines, string.format("%s | farma %d | stawka %.1f%% | oplaty %.0f / cena %.0f | przerob %.0f", r.name, r.farmId, r.rate * 100, r.feesTotal, r.price, r.valueTotal))
    end
    local farmId = MPUtil.getLocalFarmId()
    for _, pp in ipairs(self:getAllProductionPoints()) do
        if self:isRentable(pp) then
            local o = self:getOffer(pp, farmId)
            table.insert(lines, string.format("DO WYNAJECIA %s | cena %.0f | stawka %.1f%% | max/mies %.0f", MPProductionRental.getName(pp), o.price, o.rate * 100, o.maxMonthly))
        end
    end
    if #lines == 0 then
        return "Brak fabryk"
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------------------------------
-- dialog przy fabryce (zamiast samego "Kup")

function MPProductionRental.showRentOrBuyDialog(pp, onBuy)
    local inst = MPProductionRental.instance
    if inst == nil then
        onBuy()
        return
    end
    local farmId = MPUtil.getLocalFarmId()
    local offer = inst:getOffer(pp, farmId)
    MPFinanceDialog.show({
        layout = "split",
        title = MPProductionRental.getName(pp),
        image = MPProductionRental.getImage(pp),
        getDetails = function() return MPProductionRental.getDetails(pp, nil) end,
        getText = function()
            return table.concat({
                MPUtil.getText("megaPatch_prod_offer1", MPUtil.formatMoney(offer.price)),
                "",
                MPUtil.getText("megaPatch_prod_offer2"),
                MPUtil.getText("megaPatch_prod_offer3", string.format("%.1f", offer.rate * 100)),
                MPUtil.getText("megaPatch_prod_offer4", MPUtil.formatMoney(offer.feeAtReference)),
                MPUtil.getText("megaPatch_prod_offer5", MPUtil.formatMoney(offer.feeAtFull)),
                "",
                MPUtil.getText("megaPatch_prod_offer6", tostring(MPProductionRental.BREAK_EVEN_YEARS)),
                MPUtil.getText("megaPatch_prod_offer7")
            }, "\n")
        end,
        okText = MPUtil.getText("megaPatch_prod_buy"),
        onOk = onBuy,
        optionA = {
            getLabel = function() return MPUtil.getText("megaPatch_prod_rent") end,
            closeOnClick = true,
            onClick = function()
                MPRequestEvent.sendRequest(MPProductionRental.MODULE, "rent", MPProductionRental.getRequestData(pp))
            end
        }
    })
end

function MPProductionRental.callOriginalBuy(pp)
    if MPProductionRental.originalBuyRequest ~= nil then
        MPProductionRental.originalBuyRequest(pp)
    end
end

---------------------------------------------------------------------------------------------------
-- hooks

function MPProductionRental.installHooks()
    -- pomiar przerobu: ubytek surowca w magazynie wynajetej fabryki
    Storage.setFillLevel = Utils.overwrittenFunction(Storage.setFillLevel, function(storage, superFunc, fillLevel, fillType, ...)
        local pp = storage.megaPatchProductionPoint
        if pp == nil or not g_currentMission:getIsServer() then
            return superFunc(storage, fillLevel, fillType, ...)
        end
        local old = storage.fillLevels ~= nil and storage.fillLevels[fillType] or nil
        local result = superFunc(storage, fillLevel, fillType, ...)
        local new = storage.fillLevels ~= nil and storage.fillLevels[fillType] or nil
        if old ~= nil and new ~= nil and new < old then
            local inst = MPProductionRental.instance
            if inst ~= nil then
                inst:onInputConsumed(pp, fillType, old - new)
            end
        end
        return result
    end)

    -- wynajetej fabryki nie mozna sprzedac
    Placeable.canBeSold = Utils.overwrittenFunction(Placeable.canBeSold, function(placeable, superFunc, ...)
        local spec = placeable.spec_productionPoint
        if spec ~= nil and spec.productionPoint ~= nil and spec.productionPoint.megaPatchRental ~= nil then
            return false, MPUtil.getText("megaPatch_prod_cannotSell")
        end
        return superFunc(placeable, ...)
    end)

    Placeable.getSellPrice = Utils.overwrittenFunction(Placeable.getSellPrice, function(placeable, superFunc, ...)
        local spec = placeable.spec_productionPoint
        if spec ~= nil and spec.productionPoint ~= nil and spec.productionPoint.megaPatchRental ~= nil then
            return 0
        end
        return superFunc(placeable, ...)
    end)

    -- przy fabryce: wybor Kup / Korzystaj bez kupowania
    MPProductionRental.originalBuyRequest = ProductionPoint.buyRequest
    ProductionPoint.buyRequest = Utils.overwrittenFunction(ProductionPoint.buyRequest, function(pp, superFunc, requestCallback, target)
        if g_guidedTourManager ~= nil and g_guidedTourManager:getIsTourRunning() then
            return superFunc(pp, requestCallback, target)
        end
        MPProductionRental.showRentOrBuyDialog(pp, function()
            superFunc(pp, requestCallback, target)
        end)
    end)
end
