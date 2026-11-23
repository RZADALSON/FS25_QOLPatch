-- FS25_MegaPatch: strony w menu gry (ESC): "Finansowanie" i "Fabryki (wynajem)"
-- Jedna klasa ramki, dwa "providery" danych.

MPInGameMenuFinanceFrame = {}
local MPInGameMenuFinanceFrame_mt = Class(MPInGameMenuFinanceFrame, TabbedMenuFrameElement)

local modDirectory = g_currentModDirectory

function MPInGameMenuFinanceFrame.new(provider)
    local self = MPInGameMenuFinanceFrame:superClass().new(nil, MPInGameMenuFinanceFrame_mt)
    self.provider = provider
    self.hasCustomMenuButtons = true
    self.sections = {}
    self.selected = nil
    return self
end

function MPInGameMenuFinanceFrame:initialize()
    self.backButtonInfo = {inputAction = InputAction.MENU_BACK}
    self.buttonA = {inputAction = InputAction.MENU_ACTIVATE, text = "", callback = function() self:onButton("A") end}
    self.buttonB = {inputAction = InputAction.MENU_EXTRA_1, text = "", callback = function() self:onButton("B") end}
    self.buttonC = {inputAction = InputAction.MENU_EXTRA_2, text = "", callback = function() self:onButton("C") end}
    self:updateButtons()
end

function MPInGameMenuFinanceFrame:onGuiSetupFinished()
    MPInGameMenuFinanceFrame:superClass().onGuiSetupFinished(self)
    self.financeTable:setDataSource(self)
    self.financeTable:setDelegate(self)
end

function MPInGameMenuFinanceFrame:onFrameOpen(element)
    MPInGameMenuFinanceFrame:superClass().onFrameOpen(self)
    self.pageTitle:setText(self.provider.title())
    local headers = self.provider.headers()
    for i = 1, 8 do
        local h = self["h" .. i]
        if h ~= nil then
            h:setText(headers[i] or "")
        end
    end
    self.provider.addListener(self, self.updateContent)
    self:updateContent()
    FocusManager:setFocus(self.financeTable)
end

function MPInGameMenuFinanceFrame:onFrameClose()
    MPInGameMenuFinanceFrame:superClass().onFrameClose(self)
    self.provider.removeListener(self)
end

function MPInGameMenuFinanceFrame:updateContent()
    if self.financeTable == nil then
        return
    end
    self.sections = self.provider.sections(MPUtil.getLocalFarmId())
    local total = 0
    for _, s in ipairs(self.sections) do
        total = total + #s.items
    end
    self.emptyText:setText(self.provider.emptyText())
    self.emptyText:setVisible(total == 0)
    self.infoText:setText(self.provider.info())
    self.financeTable:reloadData()
    self:updateSelection()
end

function MPInGameMenuFinanceFrame:updateSelection()
    local section = self.financeTable.selectedSectionIndex or 1
    local index = self.financeTable.selectedIndex or 1
    local s = self.sections[section]
    self.selected = s ~= nil and s.items[index] or nil
    self:updateButtons()
end

function MPInGameMenuFinanceFrame:onListSelectionChanged(list, section, index)
    local s = self.sections[section]
    self.selected = s ~= nil and s.items[index] or nil
    self:updateButtons()
end

function MPInGameMenuFinanceFrame:updateButtons()
    if self.backButtonInfo == nil then
        return
    end
    local info = {self.backButtonInfo}
    local actions = self.selected ~= nil and self.provider.actions(self.selected) or {}
    local map = {A = self.buttonA, B = self.buttonB, C = self.buttonC}
    for key, button in pairs(map) do
        local a = actions[key]
        button.action = a
        if a ~= nil then
            button.text = a.text
            button.disabled = a.disabled == true
        end
    end
    for _, key in ipairs({"A", "B", "C"}) do
        if actions[key] ~= nil then
            table.insert(info, map[key])
        end
    end
    self.menuButtonInfo = info
    self:setMenuButtonInfo(info)
    self:setMenuButtonInfoDirty()
end

function MPInGameMenuFinanceFrame:onButton(key)
    local button = ({A = self.buttonA, B = self.buttonB, C = self.buttonC})[key]
    print(string.format("[MegaPatch] Przycisk %s: akcja=%s, wylaczony=%s, wybrany=%s", key, tostring(button ~= nil and button.action ~= nil), tostring(button ~= nil and button.disabled), tostring(self.selected ~= nil)))
    if button ~= nil and button.action ~= nil and not button.disabled then
        button.action.run()
    end
