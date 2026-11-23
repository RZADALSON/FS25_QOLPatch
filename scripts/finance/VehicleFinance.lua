-- FS25_MegaPatch: finansowanie pojazdow (kredyt ratalny / leasing z wykupem)
--
-- Jak to dziala:
--  * Pojazd bierzesz w sklepie w LEASING (jak dotad). W menu gry, zakladka "Finansowanie",
--    mozesz zamienic leasing na finansowanie. Wszystko co juz zaplaciles za leasing tego pojazdu
--    (oplata poczatkowa + oplaty dzienne + oplaty za motogodziny) jest odliczane od ceny.
--  * Pojazd od razu przechodzi na farme (OWNED), ale bank ma na nim zastaw do konca splaty.
--  * Rata annuitetowa pobierana co miesiac gry (zmiana okresu). Oprocentowanie zalezy od
--    trudnosci ekonomicznej i dlugosci umowy.
--  * Brak srodkow = rata niezaplacona: oplata za zwloke + odsetki karne od calego salda.
--    Po 3 niezaplaconych ratach z rzedu bank zabiera pojazd (licytacja 85% wartosci rynkowej,
--    nadwyzka ponad dlug wraca na konto, niedobor jest umarzany).
--  * Splata calosci (rata po racie albo przedterminowo) = pojazd na stale Twoj, bez zastawu.
--  * Sprzedaz finansowanego pojazdu: pozostale saldo jest automatycznie potracane z konta.
--  * Dla istniejacego zapisu kwota wplacona za leasing jest szacowana z wieku i motogodzin
--    pojazdu (oznaczone "~"), od zainstalowania moda liczona jest dokladnie.

MPVehicleFinance = {}
local MPVehicleFinance_mt = Class(MPVehicleFinance)

MPVehicleFinance.MODULE = "finance"

-- okres: 6-84 miesiecy co 6, wklad wlasny: 0-60% co 5
MPVehicleFinance.TERMS = {6, 12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72, 78, 84}
MPVehicleFinance.DOWN_PAYMENTS = {0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60}
MPVehicleFinance.DEFAULT_TERM_INDEX = 6
MPVehicleFinance.DEFAULT_DOWN_INDEX = 3

-- oprocentowanie roczne wg trudnosci ekonomicznej (latwy / normalny / trudny)
MPVehicleFinance.BASE_APR = {0.049, 0.069, 0.099}
MPVehicleFinance.TERM_PREMIUM_PER_YEAR = 0.0025
MPVehicleFinance.ORIGINATION_FEE = 0.01       -- prowizja bankowa od kwoty kredytu
MPVehicleFinance.ORIGINATION_FEE_MIN = 250
MPVehicleFinance.LATE_FEE_RATE = 0.05         -- oplata za zwloke: 5% raty
MPVehicleFinance.LATE_FEE_MIN = 150
MPVehicleFinance.PENALTY_APR_ADD = 0.08       -- odsetki karne: +8 p.p. gdy sa zaleglosci
MPVehicleFinance.REPOSSESS_AFTER = 3          -- tyle niezaplaconych rat z rzedu = odebranie pojazdu
MPVehicleFinance.EARLY_PAYOFF_FEE = 0.01      -- prowizja za wczesniejsza splate
MPVehicleFinance.AUCTION_FACTOR = 0.85
MPVehicleFinance.MIN_PRINCIPAL = 1000         -- ponizej tej kwoty: wykup jednorazowy zamiast kredytu
MPVehicleFinance.PER_DAY_LEASING_FACTOR_FALLBACK = 0.01
MPVehicleFinance.RUNNING_LEASING_FACTOR_FALLBACK = 0.021

MPVehicleFinance.SCAN_INTERVAL = 5000
MPVehicleFinance.SOLD_CHECK_DELAY = 4000

function MPVehicleFinance.new(megaPatch)
    local self = setmetatable({}, MPVehicleFinance_mt)
    self.megaPatch = megaPatch
    self.contracts = {}       -- [uid] = contract
    self.leasePaid = {}       -- [uid] = {paid=, est=bool, farmId=}
    self.pendingDeleted = {}  -- [uid] = {time=, farmId=}
    self.repossessing = {}
    self.scanTimer = 0
    self.missionStarted = false
    self.listeners = {}
    return self
