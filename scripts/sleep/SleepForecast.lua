-- FS25_MegaPatch: prognoza na czas dlugiego snu (1-12 miesiecy)
--
-- Liczy dla wybranej liczby miesiecy:
--  * pola: co bedzie gotowe do zbioru po przebudzeniu, co przejrzeje i zgnije (strata), chwasty
--  * zwierzeta: kiedy skonczy sie pasza / woda / slomka
--  * fabryki (wlasne i wynajete): kiedy zabraknie surowca, kiedy zapelni sie magazyn, wartosc produkcji
--  * pieniadze: koszty stale (z historii finansow gry), leasing, raty finansowania, utrzymanie maszyn,
--    oplaty za fabryki, sprzedaz bezposrednia z fabryk; najnizsze saldo w trakcie snu
--  * maszyny: utrata wartosci przez wiek, maszyny wymagajace naprawy
-- Wynik: prawdopodobny zarobek, prawdopodobna strata i rekomendacja.

MPSleepForecast = {}

MPSleepForecast.PERIOD_NAMES = {
    EARLY_SPRING = 1, MID_SPRING = 2, LATE_SPRING = 3,
    EARLY_SUMMER = 4, MID_SUMMER = 5, LATE_SUMMER = 6,
    EARLY_AUTUMN = 7, MID_AUTUMN = 8, LATE_AUTUMN = 9,
    EARLY_WINTER = 10, MID_WINTER = 11, LATE_WINTER = 12
}

-- kategorie statystyk finansowych gry, ktore biegna takze gdy nikt nie pracuje
-- (leasing, utrzymanie maszyn i koszty fabryk liczone sa osobno i dokladnie)
MPSleepForecast.PASSIVE_STATS = {"propertyMaintenance", "propertyIncome", "loanInterest", "purchaseWater", "soldMilk", "animalUpkeep", "incomeBga"}

-- progi rekomendacji
MPSleepForecast.LOSS_ABS_THRESHOLD = 20000
MPSleepForecast.LOSS_REL_THRESHOLD = 0.15

MPSleepForecast.growthCache = {}

---------------------------------------------------------------------------------------------------
-- wzrost upraw (z pliku foliage danej uprawy, sekcja growth/seasonal)

function MPSleepForecast.getGrowthRules(fruitType)
    local cache = MPSleepForecast.growthCache
    if cache[fruitType.index] ~= nil then
        return cache[fruitType.index] or nil
    end
    local rules = false
    if fruitType.xmlFilename ~= nil and fruitType.nameToGrowthState ~= nil then
        local xmlFile = XMLFile.load("mpGrowth", fruitType.xmlFilename)
        if xmlFile ~= nil then
            rules = {}
            local i = 0
            while true do
                local pk = string.format("foliageType.growth.seasonal.period(%d)", i)
                if not xmlFile:hasProperty(pk) then
                    break
                end
                local period = MPSleepForecast.PERIOD_NAMES[xmlFile:getString(pk .. "#name", "")]
                if period ~= nil then
                    rules[period] = {}
                    local j = 0
                    while true do
                        local uk = string.format("%s.update(%d)", pk, j)
                        if not xmlFile:hasProperty(uk) then
                            break
                        end
                        local s = fruitType.nameToGrowthState[xmlFile:getString(uk .. "#startState", "")]
                        local e = fruitType.nameToGrowthState[xmlFile:getString(uk .. "#endState", "")]
                        if s ~= nil and e ~= nil then
                            rules[period][s] = e
                        end
                        j = j + 1
                    end
                end
                i = i + 1
            end
            xmlFile:delete()
        end
    end
    cache[fruitType.index] = rules
    return rules or nil
end

function MPSleepForecast.isHarvestReady(fruitType, state)
    return fruitType.minHarvestingGrowthState ~= nil and fruitType.minHarvestingGrowthState > 0
        and state >= fruitType.minHarvestingGrowthState and state <= fruitType.maxHarvestingGrowthState
end

function MPSleepForecast.isWithered(fruitType, state)
    return fruitType.witheredState ~= nil and state == fruitType.witheredState
end

