-- FS25_MegaPatch: narzedzia budowy
--  * darmowe malowanie terenu i terraforming (koszt Landscaping = 0) - zastepuje osobny mod
--  * Cofnij / Ponow (Ctrl+Z / Ctrl+Y w trybie budowy) dla postawionych i sprzedanych obiektow,
--    ze 100% zwrotem pieniedzy; obiekt wraca dokladnie taki sam (konfiguracja, zawartosc magazynu itd.)
--  * diagnostyka API budowy (mpDiag / mpTrace) - do rozbudowy o cofanie terenu i malowanie po linii

MPConstructionTools = {}
local MPConstructionTools_mt = Class(MPConstructionTools)

MPConstructionTools.MODULE = "construction"
MPConstructionTools.MAX_STEPS = 50
MPConstructionTools.FREE_LANDSCAPING = true
MPConstructionTools.OPEN_TIMEOUT = 30000   -- ms: "tryb budowy otwarty" wygasa, jesli klient przestanie go odswiezac
MPConstructionTools.OPEN_REFRESH = 10000   -- ms: co ile klient potwierdza otwarty tryb budowy

-- Cofanie dziala na serwerze, osobno dla kazdej farmy (wspolne dla wszystkich jej czlonkow):
--  * klient zglasza serwerowi, ze ma otwarty tryb budowy
--  * serwer zapisuje postawienie/sprzedaz obiektow farmy, ktorej ktos ma otwarta budowe
--  * Ctrl+Z / Ctrl+Y wysyla zadanie do serwera; serwer usuwa/przywraca obiekt i oddaje/pobiera pieniadze
local FarmHistory = {}
local FarmHistory_mt = {__index = FarmHistory}

function MPConstructionTools.new(megaPatch)
    local self = setmetatable({}, MPConstructionTools_mt)
    self.megaPatch = megaPatch
    self.farms = {}          -- serwer: [farmId] = FarmHistory
    self.ignoreAdd = {}      -- serwer: [uniqueId] = true - obiekty przywracane przez cofnij/ponow
    self.openBy = {}         -- serwer: [polaczenie] = {farmId, time}
    self.localOpen = false   -- klient: czy wyslalismy "budowa otwarta"
    self.openRefresh = 0
    self.constructionOpen = false
    return self
end

function MPConstructionTools:loadMap()
    MPConstructionTools.instance = self
end

function MPConstructionTools:delete()
    for _, h in pairs(self.farms) do
        for _, a in ipairs(h.history) do
            MPConstructionTools.deleteSnapshot(a)
        end
    end
    self.farms = {}
    MPConstructionTools.instance = nil
end

function MPConstructionTools:getFarm(farmId)
    local h = self.farms[farmId]
    if h == nil then
        h = setmetatable({farmId = farmId, history = {}, index = 0, busy = false, module = self}, FarmHistory_mt)
        self.farms[farmId] = h
    end
    return h
end

---------------------------------------------------------------------------------------------------
-- migawki obiektow (ten sam mechanizm co przeladowanie obiektow w grze) - serwer

function MPConstructionTools.snapshot(placeable)
    local ps = g_currentMission.placeableSystem
    if ps == nil or ps.savePlaceableToXML == nil then
        return nil
    end
    local xmlFile = XMLFile.create("mpUndoSnapshot", "", "placeables", Placeable.xmlSchemaSavegame)
    if xmlFile == nil then
        return nil
    end
    local index = 1
    for i, p in ipairs(ps.placeables) do
        if p == placeable then
            index = i
            break
        end
    end
    local ok, err = pcall(ps.savePlaceableToXML, ps, placeable, xmlFile, 0, index, {})
    if not ok then
        Logging.warning("[MegaPatch] Undo snapshot failed: %s", tostring(err))
        xmlFile:delete()
        return nil
    end
    return xmlFile
end

function MPConstructionTools.deleteSnapshot(action)
    if action.xmlFile ~= nil then
        action.xmlFile:delete()
        action.xmlFile = nil
    end
end

function MPConstructionTools:findPlaceable(uniqueId)
    local ps = g_currentMission.placeableSystem
    if ps == nil or uniqueId == nil then
        return nil
    end
    return ps.placableByUniqueId ~= nil and ps.placableByUniqueId[uniqueId] or nil
end

---------------------------------------------------------------------------------------------------
-- kto ma otwarty tryb budowy (serwer)

function MPConstructionTools:isFarmBuilding(farmId)
    for key, entry in pairs(self.openBy) do
        if g_time - entry.time > MPConstructionTools.OPEN_TIMEOUT then
            self.openBy[key] = nil
        elseif entry.farmId == farmId then
            return true
        end
    end
    return false