end

function MPVehicleFinance:loadMap()
    MPVehicleFinance.instance = self
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
        g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    end
end

function MPVehicleFinance:delete()
    g_messageCenter:unsubscribeAll(self)
    MPVehicleFinance.instance = nil
end

function MPVehicleFinance:onStartMission()
    self.missionStarted = true
    if g_currentMission:getIsServer() then
        self:scanVehicles()
        self:raiseChanged()
    end
end

function MPVehicleFinance:addChangeListener(func, target)
    self.listeners[target] = func
end

function MPVehicleFinance:removeChangeListener(target)
    self.listeners[target] = nil
end

function MPVehicleFinance:notifyListeners()
    for target, func in pairs(self.listeners) do
        func(target)
    end
end

-- server: stan zmieniony -> synchronizacja + odswiezenie GUI
function MPVehicleFinance:raiseChanged()
    MPStateSyncEvent.broadcast(MPVehicleFinance.MODULE, self:getState())
    self:notifyListeners()
end

---------------------------------------------------------------------------------------------------
-- leasing: sledzenie ile zaplacono

function MPVehicleFinance.getLeasingFactors(vehicle)
    local perDay = EconomyManager.PER_DAY_LEASING_FACTOR or MPVehicleFinance.PER_DAY_LEASING_FACTOR_FALLBACK
    local running = EconomyManager.DEFAULT_RUNNING_LEASING_FACTOR or MPVehicleFinance.RUNNING_LEASING_FACTOR_FALLBACK
    local storeItem = vehicle ~= nil and g_storeManager:getItemByXMLFilename(vehicle.configFileName) or nil
    if storeItem ~= nil and storeItem.runningLeasingFactor ~= nil then
        running = storeItem.runningLeasingFactor
    end
    return perDay, running
end

function MPVehicleFinance:estimateLeasePaid(vehicle)
    local price = vehicle:getPrice() or 0
    local perDay, running = MPVehicleFinance.getLeasingFactors(vehicle)
    local initial
    local em = g_currentMission.economyManager
    if em ~= nil and em.getInitialLeasingPrice ~= nil then
        initial = em:getInitialLeasingPrice(price)
    else
        initial = price * (0.02 + running + perDay)
    end
    local days = math.max(0, (vehicle.age or 0) * MPUtil.getDaysPerPeriod())
    local hours = math.floor((vehicle.operatingTime or 0) / (1000 * 60 * 60))
    return initial + price * perDay * days + price * running * hours
end

function MPVehicleFinance:scanVehicles()
    if g_currentMission.vehicleSystem == nil then
        return false
    end
    local changed = false
    local present = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        local uid = MPUtil.getVehicleUniqueId(vehicle)
        if uid ~= nil then
            present[uid] = true
            if vehicle.propertyState == VehiclePropertyState.LEASED and self.leasePaid[uid] == nil and not vehicle.markedForDeletion then
                local isNew = (vehicle.age or 0) == 0 and (vehicle.operatingTime or 0) < 60000
                self.leasePaid[uid] = {paid = self:estimateLeasePaid(vehicle), est = not isNew, farmId = vehicle:getOwnerFarmId()}
                changed = true
            end
        end
    end
    -- pojazdy oddane z leasingu / usuniete
    for uid, _ in pairs(self.leasePaid) do
        if not present[uid] and self.contracts[uid] == nil then
            self.leasePaid[uid] = nil
            changed = true
        end
    end
    return changed
end

function MPVehicleFinance:addLeasePayment(vehicle, amount)
    local uid = MPUtil.getVehicleUniqueId(vehicle)
    if uid == nil or amount <= 0 then
        return
    end
    local entry = self.leasePaid[uid]
    if entry == nil then
        entry = {paid = self:estimateLeasePaid(vehicle), est = true, farmId = vehicle:getOwnerFarmId()}
        self.leasePaid[uid] = entry
    end
    entry.paid = entry.paid + amount
end

function MPVehicleFinance:onDayChanged()
    if g_currentMission.vehicleSystem == nil then
        return
    end
    local perDayFactor = EconomyManager.PER_DAY_LEASING_FACTOR or MPVehicleFinance.PER_DAY_LEASING_FACTOR_FALLBACK
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.propertyState == VehiclePropertyState.LEASED then
            self:addLeasePayment(vehicle, (vehicle:getPrice() or 0) * perDayFactor)
        end
    end
    self:raiseChanged()