-- symulacja stanu wzrostu przez kolejne zmiany okresu; zwraca stan koncowy i
-- pierwszy miesiac w ktorym byl gotowy do zbioru / zgnil
function MPSleepForecast.simulateGrowth(fruitType, state, startPeriod, months)
    local rules = MPSleepForecast.getGrowthRules(fruitType)
    local readyAt, witheredAt = nil, nil
    if MPSleepForecast.isHarvestReady(fruitType, state) then
        readyAt = 0
    end
    if rules == nil then
        return state, readyAt, witheredAt, false
    end
    local period = startPeriod
    for m = 1, months do
        period = period % 12 + 1
        local r = rules[period]
        if r ~= nil and r[state] ~= nil then
            state = r[state]
        end
        if readyAt == nil and MPSleepForecast.isHarvestReady(fruitType, state) then
            readyAt = m
        end
        if witheredAt == nil and MPSleepForecast.isWithered(fruitType, state) then
            witheredAt = m
        end
    end
    return state, readyAt, witheredAt, true
end

local function pricePerLiter(fillTypeIndex)
    local em = g_currentMission.economyManager
    return (em ~= nil and fillTypeIndex ~= nil and em:getPricePerLiter(fillTypeIndex)) or 0
end

function MPSleepForecast.getFieldYieldValue(field, fruitType)
    local area = (field.areaHa or 0) * 10000
    local liters = area * (fruitType.literPerSqm or 0)
    local fillType = fruitType.fillType
    return liters * pricePerLiter(fillType ~= nil and fillType.index or nil)
end

function MPSleepForecast.getFieldOwner(field)
    if field.farmland ~= nil then
        return g_farmlandManager:getFarmlandOwner(field.farmland.id)
    end
    return field.fieldState ~= nil and field.fieldState.ownerFarmId or 0
end

function MPSleepForecast.forecastFields(r, farmId, months)
    if g_fieldManager == nil or g_fruitTypeManager == nil then
        return
    end
    local startPeriod = MPUtil.getCurrentPeriod()
    for _, field in ipairs(g_fieldManager:getFields() or {}) do
        local fs = field.fieldState
        if fs ~= nil and MPSleepForecast.getFieldOwner(field) == farmId and fs.fruitTypeIndex ~= nil and fs.fruitTypeIndex ~= FruitType.UNKNOWN then
            local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fs.fruitTypeIndex)
            if fruitType ~= nil and (fruitType.literPerSqm or 0) > 0 then
                local name = field.name or tostring(field.farmland ~= nil and field.farmland.id or "?")
                local cropName = fruitType.fillType ~= nil and fruitType.fillType.title or fruitType.name
                local endState, readyAt, witheredAt, known = MPSleepForecast.simulateGrowth(fruitType, fs.growthState or 0, startPeriod, months)
                local value = MPSleepForecast.getFieldYieldValue(field, fruitType)
                if witheredAt ~= nil and readyAt ~= nil and readyAt <= witheredAt then
                    r.losses.crops = r.losses.crops + value
                    table.insert(r.warnings, {sev = 3, text = MPUtil.getText("megaPatch_sleep_wFieldRot", name, cropName, tostring(math.max(1, witheredAt)), MPUtil.formatMoney(value))})
                elseif known and MPSleepForecast.isHarvestReady(fruitType, endState) then
                    r.income.harvest = r.income.harvest + value
                    table.insert(r.info, MPUtil.getText("megaPatch_sleep_iFieldReady", name, cropName, MPUtil.formatMoney(value)))
                end
                if (fs.weedState or 0) > 0 and witheredAt == nil then
                    table.insert(r.warnings, {sev = 1, text = MPUtil.getText("megaPatch_sleep_wWeeds", name)})
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- zwierzeta

function MPSleepForecast.getPlaceables()
    local ps = g_currentMission.placeableSystem
    return ps ~= nil and ps.placeables or {}
end

function MPSleepForecast.forecastAnimals(r, farmId, months)
    local hours = r.days * 24
    local timeAdj = (g_currentMission.environment ~= nil and g_currentMission.environment.timeAdjustment) or 1
    for _, p in ipairs(MPSleepForecast.getPlaceables()) do
        if p:getOwnerFarmId() == farmId and p.spec_husbandryAnimals ~= nil and p.getNumOfAnimals ~= nil and p:getNumOfAnimals() > 0 then
            local name = p.getName ~= nil and p:getName() or "?"
            local function check(level, perHour, key)
                if perHour ~= nil and perHour > 0 then
                    local h = level / (perHour * timeAdj)
                    if h < hours then
                        local daysLeft = h / 24
                        table.insert(r.warnings, {sev = 3, text = MPUtil.getText(key, name, MPSleepForecast.formatDuration(daysLeft))})
                        r.animalShortage = true
                    end
                end
            end
            local food = p.spec_husbandryFood
            if food ~= nil and p.getTotalFood ~= nil then
                check(p:getTotalFood(), food.litersPerHour, "megaPatch_sleep_wFood")
            end
            local water = p.spec_husbandryWater
            if water ~= nil and not water.automaticWaterSupply and water.fillType ~= nil then
                check(p:getHusbandryFillLevel(water.fillType), water.litersPerHour, "megaPatch_sleep_wWater")
            end
            local straw = p.spec_husbandryStraw
            if straw ~= nil and straw.inputFillType ~= nil then
                check(p:getHusbandryFillLevel(straw.inputFillType), straw.inputLitersPerHour, "megaPatch_sleep_wStraw")
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- fabryki