end

function MPConstructionTools.isConstructionOpen()
    if g_gui == nil then
        return false
    end
    if g_gui.currentGuiName == "ConstructionScreen" then
        return true
    end
    local screen = g_gui.screenControllers ~= nil and ConstructionScreen ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
    if screen == nil then
        return false
    end
    local current = g_gui.currentGui
    if current ~= nil and (current == screen or current.target == screen) then
        return true
    end
    return screen.isOpen == true
end

---------------------------------------------------------------------------------------------------
-- rejestrowanie akcji (serwer)

function MPConstructionTools:isTracked(placeable)
    if not g_currentMission:getIsServer() then
        return false
    end
    if placeable == nil or placeable.isPreplaced or placeable.isReloading or placeable.megaPatchSkipUndo then
        return false
    end
    if PlaceablePropertyState ~= nil and placeable.propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW then
        return false
    end
    local uid = placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
    if uid == nil then
        return false
    end
    local farmId = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
    if farmId == nil or farmId == 0 or not self:isFarmBuilding(farmId) then
        return false
    end
    return not self:getFarm(farmId).busy, farmId
end

function MPConstructionTools:onPlaceableAdded(placeable)
    local uid = placeable ~= nil and placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
    if uid ~= nil and self.ignoreAdd[uid] then
        self.ignoreAdd[uid] = nil
        return
    end
    local tracked, farmId = self:isTracked(placeable)
    if not tracked then
        return
    end
    local h = self:getFarm(farmId)
    local action = {
        kind = "place", uniqueId = uid, name = placeable.getName ~= nil and placeable:getName() or "?",
        amount = placeable:getPrice() or 0, moneyBefore = h.lastMoney, time = g_time
    }
    h:pushAction(action)
    h.pendingMoney = action
end

function MPConstructionTools:onPlaceableRemoving(placeable)
    local tracked, farmId = self:isTracked(placeable)
    if not tracked then
        return
    end
    local xmlFile = MPConstructionTools.snapshot(placeable)
    if xmlFile == nil then
        return
    end
    local action = {
        kind = "remove", uniqueId = placeable:getUniqueId(), name = placeable.getName ~= nil and placeable:getName() or "?",
        amount = (placeable.getSellPrice ~= nil and placeable:getSellPrice()) or 0, xmlFile = xmlFile
    }
    self:getFarm(farmId):pushAction(action)
end

function MPConstructionTools:update(dt)
    -- klient (takze host): zglaszamy serwerowi otwarty tryb budowy
    if g_currentMission:getIsClient() then
        local open = MPConstructionTools.isConstructionOpen()
        self.openRefresh = self.openRefresh - dt
        if open ~= self.localOpen or (open and self.openRefresh <= 0) then
            self.localOpen = open
            self.openRefresh = MPConstructionTools.OPEN_REFRESH
            MPRequestEvent.sendRequest(MPConstructionTools.MODULE, "mode", {open = open})
        end
    end
    -- serwer: dokladna kwota zakupu (cena + koszt wyrownania terenu) mierzona po zmianie salda farmy
    if g_currentMission:getIsServer() then
        for farmId, h in pairs(self.farms) do
            local money = MPUtil.getFarmMoney(farmId)
            local p = h.pendingMoney
            if p ~= nil and g_time - p.time > 1500 then
                if p.moneyBefore ~= nil then
                    local spent = p.moneyBefore - money
                    if spent > p.amount and spent < p.amount * 3 + 10000 then
                        p.amount = spent
                    end
                end
                h.pendingMoney = nil
            end
            if h.pendingMoney == nil then
                h.lastMoney = money
            end
        end
    end
end

function MPConstructionTools:onRequest(action, data, farmId, connection)
    if not g_currentMission:getIsServer() or farmId == nil or farmId == 0 then
        return
    end
    local key = connection or "local"
    if action == "mode" then
        if data.open then
            self.openBy[key] = {farmId = farmId, time = g_time}
            local h = self:getFarm(farmId)
            if h.pendingMoney == nil then
                h.lastMoney = MPUtil.getFarmMoney(farmId)
            end
        else
            self.openBy[key] = nil
        end
    elseif action == "undo" or action == "redo" then
        local h = self:getFarm(farmId)
        h.replyTo = connection
        if action == "undo" then
            h:undo()
        else
            h:redo()
        end
        h.replyTo = nil
    end
end

---------------------------------------------------------------------------------------------------
-- historia jednej farmy (serwer)