end

function MPVehicleFinance:onVehicleOperatingHour(vehicle)
    if vehicle.propertyState == VehiclePropertyState.LEASED then
        local _, running = MPVehicleFinance.getLeasingFactors(vehicle)
        self:addLeasePayment(vehicle, (vehicle:getPrice() or 0) * running)
    end
end

function MPVehicleFinance:getLeasePaid(uid)
    local entry = self.leasePaid[uid]
    if entry == nil then
        return 0, false
    end
    return entry.paid, entry.est
end

---------------------------------------------------------------------------------------------------
-- oferta

function MPVehicleFinance:getApr(termMonths)
    local base = MPVehicleFinance.BASE_APR[MPUtil.getEconomicDifficulty()] or MPVehicleFinance.BASE_APR[2]
    local years = termMonths / 12
    return base + MPVehicleFinance.TERM_PREMIUM_PER_YEAR * math.max(0, years - 1)
end

function MPVehicleFinance:getQuote(vehicle, termIndex, downIndex)
    local uid = MPUtil.getVehicleUniqueId(vehicle)
    local term = MPVehicleFinance.TERMS[termIndex] or MPVehicleFinance.TERMS[MPVehicleFinance.DEFAULT_TERM_INDEX]
    local downRate = MPVehicleFinance.DOWN_PAYMENTS[downIndex] or MPVehicleFinance.DOWN_PAYMENTS[MPVehicleFinance.DEFAULT_DOWN_INDEX]
    local price = vehicle:getPrice() or 0
    local paid, est = self:getLeasePaid(uid)
    local credit = math.min(paid, price)
    local rest = math.max(0, price - credit)
    local down = math.floor(rest * downRate + 0.5)
    local principal = rest - down

    local q = {
        uid = uid, name = MPUtil.getVehicleName(vehicle), price = price, credit = credit, creditEstimated = est,
        term = term, termIndex = termIndex, downIndex = downIndex, downRate = downRate, down = down,
        principal = principal, isBuyout = false
    }

    if principal < MPVehicleFinance.MIN_PRINCIPAL then
        q.isBuyout = true
        q.principal = 0
        q.down = rest
        q.fee = 0
        q.apr = 0
        q.installment = 0
        q.total = rest
        q.upfront = rest
        return q
    end

    q.apr = self:getApr(term)
    q.fee = math.max(MPVehicleFinance.ORIGINATION_FEE_MIN, math.floor(principal * MPVehicleFinance.ORIGINATION_FEE + 0.5))
    q.installment = MPUtil.annuity(principal, q.apr, term)
    q.total = q.installment * term + down + q.fee
    q.upfront = down + q.fee
    return q
end

---------------------------------------------------------------------------------------------------
-- akcje (server)

function MPVehicleFinance:onRequest(action, data, farmId, connection)
    if not g_currentMission:getIsServer() then
        return
    end
    -- klient zna pojazd po sieciowym ID; na serwerze umowy sa trzymane pod uniqueId serwera
    local vehicle = MPUtil.resolveVehicle(data)
    local uid = vehicle ~= nil and MPUtil.getVehicleUniqueId(vehicle) or data.uid
    if uid == nil then
        return
    end
    if action == "start" then
        self:startContract(uid, data.termIndex, data.downIndex, farmId)
    elseif action == "payArrears" then
        self:payArrears(uid, farmId)
    elseif action == "payOff" then
        self:payOff(uid, farmId)
    end
end

