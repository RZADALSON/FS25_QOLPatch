-- FS25_MegaPatch: farby drogowe - rozmiar i dopasowanie do terenu
--
-- Kazda naklejka to siatka 4x4 kafelkow (kazdy z wlasnym fragmentem tekstury). Po postawieniu
-- (i w podgladzie budowy) kazdy kafelek jest ustawiany na wysokosci terenu i pochylany zgodnie ze
-- spadkiem, wiec naklejka "lezy" na nierownym terenie zamiast chowac sie pod nim.
-- Rozmiar: PgUp / PgDn w trybie budowy (1-10 m), zapamietywany dla kazdej postawionej naklejki.

MPPaintDecals = {}
local MPPaintDecals_mt = Class(MPPaintDecals)

MPPaintDecals.MODULE = "paints"
MPPaintDecals.GRID = 4
MPPaintDecals.SIZES = {1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10}
MPPaintDecals.DEFAULT_SIZE_INDEX = 5
MPPaintDecals.HEIGHT_OFFSET = 0.04
MPPaintDecals.OVERLAP = 1.5
-- orientacja obrazu na siatce (0-7): 0-3 obrot o 90 stopni, 4-7 to samo z odbiciem
MPPaintDecals.DEFAULT_ORIENTATION = 0

function MPPaintDecals.new(megaPatch)
    local self = setmetatable({}, MPPaintDecals_mt)
    self.megaPatch = megaPatch
    self.sizeIndex = MPPaintDecals.DEFAULT_SIZE_INDEX
    self.sizes = {}          -- serwer: [uniqueId serwera] = size (m)
    self.farmSizes = {}      -- serwer: [farmId] = rozmiar wybrany ostatnio przez gracza tej farmy
    self.clientSizes = {}    -- klient: [sieciowe ID] = size (rozmiary z serwera)
    self.syncDirty = false
    self.syncTimer = 0
    self.orientation = MPPaintDecals.DEFAULT_ORIENTATION
    self.preview = nil
    self.refreshTimer = 0
    self.missionStarted = false
    return self
end

function MPPaintDecals:loadMap()
    MPPaintDecals.instance = self
end

function MPPaintDecals:delete()
    MPPaintDecals.instance = nil
end

function MPPaintDecals:onStartMission()
    self.missionStarted = true
    -- postawione wczesniej naklejki: rozmiar z zapisu + dopasowanie do terenu
    local ps = g_currentMission.placeableSystem
    for _, placeable in ipairs(ps ~= nil and ps.placeables or {}) do
        if MPPaintDecals.isPaint(placeable) then
            self:applyToPlaceable(placeable)
        end
    end
end

function MPPaintDecals.isPaint(placeable)
    local fn = placeable ~= nil and placeable.configFileName or nil
    return fn ~= nil and string.find(fn, MegaPatch.MOD_NAME, 1, true) ~= nil
        and (string.find(fn, "/objects/paints/", 1, true) ~= nil or string.find(fn, "/objects/parkingLines/", 1, true) ~= nil)
end

function MPPaintDecals:getCurrentSize()
    return MPPaintDecals.SIZES[self.sizeIndex] or 3
end

