-- FS25_MegaPatch: dlugi sen (1-12 miesiecy)
--
-- W lozku (dom na farmie) pojawia sie wybor: zwykly sen do rana albo "Dlugi sen".
-- Przed snem pokazywana jest prognoza (MPSleepForecast) z rekomendacja.
-- Sen dziala przez mocne przyspieszenie czasu gry - cala symulacja (wzrost upraw, zwierzeta, fabryki,
-- koszty, raty) liczy sie normalnie, tylko szybko. Mozna sie obudzic w kazdej chwili.
-- Multiplayer: kazdy gracz farmy moze zaczac sen (czas gry jest wspolny, wiec spia wszyscy);
-- serwer prowadzi sen, wszyscy widza postep i kazdy moze obudzic wszystkich.

MPLongSleep = {}
local MPLongSleep_mt = Class(MPLongSleep)

MPLongSleep.MODULE = "sleep"
MPLongSleep.MAX_MONTHS = 12
MPLongSleep.WAKE_HOUR = 6
MPLongSleep.TARGET_REAL_SECONDS = 240      -- ile realnie ma trwac sen (orientacyjnie)
MPLongSleep.MIN_TIME_SCALE = 600
MPLongSleep.MAX_TIME_SCALE = 3000          -- <1 min gry na klatke przy 60 FPS: zdarzenia godzinowe sie nie gubia

function MPLongSleep.new(megaPatch)
    local self = setmetatable({}, MPLongSleep_mt)
    self.megaPatch = megaPatch
    self.active = false
    self.refreshTimer = 0
    return self
end

function MPLongSleep:loadMap()
    MPLongSleep.instance = self
    MPLongSleep.hookSleepManager()
end

function MPLongSleep:onStartMission()
    MPLongSleep.hookSleepManager()
end

function MPLongSleep:delete()
    if self.active then
        self:restoreTimeScale()
    end
    MPLongSleep.instance = nil
end

function MPLongSleep.canStartHere()
    local farmId = MPUtil.getLocalFarmId()
    return farmId ~= nil and farmId ~= FarmManager.SPECTATOR_FARM_ID
end

function MPLongSleep.getHour()
    local env = g_currentMission.environment
    return math.floor((env.dayTime or 0) / (60 * 60 * 1000))
end

function MPLongSleep.getAbsHours()
    local env = g_currentMission.environment
    return (env.currentMonotonicDay or 0) * 24 + (env.dayTime or 0) / (60 * 60 * 1000)
end

function MPLongSleep:getTimeScale()
    return g_currentMission.missionInfo.timeScale or 1
end

function MPLongSleep:setTimeScale(scale)
    if g_currentMission.setTimeScale ~= nil then
        g_currentMission:setTimeScale(scale)
    else
        g_currentMission.missionInfo.timeScale = scale
    end
end

function MPLongSleep:isAIActive(farmId)
    local vs = g_currentMission.vehicleSystem
    for _, vehicle in ipairs(vs ~= nil and vs.vehicles or {}) do
        if vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive() then
            return true
        end
    end
    return false
end

-- gracz (takze host): prosba o dlugi sen
function MPLongSleep:start(months)
    if self.active or self.view ~= nil or not MPLongSleep.canStartHere() then
        return false
    end
    MPRequestEvent.sendRequest(MPLongSleep.MODULE, "start", {months = months})
    return true
end

function MPLongSleep:stop(early)
    MPRequestEvent.sendRequest(MPLongSleep.MODULE, "stop", {early = early == true})
end

function MPLongSleep:onRequest(action, data, farmId, connection)
    if not g_currentMission:getIsServer() then
        return
    end
    if action == "start" then
        self:serverStart(tonumber(data.months) or 1, farmId, connection)
    elseif action == "stop" then
        self:serverStop(data.early == true)
    end
end