function MPVehicleFinance:startContract(uid, termIndex, downIndex, farmId)
    local vehicle = MPUtil.getVehicleByUniqueId(uid)
    if vehicle == nil or vehicle.propertyState ~= VehiclePropertyState.LEASED or vehicle:getOwnerFarmId() ~= farmId or self.contracts[uid] ~= nil then
        return false
    end
    local q = self:getQuote(vehicle, termIndex, downIndex)
    if MPUtil.getFarmMoney(farmId) < q.upfront then
        MPUtil.notifyFarm(farmId, 2, "megaPatch_finance_notEnoughMoney", q.upfront)
        return false
    end

    MPUtil.addMoney(-q.down, farmId, "SHOP_VEHICLE_BUY")
    MPUtil.addMoney(-q.fee, farmId, "LOAN_INTEREST")

    MPVehicleFinance.setVehicleOwned(vehicle)
    self.leasePaid[uid] = nil

    if q.isBuyout then
        MPUtil.notifyFarm(farmId, 3, "megaPatch_finance_boughtOut", q.name, q.upfront)
    else
        self.contracts[uid] = {
            uid = uid, farmId = farmId, name = q.name, price = q.price, credit = q.credit,
            down = q.down, principal = q.principal, apr = q.apr, term = q.term,
            installment = q.installment, balance = q.principal, missed = 0, arrears = 0,
            paidTotal = q.down + q.fee, interestTotal = 0, feesTotal = q.fee, monthsPaid = 0
        }
        MPUtil.notifyFarm(farmId, 3, "megaPatch_finance_started", q.name, q.installment)
    end
    self:raiseChanged()
    return true
end

-- LEASED -> OWNED (na serwerze i u klientow)
function MPVehicleFinance.setVehicleOwned(vehicle)
    if vehicle.propertyState ~= VehiclePropertyState.LEASED then
        return
    end
    g_currentMission:removeLeasedItem(vehicle)
    vehicle.propertyState = VehiclePropertyState.OWNED
    g_currentMission:addOwnedItem(vehicle)
end

function MPVehicleFinance:getMonthlyRate(contract)
    local apr = contract.apr
    if contract.missed > 0 then
        apr = apr + MPVehicleFinance.PENALTY_APR_ADD
    end
    return apr / 12
end

function MPVehicleFinance:getRemainingMonths(contract)
    local r = contract.apr / 12
    local b, a = contract.balance, contract.installment
    if b <= 0 then
        return 0
    end
    if r <= 0 then
        return math.ceil(b / a)
    end
    local x = 1 - r * b / a
    if x <= 0 then
        return 999
    end
    return math.ceil(-math.log(x) / math.log(1 + r))
end

-- rozliczenie miesieczne
function MPVehicleFinance:onPeriodChanged()
    if not g_currentMission:getIsServer() then
        return
    end
    local uids = {}
    for uid, _ in pairs(self.contracts) do
        table.insert(uids, uid)
    end
    for _, uid in ipairs(uids) do
        self:processContract(self.contracts[uid])
    end
    self:raiseChanged()
end

function MPVehicleFinance:processContract(c)
    if c == nil then
        return
    end
    local vehicle = MPUtil.getVehicleByUniqueId(c.uid)
    if vehicle == nil then
        if self.pendingDeleted[c.uid] == nil then
            self:settleRemovedVehicle(c)
        end
        return
    end

    local interest = c.balance * self:getMonthlyRate(c)
    c.balance = c.balance + interest
    c.interestTotal = c.interestTotal + interest

    local due = math.min(c.balance, c.installment + c.arrears)
    if MPUtil.getFarmMoney(c.farmId) >= due then
        local interestPart = math.min(interest, due)
        MPUtil.addMoney(-interestPart, c.farmId, "LOAN_INTEREST")
        MPUtil.addMoney(-(due - interestPart), c.farmId, "SHOP_VEHICLE_BUY")
        c.balance = c.balance - due
        c.paidTotal = c.paidTotal + due
        c.monthsPaid = c.monthsPaid + 1
        local hadArrears = c.missed > 0
        c.arrears = 0
        c.missed = 0
        if c.balance <= 1 then
            self:completeContract(c)
        elseif hadArrears then
            MPUtil.notifyFarm(c.farmId, 3, "megaPatch_finance_arrearsCleared", c.name)
        end
    else
        local fee = math.max(MPVehicleFinance.LATE_FEE_MIN, c.installment * MPVehicleFinance.LATE_FEE_RATE)
        c.missed = c.missed + 1
        c.arrears = c.arrears + c.installment + fee
        c.balance = c.balance + fee
        c.feesTotal = c.feesTotal + fee
        if c.missed >= MPVehicleFinance.REPOSSESS_AFTER then
            self:repossess(c, vehicle)
        else
            local left = MPVehicleFinance.REPOSSESS_AFTER - c.missed
            MPUtil.notifyFarm(c.farmId, 2, "megaPatch_finance_missed", c.name, c.arrears, tostring(left))
        end
    end
