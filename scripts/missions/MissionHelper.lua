-- FS25_MegaPatch: "Wyslij pomocnika" przy zleceniach (kontraktach).
-- Przebieg (serwer):
--   1. gracz w menu Zlecenia wybiera "Wyslij pomocnika" -> zlecenie startuje z wypozyczonymi maszynami
--   2. czekamy az gra wystawi maszyny przy sklepie
--   3. odliczanie dojazdu (zalezne od odleglosci sklep -> pole)
--   4. ciagnik/kombajn trafia na skraj pola, sprzet zostaje podpiety, brakujacy material dokupiony
--   5. pomocnik (AI) rusza do pracy w normalnym tempie

MPMissionHelper = {}
MPMissionHelper.MODULE = "helper"
local MPMissionHelper_mt = {__index = MPMissionHelper}

MPMissionHelper.AVG_SPEED_KMH = 25        -- srednia predkosc dojazdu po drogach
MPMissionHelper.ROUTE_FACTOR = 1.35       -- drogi nie ida w linii prostej
MPMissionHelper.MIN_TRAVEL = 15           -- s
MPMissionHelper.MAX_TRAVEL = 300          -- s (5 minut)
MPMissionHelper.START_TIMEOUT = 60000     -- ms na start zlecenia i wystawienie maszyn
MPMissionHelper.SETTLE_TIME = 2000        -- ms po teleporcie zanim ruszy AI
MPMissionHelper.AI_RETRIES = 6
MPMissionHelper.EDGE_MARGIN_FRONT = 8     -- m wolnego pola przed ciagnikiem
MPMissionHelper.EDGE_MARGIN_BACK = 14     -- m wolnego pola za ciagnikiem (maszyna)
MPMissionHelper.AI_BUY_FACTOR = 1.5       -- tak jak gra: material kupowany przez pomocnika jest drozszy

-- zlecenia, ktorych pomocnik polowy nie umie wykonac
MPMissionHelper.UNSUPPORTED = {
    balewrap = true, deadwood = true, treetransport = true, destructiblerock = true,
    transport = true, supplytransport = true, animaltransport = true
}

-- material eksploatacyjny wg rodzaju zlecenia; option = ustawienie gry "pomocnik kupuje ..."
local SEEDS = {name = "SEEDS", option = "helperBuySeeds", money = "PURCHASE_SEEDS"}
local FERTILIZER = {name = "FERTILIZER", option = "helperBuyFertilizer", money = "PURCHASE_FERTILIZER"}
local LIQUIDFERTILIZER = {name = "LIQUIDFERTILIZER", option = "helperBuyFertilizer", money = "PURCHASE_FERTILIZER"}
local HERBICIDE = {name = "HERBICIDE", option = "helperBuyFertilizer", money = "PURCHASE_FERTILIZER"}
MPMissionHelper.CONSUMABLES = {
    sow = {SEEDS, FERTILIZER, LIQUIDFERTILIZER},
    fertilize = {FERTILIZER, LIQUIDFERTILIZER},
    herbicide = {HERBICIDE},
    spray = {HERBICIDE}
}

function MPMissionHelper.new(megaPatch)
    local self = setmetatable({}, MPMissionHelper_mt)
    self.megaPatch = megaPatch
    self.dispatches = {}       -- serwer: [missionUid] = dispatch
    self.clientView = {}       -- klient: [missionUid] = {farmId, phase, remaining, field}
    return self
end

function MPMissionHelper:loadMap()
    MPMissionHelper.instance = self
end

function MPMissionHelper:delete()
    if MPMissionHelper.instance == self then
        MPMissionHelper.instance = nil
    end
end

---------------------------------------------------------------------------------------------------
-- pomocnicze

local function vehicleIsValid(v)
    return v ~= nil and not v.isDeleted and not v.isDeleting and v.rootNode ~= nil and entityExists(v.rootNode)
end

function MPMissionHelper.getMissionTypeKey(mission)
    local name = nil
    if mission ~= nil then
        if mission.type ~= nil and mission.type.name ~= nil then
            name = mission.type.name
        elseif mission.getMissionTypeName ~= nil then
            local ok, n = pcall(mission.getMissionTypeName, mission)
            if ok then
                name = n
            end
        end
    end
    name = string.lower(tostring(name or ""))
    name = name:gsub("mission$", "")
    return name
end

function MPMissionHelper.isFieldMission(mission)
    if mission == nil or mission.field == nil then
        return false
    end
    if AbstractFieldMission ~= nil and mission.isa ~= nil then
        local ok, res = pcall(mission.isa, mission, AbstractFieldMission)
        if ok and not res then
            return false
        end
    end
    return true
end

function MPMissionHelper.isSupported(mission)
    if not MPMissionHelper.isFieldMission(mission) then
        return false
    end
    return not MPMissionHelper.UNSUPPORTED[MPMissionHelper.getMissionTypeKey(mission)]
end

function MPMissionHelper.getMissionUid(mission)
    if mission == nil then
        return nil
    end
    if mission.getUniqueId ~= nil then
        return mission:getUniqueId()
    end
    return mission.uniqueId
end

function MPMissionHelper.getMissionByUid(uid)
    if uid == nil or g_missionManager == nil then
        return nil
    end
    if g_missionManager.getMissionByUniqueId ~= nil then
        return g_missionManager:getMissionByUniqueId(uid)
    end
    return nil
end

-- serwer: zlecenie z danych zadania klienta (uniqueId zlecenia NIE jest przesylany do klientow,
-- wspolne jest tylko sieciowe ID obiektu)
function MPMissionHelper.resolveMission(data)
    local mission = MPUtil.getObjectByNetId(data.oid)
    if mission ~= nil and (mission.status == nil or mission.getUniqueId == nil) then
        mission = nil
    end
    if mission == nil then
        mission = MPMissionHelper.getMissionByUid(data.mission)
    end
    return mission
end

function MPMissionHelper.getMissionTitle(mission)
    local title = ""
    if mission.getTitle ~= nil then
        local ok, t = pcall(mission.getTitle, mission)
        if ok and t ~= nil then
            title = t
        end
    end
    if title == "" then
        title = mission.title or ""
    end
    return title
end

function MPMissionHelper.getMissionLocation(mission)
    if mission.getLocation ~= nil then
        local ok, loc = pcall(mission.getLocation, mission)
        if ok and loc ~= nil then
            return loc
        end
    end
    return ""
end

function MPMissionHelper.getFieldName(field)
    if field == nil then
        return "?"
    end
    if field.getName ~= nil then
        local ok, n = pcall(field.getName, field)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    return tostring(field.name or "?")
end