-- serwer
function MPLongSleep:serverStart(months, farmId, connection)
    if self.active or farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false
    end
    if g_sleepManager ~= nil and g_sleepManager.isSleeping then
        return false
    end
    if self:isAIActive() then
        MPUtil.notifyConnection(connection, farmId, 2, "megaPatch_sleep_aiActive")
        return false
    end
    months = MPUtil.clamp(math.floor(months), 1, MPLongSleep.MAX_MONTHS)
    local env = g_currentMission.environment
    local targetDay = (env.currentMonotonicDay or 0) + months * MPUtil.getDaysPerPeriod()
    self.startHours = MPLongSleep.getAbsHours()
    self.targetHours = targetDay * 24 + MPLongSleep.WAKE_HOUR
    self.months = months
    self.farmId = farmId
    self.prevTimeScale = self:getTimeScale()
    local totalHours = self.targetHours - self.startHours
    local scale = MPUtil.clamp(totalHours * 3600 / MPLongSleep.TARGET_REAL_SECONDS, MPLongSleep.MIN_TIME_SCALE, MPLongSleep.MAX_TIME_SCALE)
    self.active = true
    self:setTimeScale(scale)
    -- jesli gra nie pozwala na te predkosc, ustawiamy ja wprost
    if (g_currentMission.missionInfo.timeScale or 0) < scale then
        g_currentMission.missionInfo.timeScale = scale
    end
    print(string.format("[MegaPatch] Dlugi sen: %d mies., predkosc czasu x%d", months, math.floor(scale)))
    self:syncState()
    return true
end

function MPLongSleep:serverStop(early)
    if not self.active then
        return
    end
    self.active = false
    self:restoreTimeScale()
    self.lastEarly = early
    self:syncState()
end

---------------------------------------------------------------------------------------------------
-- stan snu dla wszystkich graczy (okno postepu / nakladka)

function MPLongSleep:getState()
    return {active = self.active, months = self.months or 0, startHours = self.startHours or 0,
            targetHours = self.targetHours or 0, early = self.lastEarly == true}
end

function MPLongSleep:syncState()
    local state = self:getState()
    self:applyView(state)
    MPStateSyncEvent.broadcast(MPLongSleep.MODULE, state)
end

function MPLongSleep:applyState(state)
    if g_currentMission:getIsServer() then
        return
    end
    self:applyView(state)
end

function MPLongSleep:sendInitialClientState(connection)
    if self.active then
        connection:sendEvent(MPStateSyncEvent.new(MPLongSleep.MODULE, self:getState()))
    end
end

function MPLongSleep:applyView(state)
    if not g_currentMission:getIsClient() then
        return
    end
    if state.active and self.view == nil then
        local farmId = MPUtil.getLocalFarmId()
        self.view = {months = state.months, startHours = state.startHours, targetHours = state.targetHours,
                     farmId = farmId, startMoney = MPUtil.getFarmMoney(farmId)}
        self.mode = "dialog"
        self.checkTime = g_time + 2500
        self.checkHours = MPLongSleep.getAbsHours()
        self:showProgressDialog()
    elseif not state.active and self.view ~= nil then
        self:closeView(state.early)
    end
end

function MPLongSleep:closeView(early)
    local view = self.view
    self.view = nil
    self.mode = nil
    if MPFinanceDialog.INSTANCE ~= nil and MPFinanceDialog.INSTANCE.config == self.dialogConfig and MPFinanceDialog.INSTANCE.mpIsOpen then
        MPFinanceDialog.INSTANCE:close()
    end
    local diff = MPUtil.getFarmMoney(view.farmId) - (view.startMoney or 0)
    local key = early and "megaPatch_sleep_wokeEarly" or "megaPatch_sleep_woke"
    local slept = (MPLongSleep.getAbsHours() - view.startHours) / 24
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
        MPUtil.getText(key, string.format("%.0f", slept), MPUtil.formatMoney(diff)))
end

function MPLongSleep:draw()
    if self.view == nil or self.mode ~= "overlay" then
        return
    end
    if self.overlay == nil and Overlay ~= nil then
        self.overlay = Overlay.new(MegaPatch.MOD_DIR .. "images/white.dds", 0, 0, 1, 1)
        self.overlay:setColor(0, 0, 0, 0.7)
    end
    if self.overlay ~= nil then
        self.overlay:render()
    end
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    renderText(0.5, 0.62, 0.03, MPUtil.getText("megaPatch_sleep_sleepingTitle", tostring(self.view.months)))
    setTextBold(false)
    local y = 0.56
    for line in string.gmatch(self:getProgressText() .. "\n\n" .. MPUtil.getText("megaPatch_sleep_wakeHint"), "[^\n]+") do
        renderText(0.5, y, 0.018, line)
        y = y - 0.03
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
end