end

function MPVehicleFinance:completeContract(c)
    self.contracts[c.uid] = nil
    MPUtil.notifyFarm(c.farmId, 3, "megaPatch_finance_completed", c.name)
end

function MPVehicleFinance:repossess(c, vehicle)
    local value = 0
    if vehicle.getSellPrice ~= nil then
        value = vehicle:getSellPrice() * MPVehicleFinance.AUCTION_FACTOR
    end
    local surplus = math.floor(value - c.balance)
    self.contracts[c.uid] = nil
    self.repossessing[c.uid] = true
    if surplus > 0 then
        MPUtil.addMoney(surplus, c.farmId, "SHOP_VEHICLE_SELL")
    end
    MPUtil.notifyFarm(c.farmId, 2, "megaPatch_finance_repossessed", c.name, math.max(0, surplus))
    vehicle:delete()
end

function MPVehicleFinance:payArrears(uid, farmId)
    local c = self.contracts[uid]
    if c == nil or c.farmId ~= farmId or c.arrears <= 0 then
        return false
    end
    local amount = math.min(c.arrears, c.balance)
    if MPUtil.getFarmMoney(farmId) < amount then
        MPUtil.notifyFarm(farmId, 2, "megaPatch_finance_notEnoughMoney", amount)
        return false
    end
    MPUtil.addMoney(-amount, farmId, "SHOP_VEHICLE_BUY")
    c.balance = c.balance - amount
    c.paidTotal = c.paidTotal + amount
    c.arrears = 0
    c.missed = 0
    if c.balance <= 1 then
        self:completeContract(c)
    else
        MPUtil.notifyFarm(farmId, 3, "megaPatch_finance_arrearsCleared", c.name)
    end
    self:raiseChanged()
    return true
end

function MPVehicleFinance:getPayOffAmount(c)
    return c.balance * (1 + MPVehicleFinance.EARLY_PAYOFF_FEE)
end

function MPVehicleFinance:payOff(uid, farmId)
    local c = self.contracts[uid]
    if c == nil or c.farmId ~= farmId then
        return false
    end
    local amount = self:getPayOffAmount(c)
    if MPUtil.getFarmMoney(farmId) < amount then
        MPUtil.notifyFarm(farmId, 2, "megaPatch_finance_notEnoughMoney", amount)
        return false
    end
    MPUtil.addMoney(-c.balance, farmId, "SHOP_VEHICLE_BUY")
    MPUtil.addMoney(-(amount - c.balance), farmId, "LOAN_INTEREST")
    c.paidTotal = c.paidTotal + amount
    c.balance = 0
    self:completeContract(c)
    self:raiseChanged()
    return true
end

-- pojazd zniknal (sprzedany przez gracza): bank sciaga saldo
function MPVehicleFinance:settleRemovedVehicle(c)
    self.contracts[c.uid] = nil
    local amount = c.balance
    if amount > 0 then
        MPUtil.addMoney(-amount, c.farmId, "SHOP_VEHICLE_BUY")
    end
    MPUtil.notifyFarm(c.farmId, 1, "megaPatch_finance_soldSettled", c.name, amount)
end

function MPVehicleFinance:onVehicleDelete(vehicle)
    if g_currentMission == nil or g_currentMission.isExitingGame or not g_currentMission:getIsServer() then
        return
    end
    local uid = MPUtil.getVehicleUniqueId(vehicle)
    if uid == nil then
        return
    end
    if self.repossessing[uid] then
        self.repossessing[uid] = nil
        return
    end
    if self.contracts[uid] ~= nil and self.pendingDeleted[uid] == nil then
        self.pendingDeleted[uid] = {time = g_time + MPVehicleFinance.SOLD_CHECK_DELAY}
    end
end

function MPVehicleFinance:update(dt)
    if not self.missionStarted or not g_currentMission:getIsServer() then
        return
    end
    local changed = false
    for uid, pending in pairs(self.pendingDeleted) do
        if g_time >= pending.time then
            self.pendingDeleted[uid] = nil
            local c = self.contracts[uid]
            -- reset pojazdu laduje go ponownie z tym samym uid - wtedy nic nie robimy
            if c ~= nil and MPUtil.getVehicleByUniqueId(uid) == nil then
                self:settleRemovedVehicle(c)
                changed = true
            end
        end
    end
    self.scanTimer = self.scanTimer + dt
    if self.scanTimer > MPVehicleFinance.SCAN_INTERVAL then
        self.scanTimer = 0
        if self:scanVehicles() then
            changed = true
        end
    end
    if changed then
        self:raiseChanged()
    end
