-- FS25_MegaPatch: main loader
-- Moduly: FuelMarket (dynamiczne ceny paliw + IBC diesel), VehicleFinance (finansowanie pojazdow),
--         ProductionRental (korzystanie z fabryk bez kupowania).

MegaPatch = {}
MegaPatch.MOD_NAME = g_currentModName
MegaPatch.MOD_DIR = g_currentModDirectory
MegaPatch.SAVE_FILE = "megaPatch.xml"
MegaPatch.modules = {}

local dir = g_currentModDirectory
source(dir .. "scripts/MegaPatchUtil.lua")
source(dir .. "scripts/MegaPatchEvents.lua")
source(dir .. "scripts/fuel/FuelMarket.lua")
source(dir .. "scripts/finance/VehicleFinance.lua")
source(dir .. "scripts/finance/FinanceDialog.lua")
source(dir .. "scripts/finance/InGameMenuFinanceFrame.lua")
source(dir .. "scripts/production/ProductionRental.lua")
source(dir .. "scripts/sleep/SleepForecast.lua")
source(dir .. "scripts/sleep/LongSleep.lua")
source(dir .. "scripts/construction/ConstructionTools.lua")
source(dir .. "scripts/construction/PaintDecals.lua")
source(dir .. "scripts/missions/MissionHelper.lua")

function MegaPatch:loadMap(filename)
    self.isServer = g_currentMission:getIsServer()
    self.isClient = g_currentMission:getIsClient()

    self.fuel = MPFuelMarket.new(self)
    self.finance = MPVehicleFinance.new(self)
    self.production = MPProductionRental.new(self)
    self.sleep = MPLongSleep.new(self)
    self.construction = MPConstructionTools.new(self)
    self.paints = MPPaintDecals.new(self)
    self.helper = MPMissionHelper.new(self)
    self.modules = {self.fuel, self.finance, self.production, self.sleep, self.construction, self.paints, self.helper}

    for _, m in ipairs(self.modules) do
        m:loadMap()
    end

    if self.isServer then
        self:loadFromSavegame()
    end

    addConsoleCommand("mpFuelInfo", "MegaPatch: pokaz rynek paliw", "consoleFuelInfo", self.fuel)
    addConsoleCommand("mpFuelSetFactor", "MegaPatch: ustaw mnoznik ceny paliwa (np. 1.2)", "consoleFuelSetFactor", self.fuel)
    addConsoleCommand("mpFinanceInfo", "MegaPatch: pokaz umowy finansowania", "consoleFinanceInfo", self.finance)
    addConsoleCommand("mpFinanceForceMonth", "MegaPatch: wymus rozliczenie miesieczne finansowania", "consoleForceMonth", self.finance)
    addConsoleCommand("mpProductionInfo", "MegaPatch: pokaz wynajmowane fabryki", "consoleInfo", self.production)
    addConsoleCommand("mpPaintOrient", "MegaPatch: orientacja obrazu farb 0-7 (gdy kafelki sa poprzestawiane)", "consoleOrientation", self.paints)
    addConsoleCommand("mpDiag", "MegaPatch: zapisz API budowy/snu do log.txt", "consoleDiag", self.construction)
    addConsoleCommand("mpTrace", "MegaPatch: loguj wywolania pedzli budowy (diagnostyka)", "consoleTrace", self.construction)
    addConsoleCommand("mpHelperInfo", "MegaPatch: pomocnicy wyslani do zlecen", "consoleInfo", self.helper)
    addConsoleCommand("mpHelperSend", "MegaPatch: wyslij pomocnika do zlecenia [nr pola]", "consoleSend", self.helper)
    addConsoleCommand("mpLongSleep", "MegaPatch: prognoza (bez parametru) albo dlugi sen N miesiecy", "consoleLongSleep", self.sleep)
end

function MegaPatch:deleteMap()
    removeConsoleCommand("mpFuelInfo")
    removeConsoleCommand("mpFuelSetFactor")
    removeConsoleCommand("mpFinanceInfo")
    removeConsoleCommand("mpFinanceForceMonth")
    removeConsoleCommand("mpProductionInfo")
    removeConsoleCommand("mpLongSleep")
    removeConsoleCommand("mpDiag")
    removeConsoleCommand("mpPaintOrient")
    removeConsoleCommand("mpTrace")
    removeConsoleCommand("mpHelperInfo")
    removeConsoleCommand("mpHelperSend")
    for _, m in ipairs(self.modules) do
        if m.delete ~= nil then
            m:delete()
        end
    end
    self.modules = {}
    g_messageCenter:unsubscribeAll(self)
end

function MegaPatch:update(dt)
    for _, m in ipairs(self.modules) do
        if m.update ~= nil then
            m:update(dt)
        end
    end
end

function MegaPatch:draw()
    for _, m in ipairs(self.modules) do
        if m.draw ~= nil then
            m:draw()
        end
    end
end

function MegaPatch:onStartMission()
    for _, m in ipairs(self.modules) do
        if m.onStartMission ~= nil then
            m:onStartMission()
        end
    end
end

-- Zapis: jeden plik megaPatch.xml w katalogu zapisu gry. Nie modyfikujemy plikow gry,
-- wiec usuniecie moda nie psuje zapisu.
function MegaPatch:getSavegamePath()
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if missionInfo ~= nil and missionInfo.savegameDirectory ~= nil then
        return missionInfo.savegameDirectory .. "/" .. MegaPatch.SAVE_FILE
    end
    return nil
end

function MegaPatch:loadFromSavegame()
    local path = self:getSavegamePath()
    if path == nil or not fileExists(path) then
        return
    end
    local xmlFile = XMLFile.load("megaPatchXML", path)
    if xmlFile == nil then
        return
    end
    for _, m in ipairs(self.modules) do
        if m.loadFromXMLFile ~= nil then
            m:loadFromXMLFile(xmlFile, "megaPatch")
        end
    end
    xmlFile:delete()
end

function MegaPatch:saveToSavegame()
    local path = self:getSavegamePath()
    if path == nil then
        return
    end
    local xmlFile = XMLFile.create("megaPatchXML", path, "megaPatch")
    if xmlFile == nil then
        return
    end
    xmlFile:setInt("megaPatch#version", 1)
    for _, m in ipairs(self.modules) do
        if m.saveToXMLFile ~= nil then
            m:saveToXMLFile(xmlFile, "megaPatch")
        end
    end
    xmlFile:save()
    xmlFile:delete()
end

-- wysylka stanu do nowo dolaczajacego gracza (MP)
function MegaPatch.sendInitialClientState(mission, connection, user, farm)
    for _, m in ipairs(MegaPatch.modules) do
        if m.sendInitialClientState ~= nil then
            m:sendInitialClientState(connection)
        end
    end
end

local function onSaveCareer(missionInfo)
    if g_currentMission ~= nil and g_currentMission:getIsServer() and MegaPatch.fuel ~= nil then
        MegaPatch:saveToSavegame()
    end
end

local function onStartMission()
    MegaPatch:onStartMission()
end

local function init()
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, onSaveCareer)
    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, onStartMission)
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, MegaPatch.sendInitialClientState)

    MPFuelMarket.installHooks()
    MPVehicleFinance.installHooks()
    MPProductionRental.installHooks()
    MPLongSleep.installHooks()
    MPConstructionTools.installHooks()
    MPPaintDecals.installHooks()
    MPMissionHelper.installHooks()

    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
        MPInGameMenuFinanceFrame.register()
    end)
end

init()
addModEventListener(MegaPatch)