function MPLongSleep:restoreTimeScale()
    if self.prevTimeScale ~= nil then
        self:setTimeScale(self.prevTimeScale)
    end
end

function MPLongSleep:getProgressText()
    local v = self.view
    if v == nil then
        return ""
    end
    local now = MPLongSleep.getAbsHours()
    local total = math.max(1, v.targetHours - v.startHours)
    local done = MPUtil.clamp((now - v.startHours) / total, 0, 1)
    local daysLeft = math.max(0, (v.targetHours - now) / 24)
    local diff = MPUtil.getFarmMoney(v.farmId) - (v.startMoney or 0)
    return table.concat({
        MPUtil.getText("megaPatch_sleep_progress1", string.format("%d", done * 100)),
        MPUtil.getText("megaPatch_sleep_progress2", string.format("%.1f", daysLeft)),
        MPUtil.getText("megaPatch_sleep_progress3", MPUtil.formatMoney(MPUtil.getFarmMoney(v.farmId)), MPUtil.formatMoney(diff)),
        "",
        MPUtil.getText("megaPatch_sleep_progress4")
    }, "\n")
end

function MPLongSleep:showProgressDialog()
    local sleep = self
    self.dialogConfig = {
        layout = "wide",
        title = MPUtil.getText("megaPatch_sleep_sleepingTitle", tostring(self.view ~= nil and self.view.months or 0)),
        getText = function() return sleep:getProgressText() end,
        okText = MPUtil.getText("megaPatch_sleep_wakeUp"),
        onOk = function() sleep:stop(true) end,
        onBack = function() sleep:stop(true) end
    }
    MPFinanceDialog.show(self.dialogConfig)
end

function MPLongSleep:update(dt)
    if self.active and g_currentMission:getIsServer() and MPLongSleep.getAbsHours() >= self.targetHours then
        self:serverStop(false)
        return
    end
    if self.view == nil then
        return
    end
    -- gra pauzuje czas przy otwartym oknie? -> okno znika, postep na ekranie gry
    if self.mode == "dialog" and self.checkTime ~= nil and g_time > self.checkTime then
        self.checkTime = nil
        if MPLongSleep.getAbsHours() - (self.checkHours or 0) < 0.02 then
            print("[MegaPatch] Dlugi sen: czas stoi przy otwartym oknie - tryb nakladki")
            self.mode = "overlay"
            local dialog = MPFinanceDialog.INSTANCE
            if dialog ~= nil and dialog.mpIsOpen then
                dialog:close()
            end
        end
    end
    if self.mode ~= "dialog" then
        return
    end
    self.refreshTimer = self.refreshTimer + dt
    if self.refreshTimer > 250 then
        self.refreshTimer = 0
        local dialog = MPFinanceDialog.INSTANCE
        if dialog ~= nil and dialog.config == self.dialogConfig then
            if dialog.mpIsOpen then
                dialog:refresh()
            else
                -- dialog zamkniety w inny sposob -> pokaz ponownie (sen trwa)
                MPFinanceDialog.show(self.dialogConfig)
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- planowanie snu (prognoza)

function MPLongSleep:showPlanner()
    local state = {months = 3}
    local cache = {}
    local function forecast()
        if cache[state.months] == nil then
            cache[state.months] = MPSleepForecast.compute(MPUtil.getLocalFarmId(), state.months)
        end
        return cache[state.months]
    end
    local monthTexts = {}
    for i = 1, MPLongSleep.MAX_MONTHS do
        monthTexts[i] = MPUtil.getText("megaPatch_ui_months", tostring(i))
    end
    local sleep = self
    MPFinanceDialog.show({
        layout = "wide",
        title = MPUtil.getText("megaPatch_sleep_plannerTitle"),
        sliders = {
            {label = function() return MPUtil.getText("megaPatch_ui_sleepLabel") end, texts = monthTexts, state = state.months,
             onChange = function(i) state.months = i end}
        },
        getText = function()
            local text = MPSleepForecast.buildText(forecast())
            if not MPLongSleep.canStartHere() then
                text = MPUtil.getText("megaPatch_sleep_hostOnly") .. "\n" .. text
            end
            return text
        end,
        getOkText = function() return MPUtil.getText("megaPatch_sleep_start", tostring(state.months)) end,
        canOk = function() return MPLongSleep.canStartHere() end,
        onOk = function() sleep:start(state.months) end,
        optionA = {
            fallbackOnly = true,
            getLabel = function() return MPUtil.getText("megaPatch_sleep_months", tostring(state.months)) end,
            onClick = function() state.months = state.months % MPLongSleep.MAX_MONTHS + 1 end
        },
        optionB = {
            fallbackOnly = true,
            getLabel = function() return MPUtil.getText("megaPatch_sleep_monthsBack") end,
            onClick = function() state.months = (state.months - 2) % MPLongSleep.MAX_MONTHS + 1 end
        }
    })