end

---------------------------------------------------------------------------------------------------
-- dane dla GUI (klient)

function MPVehicleFinance:getFarmEntries(farmId)
    if self.remapPending and not g_currentMission:getIsServer() then
        self:remapClientState()
    end
    local leased, financed = {}, {}
    if g_currentMission.vehicleSystem == nil then
        return leased, financed
    end
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        local uid = MPUtil.getVehicleUniqueId(vehicle)
        if uid ~= nil and vehicle:getOwnerFarmId() == farmId and not vehicle.markedForDeletion then
            if self.contracts[uid] ~= nil then
                table.insert(financed, {vehicle = vehicle, uid = uid, contract = self.contracts[uid]})
            elseif vehicle.propertyState == VehiclePropertyState.LEASED then
                local paid, est = self:getLeasePaid(uid)
                table.insert(leased, {vehicle = vehicle, uid = uid, paid = paid, est = est})
            end
        end
    end
    local byName = function(a, b) return MPUtil.getVehicleName(a.vehicle) < MPUtil.getVehicleName(b.vehicle) end
    table.sort(leased, byName)
    table.sort(financed, byName)
    return leased, financed
end

---------------------------------------------------------------------------------------------------
-- stan / zapis

-- stan dla klientow: kazdy wpis dostaje sieciowe ID pojazdu (oid), bo uniqueId klienta jest inny
local function withNetIds(list)
    local out = {}
    for uid, entry in pairs(list) do
        local copy = {}
        for k, v in pairs(entry) do
            copy[k] = v
        end
        local vehicle = MPUtil.getVehicleByUniqueId(uid)
        copy.oid = vehicle ~= nil and MPUtil.getNetId(vehicle) or nil
        out[uid] = copy
    end
    return out
end

function MPVehicleFinance:getState()
    return {contracts = withNetIds(self.contracts), leasePaid = withNetIds(self.leasePaid)}
end

function MPVehicleFinance:applyState(state)
    if g_currentMission:getIsServer() then
        return
    end
    self.rawState = state
    self:remapClientState()
    self:notifyListeners()
end

-- klient: wpisy serwera -> klucze = uniqueId pojazdow tego klienta (pojazdy moga sie jeszcze ladowac)
function MPVehicleFinance:remapClientState()
    local state = self.rawState
    if state == nil then
        return
    end
    local contracts, leasePaid = {}, {}
    local pending = false
    local function remap(list, out, isContract)
        for _, entry in pairs(list or {}) do
            local vehicle = MPUtil.getObjectByNetId(entry.oid)
            local localUid = vehicle ~= nil and MPUtil.getVehicleUniqueId(vehicle) or nil
            if localUid ~= nil then
                local copy = {}
                for k, v in pairs(entry) do
                    copy[k] = v
                end
                copy.uid = localUid
                out[localUid] = copy
                if isContract then
                    MPVehicleFinance.setVehicleOwned(vehicle)
                end
            elseif entry.oid ~= nil then
                pending = true
            end
        end
    end
    remap(state.contracts, contracts, true)
    remap(state.leasePaid, leasePaid, false)
    self.contracts = contracts
    self.leasePaid = leasePaid
    self.remapPending = pending
end

function MPVehicleFinance:sendInitialClientState(connection)
    connection:sendEvent(MPStateSyncEvent.new(MPVehicleFinance.MODULE, self:getState()))
end

local CONTRACT_FLOATS = {"price", "credit", "down", "principal", "apr", "installment", "balance", "arrears", "paidTotal", "interestTotal", "feesTotal"}
local CONTRACT_INTS = {"farmId", "term", "missed", "monthsPaid"}