function MPMissionHelper.formatTime(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function MPMissionHelper.formatDistance(meters)
    if meters >= 1000 then
        return string.format("%.1f km", meters / 1000)
    end
    return string.format("%d m", math.floor(meters + 0.5))
end

function MPMissionHelper.getTravelSeconds(distance)
    local speed = MPMissionHelper.AVG_SPEED_KMH / 3.6
    local t = distance * MPMissionHelper.ROUTE_FACTOR / speed
    return MPUtil.clamp(t, MPMissionHelper.MIN_TRAVEL, MPMissionHelper.MAX_TRAVEL)
end

-- punkty wielokata pola w wspolrzednych swiata
function MPMissionHelper.getFieldPolygon(field)
    local points = nil
    if field.getPolygonPoints ~= nil then
        local ok, p = pcall(field.getPolygonPoints, field)
        if ok then
            points = p
        end
    end
    points = points or field.polygonPoints or {}
    local poly = {}
    for _, node in ipairs(points) do
        if node ~= nil and entityExists(node) then
            local x, _, z = getWorldTranslation(node)
            table.insert(poly, {x = x, z = z})
        end
    end
    return poly
end

function MPMissionHelper.pointInPolygon(poly, x, z)
    local inside = false
    local n = #poly
    if n < 3 then
        return false
    end
    local j = n
    for i = 1, n do
        local a, b = poly[i], poly[j]
        if ((a.z > z) ~= (b.z > z)) and (x < (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function MPMissionHelper.getFieldCenter(field)
    if field.getCenterOfFieldWorldPosition ~= nil then
        local ok, x, z = pcall(field.getCenterOfFieldWorldPosition, field)
        if ok and x ~= nil and z ~= nil then
            return x, z
        end
    end
    return field.posX or 0, field.posZ or 0
end

-- Punkt startowy na polu: od strony wjazdu (wezel teleportu pola albo najblizszy rog), tak
-- gleboko, zeby ciagnik z maszyna zmiescil sie w granicach pola. Zwraca x, z, yaw, wjazdX, wjazdZ.
function MPMissionHelper.getFieldTarget(field, fromX, fromZ)
    local poly = MPMissionHelper.getFieldPolygon(field)
    local cx, cz = MPMissionHelper.getFieldCenter(field)

    local ex, ez = nil, nil
    if field.teleportNode ~= nil and entityExists(field.teleportNode) then
        ex, _, ez = getWorldTranslation(field.teleportNode)
    end
    if ex == nil and #poly > 0 then
        local best = math.huge
        local ox, oz = fromX or cx, fromZ or cz
        for _, p in ipairs(poly) do
            local d = MathUtil.vector2Length(p.x - ox, p.z - oz)
            if d < best then
                best = d
                ex, ez = p.x, p.z
            end
        end
    end
    if ex == nil then
        return cx, cz, 0, cx, cz
    end

    local dx, dz = cx - ex, cz - ez
    local len = MathUtil.vector2Length(dx, dz)
    if len < 1 then
        return cx, cz, 0, ex, ez
    end
    dx, dz = dx / len, dz / len
    local yaw = MathUtil.getYRotationFromDirection(dx, dz)

    if #poly >= 3 then
        local front, back = MPMissionHelper.EDGE_MARGIN_FRONT, MPMissionHelper.EDGE_MARGIN_BACK
        local d = 0
        while d <= len do
            local x, z = ex + dx * d, ez + dz * d
            if MPMissionHelper.pointInPolygon(poly, x, z)
                and MPMissionHelper.pointInPolygon(poly, x + dx * front, z + dz * front)
                and MPMissionHelper.pointInPolygon(poly, x - dx * back, z - dz * back) then
                return x, z, yaw, ex, ez
            end
            d = d + 2
        end
    end
    return cx, cz, yaw, ex, ez
end

-- pozycja startowa wypozyczonych maszyn (miejsce przy sklepie) - tylko do szacunku w oknie
function MPMissionHelper.getShopSpawnPosition()
    local places = g_currentMission ~= nil and g_currentMission.storeSpawnPlaces or nil
    local place = places ~= nil and places[1] or nil
    if place == nil then
        return nil
    end
    local x = place.startX or place.x or place.posX
    local z = place.startZ or place.z or place.posZ
    if x == nil or z == nil then
        return nil
    end
    if place.endX ~= nil and place.endZ ~= nil then
        x, z = (x + place.endX) * 0.5, (z + place.endZ) * 0.5
    end
    return x, z
end

function MPMissionHelper.getStoreItemName(filename)
    if filename == nil or g_storeManager == nil then
        return nil
    end
    local item = g_storeManager:getItemByXMLFilename(filename)
    if item == nil then
        return nil
    end
    local brand = item.brandIndex ~= nil and g_brandManager ~= nil and g_brandManager:getBrandByIndex(item.brandIndex) or nil
    if brand ~= nil and brand.title ~= nil and brand.title ~= "" and brand.name ~= "NONE" then
        return brand.title .. " " .. tostring(item.name)
    end
    return item.name
end

---------------------------------------------------------------------------------------------------
-- rozpoznawanie maszyn

local function isDrivable(v)
    return v.spec_drivable ~= nil or v.spec_enterable ~= nil
end

local function isWorkTool(v)
    local spec = v.spec_workArea
    return spec ~= nil and spec.workAreas ~= nil and #spec.workAreas > 0
end

local function isWeight(v)
    if isWorkTool(v) or isDrivable(v) then
        return false
    end
    local file = string.lower(tostring(v.configFileName or ""))
    if file:find("weight") ~= nil then
        return true
    end
    if g_storeManager ~= nil and v.configFileName ~= nil then
        local item = g_storeManager:getItemByXMLFilename(v.configFileName)
        if item ~= nil and item.categoryName ~= nil and string.upper(item.categoryName):find("WEIGHT") ~= nil then
            return true
        end
    end
    return false
end

local function getAttacherVehicle(v)
    if v.getAttacherVehicle ~= nil then
        return v:getAttacherVehicle()
    end
    return nil
end

-- najlepsze polaczenie narzedzia z pojazdem: inputIndex, jointIndex, score
function MPMissionHelper.findJoint(root, tool, usedJoints)
    if root.getAttacherJoints == nil or tool.getInputAttacherJoints == nil then
        return nil
    end
    local joints = root:getAttacherJoints() or {}
    local inputs = tool:getInputAttacherJoints() or {}
    local preferDir = isWeight(tool) and 1 or -1
    local bestIn, bestJoint, bestScore = nil, nil, -1
    for inIdx, inJ in ipairs(inputs) do
        for jIdx, j in ipairs(joints) do
            local free = (j.jointIndex == nil or j.jointIndex == 0) and not j.isBlocked and not (usedJoints ~= nil and usedJoints[jIdx])
            if free and j.jointType ~= nil and j.jointType == inJ.jointType then
                local forced = inJ.forcedAttachingDirection or 0
                local dir = j.attacherJointDirection or -1
                if forced == 0 or forced == dir then
                    local score = 1
                    if dir == preferDir then
                        score = score + 2
                    end
                    if forced ~= 0 then
                        score = score + 2
                    end
                    if score > bestScore then
                        bestIn, bestJoint, bestScore = inIdx, jIdx, score
                    end
                end
            end
        end
    end
    if bestIn == nil then
        return nil
    end
    return bestIn, bestJoint, bestScore
end

-- Wybiera pojazd glowny (ciagnik/kombajn) i sprzet do podpiecia sposrod maszyn zlecenia.
function MPMissionHelper.planCombination(vehicles)
    local drivables, tools = {}, {}
    for _, v in ipairs(vehicles) do
        if vehicleIsValid(v) then
            if isDrivable(v) and v.spec_attacherJoints ~= nil then
                table.insert(drivables, v)
            elseif v.spec_attachable ~= nil and (isWorkTool(v) or isWeight(v)) then
                table.insert(tools, v)
            end
        end
    end
    -- najpierw maszyny robocze, obciazniki na koncu (zeby nie zajely tylnego TUZ)
    table.sort(tools, function(a, b)
        local wa, wb = isWeight(a) and 1 or 0, isWeight(b) and 1 or 0
        return wa < wb
    end)

    local best = nil
    for _, root in ipairs(drivables) do
        local used = {}
        local plan = {root = root, attach = {}, workTools = 0}
        for _, tool in ipairs(tools) do
            local parent = getAttacherVehicle(tool)
            if parent ~= nil then
                if parent:getRootVehicle() == root and isWorkTool(tool) then
                    plan.workTools = plan.workTools + 1
                end
            else
                local inIdx, jIdx = MPMissionHelper.findJoint(root, tool, used)
                if inIdx ~= nil then
                    used[jIdx] = true
                    table.insert(plan.attach, {tool = tool, inputIndex = inIdx, jointIndex = jIdx})
                    if isWorkTool(tool) then
                        plan.workTools = plan.workTools + 1
                    end
                end
            end
        end
        if isWorkTool(root) then
            plan.workTools = plan.workTools + 1 -- np. kombajn z wlasnym zespolem roboczym
        end
        if best == nil or plan.workTools > best.workTools then
            best = plan
        end
    end
    if best == nil and #drivables > 0 then
        best = {root = drivables[1], attach = {}, workTools = 0}
    end
    return best
end

---------------------------------------------------------------------------------------------------
-- przenoszenie pojazdow

local function terrainHeight(x, z)
    return getTerrainHeightAtWorldPos(g_terrainNode, x, 300, z)
end

-- Ustawia pojazd tak, ze jego wezel `node` trafia dokladnie w (tx, ty, tz), z obrotem yaw.
-- Pojazd musi byc wyjety z fizyki.
local function placeVehicleNode(v, node, tx, ty, tz, yaw)
    local oy = terrainHeight(tx, tz)
    v:setAbsolutePosition(tx, oy, tz, 0, yaw, 0)
    local nx, ny, nz = getWorldTranslation(node)
    v:setAbsolutePosition(tx + (tx - nx), oy + (ty - ny), tz + (tz - nz), 0, yaw, 0)
end

-- Przenosi caly zestaw (pojazd + to, co juz jest do niego podpiete) na pole.
function MPMissionHelper.moveCombination(root, x, z, yaw)
    local children = root:getChildVehicles() or {root}
    local rx, ry, rz = getWorldTranslation(root.rootNode)
    local rootHeight = ry - terrainHeight(rx, rz)
    rootHeight = MPUtil.clamp(rootHeight, 0.3, 4) + 0.15

    -- polozenie pozostalych czlonow wzgledem pojazdu glownego
    local rdx, _, rdz = localDirectionToWorld(root.rootNode, 0, 0, 1)
    local rootYaw = MathUtil.getYRotationFromDirection(rdx, rdz)
    local relative = {}
    for _, v in ipairs(children) do
        if v ~= root and vehicleIsValid(v) then
            local vx, vy, vz = getWorldTranslation(v.rootNode)
            local lx, ly, lz = worldToLocal(root.rootNode, vx, vy, vz)
            local dx, _, dz = localDirectionToWorld(v.rootNode, 0, 0, 1)
            local vYaw = MathUtil.getYRotationFromDirection(dx, dz)
            table.insert(relative, {v = v, lx = lx, ly = ly, lz = lz, yaw = vYaw - rootYaw})
        end
    end

    for _, v in ipairs(children) do
        if vehicleIsValid(v) and v.isAddedToPhysics then
            v:removeFromPhysics()
        end
    end

    placeVehicleNode(root, root.rootNode, x, terrainHeight(x, z) + rootHeight, z, yaw)
    for _, r in ipairs(relative) do
        local wx, wy, wz = localToWorld(root.rootNode, r.lx, r.ly, r.lz)
        placeVehicleNode(r.v, r.v.rootNode, wx, wy, wz, yaw + r.yaw)
    end

    for _, v in ipairs(children) do
        if vehicleIsValid(v) and not v.isAddedToPhysics then
            v:addToPhysics()
        end
    end
end

---------------------------------------------------------------------------------------------------
-- ukrywanie maszyn na czas dojazdu (pomocnik "zabral" sprzet)

-- metody pojazdu wylaczane na czas ukrycia: Tab, wsiadanie (tez z menu), ikona na mapie
local HIDDEN_METHODS = {"getIsTabbable", "getIsEnterable", "getIsEnterableFromMenu", "getIsMapHotspotVisible"}
local function returnFalse()
    return false
end

-- hidden=true: niewidoczny, bez fizyki, bez Tab/wsiadania. hidden=false: widoczny;
-- keepOutOfPhysics=true zostawia go poza fizyka (gdy zaraz bedzie przenoszony).
function MPMissionHelper.setVehicleHidden(v, hidden, keepOutOfPhysics)
    if not vehicleIsValid(v) then
        return
    end
    if hidden then
        if v.megaPatchHidden then
            return
        end
        v.megaPatchHidden = true
        v.megaPatchOrigMethods = {}
        for _, name in ipairs(HIDDEN_METHODS) do
            if v[name] ~= nil then
                local own = rawget(v, name)
                v.megaPatchOrigMethods[name] = own ~= nil and own or false
                v[name] = returnFalse
            end
        end
        if v.isAddedToPhysics then
            v:removeFromPhysics()
        end
        v:setVisibility(false)
    else
        if not v.megaPatchHidden then
            return
        end
        v.megaPatchHidden = nil
        for name, own in pairs(v.megaPatchOrigMethods or {}) do
            if own == false then
                v[name] = nil
            else
                v[name] = own
            end
        end
        v.megaPatchOrigMethods = nil
        v:setVisibility(true)
        if not keepOutOfPhysics and not v.isAddedToPhysics then
            v:addToPhysics()
        end
    end
    if v.updateMapHotspot ~= nil then
        v:updateMapHotspot()
    end
end

function MPMissionHelper:hideDispatchVehicles(d, mission)
    d.hidden = {}
    for _, v in ipairs(mission.vehicles or {}) do
        if vehicleIsValid(v) and not v.megaPatchHidden then
            MPMissionHelper.setVehicleHidden(v, true)
            table.insert(d.hidden, v)
        end
    end
end

function MPMissionHelper:showDispatchVehicles(d, keepOutOfPhysics)
    for _, v in ipairs(d.hidden or {}) do
        MPMissionHelper.setVehicleHidden(v, false, keepOutOfPhysics)
    end
    d.hidden = nil
end

-- Miejsce postoju dla dodatkowych maszyn (np. ciagnik z przyczepa przy zniwach): przy wjezdzie,
-- poza polem, zeby nie zawadzaly pomocnikowi. k = 1, 2, ...
function MPMissionHelper.getParkingSlot(field, d, k)
    local poly = MPMissionHelper.getFieldPolygon(field)
    local ex, ez = d.entryX or d.targetX, d.entryZ or d.targetZ
    local dx, dz = math.sin(d.targetYaw or 0), math.cos(d.targetYaw or 0)
    local rx, rz = dz, -dx
    local candidates = {}
    for i = 0, 3 do
        local back = 6 + 9 * i
        table.insert(candidates, {ex - dx * back, ez - dz * back})
        table.insert(candidates, {ex - dx * 6 + rx * 9 * (i + 1), ez - dz * 6 + rz * 9 * (i + 1)})
        table.insert(candidates, {ex - dx * 6 - rx * 9 * (i + 1), ez - dz * 6 - rz * 9 * (i + 1)})
    end
    local found = 0
    for _, c in ipairs(candidates) do
        if not MPMissionHelper.pointInPolygon(poly, c[1], c[2]) then
            found = found + 1
            if found == k then
                return c[1], c[2]
            end
        end
    end
    local c = candidates[math.min(k, #candidates)]
    return c[1], c[2]
end

-- pozostale maszyny zlecenia: dodatkowe ciagniki (z przyczepami) i luzny sprzet - na postoj przy wjezdzie
function MPMissionHelper:placeOtherVehicles(d, mission, root)
    local inMain = {}
    for _, v in ipairs(root:getChildVehicles() or {root}) do
        inMain[v] = true
    end
    local drivables, loose = {}, {}
    for _, v in ipairs(mission.vehicles or {}) do
        if vehicleIsValid(v) and not inMain[v] and getAttacherVehicle(v) == nil then
            if isDrivable(v) and v.spec_attacherJoints ~= nil then
                table.insert(drivables, v)
            else
                table.insert(loose, v)
            end
        end
    end
    local slot = 0
    local yaw = d.targetYaw
    for _, tractor in ipairs(drivables) do
        slot = slot + 1
        local x, z = MPMissionHelper.getParkingSlot(mission.field, d, slot)
        MPMissionHelper.moveCombination(tractor, x, z, yaw)
        local used = {}
        for i = #loose, 1, -1 do
            local tool = loose[i]
            if tool.spec_attachable ~= nil then
                local inIdx, jIdx = MPMissionHelper.findJoint(tractor, tool, used)
                if inIdx ~= nil then
                    used[jIdx] = true
                    local ok, res = pcall(MPMissionHelper.attachTool, tractor, {tool = tool, inputIndex = inIdx, jointIndex = jIdx}, yaw)
                    if ok and res then
                        table.remove(loose, i)
                    end
                end
            end
        end
    end
    for _, v in ipairs(loose) do
        slot = slot + 1
        local x, z = MPMissionHelper.getParkingSlot(mission.field, d, slot)
        local vx, vy, vz = getWorldTranslation(v.rootNode)
        local h = MPUtil.clamp(vy - terrainHeight(vx, vz), 0.2, 4) + 0.1
        if v.isAddedToPhysics then
            v:removeFromPhysics()
        end
        placeVehicleNode(v, v.rootNode, x, terrainHeight(x, z) + h, z, yaw)
        v:addToPhysics()
    end
end

-- Stawia narzedzie przy zaczepie pojazdu i podpina je (plynne podpiecie wyrownuje reszte).
function MPMissionHelper.attachTool(root, entry, yaw)
    local tool = entry.tool
    local joints = root:getAttacherJoints()
    local joint = joints ~= nil and joints[entry.jointIndex] or nil
    local inputs = tool:getInputAttacherJoints()
    local input = inputs ~= nil and inputs[entry.inputIndex] or nil
    if joint == nil or input == nil or input.node == nil then
        return false
    end
    local jointNode = joint.jointTransform or joint.node
    if jointNode == nil then
        return false
    end
    if joint.jointIndex ~= nil and joint.jointIndex ~= 0 then
        return false -- zaczep zajety w miedzyczasie
    end
    local jx, jy, jz = getWorldTranslation(jointNode)

    if tool.isAddedToPhysics then
        tool:removeFromPhysics()
    end
    placeVehicleNode(tool, input.node, jx, jy, jz, yaw)
    tool:addToPhysics()

    root:attachImplement(tool, entry.inputIndex, entry.jointIndex, false, nil, false, false, false)
    return getAttacherVehicle(tool) == root
end

-- Uzupelnia pusty material (nasiona, nawoz, srodki), jesli w grze wylaczono "pomocnik kupuje ...".
-- Zwraca wydana kwote.
function MPMissionHelper.refillConsumables(root, farmId, missionKey)
    local spent = 0
    local consumables = MPMissionHelper.CONSUMABLES[missionKey or ""]
    if consumables == nil then
        return 0
    end
    local info = g_currentMission.missionInfo
    local economy = g_currentMission.economyManager
    if economy == nil or g_fillTypeManager == nil then
        return 0
    end
    for _, v in ipairs(root:getChildVehicles() or {root}) do
        if vehicleIsValid(v) and v.getFillUnits ~= nil and v.spec_fillUnit ~= nil then
            for idx, _ in ipairs(v:getFillUnits()) do
                if v:getFillUnitFillLevel(idx) < 1 then
                    for _, c in ipairs(consumables) do
                        local fillType = g_fillTypeManager:getFillTypeIndexByName(c.name)
                        if fillType ~= nil and v:getFillUnitSupportsFillType(idx, fillType) then
                            if info == nil or not info[c.option] then
                                local capacity = v:getFillUnitCapacity(idx) or 0
                                local pricePerLiter = economy:getCostPerLiter(fillType, false) or 0
                                if capacity > 0 and capacity < math.huge then
                                    local added = v:addFillUnitFillLevel(farmId, idx, capacity, fillType, ToolType.UNDEFINED, nil) or 0
                                    if added > 0 then
                                        local cost = added * pricePerLiter * MPMissionHelper.AI_BUY_FACTOR
                                        if cost > 0 then
                                            g_currentMission:addMoney(-cost, farmId, MPUtil.moneyType(c.money, "OTHER"), true, true)
                                            spent = spent + cost
                                        end
                                    end
                                end
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    return spent
end

---------------------------------------------------------------------------------------------------
-- start pomocnika

function MPMissionHelper.getFieldWorkJobType()
    local manager = g_currentMission.aiJobTypeManager
    if AIJobType ~= nil and AIJobType.FIELDWORK ~= nil then
        return AIJobType.FIELDWORK
    end
    if manager ~= nil and manager.getJobTypeIndexByName ~= nil then
        return manager:getJobTypeIndexByName("FIELDWORK")
    end
    return nil
end

-- zwraca ok, kod bledu ("limit", "notSupported", "invalid", tekst bledu gry)
function MPMissionHelper.startAI(root, farmId)
    local mission = g_currentMission
    if mission.aiSystem == nil or mission.aiJobTypeManager == nil then
        return false, "notSupported"
    end
    if root.getIsAIActive ~= nil and root:getIsAIActive() then
        return true
    end
    if mission.aiSystem:getAILimitedReached() then
        return false, "limit"
    end
    local jobType = MPMissionHelper.getFieldWorkJobType()
    if jobType == nil then
        return false, "notSupported"
    end
    local job = mission.aiJobTypeManager:createJob(jobType)
    if job == nil then
        return false, "notSupported"
    end
    if job.getIsAvailableForVehicle ~= nil and not job:getIsAvailableForVehicle(root) then
        return false, "notSupported"
    end
    job:applyCurrentState(root, mission, farmId, true)
    job:setValues()
    local valid, errorMessage = job:validate(farmId)
    if not valid then
        return false, errorMessage or "invalid"
    end
    mission.aiSystem:startJob(job, farmId)
    return true
end

---------------------------------------------------------------------------------------------------
-- serwer: zlecenia pomocnika

function MPMissionHelper:onRequest(action, data, farmId, connection)
    if not g_currentMission:getIsServer() then
        return
    end
    if action == "dispatch" then
        local mission = MPMissionHelper.resolveMission(data)
        local uid = MPMissionHelper.getMissionUid(mission)
        if mission == nil or uid == nil or self.dispatches[uid] ~= nil or not MPMissionHelper.isSupported(mission) then
            return
        end
        -- kazdy gracz farmy moze wyslac pomocnika (pelny dostep dla wspolnikow)
        self.dispatches[uid] = {uid = uid, farmId = farmId, phase = "waitStart", timer = 0, retries = 0}
        if data.startHere then
            -- gdy zdarzenie startu zlecenia z gry jest niedostepne - startujemy po stronie serwera
            local state = g_missionManager:startMission(mission, farmId, true)
            if MissionStartState ~= nil and state ~= MissionStartState.OK then
                self.dispatches[uid] = nil
                MPUtil.notifyFarm(farmId, 2, "megaPatch_helper_startFailed")
                return
            end
        end
        self:syncState()
    elseif action == "cancel" then
        local mission = MPMissionHelper.resolveMission(data)
        local uid = MPMissionHelper.getMissionUid(mission)
        local d = uid ~= nil and self.dispatches[uid] or nil
        if d ~= nil and d.farmId == farmId and d.phase ~= "working" then
            self:finishDispatch(d, nil)
            MPUtil.notifyFarm(farmId, 1, "megaPatch_helper_cancelled")
        end
    end
end

function MPMissionHelper:finishDispatch(d, notifyKey, ...)
    self.dispatches[d.uid] = nil
    self:showDispatchVehicles(d, false)
    if notifyKey ~= nil then
        MPUtil.notifyFarm(d.farmId, 2, notifyKey, ...)
    end
    self:syncState()
end

function MPMissionHelper:update(dt)
    if g_currentMission:getIsServer() then
        for _, d in pairs(self.dispatches) do
            local ok, err = pcall(self.updateDispatch, self, d, dt)
            if not ok then
                Logging.error("[MegaPatch] Pomocnik zlecenia: %s", tostring(err))
                self:finishDispatch(d, "megaPatch_helper_failed", "error")
            end
        end
    end
    self:updateClient(dt)
end

function MPMissionHelper:updateDispatch(d, dt)
    local mission = MPMissionHelper.getMissionByUid(d.uid)
    if mission == nil then
        if d.phase == "resume" and d.timer < MPMissionHelper.START_TIMEOUT then
            d.timer = d.timer + dt
            return
        end
        self:finishDispatch(d, nil)
        return
    end
    local status = mission.status
    if MissionStatus ~= nil and (status == MissionStatus.FINISHED or status == MissionStatus.DISMISSED) then
        self:finishDispatch(d, nil)
        return
    end

    if d.phase == "waitStart" then
        d.timer = d.timer + dt
        local running = mission.getIsRunning ~= nil and mission:getIsRunning()
        if running and mission.farmId == d.farmId then
            if not mission.spawnedVehicles or mission.vehicles == nil or #mission.vehicles == 0 then
                self:finishDispatch(d, "megaPatch_helper_noVehicles")
                return
            end
            if mission.vehiclesToLoad ~= nil and #mission.vehicles < #mission.vehiclesToLoad then
                return -- jeszcze sie laduja
            end
            local plan = MPMissionHelper.planCombination(mission.vehicles)
            if plan == nil then
                self:finishDispatch(d, "megaPatch_helper_noTractor")
                return
            end
            local root = plan.root
            for _, v in ipairs(mission.vehicles) do
                if vehicleIsValid(v) and v.getIsControlled ~= nil and v:getIsControlled() then
                    self:finishDispatch(d, "megaPatch_helper_takenOver")
                    return
                end
            end
            local sx, _, sz = getWorldTranslation(root.rootNode)
            local tx, tz, yaw, ex, ez = MPMissionHelper.getFieldTarget(mission.field, sx, sz)
            local distance = MathUtil.vector2Length(tx - sx, tz - sz)
            d.root = root
            d.startX, d.startZ = sx, sz
            d.targetX, d.targetZ, d.targetYaw = tx, tz, yaw
            d.entryX, d.entryZ = ex, ez
            self:hideDispatchVehicles(d, mission)
            d.distance = distance
            d.total = MPMissionHelper.getTravelSeconds(distance)
            d.remaining = d.total
            d.fieldName = MPMissionHelper.getFieldName(mission.field)
            d.phase = "travel"
            MPUtil.notifyFarm(d.farmId, 1, "megaPatch_helper_left", d.fieldName, MPMissionHelper.formatDistance(distance), MPMissionHelper.formatTime(d.total))
            self:syncState()
        elseif mission:getWasStarted() and mission.farmId ~= d.farmId then
            self:finishDispatch(d, nil) -- zlecenie przyjal ktos inny
        elseif d.timer > 5000 and mission.getIsReadyToStart ~= nil and mission:getIsReadyToStart() then
            self:finishDispatch(d, nil) -- start odrzucony (gra pokazuje powod)
        elseif d.timer > MPMissionHelper.START_TIMEOUT then
            -- zlecenie nie wystartowalo (np. limit zlecen) - gra sama pokazuje powod
            self:finishDispatch(d, nil)
        end

    elseif d.phase == "travel" then
        local root = d.root
        if not vehicleIsValid(root) then
            self:finishDispatch(d, "megaPatch_helper_failed", "vehicle")
            return
        end
        -- maszyny sa ukryte; gdyby mimo to ktos do nich wsiadl - przerywamy i oddajemy je przy sklepie
        local controlled = root.getIsControlled ~= nil and root:getIsControlled()
        if controlled then
            self:finishDispatch(d, "megaPatch_helper_takenOver")
            return
        end
        d.remaining = d.remaining - dt * 0.001
        if d.remaining <= 0 then
            self:arrive(d, mission)
        end

    elseif d.phase == "resume" then
        d.timer = d.timer + dt
        local running = mission.getIsRunning ~= nil and mission:getIsRunning()
        local count = mission.vehicles ~= nil and #mission.vehicles or 0
        local loaded = count > 0 and (mission.vehiclesToLoad == nil or count >= #mission.vehiclesToLoad)
        if running and (loaded or (d.timer > MPMissionHelper.START_TIMEOUT and count > 0)) then
            local plan = MPMissionHelper.planCombination(mission.vehicles)
            if plan == nil then
                self:finishDispatch(d, nil)
                return
            end
            d.root = plan.root
            d.fieldName = MPMissionHelper.getFieldName(mission.field)
            if d.resumePhase == "travel" then
                self:hideDispatchVehicles(d, mission)
                d.phase = "travel"
            else
                d.phase = "settle"
                d.timer = MPMissionHelper.SETTLE_TIME
                d.retries = 0
            end
            self:syncState()
        elseif d.timer > MPMissionHelper.START_TIMEOUT * 2 then
            self:finishDispatch(d, nil)
        end

    elseif d.phase == "settle" then
        d.timer = d.timer - dt
        if d.timer <= 0 then
            local root = d.root
            if not vehicleIsValid(root) then
                self:finishDispatch(d, "megaPatch_helper_failed", "vehicle")
                return
            end
            local ok, err = MPMissionHelper.startAI(root, d.farmId)
            if ok then
                d.phase = "working"
                d.timer = 0
                MPUtil.notifyFarm(d.farmId, 3, "megaPatch_helper_started", d.fieldName)
                self:syncState()
            elseif err == "limit" then
                if not d.limitNotified then
                    d.limitNotified = true
                    MPUtil.notifyFarm(d.farmId, 2, "megaPatch_helper_waitLimit")
                end
                d.timer = 5000
            else
                d.retries = d.retries + 1
                if d.retries >= MPMissionHelper.AI_RETRIES then
                    Logging.warning("[MegaPatch] Pomocnik nie wystartowal na polu %s: %s", tostring(d.fieldName), tostring(err))
                    self:finishDispatch(d, "megaPatch_helper_aiFailed", d.fieldName)
                else
                    d.timer = 1000
                end
            end
        end

    elseif d.phase == "working" then
        d.timer = d.timer + dt
        local root = d.root
        if not vehicleIsValid(root) then
            self:finishDispatch(d, nil)
            return
        end
        if d.timer > 3000 and root.getIsAIActive ~= nil and not root:getIsAIActive() then
            -- pomocnik skonczyl albo zatrzymal sie (gra sama pokazuje komunikat AI)
            self:finishDispatch(d, nil)
        end
    end
end

function MPMissionHelper:arrive(d, mission)
    local root = d.root
    local yaw = d.targetYaw
    self:showDispatchVehicles(d, true)
    MPMissionHelper.moveCombination(root, d.targetX, d.targetZ, yaw)

    -- podpinanie sprzetu przy polu (plan liczony od nowa - stan zaczepow mogl sie zmienic)
    local plan = MPMissionHelper.planCombination(mission.vehicles)
    local attached, failed = 0, 0
    if plan ~= nil and plan.root == root then
        for _, entry in ipairs(plan.attach) do
            local ok, res = pcall(MPMissionHelper.attachTool, root, entry, yaw)
            if ok and res then
                attached = attached + 1
            else
                failed = failed + 1
                if not ok then
                    Logging.warning("[MegaPatch] Pomocnik: blad podpinania %s: %s", tostring(entry.tool.configFileName), tostring(res))
                end
            end
        end
    end

    local okOther, errOther = pcall(self.placeOtherVehicles, self, d, mission, root)
    if not okOther then
        Logging.warning("[MegaPatch] Pomocnik: dodatkowe maszyny: %s", tostring(errOther))
    end
    -- cokolwiek zostalo poza fizyka (np. blad podpiecia) wraca do fizyki na miejscu
    for _, v in ipairs(mission.vehicles or {}) do
        if vehicleIsValid(v) and not v.isAddedToPhysics then
            v:addToPhysics()
        end
    end

    local spent = MPMissionHelper.refillConsumables(root, d.farmId, MPMissionHelper.getMissionTypeKey(mission))
    if spent > 0 then
        MPUtil.notifyFarm(d.farmId, 1, "megaPatch_helper_bought", spent)
    end
    if failed > 0 then
        MPUtil.notifyFarm(d.farmId, 2, "megaPatch_helper_attachFailed", tostring(failed))
    end

    d.phase = "settle"
    d.timer = MPMissionHelper.SETTLE_TIME
    d.retries = 0
    MPUtil.notifyFarm(d.farmId, 1, "megaPatch_helper_arrived", d.fieldName)
    self:syncState()
end

---------------------------------------------------------------------------------------------------
-- stan dla klientow (odliczanie na ekranie)

function MPMissionHelper:getState()
    local list = {}
    for uid, d in pairs(self.dispatches) do
        local hidden = {}
        for _, v in ipairs(d.hidden or {}) do
            if vehicleIsValid(v) and NetworkUtil ~= nil and NetworkUtil.getObjectId ~= nil then
                local id = NetworkUtil.getObjectId(v)
                if id ~= nil then
                    table.insert(hidden, id)
                end
            end
        end
        local mission = MPMissionHelper.getMissionByUid(uid)
        list[uid] = {farmId = d.farmId, phase = d.phase, remaining = d.remaining or 0, total = d.total or 0, field = d.fieldName or "", hidden = hidden,
                     oid = mission ~= nil and MPUtil.getNetId(mission) or nil}
    end
    return {dispatches = list}
end

function MPMissionHelper:syncState()
    local state = self:getState()
    self:applyState(state)
    MPStateSyncEvent.broadcast(MPMissionHelper.MODULE, state)
end

function MPMissionHelper:applyState(state)
    self.clientView = {}
    local hiddenIds = {}
    for uid, d in pairs(state.dispatches or {}) do
        self.clientView[uid] = {farmId = d.farmId, phase = d.phase, remaining = tonumber(d.remaining) or 0, total = tonumber(d.total) or 0, field = d.field, oid = tonumber(d.oid)}
        for _, id in pairs(d.hidden or {}) do
            local n = tonumber(id)
            if n ~= nil then
                hiddenIds[n] = true
            end
        end
    end
    if g_currentMission:getIsServer() then
        return -- serwer ukrywa maszyny sam
    end
    -- klient: ukrycie tych samych maszyn; odkrycie z malym opoznieniem (az dojdzie nowa pozycja z serwera)
    self.clientHidden = self.clientHidden or {}
    self.clientUnhide = self.clientUnhide or {}
    for id, _ in pairs(self.clientHidden) do
        if not hiddenIds[id] then
            self.clientHidden[id] = nil
            self.clientUnhide[id] = 1000
        end
    end
    for id, _ in pairs(hiddenIds) do
        self.clientHidden[id] = true
        self.clientUnhide[id] = nil
    end
end

function MPMissionHelper:updateClientVehicles(dt)
    if g_currentMission:getIsServer() or self.clientHidden == nil or NetworkUtil == nil or NetworkUtil.getObject == nil then
        return
    end
    for id, _ in pairs(self.clientHidden) do
        local v = NetworkUtil.getObject(id)
        if v ~= nil and not v.megaPatchHidden then
            MPMissionHelper.setVehicleHidden(v, true)
        end
    end
    for id, t in pairs(self.clientUnhide) do
        t = t - dt
        if t <= 0 then
            self.clientUnhide[id] = nil
            local v = NetworkUtil.getObject(id)
            if v ~= nil then
                MPMissionHelper.setVehicleHidden(v, false)
            end
        else
            self.clientUnhide[id] = t
        end
    end
end

function MPMissionHelper:sendInitialClientState(connection)
    connection:sendEvent(MPStateSyncEvent.new(MPMissionHelper.MODULE, self:getState()))
end

function MPMissionHelper:updateClient(dt)
    if not g_currentMission:getIsClient() then
        return
    end
    self:updateClientVehicles(dt)
    local farmId = MPUtil.getLocalFarmId()
    for uid, v in pairs(self.clientView) do
        if v.farmId == farmId then
            if v.phase == "travel" then
                local server = self.dispatches[uid]
                if server ~= nil and server.remaining ~= nil then
                    v.remaining = server.remaining
                else
                    v.remaining = math.max(0, v.remaining - dt * 0.001)
                end
                self:printText(MPUtil.getText("megaPatch_helper_hudTravel", v.field, MPMissionHelper.formatTime(v.remaining)))
            elseif v.phase == "settle" then
                self:printText(MPUtil.getText("megaPatch_helper_hudArrived", v.field))
            elseif v.phase == "waitStart" then
                self:printText(MPUtil.getText("megaPatch_helper_hudWaiting"))
            end
        end
    end
end

function MPMissionHelper:printText(text)
    if g_currentMission.addExtraPrintText ~= nil then
        g_currentMission:addExtraPrintText(text)
    end
end

function MPMissionHelper:isDispatched(mission)
    local uid = MPMissionHelper.getMissionUid(mission)
    if uid ~= nil and self.dispatches[uid] ~= nil then
        return true
    end
    if g_currentMission:getIsServer() then
        return uid ~= nil and self.clientView[uid] ~= nil
    end
    local oid = MPUtil.getNetId(mission)
    for _, v in pairs(self.clientView) do
        if oid ~= nil and v.oid == oid then
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------------------------------
-- zapis: trwajacy dojazd przetrwa zapis gry (maszyny zapisuja sie przy sklepie, po wczytaniu
-- znow znikaja i pomocnik jedzie dalej)

function MPMissionHelper:saveToXMLFile(xmlFile, key)
    local i = 0
    for uid, d in pairs(self.dispatches) do
        local phase = d.phase == "resume" and d.resumePhase or d.phase
        if (phase == "travel" or phase == "settle") and d.targetX ~= nil then
            local k = string.format("%s.helper.dispatch(%d)", key, i)
            xmlFile:setString(k .. "#mission", tostring(uid))
            xmlFile:setInt(k .. "#farmId", d.farmId)
            xmlFile:setString(k .. "#phase", phase)
            xmlFile:setFloat(k .. "#remaining", d.remaining or 0)
            xmlFile:setFloat(k .. "#total", d.total or 0)
            xmlFile:setFloat(k .. "#x", d.targetX)
            xmlFile:setFloat(k .. "#z", d.targetZ)
            xmlFile:setFloat(k .. "#yaw", d.targetYaw or 0)
            xmlFile:setFloat(k .. "#entryX", d.entryX or d.targetX)
            xmlFile:setFloat(k .. "#entryZ", d.entryZ or d.targetZ)
            xmlFile:setFloat(k .. "#distance", d.distance or 0)
            i = i + 1
        end
    end
end

function MPMissionHelper:loadFromXMLFile(xmlFile, key)
    self.dispatches = {}
    local i = 0
    while true do
        local k = string.format("%s.helper.dispatch(%d)", key, i)
        if not xmlFile:hasProperty(k) then
            break
        end
        local uid = xmlFile:getString(k .. "#mission")
        if uid ~= nil then
            local tx, tz = xmlFile:getFloat(k .. "#x", 0), xmlFile:getFloat(k .. "#z", 0)
            self.dispatches[uid] = {
                uid = uid, farmId = xmlFile:getInt(k .. "#farmId", 1), phase = "resume",
                resumePhase = xmlFile:getString(k .. "#phase", "travel"), timer = 0, retries = 0,
                remaining = xmlFile:getFloat(k .. "#remaining", 0), total = xmlFile:getFloat(k .. "#total", 0),
                targetX = tx, targetZ = tz, targetYaw = xmlFile:getFloat(k .. "#yaw", 0),
                entryX = xmlFile:getFloat(k .. "#entryX", tx), entryZ = xmlFile:getFloat(k .. "#entryZ", tz),
                distance = xmlFile:getFloat(k .. "#distance", 0)
            }
        end
        i = i + 1
    end
end

---------------------------------------------------------------------------------------------------
-- klient: okno potwierdzenia

function MPMissionHelper.canOffer(mission)
    if mission == nil or not MPMissionHelper.isSupported(mission) then
        return false
    end
    if mission.getIsReadyToStart ~= nil then
        if not mission:getIsReadyToStart() then
            return false
        end
    elseif MissionStatus ~= nil and mission.status ~= MissionStatus.CREATED then
        return false
    end
    if mission.vehiclesToLoad == nil or #mission.vehiclesToLoad == 0 then
        return false
    end
    local inst = MPMissionHelper.instance
    if inst ~= nil and inst:isDispatched(mission) then
        return false
    end
    return true
end

function MPMissionHelper.buildOfferText(mission)
    local lines = {}
    table.insert(lines, MPMissionHelper.getMissionLocation(mission))
    local reward = 0
    if mission.getReward ~= nil then
        local ok, r = pcall(mission.getReward, mission)
        if ok and r ~= nil then
            reward = r
        end
    end
    local vehicleCosts = 0
    if mission.getVehicleCosts ~= nil then
        local ok, c = pcall(mission.getVehicleCosts, mission)
        if ok and c ~= nil then
            vehicleCosts = c
        end
    end
    table.insert(lines, MPUtil.getText("megaPatch_helper_reward", MPUtil.formatMoney(reward), MPUtil.formatMoney(vehicleCosts)))

    local names = {}
    for _, info in ipairs(mission.vehiclesToLoad or {}) do
        local name = MPMissionHelper.getStoreItemName(info.filename)
        if name ~= nil then
            table.insert(names, name)
        end
    end
    if #names > 0 then
        table.insert(lines, MPUtil.getText("megaPatch_helper_vehicles", table.concat(names, ", ")))
    end

    local sx, sz = MPMissionHelper.getShopSpawnPosition()
    if sx ~= nil and mission.field ~= nil then
        local tx, tz = MPMissionHelper.getFieldTarget(mission.field, sx, sz)
        local distance = MathUtil.vector2Length(tx - sx, tz - sz)
        table.insert(lines, MPUtil.getText("megaPatch_helper_eta", MPMissionHelper.formatDistance(distance), MPMissionHelper.formatTime(MPMissionHelper.getTravelSeconds(distance))))
    else
        table.insert(lines, MPUtil.getText("megaPatch_helper_etaLater"))
    end

    table.insert(lines, "")
    table.insert(lines, MPUtil.getText("megaPatch_helper_how"))
    table.insert(lines, MPUtil.getText("megaPatch_helper_wage"))
    local key = MPMissionHelper.getMissionTypeKey(mission)
    if key == "harvest" then
        table.insert(lines, MPUtil.getText("megaPatch_helper_noteHarvest"))
    elseif key == "sow" or key == "fertilize" or key == "herbicide" or key == "spray" or key == "lime" then
        table.insert(lines, MPUtil.getText("megaPatch_helper_noteMaterial"))
    end
    table.insert(lines, MPUtil.getText("megaPatch_helper_noteTakeOver"))
    return table.concat(lines, "\n")
end

function MPMissionHelper.openDialog(mission)
    if not MPMissionHelper.canOffer(mission) then
        return
    end
    local uid = MPMissionHelper.getMissionUid(mission)
    MPFinanceDialog.show({
        layout = "wide",
        title = MPUtil.getText("megaPatch_helper_title", MPMissionHelper.getMissionTitle(mission)),
        getText = function()
            return MPMissionHelper.buildOfferText(mission)
        end,
        okText = MPUtil.getText("megaPatch_helper_send"),
        canOk = function()
            return MPMissionHelper.canOffer(mission)
        end,
        onOk = function()
            MPMissionHelper.sendDispatch(mission, uid)
        end
    })
end

function MPMissionHelper.sendDispatch(mission, uid)
    local farmId = MPUtil.getLocalFarmId()
    local canUseGameEvent = MissionStartEvent ~= nil and MissionStartEvent.new ~= nil and g_client ~= nil
    MPRequestEvent.sendRequest(MPMissionHelper.MODULE, "dispatch", {mission = uid, oid = MPUtil.getNetId(mission), startHere = not canUseGameEvent})
    if canUseGameEvent then
        -- ten sam start co przycisk "Akceptuj" z wypozyczeniem maszyn - menu gry dostaje zwykla odpowiedz
        g_client:getServerConnection():sendEvent(MissionStartEvent.new(mission, farmId, true))
    end
end

---------------------------------------------------------------------------------------------------
-- przycisk w menu Zlecenia

function MPMissionHelper.getSelectedMission(frame)
    if frame == nil or frame.contractsList == nil or frame.sectionContracts == nil or frame.subCategorySelector == nil then
        return nil
    end
    local section, index = frame.contractsList:getSelectedPath()
    local listType = frame.subCategorySelector:getState()
    local sections = frame.sectionContracts[listType]
    local sec = sections ~= nil and sections[section] or nil
    local contract = sec ~= nil and sec.contracts ~= nil and sec.contracts[index] or nil
    return contract ~= nil and contract.mission or nil
end

local BUTTON_ACTIONS = {"MENU_EXTRA_2", "MENU_EXTRA_1", "MENU_EXTRA_3", "MENU_ACTIVATE"}

function MPMissionHelper.onSetButtonsForState(frame, ...)
    local ok, err = pcall(MPMissionHelper.addContractsButton, frame)
    if not ok then
        Logging.warning("[MegaPatch] Przycisk pomocnika w zleceniach: %s", tostring(err))
    end
end

function MPMissionHelper.addContractsButton(frame)
    local buttons = frame.menuButtonInfo
    if buttons == nil then
        return
    end
    for i = #buttons, 1, -1 do
        if buttons[i] ~= nil and buttons[i].megaPatchHelper then
            table.remove(buttons, i)
        end
    end
    local mission = MPMissionHelper.getSelectedMission(frame)
    if not MPMissionHelper.canOffer(mission) then
        return
    end
    local used = {}
    for _, b in ipairs(buttons) do
        if b.inputAction ~= nil then
            used[b.inputAction] = true
        end
    end
    local action = nil
    for _, name in ipairs(BUTTON_ACTIONS) do
        local a = InputAction[name]
        if a ~= nil and not used[a] then
            action = a
            break
        end
    end
    if action == nil then
        return
    end
    table.insert(buttons, {
        megaPatchHelper = true,
        inputAction = action,
        text = MPUtil.getText("megaPatch_helper_button"),
        callback = function()
            MPMissionHelper.openDialog(MPMissionHelper.getSelectedMission(frame))
        end
    })
    if frame.setMenuButtonInfoDirty ~= nil then
        frame:setMenuButtonInfoDirty()
    end
end

function MPMissionHelper.installHooks()
    if InGameMenuContractsFrame ~= nil and InGameMenuContractsFrame.setButtonsForState ~= nil then
        InGameMenuContractsFrame.setButtonsForState = Utils.appendedFunction(InGameMenuContractsFrame.setButtonsForState, MPMissionHelper.onSetButtonsForState)
    else
        Logging.warning("[MegaPatch] Brak InGameMenuContractsFrame.setButtonsForState - przycisk pomocnika tylko z konsoli (mpHelperSend)")
    end
end

---------------------------------------------------------------------------------------------------
-- konsola

function MPMissionHelper:consoleInfo()
    local lines = {}
    for uid, d in pairs(self.dispatches) do
        table.insert(lines, string.format("%s: farma %s, etap %s, pozostalo %.0f s, pole %s", tostring(uid), tostring(d.farmId), tostring(d.phase), d.remaining or 0, tostring(d.fieldName)))
    end
    if #lines == 0 then
        table.insert(lines, "Brak aktywnych pomocnikow zlecen")
    end
    local count = 0
    for _, m in ipairs(g_missionManager ~= nil and g_missionManager:getMissions() or {}) do
        if MPMissionHelper.canOffer(m) then
            count = count + 1
        end
    end
    table.insert(lines, string.format("Zlecenia z mozliwoscia wyslania pomocnika: %d", count))
    return table.concat(lines, "\n")
end

-- mpHelperSend <nr pola>: to samo co przycisk w menu (do testow)
function MPMissionHelper:consoleSend(fieldName)
    for _, m in ipairs(g_missionManager ~= nil and g_missionManager:getMissions() or {}) do
        if MPMissionHelper.canOffer(m) and (fieldName == nil or MPMissionHelper.getFieldName(m.field) == tostring(fieldName)) then
            MPMissionHelper.sendDispatch(m, MPMissionHelper.getMissionUid(m))
            return string.format("Wyslano pomocnika: %s (%s)", MPMissionHelper.getMissionTitle(m), MPMissionHelper.getMissionLocation(m))
        end
    end
    return "Nie znaleziono zlecenia, do ktorego mozna wyslac pomocnika"
end