function FarmHistory:pushAction(action)
    -- nowa akcja usuwa "przyszlosc" (ponow)
    for i = #self.history, self.index + 1, -1 do
        MPConstructionTools.deleteSnapshot(self.history[i])
        table.remove(self.history, i)
    end
    table.insert(self.history, action)
    if #self.history > MPConstructionTools.MAX_STEPS then
        MPConstructionTools.deleteSnapshot(self.history[1])
        table.remove(self.history, 1)
    end
    self.index = #self.history
end

function FarmHistory:isBusy()
    if self.busy and self.busySince ~= nil and g_time - self.busySince > 5000 then
        Logging.warning("[MegaPatch] Cofnij: przywracanie obiektu nie zakonczylo sie - odblokowano")
        self.busy = false
    end
    return self.busy
end

-- obiekt usuniety przez cofanie, ktorego gra jeszcze fizycznie nie skasowala
function FarmHistory:isPendingDelete(uniqueId)
    local p = self.module:findPlaceable(uniqueId)
    return p ~= nil and p.megaPatchSkipUndo == true
end

function FarmHistory:restoreSnapshot(action, callback)
    local xmlFile = action.xmlFile
    if xmlFile == nil then
        return false
    end
    local key = "placeables.placeable(0)"
    local filename = xmlFile:getValue(key .. "#filename")
    if filename == nil then
        return false
    end
    if string.startsWith(filename, "$data") then
        filename = Utils.getFilename(filename)
    end
    filename = NetworkUtil.convertFromNetworkFilename(filename)
    local storeItem = g_storeManager:getItemByXMLFilename(filename)
    if storeItem == nil then
        return false
    end
    local uid = xmlFile:getValue(key .. "#uniqueId")
    if uid ~= nil then
        self.module.ignoreAdd[uid] = true
    end
    local data = PlaceableLoadingData.new()
    data:setStoreItem(storeItem)
    data:setSavegameData({xmlFile = xmlFile, key = key, ignoreFarmId = false})
    self.busy = true
    self.busySince = g_time
    data:load(function(target, placeable, loadingState)
        target.busy = false
        if callback ~= nil then
            callback(placeable, loadingState)
        end
    end, self, nil)
    return true
end

-- usuniecie obiektu przez cofnij/ponow (bez zapisu w historii)
function FarmHistory:removeTracked(action)
    local placeable = self.module:findPlaceable(action.uniqueId)
    if placeable == nil or placeable.megaPatchSkipUndo then
        return false
    end
    MPConstructionTools.deleteSnapshot(action)
    action.xmlFile = MPConstructionTools.snapshot(placeable)
    placeable.megaPatchSkipUndo = true
    placeable:delete()
    return true
end

function FarmHistory:undo()
    if self:isBusy() then
        return
    end
    local action = self.history[self.index]
    if action == nil then
        self:notify("megaPatch_undo_nothing")
        return
    end
    if self.pendingMoney == action then
        self.pendingMoney = nil
    end
    if action.kind == "place" then
        if not self:removeTracked(action) then
            self:notify("megaPatch_undo_failed", action.name)
            return
        end
        MPUtil.addMoney(action.amount, self.farmId, "SHOP_PROPERTY_SELL")
        self.index = self.index - 1
        self:notify("megaPatch_undo_placeUndone", action.name, action.amount)
    elseif action.kind == "remove" then
        if self:isPendingDelete(action.uniqueId) or self.module:findPlaceable(action.uniqueId) ~= nil then
            return
        end
        local ok = self:restoreSnapshot(action, function(placeable, state)
            if placeable ~= nil then
                action.uniqueId = placeable:getUniqueId()
            end
        end)
        if not ok then
            self:notify("megaPatch_undo_failed", action.name)
            return
        end
        MPUtil.addMoney(-action.amount, self.farmId, "SHOP_PROPERTY_BUY")
        self.index = self.index - 1
        self:notify("megaPatch_undo_removeUndone", action.name, action.amount)
    end
end

function FarmHistory:redo()
    if self:isBusy() then
        return
    end
    local action = self.history[self.index + 1]
    if action == nil then
        self:notify("megaPatch_redo_nothing")
        return
    end
    if action.kind == "place" then
        if MPUtil.getFarmMoney(self.farmId) < action.amount then
            self:notify("megaPatch_finance_notEnoughMoney", action.amount)
            return
        end
        if self:isPendingDelete(action.uniqueId) or self.module:findPlaceable(action.uniqueId) ~= nil then
            return
        end
        local ok = self:restoreSnapshot(action, function(placeable, state)
            if placeable ~= nil then
                action.uniqueId = placeable:getUniqueId()
            end
        end)
        if not ok then
            self:notify("megaPatch_undo_failed", action.name)
            return
        end
        MPUtil.addMoney(-action.amount, self.farmId, "SHOP_PROPERTY_BUY")
        self.index = self.index + 1
        self:notify("megaPatch_redo_place", action.name, action.amount)
    elseif action.kind == "remove" then
        if not self:removeTracked(action) then
            self:notify("megaPatch_undo_failed", action.name)
            return
        end
        MPUtil.addMoney(action.amount, self.farmId, "SHOP_PROPERTY_SELL")
        self.index = self.index + 1
        self:notify("megaPatch_redo_remove", action.name, action.amount)
    end