end

-- podmiana g_sleepManager.showDialog (instancja tworzona przez gre, wiec hak przy pierwszej okazji)
function MPLongSleep.hookSleepManager()
    local sm = g_sleepManager
    if sm == nil or sm.megaPatchHooked or sm.showDialog == nil then
        return
    end
    sm.megaPatchHooked = true
    local original = sm.showDialog
    MPLongSleep.originalShowDialog = original
    sm.showDialog = function(manager, ...)
        local inst = MPLongSleep.instance
        local args = {...}
        local function runOriginal()
            return original(manager, unpack(args))
        end
        if inst ~= nil and (inst.active or inst.view ~= nil) then
            -- lozko w trakcie dlugiego snu = pobudka
            inst:stop(true)
            return
        end
        if inst == nil then
            return runOriginal()
        end
        local ok, err = pcall(inst.showBedChoice, inst, runOriginal)
        local visible = MPFinanceDialog.INSTANCE ~= nil and MPFinanceDialog.INSTANCE.mpIsOpen
        if not ok or not visible then
            print("[MegaPatch] Sen: okno wyboru nie otworzylo sie (" .. tostring(err) .. ") - zwykly sen")
            return runOriginal()
        end
        print("[MegaPatch] Sen: pokazano wybor snu")
    end
end

function MPLongSleep:showBedChoice(originalRun)
    local sleep = self
    MPFinanceDialog.show({
        layout = "wide",
        title = MPUtil.getText("megaPatch_sleep_bedTitle"),
        getText = function() return MPUtil.getText("megaPatch_sleep_bedText") end,
        okText = MPUtil.getText("megaPatch_sleep_normal"),
        onOk = originalRun,
        optionA = {
            closeOnClick = true,
            getLabel = function() return MPUtil.getText("megaPatch_sleep_long") end,
            onClick = function() sleep:showPlanner() end
        }
    })
end

function MPLongSleep:consoleLongSleep(months)
    local m = tonumber(months)
    if m == nil then
        local r = MPSleepForecast.compute(MPUtil.getLocalFarmId(), 3)
        return MPSleepForecast.buildText(r)
    end
    if self:start(m) then
        return "Dlugi sen: " .. tostring(m) .. " mies. (prosba wyslana)"
    end
    return "Nie mozna rozpoczac snu (sen juz trwa albo jestes obserwatorem)"
end

---------------------------------------------------------------------------------------------------
-- hooks

function MPLongSleep.installHooks()
    -- przechwycenie otwierania snu (dzialaja wszystkie lozka, rowniez z modow)
    MPLongSleep.hookSleepManager()
    if FarmhouseActivatable ~= nil and FarmhouseActivatable.run ~= nil then
        FarmhouseActivatable.run = Utils.overwrittenFunction(FarmhouseActivatable.run, function(activatable, superFunc, ...)
            print("[MegaPatch] Sen: aktywowano lozko")
            MPLongSleep.hookSleepManager()
            return superFunc(activatable, ...)
        end)
    end

    -- zapis w trakcie snu: do pliku idzie normalna predkosc czasu
    FSCareerMissionInfo.saveToXMLFile = Utils.overwrittenFunction(FSCareerMissionInfo.saveToXMLFile, function(missionInfo, superFunc, ...)
        local inst = MPLongSleep.instance
        if inst ~= nil and inst.active and inst.prevTimeScale ~= nil then
            local current = missionInfo.timeScale
            missionInfo.timeScale = inst.prevTimeScale
            local result = superFunc(missionInfo, ...)
            missionInfo.timeScale = current
            return result
        end
        return superFunc(missionInfo, ...)
    end)
end