local function getCyclesPerMonth(production)
    if production.cyclesPerMonth ~= nil then
        return production.cyclesPerMonth
    elseif production.cyclesPerHour ~= nil then
        return production.cyclesPerHour * 24
    elseif production.cyclesPerMinute ~= nil then
        return production.cyclesPerMinute * 1440
    end
    return 0
end

local function getCostsPerMonth(production)
    if production.megaPatchOrigCosts ~= nil then
        return 0
    end
    if production.costsPerActiveMonth ~= nil then
        return production.costsPerActiveMonth
    elseif production.costsPerActiveHour ~= nil then
        return production.costsPerActiveHour * 24
    elseif production.costsPerActiveMinute ~= nil then
        return production.costsPerActiveMinute * 1440
    end
    return 0
end

function MPSleepForecast.forecastProductions(r, farmId, months)
    local pcm = g_currentMission.productionChainManager
    if pcm == nil then
        return
    end
    for _, pp in ipairs(pcm.productionPoints or {}) do
        if pp:getOwnerFarmId() == farmId and pp.storage ~= nil then
            local name = MPProductionRental.getName(pp)
            local active = pp.activeProductions or {}
            local share = (#active > 1 and pp.sharedThroughputCapacity ~= false) and (1 / #active) or 1
            local rental = pp.megaPatchRental
            for _, production in ipairs(active) do
                local cycles = getCyclesPerMonth(production) * share
                local runMonths = months
                -- surowce
                for _, input in ipairs(production.inputs or {}) do
                    local need = cycles * (input.amount or 0)
                    if need > 0 then
                        local have = pp.storage:getFillLevel(input.type) or 0
                        local m = have / need
                        if m < runMonths then
                            runMonths = m
                        end
                        if m < months then
                            local ft = g_fillTypeManager:getFillTypeByIndex(input.type)
                            table.insert(r.warnings, {sev = 2, text = MPUtil.getText("megaPatch_sleep_wInput", name, ft ~= nil and ft.title or "?", MPSleepForecast.formatMonths(m))})
                        end
                    end
                end
                -- produkty
                local value = 0
                for _, output in ipairs(production.outputs or {}) do
                    local perMonth = cycles * (output.amount or 0)
                    local outMonths = runMonths
                    local directSell = output.sellDirectly or (pp.outputFillTypeIdsDirectSell ~= nil and pp.outputFillTypeIdsDirectSell[output.type] ~= nil)
                    if not directSell and perMonth > 0 and pp.storage.getFreeCapacity ~= nil then
                        local free = pp.storage:getFreeCapacity(output.type) or 0
                        local m = free / perMonth
                        if m < runMonths then
                            outMonths = m
                            local ft = g_fillTypeManager:getFillTypeByIndex(output.type)
                            table.insert(r.warnings, {sev = 2, text = MPUtil.getText("megaPatch_sleep_wStorageFull", name, ft ~= nil and ft.title or "?", MPSleepForecast.formatMonths(m))})
                        end
                    end
                    local v = perMonth * outMonths * pricePerLiter(output.type)
                    value = value + v
                    if directSell then
                        r.income.directSell = r.income.directSell + v
                        r.monthly.income = r.monthly.income + v / math.max(months, 1)
                    else
                        r.income.stored = r.income.stored + v
                    end
                end
                if rental ~= nil then
                    local fee = value * (rental.rate or 0)
                    r.costs.rentals = r.costs.rentals + fee
                    r.monthly.cost = r.monthly.cost + fee / math.max(months, 1)
                else
                    local c = getCostsPerMonth(production) * months
                    r.costs.production = r.costs.production + c
                    r.monthly.cost = r.monthly.cost + c / math.max(months, 1)
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- pieniadze i maszyny

function MPSleepForecast.getPassiveDailyNet(farmId)
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.stats == nil then
        return 0
    end
    local history = farm.stats.financesHistory or {}
    local total, days = 0, 0
    for _, day in ipairs(history) do
        local sum = 0
        for _, stat in ipairs(MPSleepForecast.PASSIVE_STATS) do
            local v = day[stat]
            if type(v) == "number" then
                sum = sum + v
            end
        end
        total = total + sum
        days = days + 1
        if days >= 7 then
            break
        end
    end
    if days == 0 then
        return 0
    end
    return total / days
end

function MPSleepForecast.forecastMoneyAndVehicles(r, farmId, months)
    local days = r.days
    -- koszty stale z historii gry (utrzymanie budynkow, odsetki kredytu, woda, ...)
    local passive = MPSleepForecast.getPassiveDailyNet(farmId) * days
    if passive < 0 then
        r.costs.passive = -passive
    else
        r.income.passive = passive
    end
    r.monthly.cost = r.monthly.cost + math.max(0, -passive) / math.max(months, 1)
    r.monthly.income = r.monthly.income + math.max(0, passive) / math.max(months, 1)

    local perDayLeasing = EconomyManager.PER_DAY_LEASING_FACTOR or 0.01
    local vs = g_currentMission.vehicleSystem
    for _, vehicle in ipairs(vs ~= nil and vs.vehicles or {}) do
        if vehicle:getOwnerFarmId() == farmId and not vehicle.markedForDeletion then
            if vehicle.propertyState == VehiclePropertyState.LEASED then
                local c = (vehicle:getPrice() or 0) * perDayLeasing * days
                r.costs.leasing = r.costs.leasing + c
                r.monthly.cost = r.monthly.cost + c / math.max(months, 1)
            elseif vehicle.propertyState == VehiclePropertyState.OWNED then
                if vehicle.getDailyUpkeep ~= nil then
                    local c = (vehicle:getDailyUpkeep() or 0) * days
                    r.costs.upkeep = r.costs.upkeep + c
                    r.monthly.cost = r.monthly.cost + c / math.max(months, 1)
                end
                local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
                if storeItem ~= nil and Vehicle.calculateSellPrice ~= nil and vehicle.getSellPrice ~= nil and not vehicle.isPallet then
                    local now = vehicle:getSellPrice()
                    local later = Vehicle.calculateSellPrice(storeItem, (vehicle.age or 0) + months, vehicle.operatingTime or 0, vehicle:getPrice(), vehicle:getRepairPrice(), vehicle:getRepaintPrice())
                    if now ~= nil and later ~= nil and now > later then
                        r.losses.depreciation = r.losses.depreciation + (now - later)
                    end
                end
                if vehicle.getVehicleDamage ~= nil and (vehicle:getVehicleDamage() or 0) >= 0.5 then
                    r.damaged = r.damaged + 1
                end
            end
            if vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive() then
                r.aiActive = true
            end
        end
    end
    if r.damaged > 0 then
        table.insert(r.warnings, {sev = 1, text = MPUtil.getText("megaPatch_sleep_wDamaged", tostring(r.damaged))})
    end

    -- raty finansowania (MegaPatch)
    local finance = MegaPatch.finance
    if finance ~= nil then
        for _, c in pairs(finance.contracts) do
            if c.farmId == farmId then
                local n = math.min(months, finance:getRemainingMonths(c))
                local cost = c.installment * n + (c.arrears or 0)
                r.costs.finance = r.costs.finance + cost
                r.monthly.finance = r.monthly.finance + c.installment
                if (c.missed or 0) > 0 then
                    table.insert(r.warnings, {sev = 3, text = MPUtil.getText("megaPatch_sleep_wFinanceLate", c.name or "?")})
                    r.repossessRisk = true
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------

function MPSleepForecast.formatMonths(m)
    if m < 1 then
        return MPUtil.getText("megaPatch_sleep_lessThanMonth")
    end
    return string.format("%.1f", m)
end

function MPSleepForecast.formatDuration(days)
    return string.format("%.1f", days)
end

function MPSleepForecast.compute(farmId, months)
    local r = {
        months = months, days = months * MPUtil.getDaysPerPeriod(),
        money = MPUtil.getFarmMoney(farmId),
        warnings = {}, info = {},
        income = {harvest = 0, directSell = 0, stored = 0, passive = 0},
        costs = {passive = 0, leasing = 0, upkeep = 0, finance = 0, rentals = 0, production = 0},
        losses = {crops = 0, depreciation = 0},
        monthly = {income = 0, cost = 0, finance = 0},
        damaged = 0, aiActive = false, animalShortage = false, repossessRisk = false
    }

    MPSleepForecast.forecastFields(r, farmId, months)
    MPSleepForecast.forecastAnimals(r, farmId, months)
    MPSleepForecast.forecastProductions(r, farmId, months)
    MPSleepForecast.forecastMoneyAndVehicles(r, farmId, months)

    -- przeplyw gotowki miesiac po miesiacu: najnizsze saldo i ryzyko nieplaconych rat
    local balance = r.money
    local minBalance = balance
    local missed = 0
    for m = 1, months do
        balance = balance + r.monthly.income - r.monthly.cost
        if balance < r.monthly.finance then
            missed = missed + 1
        else
            balance = balance - r.monthly.finance
        end
        minBalance = math.min(minBalance, balance)
    end
    r.minBalance = minBalance
    if missed > 0 and r.monthly.finance > 0 then
        r.repossessRisk = r.repossessRisk or missed >= (MPVehicleFinance.REPOSSESS_AFTER or 3)
        table.insert(r.warnings, {sev = 3, text = MPUtil.getText("megaPatch_sleep_wFinanceMoney", tostring(missed))})
    end
    if minBalance < 0 then
        table.insert(r.warnings, {sev = 3, text = MPUtil.getText("megaPatch_sleep_wNegative", MPUtil.formatMoney(minBalance))})
    end

    local cashCosts = r.costs.passive + r.costs.leasing + r.costs.upkeep + r.costs.finance + r.costs.rentals + r.costs.production
    r.expectedGain = r.income.harvest + r.income.directSell + r.income.stored + r.income.passive
    r.expectedLoss = cashCosts + r.losses.crops + r.losses.depreciation
    r.net = r.expectedGain - r.expectedLoss

    -- "realna" strata = rzeczy, ktorych nie da sie odzyskac (zgnile plony, kary, utrata pojazdu, ujemne saldo)
    local hardLoss = r.losses.crops + math.max(0, -minBalance)
    local threshold = math.max(MPSleepForecast.LOSS_ABS_THRESHOLD, math.abs(r.money) * MPSleepForecast.LOSS_REL_THRESHOLD)
    r.recommended = not (r.repossessRisk or r.animalShortage or hardLoss > threshold or r.net < -threshold)

    table.sort(r.warnings, function(a, b) return a.sev > b.sev end)
    return r
end

function MPSleepForecast.buildText(r)
    local L = {}
    local function add(s) table.insert(L, s) end
    if r.recommended then
        add(MPUtil.getText("megaPatch_sleep_recommended"))
    else
        add(MPUtil.getText("megaPatch_sleep_notRecommended"))
    end
    add(MPUtil.getText("megaPatch_sleep_gain", MPUtil.formatMoney(r.expectedGain)) .. "   " .. MPUtil.getText("megaPatch_sleep_loss", MPUtil.formatMoney(r.expectedLoss)) .. "   " .. MPUtil.getText("megaPatch_sleep_net", MPUtil.formatMoney(r.net)))
    add(MPUtil.getText("megaPatch_sleep_gainParts", MPUtil.formatMoney(r.income.harvest), MPUtil.formatMoney(r.income.directSell + r.income.passive), MPUtil.formatMoney(r.income.stored)))
    add(MPUtil.getText("megaPatch_sleep_costParts", MPUtil.formatMoney(r.costs.passive + r.costs.upkeep + r.costs.production), MPUtil.formatMoney(r.costs.leasing), MPUtil.formatMoney(r.costs.finance), MPUtil.formatMoney(r.costs.rentals)))
    add(MPUtil.getText("megaPatch_sleep_lossParts", MPUtil.formatMoney(r.losses.crops), MPUtil.formatMoney(r.losses.depreciation)))
    add(MPUtil.getText("megaPatch_sleep_balance", MPUtil.formatMoney(r.money), MPUtil.formatMoney(r.minBalance)))
    add("")
    local maxLines = 10
    local shown = 0
    for _, w in ipairs(r.warnings) do
        if shown >= maxLines then
            add(MPUtil.getText("megaPatch_sleep_more", tostring(#r.warnings - shown)))
            break
        end
        local prefix = w.sev >= 3 and "[!!] " or (w.sev == 2 and "[!] " or "[i] ")
        add(prefix .. w.text)
        shown = shown + 1
    end
    for _, i in ipairs(r.info) do
        if shown >= maxLines then
            break
        end
        add("[+] " .. i)
        shown = shown + 1
    end
    if #r.warnings == 0 and #r.info == 0 then
        add(MPUtil.getText("megaPatch_sleep_nothing"))
    end
    if r.aiActive then
        add("")
        add(MPUtil.getText("megaPatch_sleep_aiActive"))
    end
    return table.concat(L, "\n")
end