end

-- komunikat dla gracza, ktory nacisnal Ctrl+Z/Ctrl+Y; w trybie budowy jako migajacy napis (typ 4)
function FarmHistory:notify(key, ...)
    MPUtil.notifyConnection(self.replyTo, self.farmId, 4, key, ...)
end

---------------------------------------------------------------------------------------------------
-- klawisze (klient): zadanie do serwera

function MPConstructionTools.onUndoAction()
    if MPConstructionTools.instance ~= nil then
        MPRequestEvent.sendRequest(MPConstructionTools.MODULE, "undo", {})
    end
end

function MPConstructionTools.onRedoAction()
    if MPConstructionTools.instance ~= nil then
        MPRequestEvent.sendRequest(MPConstructionTools.MODULE, "redo", {})
    end
end

---------------------------------------------------------------------------------------------------
-- diagnostyka API (do log.txt)
MPConstructionTools.DIAG_CLASSES = {
    "ConstructionScreen", "GuiTopDownCursor", "ConstructionBrush", "ConstructionBrushSculpt", "ConstructionBrushPaint",
    "ConstructionBrushPlaceable", "ConstructionBrushDestruct", "Landscaping", "LandscapingSculptEvent", "LandscapingEvent",
    "SleepManager", "SleepDialog", "GroundTypeManager", "TerrainDeformation", "ShopConfigScreen"
}

local function listKeys(t, onlyFunctions)
    local keys = {}
    if type(t) ~= "table" then
        return keys
    end
    for k, v in pairs(t) do
        if (type(v) == "function") == onlyFunctions then
            table.insert(keys, tostring(k) .. (onlyFunctions and "" or ("=" .. tostring(v))))
        end
    end
    table.sort(keys)
    return keys
end

function MPConstructionTools:consoleDiag()
    print("[MegaPatch] ===== DIAG START =====")
    for _, name in ipairs(MPConstructionTools.DIAG_CLASSES) do
        local cls = _G[name]
        print(string.format("[MegaPatch] CLASS %s (%s): %s", name, type(cls), table.concat(listKeys(cls, true), ", ")))
        if type(cls) == "table" then
            print(string.format("[MegaPatch] CONST %s: %s", name, table.concat(listKeys(cls, false), ", ")))
        end
    end
    for _, g in ipairs({"g_sleepManager", "g_groundTypeManager", "g_terrainDeformationQueue"}) do
        local obj = _G[g]
        print(string.format("[MegaPatch] OBJ %s fields: %s", g, table.concat(listKeys(obj, false), ", ")))
        if type(obj) == "table" then
            local mt = getmetatable(obj)
            print(string.format("[MegaPatch] OBJ %s methods: %s", g, table.concat(listKeys(mt ~= nil and mt.__index or nil, true), ", ")))
        end
    end
    local screen = g_gui ~= nil and g_gui.screenControllers ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
    if screen ~= nil then
        print("[MegaPatch] SCREEN fields: " .. table.concat(listKeys(screen, false), ", "))
        if screen.cursor ~= nil then
            print("[MegaPatch] CURSOR fields: " .. table.concat(listKeys(screen.cursor, false), ", "))
        end
        if screen.brush ~= nil then
            print("[MegaPatch] BRUSH fields: " .. table.concat(listKeys(screen.brush, false), ", "))
        end
    end
    print("[MegaPatch] ===== DIAG END =====")
    return "Diagnostyka zapisana w log.txt"
end