end

-- DataSource
function MPInGameMenuFinanceFrame:getNumberOfSections()
    return math.max(1, #self.sections)
end

function MPInGameMenuFinanceFrame:getNumberOfItemsInSection(list, section)
    local s = self.sections[section]
    return s ~= nil and #s.items or 0
end

function MPInGameMenuFinanceFrame:getTitleForSectionHeader(list, section)
    local s = self.sections[section]
    return s ~= nil and s.title or ""
end

function MPInGameMenuFinanceFrame:populateCellForItemInSection(list, section, index, cell)
    local s = self.sections[section]
    local item = s ~= nil and s.items[index] or nil
    if item == nil then
        return
    end
    local cols = self.provider.row(item)
    for i = 1, 8 do
        local c = cell:getAttribute("c" .. i)
        if c ~= nil then
            c:setText(cols[i] or "")
        end
    end
end

---------------------------------------------------------------------------------------------------
-- rejestracja stron w menu

local function addPage(frame, pageName, iconFile, afterPageName)
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
        return
    end
    inGameMenu.controlIDs[pageName] = nil
    inGameMenu[pageName] = frame
    inGameMenu.pagingElement:addElement(frame)
    inGameMenu:exposeControlsAsFields(pageName)

    local position = #inGameMenu.pagingElement.elements
    local after = afterPageName ~= nil and inGameMenu[afterPageName] or nil
    for i, el in ipairs(inGameMenu.pagingElement.elements) do
        if after ~= nil and el == after then
            position = i + 1
            break
        end
    end

    for i = 1, #inGameMenu.pagingElement.elements do
        if inGameMenu.pagingElement.elements[i] == frame then
            table.remove(inGameMenu.pagingElement.elements, i)
            table.insert(inGameMenu.pagingElement.elements, math.min(position, #inGameMenu.pagingElement.elements + 1), frame)
            break
        end
    end
    for i = 1, #inGameMenu.pagingElement.pages do
        local page = inGameMenu.pagingElement.pages[i]
        if page.element == frame then
            table.remove(inGameMenu.pagingElement.pages, i)
            table.insert(inGameMenu.pagingElement.pages, math.min(position, #inGameMenu.pagingElement.pages + 1), page)
            break
        end
    end
    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()

    inGameMenu:registerPage(frame, position, function()
        return g_currentMission ~= nil and MPUtil.getLocalFarmId() ~= FarmManager.SPECTATOR_FARM_ID
    end)
    inGameMenu:addPageTab(frame, Utils.getFilename(iconFile, modDirectory), GuiUtils.getUVs({0, 0, 1024, 1024}))

    for i = 1, #inGameMenu.pageFrames do
        if inGameMenu.pageFrames[i] == frame then
            table.remove(inGameMenu.pageFrames, i)
            table.insert(inGameMenu.pageFrames, math.min(position, #inGameMenu.pageFrames + 1), frame)
            break
        end
    end
    inGameMenu:rebuildTabList()
end

function MPInGameMenuFinanceFrame.register()
    if MPInGameMenuFinanceFrame.registered then
        return
    end
    MPInGameMenuFinanceFrame.registered = true
    MPFinanceDialog.register()

    local financeFrame = MPInGameMenuFinanceFrame.new(MPFinanceProvider)
    g_gui:loadGui(modDirectory .. "gui/MPInGameMenuFrame.xml", "MPInGameMenuFinance", financeFrame, true)
    financeFrame:initialize()
    addPage(financeFrame, "mpPageFinance", "images/menuIconFinance.dds", "pageStatistics")

    local productionFrame = MPInGameMenuFinanceFrame.new(MPProductionProvider)
    g_gui:loadGui(modDirectory .. "gui/MPInGameMenuFrame.xml", "MPInGameMenuProduction", productionFrame, true)
    productionFrame:initialize()
    addPage(productionFrame, "mpPageProduction", "images/menuIconFactory.dds", "pageProduction")
end

---------------------------------------------------------------------------------------------------
-- provider: finansowanie pojazdow

MPFinanceProvider = {}

function MPFinanceProvider.title()
    return MPUtil.getText("megaPatch_finance_pageTitle")
end

function MPFinanceProvider.emptyText()
    return MPUtil.getText("megaPatch_finance_empty")
end

function MPFinanceProvider.info()
    local fuel = MegaPatch.fuel
    if fuel == nil then
        return ""
    end
    local pct = (fuel.factor - 1) * 100
    return MPUtil.getText("megaPatch_fuel_headerInfo", g_i18n:formatMoney(fuel:getDieselPrice(), 2, true, true), string.format("%+.1f", pct))
end

function MPFinanceProvider.headers()
    return {
        MPUtil.getText("megaPatch_finance_colVehicle"), MPUtil.getText("megaPatch_finance_colStatus"),
        MPUtil.getText("megaPatch_finance_colPrice"), MPUtil.getText("megaPatch_finance_colLeasePaid"),
        MPUtil.getText("megaPatch_finance_colBalance"), MPUtil.getText("megaPatch_finance_colInstallment"),
        MPUtil.getText("megaPatch_finance_colArrears"), MPUtil.getText("megaPatch_finance_colMonths")
    }
end

function MPFinanceProvider.addListener(target, func)
    if MegaPatch.finance ~= nil then
        MegaPatch.finance:addChangeListener(func, target)
    end
end

function MPFinanceProvider.removeListener(target)
    if MegaPatch.finance ~= nil then
        MegaPatch.finance:removeChangeListener(target)
    end
end

function MPFinanceProvider.sections(farmId)
    local finance = MegaPatch.finance
    if finance == nil then
        return {}
    end
    local leased, financed = finance:getFarmEntries(farmId)
    return {
        {title = MPUtil.getText("megaPatch_finance_sectionLeased"), items = leased},
        {title = MPUtil.getText("megaPatch_finance_sectionFinanced"), items = financed}
    }
end

function MPFinanceProvider.row(item)
    local finance = MegaPatch.finance
    local name = MPUtil.getVehicleName(item.vehicle)
    local price = item.vehicle:getPrice() or 0
    if item.contract == nil then
        return {
            name, MPUtil.getText("megaPatch_finance_statusLeased"), MPUtil.formatMoney(price),
            (item.est and "~" or "") .. MPUtil.formatMoney(item.paid), "-", "-", "-", "-"
        }
    end
    local c = item.contract
    local status = MPUtil.getText("megaPatch_finance_statusOk")
    if c.missed > 0 then
        status = MPUtil.getText("megaPatch_finance_statusLate", tostring(c.missed))
    end
    return {
        name, status, MPUtil.formatMoney(c.price), MPUtil.formatMoney(c.credit), MPUtil.formatMoney(c.balance),
        MPUtil.formatMoney(c.installment), c.arrears > 0 and MPUtil.formatMoney(c.arrears) or "-",
        tostring(finance:getRemainingMonths(c))
    }
end

function MPFinanceProvider.actions(item)
    if item.contract == nil then
        return {A = {text = MPUtil.getText("megaPatch_finance_btnFinance"), run = function() MPFinanceProvider.openQuote(item) end}}
    end
    local c = item.contract
    return {
        B = {text = MPUtil.getText("megaPatch_finance_btnPayArrears"), disabled = c.arrears <= 0, run = function() MPFinanceProvider.confirmPayArrears(item) end},
        C = {text = MPUtil.getText("megaPatch_finance_btnPayOff"), run = function() MPFinanceProvider.confirmPayOff(item) end}
    }
end

function MPFinanceProvider.getVehicleDetails(vehicle, extraLines)
    local lines = {MPUtil.getText("megaPatch_ui_vehicle", MPUtil.getVehicleName(vehicle))}
    table.insert(lines, MPUtil.getText("megaPatch_ui_price", MPUtil.formatMoney(vehicle:getPrice() or 0)))
    if vehicle.age ~= nil then
        table.insert(lines, MPUtil.getText("megaPatch_ui_age", tostring(math.floor(vehicle.age))))
    end
    if vehicle.operatingTime ~= nil then
        table.insert(lines, MPUtil.getText("megaPatch_ui_hours", string.format("%.1f", vehicle.operatingTime / 3600000)))
    end
    if vehicle.getSellPrice ~= nil then
        local ok, v = pcall(vehicle.getSellPrice, vehicle)
        if ok and v ~= nil then
            table.insert(lines, MPUtil.getText("megaPatch_ui_value", MPUtil.formatMoney(v)))
        end
    end
    for _, l in ipairs(extraLines or {}) do
        table.insert(lines, l)
    end
    return table.concat(lines, "\n")
end

function MPFinanceProvider.openQuote(item)
    local finance = MegaPatch.finance
    local state = {term = MPVehicleFinance.DEFAULT_TERM_INDEX, down = MPVehicleFinance.DEFAULT_DOWN_INDEX}
    local function quote()
        return finance:getQuote(item.vehicle, state.term, state.down)
    end
    local termTexts, downTexts = {}, {}
    for i, t in ipairs(MPVehicleFinance.TERMS) do
        termTexts[i] = MPUtil.getText("megaPatch_ui_months", tostring(t))
    end
    for i, d in ipairs(MPVehicleFinance.DOWN_PAYMENTS) do
        downTexts[i] = string.format("%d %%", math.floor(d * 100 + 0.5))
    end
    MPFinanceDialog.show({
        layout = "split",
        title = MPUtil.getText("megaPatch_finance_dialogTitle", MPUtil.getVehicleName(item.vehicle)),
        image = MPFinanceProvider.getVehicleImage(item.vehicle),
        getDetails = function()
            local q = quote()
            local credit = "-" .. MPUtil.formatMoney(q.credit) .. (q.creditEstimated and (" " .. MPUtil.getText("megaPatch_ui_estimated")) or "")
            return MPFinanceProvider.getVehicleDetails(item.vehicle, {"", MPUtil.getText("megaPatch_finance_qCredit", credit)})
        end,
        sliders = {
            {label = function() return MPUtil.getText("megaPatch_ui_termLabel") end, texts = termTexts, state = state.term,
             onChange = function(i) state.term = i end},
            {label = function() return MPUtil.getText("megaPatch_ui_downLabel", MPUtil.formatMoney(quote().down)) end, texts = downTexts, state = state.down,
             onChange = function(i) state.down = i end},
        },
        getText = function()
            local q = quote()
            local money = MPUtil.getFarmMoney(MPUtil.getLocalFarmId())
            local lines = {}
            if q.isBuyout then
                table.insert(lines, MPUtil.getText("megaPatch_finance_qBuyout", MPUtil.formatMoney(q.upfront)))
            else
                table.insert(lines, MPUtil.getText("megaPatch_finance_qInstallment", MPUtil.formatMoney(q.installment)))
                table.insert(lines, "")
                table.insert(lines, MPUtil.getText("megaPatch_finance_qPrincipal", MPUtil.formatMoney(q.principal)))
                table.insert(lines, MPUtil.getText("megaPatch_ui_apr", string.format("%.2f", q.apr * 100)))
                table.insert(lines, MPUtil.getText("megaPatch_finance_qFee", MPUtil.formatMoney(q.fee)))
                table.insert(lines, MPUtil.getText("megaPatch_finance_qUpfront", MPUtil.formatMoney(q.upfront)))
                table.insert(lines, MPUtil.getText("megaPatch_finance_qTotal", MPUtil.formatMoney(q.total)))
                table.insert(lines, "")
                table.insert(lines, MPUtil.getText("megaPatch_finance_qRules", tostring(MPVehicleFinance.REPOSSESS_AFTER)))
            end
            if money < q.upfront then
                table.insert(lines, "")
                table.insert(lines, MPUtil.getText("megaPatch_finance_qNoMoney") .. " (" .. MPUtil.formatMoney(money) .. ")")
            end
            return table.concat(lines, "\n")
        end,
        okText = MPUtil.getText("megaPatch_finance_sign"),
        canOk = function()
            return MPUtil.getFarmMoney(MPUtil.getLocalFarmId()) >= quote().upfront
        end,
        onOk = function()
            MPRequestEvent.sendRequest(MPVehicleFinance.MODULE, "start", {uid = item.uid, oid = MPUtil.getNetId(item.vehicle), termIndex = state.term, downIndex = state.down})
        end,
        -- zapas, gdyby suwaki nie zaladowaly sie w tej wersji gry
        optionA = {
            fallbackOnly = true,
            getLabel = function()
                return MPUtil.getText("megaPatch_finance_btnTerm", tostring(MPVehicleFinance.TERMS[state.term]))
            end,
            onClick = function()
                state.term = state.term % #MPVehicleFinance.TERMS + 1
            end
        },
        optionB = {
            fallbackOnly = true,
            getLabel = function()
                return MPUtil.getText("megaPatch_finance_btnDown", string.format("%d", MPVehicleFinance.DOWN_PAYMENTS[state.down] * 100))
            end,
            onClick = function()
                state.down = state.down % #MPVehicleFinance.DOWN_PAYMENTS + 1
            end
        }
    })
end

function MPFinanceProvider.getVehicleImage(vehicle)
    if vehicle == nil then
        return nil
    end
    if vehicle.getImageFilename ~= nil then
        local ok, img = pcall(vehicle.getImageFilename, vehicle)
        if ok and img ~= nil and img ~= "" then
            return img
        end
    end
    local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    return storeItem ~= nil and storeItem.imageFilename or nil
end

function MPFinanceProvider.getContractDetails(item)
    local c = item.contract
    return MPFinanceProvider.getVehicleDetails(item.vehicle, {
        "",
        MPUtil.getText("megaPatch_finance_colBalance") .. ": " .. MPUtil.formatMoney(c.balance),
        MPUtil.getText("megaPatch_finance_colInstallment") .. ": " .. MPUtil.formatMoney(c.installment),
        MPUtil.getText("megaPatch_finance_colArrears") .. ": " .. MPUtil.formatMoney(c.arrears),
        MPUtil.getText("megaPatch_finance_colMonths") .. ": " .. tostring(MegaPatch.finance:getRemainingMonths(c))
    })
end

function MPFinanceProvider.confirmPayArrears(item)
    local c = item.contract
    MPFinanceDialog.show({
        layout = "split",
        title = MPUtil.getVehicleName(item.vehicle),
        image = MPFinanceProvider.getVehicleImage(item.vehicle),
        getDetails = function() return MPFinanceProvider.getContractDetails(item) end,
        getText = function()
            return MPUtil.getText("megaPatch_finance_confirmArrears", MPUtil.formatMoney(math.min(c.arrears, c.balance)))
        end,
        okText = MPUtil.getText("megaPatch_finance_btnPayArrears"),
        onOk = function()
            MPRequestEvent.sendRequest(MPVehicleFinance.MODULE, "payArrears", {uid = item.uid, oid = MPUtil.getNetId(item.vehicle)})
        end
    })
end

function MPFinanceProvider.confirmPayOff(item)
    local c = item.contract
    local amount = MegaPatch.finance:getPayOffAmount(c)
    MPFinanceDialog.show({
        layout = "split",
        title = MPUtil.getVehicleName(item.vehicle),
        image = MPFinanceProvider.getVehicleImage(item.vehicle),
        getDetails = function() return MPFinanceProvider.getContractDetails(item) end,
        getText = function()
            return MPUtil.getText("megaPatch_finance_confirmPayOff", MPUtil.formatMoney(c.balance), MPUtil.formatMoney(amount - c.balance), MPUtil.formatMoney(amount))
        end,
        okText = MPUtil.getText("megaPatch_finance_btnPayOff"),
        canOk = function()
            return MPUtil.getFarmMoney(MPUtil.getLocalFarmId()) >= amount
        end,
        onOk = function()
            MPRequestEvent.sendRequest(MPVehicleFinance.MODULE, "payOff", {uid = item.uid, oid = MPUtil.getNetId(item.vehicle)})
        end
    })
end

---------------------------------------------------------------------------------------------------
-- provider: fabryki

MPProductionProvider = {}

function MPProductionProvider.title()
    return MPUtil.getText("megaPatch_prod_pageTitle")
end

function MPProductionProvider.emptyText()
    return MPUtil.getText("megaPatch_prod_empty")
end

function MPProductionProvider.info()
    return MPUtil.getText("megaPatch_prod_headerInfo", tostring(MPProductionRental.BREAK_EVEN_YEARS))
end

function MPProductionProvider.headers()
    return {
        MPUtil.getText("megaPatch_prod_colName"), MPUtil.getText("megaPatch_finance_colStatus"),
        MPUtil.getText("megaPatch_prod_colPrice"), MPUtil.getText("megaPatch_prod_colRate"),
        MPUtil.getText("megaPatch_prod_colFeesTotal"), MPUtil.getText("megaPatch_prod_colLastMonth"),
        MPUtil.getText("megaPatch_prod_colValue"), MPUtil.getText("megaPatch_prod_colBreakEven")
    }
end

function MPProductionProvider.addListener(target, func)
    if MegaPatch.production ~= nil then
        MegaPatch.production:addChangeListener(func, target)
    end
end

function MPProductionProvider.removeListener(target)
    if MegaPatch.production ~= nil then
        MegaPatch.production:removeChangeListener(target)
    end
end

function MPProductionProvider.sections(farmId)
    local prod = MegaPatch.production
    if prod == nil then
        return {}
    end
    local rented, available, owned = prod:getEntries(farmId)
    return {
        {title = MPUtil.getText("megaPatch_prod_sectionRented"), items = rented},
        {title = MPUtil.getText("megaPatch_prod_sectionAvailable"), items = available},
        {title = MPUtil.getText("megaPatch_prod_sectionOwned"), items = owned}
    }
end

function MPProductionProvider.row(item)
    local name = MPProductionRental.getName(item.pp)
    local dist = MPProductionRental.formatDistance(MPProductionRental.getDistance(item.pp))
    if dist ~= "" then
        name = name .. "  (" .. dist .. ")"
    end
    if item.owned then
        return {name, MPUtil.getText("megaPatch_prod_statusOwned"), "-", "-", "-", "-", "-", "-"}
    end
    if item.rental ~= nil then
        local r = item.rental
        local years = MegaPatch.production:getBreakEvenYears(r)
        return {
            name, MPUtil.getText("megaPatch_prod_statusRented"), MPUtil.formatMoney(r.price),
            string.format("%.1f %%", r.rate * 100), MPUtil.formatMoney(r.feesTotal),
            MPUtil.formatMoney(r.lastMonthFee > 0 and r.lastMonthFee or r.monthFee), MPUtil.formatMoney(r.valueTotal),
            years ~= nil and string.format("%.1f", years) or "-"
        }
    end
    local o = item.offer
    return {
        name, MPUtil.getText("megaPatch_prod_statusAvailable"), MPUtil.formatMoney(o.price),
        string.format("%.1f %%", o.rate * 100), "-", MPUtil.formatMoney(o.feeAtReference), "-",
        tostring(MPProductionRental.BREAK_EVEN_YEARS)
    }
end

function MPProductionProvider.actions(item)
    local uid = MPProductionRental.getPlaceableUid(item.pp)
    local mapAction = {text = MPUtil.getText("megaPatch_prod_showOnMap"), run = function() MPProductionRental.showOnMap(item.pp) end}
    if item.owned then
        return {A = mapAction}
    end
    if item.rental == nil then
        return {C = mapAction, A = {text = MPUtil.getText("megaPatch_prod_rent"), run = function()
            MPProductionRental.showRentOrBuyDialog(item.pp, function()
                MPProductionRental.callOriginalBuy(item.pp)
            end)
        end}}
    end
    return {
        A = mapAction,
        B = {text = MPUtil.getText("megaPatch_prod_buy"), run = function()
            local price = MegaPatch.production:getBuyPrice(item.pp, MPUtil.getLocalFarmId())
            MPFinanceDialog.show({
                layout = "split",
                title = MPProductionRental.getName(item.pp),
                image = MPProductionRental.getImage(item.pp),
                getDetails = function() return MPProductionRental.getDetails(item.pp, item.rental) end,
                getText = function() return MPUtil.getText("megaPatch_prod_confirmBuy", MPUtil.formatMoney(price), MPUtil.formatMoney(item.rental.feesTotal)) end,
                okText = MPUtil.getText("megaPatch_prod_buy"),
                canOk = function() return MPUtil.getFarmMoney(MPUtil.getLocalFarmId()) >= price end,
                onOk = function() MPRequestEvent.sendRequest(MPProductionRental.MODULE, "buy", MPProductionRental.getRequestData(item.pp)) end
            })
        end},
        C = {text = MPUtil.getText("megaPatch_prod_end"), run = function()
            MPFinanceDialog.show({
                layout = "split",
                title = MPProductionRental.getName(item.pp),
                image = MPProductionRental.getImage(item.pp),
                getDetails = function() return MPProductionRental.getDetails(item.pp, item.rental) end,
                getText = function() return MPUtil.getText("megaPatch_prod_confirmEnd") end,
                okText = MPUtil.getText("megaPatch_prod_end"),
                onOk = function() MPRequestEvent.sendRequest(MPProductionRental.MODULE, "end", MPProductionRental.getRequestData(item.pp)) end
            })
        end}
    }
end