function MPVehicleFinance:loadFromXMLFile(xmlFile, key)
    self.contracts = {}
    self.leasePaid = {}
    local i = 0
    while true do
        local k = string.format("%s.finance.contract(%d)", key, i)
        if not xmlFile:hasProperty(k) then
            break
        end
        local c = {uid = xmlFile:getString(k .. "#uid"), name = xmlFile:getString(k .. "#name", "?")}
        for _, f in ipairs(CONTRACT_FLOATS) do
            c[f] = xmlFile:getFloat(k .. "#" .. f, 0)
        end
        for _, f in ipairs(CONTRACT_INTS) do
            c[f] = xmlFile:getInt(k .. "#" .. f, 0)
        end
        if c.uid ~= nil then
            self.contracts[c.uid] = c
        end
        i = i + 1
    end
    i = 0
    while true do
        local k = string.format("%s.finance.lease(%d)", key, i)
        if not xmlFile:hasProperty(k) then
            break
        end
        local uid = xmlFile:getString(k .. "#uid")
        if uid ~= nil then
            self.leasePaid[uid] = {paid = xmlFile:getFloat(k .. "#paid", 0), est = xmlFile:getBool(k .. "#estimated", true), farmId = xmlFile:getInt(k .. "#farmId", 1)}
        end
        i = i + 1
    end
end

function MPVehicleFinance:saveToXMLFile(xmlFile, key)
    local i = 0
    for uid, c in pairs(self.contracts) do
        local k = string.format("%s.finance.contract(%d)", key, i)
        xmlFile:setString(k .. "#uid", uid)
        xmlFile:setString(k .. "#name", c.name or "?")
        for _, f in ipairs(CONTRACT_FLOATS) do
            xmlFile:setFloat(k .. "#" .. f, c[f] or 0)
        end
        for _, f in ipairs(CONTRACT_INTS) do
            xmlFile:setInt(k .. "#" .. f, c[f] or 0)
        end
        i = i + 1
    end
    i = 0
    for uid, e in pairs(self.leasePaid) do
        local k = string.format("%s.finance.lease(%d)", key, i)
        xmlFile:setString(k .. "#uid", uid)
        xmlFile:setFloat(k .. "#paid", e.paid or 0)
        xmlFile:setBool(k .. "#estimated", e.est == true)
        xmlFile:setInt(k .. "#farmId", e.farmId or 1)
        i = i + 1
    end
end

---------------------------------------------------------------------------------------------------
-- konsola

function MPVehicleFinance:consoleFinanceInfo()
    local lines = {}
    for uid, c in pairs(self.contracts) do
        table.insert(lines, string.format("%s | saldo %.0f | rata %.0f | zaleglosci %.0f (%d) | ~%d mies.", c.name, c.balance, c.installment, c.arrears, c.missed, self:getRemainingMonths(c)))
    end
    for uid, e in pairs(self.leasePaid) do
        local v = MPUtil.getVehicleByUniqueId(uid)
        table.insert(lines, string.format("LEASING %s | wplacono %s%.0f", v ~= nil and MPUtil.getVehicleName(v) or uid, e.est and "~" or "", e.paid))
    end
    if #lines == 0 then
        return "Brak umow i pojazdow w leasingu"
    end
    return table.concat(lines, "\n")
end

function MPVehicleFinance:consoleForceMonth()
    if not g_currentMission:getIsServer() then
        return "Tylko na serwerze"
    end
    self:onPeriodChanged()
    return self:consoleFinanceInfo()
end

---------------------------------------------------------------------------------------------------
-- hooks

function MPVehicleFinance.installHooks()
    if EconomyManager.vehicleOperatingHourChanged ~= nil then
        EconomyManager.vehicleOperatingHourChanged = Utils.appendedFunction(EconomyManager.vehicleOperatingHourChanged, function(em, vehicle)
            local inst = MPVehicleFinance.instance
            if inst ~= nil and vehicle ~= nil and g_currentMission:getIsServer() then
                inst:onVehicleOperatingHour(vehicle)
            end
        end)
    else
        Logging.warning("[MegaPatch] EconomyManager.vehicleOperatingHourChanged not found - leasing hours not tracked")
    end

    Vehicle.delete = Utils.prependedFunction(Vehicle.delete, function(vehicle, immediate)
        local inst = MPVehicleFinance.instance
        if inst ~= nil and not vehicle.markedForDeletion and vehicle.propertyState == VehiclePropertyState.OWNED then
            inst:onVehicleDelete(vehicle)
        end
    end)
end