-- sledzenie wywolan funkcji (pierwsze 20 wywolan kazdej funkcji) - do poznania argumentow
function MPConstructionTools:consoleTrace()
    if self.traceInstalled then
        return "Trace juz aktywny"
    end
    self.traceInstalled = true
    local counts = {}
    for _, name in ipairs({"GuiTopDownCursor", "ConstructionBrushSculpt", "ConstructionBrushPaint", "ConstructionBrush", "Landscaping", "SleepManager"}) do
        local cls = _G[name]
        if type(cls) == "table" then
            for fname, f in pairs(cls) do
                if type(f) == "function" and fname ~= "update" and fname ~= "draw" and fname ~= "new" then
                    local key = name .. "." .. fname
                    cls[fname] = function(...)
                        local n = (counts[key] or 0) + 1
                        counts[key] = n
                        if n <= 20 then
                            local args = {...}
                            local parts = {}
                            for i = 2, math.min(select("#", ...), 10) do
                                local a = args[i]
                                parts[#parts + 1] = type(a) == "number" and string.format("%.3f", a) or tostring(a)
                            end
                            print(string.format("[MegaPatch] TRACE %s(%s)", key, table.concat(parts, ", ")))
                        end
                        return f(...)
                    end
                end
            end
        end
    end
    return "Trace wlaczony - uzyj pedzli budowy, potem zamknij gre i wyslij log.txt"
end

---------------------------------------------------------------------------------------------------
-- hooks

-- wlasna zakladka budowy "Farby i oznakowanie" (Ksztaltowanie terenu)
function MPConstructionTools.addPaintTab(storeManager)
    if storeManager == nil or storeManager.modConstructionTabs == nil then
        return
    end
    for _, t in ipairs(storeManager.modConstructionTabs) do
        if t.tabName == "mpPaints" then
            return
        end
    end
    local title = "Farby i oznakowanie"
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText("megaPatch_paint_tab", MegaPatch.MOD_NAME) then
        title = g_i18n:getText("megaPatch_paint_tab", MegaPatch.MOD_NAME)
    end
    table.insert(storeManager.modConstructionTabs, {
        categoryName = "landscaping", tabName = "mpPaints", tabTitle = title,
        tabIconFilename = MegaPatch.MOD_DIR .. "images/menuIconPaint.dds",
        tabIconUVs = GuiUtils.getUVs("0 0 256 256", {256, 256})
    })
end

function MPConstructionTools.installHooks()
    MPConstructionTools.addPaintTab(g_storeManager)
    StoreManager.loadMapData = Utils.prependedFunction(StoreManager.loadMapData, function(sm)
        MPConstructionTools.addPaintTab(sm)
    end)

    -- darmowe malowanie i terraforming
    if Landscaping ~= nil and Landscaping.getCost ~= nil then
        Landscaping.getCost = Utils.overwrittenFunction(Landscaping.getCost, function(self, superFunc, ...)
            if MPConstructionTools.FREE_LANDSCAPING then
                return 0
            end
            return superFunc(self, ...)
        end)
    end

    PlaceableSystem.addPlaceable = Utils.appendedFunction(PlaceableSystem.addPlaceable, function(ps, placeable)
        local inst = MPConstructionTools.instance
        if inst ~= nil then
            inst:onPlaceableAdded(placeable)
        end
    end)

    PlaceableSystem.removePlaceable = Utils.prependedFunction(PlaceableSystem.removePlaceable, function(ps, placeable)
        local inst = MPConstructionTools.instance
        if inst ~= nil and not g_currentMission.isExitingGame then
            inst:onPlaceableRemoving(placeable)
        end
    end)

    ConstructionScreen.onOpen = Utils.appendedFunction(ConstructionScreen.onOpen, function()
        if MPConstructionTools.instance ~= nil then
            MPConstructionTools.instance.constructionOpen = true
        end
    end)
    ConstructionScreen.onClose = Utils.appendedFunction(ConstructionScreen.onClose, function()
        if MPConstructionTools.instance ~= nil then
            MPConstructionTools.instance.constructionOpen = false
        end
    end)

    -- Ctrl+Z / Ctrl+Y w trybie budowy
    ConstructionScreen.registerBrushActionEvents = Utils.appendedFunction(ConstructionScreen.registerBrushActionEvents, function(screen)
        if InputAction.MP_UNDO == nil or screen.brushEvents == nil then
            return
        end
        print("[MegaPatch] Cofnij/Ponow: rejestracja klawiszy w trybie budowy")
        local _, undoId = g_inputBinding:registerActionEvent(InputAction.MP_UNDO, screen, MPConstructionTools.onUndoAction, false, true, false, true)
        if undoId ~= nil then
            g_inputBinding:setActionEventText(undoId, MPUtil.getText("megaPatch_undo_action"))
            table.insert(screen.brushEvents, undoId)
        end
        local _, redoId = g_inputBinding:registerActionEvent(InputAction.MP_REDO, screen, MPConstructionTools.onRedoAction, false, true, false, true)
        if redoId ~= nil then
            g_inputBinding:setActionEventText(redoId, MPUtil.getText("megaPatch_redo_action"))
            table.insert(screen.brushEvents, redoId)
        end
    end)
end