-- szuka wezla, ktorego nazwa zaczyna sie od "prefix"
function MPPaintDecals.findNode(node, prefix, depth)
    if node == nil or node == 0 or depth > 4 then
        return nil
    end
    local name = getName(node)
    if name ~= nil and string.sub(name, 1, #prefix) == prefix then
        return node
    end
    for i = 0, getNumOfChildren(node) - 1 do
        local found = MPPaintDecals.findNode(getChildAt(node, i), prefix, depth + 1)
        if found ~= nil then
            return found
        end
    end
    return nil
end

-- "mpTiles_4x4" albo "mpTiles_16x4_fixed_1.25" -> kolumny, wiersze, staly rozmiar kafelka (m)
function MPPaintDecals.parseGrid(name)
    local cols, rows = string.match(name or "", "mpTiles_(%d+)x(%d+)")
    local fixed = string.match(name or "", "_fixed_([%d%.]+)")
    return tonumber(cols) or MPPaintDecals.GRID, tonumber(rows) or MPPaintDecals.GRID, tonumber(fixed)
end

-- dlugosc boku kafelka w skali 1 (z bryly brzegowej ksztaltu gry)
function MPPaintDecals:getBaseSize(tile)
    if self.baseSize == nil then
        local _, _, _, radius = getShapeBoundingSphere(tile)
        if radius ~= nil and radius > 0.01 then
            self.baseSize = radius * math.sqrt(2)
            print(string.format("[MegaPatch] Farby: bazowy rozmiar siatki %.3f m", self.baseSize))
        else
            self.baseSize = 4
        end
    end
    return self.baseSize
end

-- kierunki "w prawo" i "w gore" obrazu w ukladzie lokalnym (x, z)
function MPPaintDecals:getAxes()
    local o = self.orientation % 8
    local rx, rz, ux, uz = 1, 0, 0, -1
    for _ = 1, o % 4 do
        rx, rz = -rz, rx
        ux, uz = -uz, ux
    end
    if o >= 4 then
        rx, rz = -rx, -rz
    end
    return rx, rz, ux, uz
end

local function terrainHeight(x, z)
    return getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
end

function MPPaintDecals:layout(rootNode, size)
    local tilesNode = MPPaintDecals.findNode(rootNode, "mpTiles", 0)
    if tilesNode == nil or g_terrainNode == nil then
        return false
    end
    local first = getChildAt(tilesNode, 0)
    if first == nil or first == 0 then
        return false
    end
    local cols, rows, fixed = MPPaintDecals.parseGrid(getName(tilesNode))
    local base = self:getBaseSize(first)
    -- staly rozmiar (pasy parkingowe) albo rozmiar wybrany PgUp/PgDn (dluzszy bok)
    local t = fixed or (size / math.max(cols, rows))
    -- kafelek rysowany wiekszy niz komorka: zakladka zakrywa brakujace rogi siatki
    local scale = t * MPPaintDecals.OVERLAP / base
    local rx, rz, ux, uz = self:getAxes()
    local half = t * 0.5
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local tile = getChild(tilesNode, string.format("t_%d_%d", r, c))
            if tile ~= nil and tile ~= 0 then
                local a = (c - (cols - 1) / 2) * t
                local b = ((rows - 1) / 2 - r) * t
                local lx = a * rx + b * ux
                local lz = a * rz + b * uz
                setScale(tile, scale, scale, scale)
                -- wysokosc terenu pod srodkiem kafelka i jego nachylenie
                local wx, _, wz = localToWorld(tilesNode, lx, 0, lz)
                local h = terrainHeight(wx, wz)
                local x1, _, z1 = localToWorld(tilesNode, lx + half, 0, lz)
                local x2, _, z2 = localToWorld(tilesNode, lx - half, 0, lz)
                local x3, _, z3 = localToWorld(tilesNode, lx, 0, lz + half)
                local x4, _, z4 = localToWorld(tilesNode, lx, 0, lz - half)
                local h1, h2, h3, h4 = terrainHeight(x1, z1), terrainHeight(x2, z2), terrainHeight(x3, z3), terrainHeight(x4, z4)
                -- uniesienie: zawsze nad najwyzszym punktem pod kafelkiem (nie chowa sie w nierownosciach)
                local bump = math.max(h1, h2, h3, h4, h) - h
                local _, ly, _ = worldToLocal(tilesNode, wx, h + MPPaintDecals.HEIGHT_OFFSET + bump * 0.5, wz)
                setTranslation(tile, lx, ly, lz)
                setRotation(tile, -math.atan2(h3 - h4, t), 0, math.atan2(h1 - h2, t))
            end
        end
    end
    return true
end

-- Rozmiar postawionej farby. Serwer: zapamietany albo ostatnio wybrany przez gracza farmy-wlasciciela.
-- Klient: rozmiar przyslany przez serwer (po sieciowym ID); zanim dojdzie - domyslny.
function MPPaintDecals:getPlacedSize(placeable)
    if g_currentMission:getIsServer() then
        local uid = placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
        local size = uid ~= nil and self.sizes[uid] or nil
        if size == nil then
            local farmId = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
            size = (farmId ~= nil and self.farmSizes[farmId]) or self:getCurrentSize()
            if uid ~= nil and self.missionStarted then
                self.sizes[uid] = size
                self.syncDirty = true
            end
        end
        return size
    end
    local oid = MPUtil.getNetId(placeable)
    return (oid ~= nil and self.clientSizes[oid]) or MPPaintDecals.SIZES[MPPaintDecals.DEFAULT_SIZE_INDEX]
end

function MPPaintDecals:applyToPlaceable(placeable)
    local size = self:getPlacedSize(placeable)
    placeable.megaPatchPaintSize = size
    self:layout(placeable.rootNode, size)
end

function MPPaintDecals:forEachPaint(func)
    local ps = g_currentMission.placeableSystem
    for _, placeable in ipairs(ps ~= nil and ps.placeables or {}) do
        if MPPaintDecals.isPaint(placeable) and placeable.rootNode ~= nil then
            func(placeable)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- multiplayer: rozmiary farb i orientacja z serwera

function MPPaintDecals:getState()
    local sizes = {}
    self:forEachPaint(function(placeable)
        local uid = placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
        local oid = MPUtil.getNetId(placeable)
        if uid ~= nil and oid ~= nil and self.sizes[uid] ~= nil then
            sizes[oid] = self.sizes[uid]
        end
    end)
    return {orientation = self.orientation, sizes = sizes}
end

function MPPaintDecals:applyState(state)
    if g_currentMission:getIsServer() then
        return
    end
    local orientationChanged = state.orientation ~= nil and state.orientation ~= self.orientation
    self.orientation = state.orientation or self.orientation
    self.clientSizes = {}
    for oid, size in pairs(state.sizes or {}) do
        local id, s = tonumber(oid), tonumber(size)
        if id ~= nil and s ~= nil then
            self.clientSizes[id] = s
        end
    end
    self:forEachPaint(function(placeable)
        local size = self:getPlacedSize(placeable)
        if orientationChanged or placeable.megaPatchPaintSize ~= size then
            self:applyToPlaceable(placeable)
        end
    end)
end

function MPPaintDecals:sendInitialClientState(connection)
    connection:sendEvent(MPStateSyncEvent.new(MPPaintDecals.MODULE, self:getState()))
end

function MPPaintDecals:onRequest(action, data, farmId, connection)
    if not g_currentMission:getIsServer() then
        return
    end
    if action == "size" then
        local size = tonumber(data.size)
        for _, s in ipairs(MPPaintDecals.SIZES) do
            if s == size then
                self.farmSizes[farmId] = size
                return
            end
        end
    end
end

function MPPaintDecals:sendSelectedSize()
    MPRequestEvent.sendRequest(MPPaintDecals.MODULE, "size", {size = self:getCurrentSize()})
end

-- podglad w trybie budowy: kazda klatke ustawiamy rozmiar i teren pod kursorem
function MPPaintDecals:update(dt)
    -- serwer: nowe/zmienione rozmiary -> klienci (zbiorczo, max raz na sekunde)
    if self.syncDirty and g_currentMission:getIsServer() then
        self.syncTimer = self.syncTimer + dt
        if self.syncTimer > 1000 then
            self.syncTimer = 0
            self.syncDirty = false
            MPStateSyncEvent.broadcast(MPPaintDecals.MODULE, self:getState())
        end
    end
    local preview = self.preview
    if preview == nil then
        return
    end
    if preview.isDeleted or preview.rootNode == nil or not entityExists(preview.rootNode) or not MPConstructionTools.isConstructionOpen() then
        self.preview = nil
        return
    end
    self.refreshTimer = self.refreshTimer + dt
    if self.refreshTimer > 50 then
        self.refreshTimer = 0
        self:layout(preview.rootNode, self:getCurrentSize())
    end
end

function MPPaintDecals:changeSize(delta)
    self.sizeIndex = MPUtil.clamp(self.sizeIndex + delta, 1, #MPPaintDecals.SIZES)
    local text = MPUtil.getText("megaPatch_paint_size", tostring(self:getCurrentSize()))
    if g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(text, 1500)
    end
    if self.preview ~= nil and self.preview.rootNode ~= nil and entityExists(self.preview.rootNode) then
        self:layout(self.preview.rootNode, self:getCurrentSize())
    end
    self:updateActionTexts()
    self:sendSelectedSize()
end

function MPPaintDecals:updateActionTexts()
    local text = MPUtil.getText("megaPatch_paint_sizeAction", tostring(self:getCurrentSize()))
    for _, id in ipairs({self.biggerEventId, self.smallerEventId}) do
        if id ~= nil then
            g_inputBinding:setActionEventText(id, text)
        end
    end
end

function MPPaintDecals.onBigger()
    if MPPaintDecals.instance ~= nil then
        MPPaintDecals.instance:changeSize(1)
    end
end

function MPPaintDecals.onSmaller()
    if MPPaintDecals.instance ~= nil then
        MPPaintDecals.instance:changeSize(-1)
    end
end

function MPPaintDecals:onPlaceableAdded(placeable)
    if self.preview == placeable then
        self.preview = nil
    end
    if MPPaintDecals.isPaint(placeable) then
        self:applyToPlaceable(placeable)
    end
end

-- kazdy obiekt-farba, ktory nie jest jeszcze w systemie, to podglad budowy
function MPPaintDecals:onPlaceableLoaded(placeable)
    if not MPPaintDecals.isPaint(placeable) then
        return
    end
    local ps = g_currentMission.placeableSystem
    local uid = placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
    local registered = uid ~= nil and ps ~= nil and ps.placableByUniqueId ~= nil and ps.placableByUniqueId[uid] == placeable
    if not registered and MPConstructionTools.isConstructionOpen() then
        self.preview = placeable
        self:layout(placeable.rootNode, self:getCurrentSize())
    end
end

function MPPaintDecals:consoleOrientation(value)
    local o = tonumber(value)
    if o == nil then
        return "Uzycie: mpPaintOrient 0-7 (obecnie " .. tostring(self.orientation) .. ")"
    end
    self.orientation = math.floor(o) % 8
    self:forEachPaint(function(placeable)
        self:applyToPlaceable(placeable)
    end)
    if g_currentMission:getIsServer() then
        MPStateSyncEvent.broadcast(MPPaintDecals.MODULE, self:getState())
    end
    return "Orientacja farb: " .. tostring(self.orientation)
end

function MPPaintDecals:loadFromXMLFile(xmlFile, key)
    self.orientation = xmlFile:getInt(key .. ".paints#orientation", MPPaintDecals.DEFAULT_ORIENTATION)
    self.sizeIndex = MPUtil.clamp(xmlFile:getInt(key .. ".paints#sizeIndex", MPPaintDecals.DEFAULT_SIZE_INDEX), 1, #MPPaintDecals.SIZES)
    self.sizes = {}
    local i = 0
    while true do
        local k = string.format("%s.paints.paint(%d)", key, i)
        if not xmlFile:hasProperty(k) then
            break
        end
        local uid = xmlFile:getString(k .. "#uid")
        if uid ~= nil then
            self.sizes[uid] = xmlFile:getFloat(k .. "#size", 3)
        end
        i = i + 1
    end
end

function MPPaintDecals:saveToXMLFile(xmlFile, key)
    xmlFile:setInt(key .. ".paints#orientation", self.orientation)
    xmlFile:setInt(key .. ".paints#sizeIndex", self.sizeIndex)
    local ps = g_currentMission.placeableSystem
    local i = 0
    for uid, size in pairs(self.sizes) do
        -- zapisujemy tylko istniejace naklejki
        if ps ~= nil and ps.placableByUniqueId ~= nil and ps.placableByUniqueId[uid] ~= nil then
            local k = string.format("%s.paints.paint(%d)", key, i)
            xmlFile:setString(k .. "#uid", uid)
            xmlFile:setFloat(k .. "#size", size)
            i = i + 1
        end
    end
end

---------------------------------------------------------------------------------------------------

function MPPaintDecals.installHooks()
    PlaceableSystem.addPlaceable = Utils.appendedFunction(PlaceableSystem.addPlaceable, function(ps, placeable)
        local inst = MPPaintDecals.instance
        if inst ~= nil then
            inst:onPlaceableAdded(placeable)
        end
    end)

    if Placeable.setPose ~= nil then
        Placeable.setPose = Utils.appendedFunction(Placeable.setPose, function(placeable)
            local inst = MPPaintDecals.instance
            if inst ~= nil and MPPaintDecals.isPaint(placeable) then
                inst:onPlaceableLoaded(placeable)
            end
        end)
    end
    if Placeable.loadFinished ~= nil then
        Placeable.loadFinished = Utils.appendedFunction(Placeable.loadFinished, function(placeable)
            local inst = MPPaintDecals.instance
            if inst ~= nil and MPPaintDecals.isPaint(placeable) then
                inst:onPlaceableLoaded(placeable)
            end
        end)
    end

    -- PgUp / PgDn w trybie budowy: rozmiar farby
    ConstructionScreen.registerBrushActionEvents = Utils.appendedFunction(ConstructionScreen.registerBrushActionEvents, function(screen)
        local inst = MPPaintDecals.instance
        if inst == nil or InputAction.MP_PAINT_BIGGER == nil or screen.brushEvents == nil then
            return
        end
        local _, biggerId = g_inputBinding:registerActionEvent(InputAction.MP_PAINT_BIGGER, screen, MPPaintDecals.onBigger, false, true, false, true)
        local _, smallerId = g_inputBinding:registerActionEvent(InputAction.MP_PAINT_SMALLER, screen, MPPaintDecals.onSmaller, false, true, false, true)
        inst.biggerEventId, inst.smallerEventId = biggerId, smallerId
        inst:sendSelectedSize()
        for _, id in ipairs({biggerId, smallerId}) do
            if id ~= nil then
                table.insert(screen.brushEvents, id)
            end
        end
        inst:updateActionTexts()
    end)
end
