-- FS25_MegaPatch: uniwersalny dialog (oferta finansowania / potwierdzenia)
-- Przyciski: OK (Enter) = zatwierdz, Activate = opcja A (np. okres), Cancel = opcja B (np. wklad), Back = zamknij

MPFinanceDialog = {}
local MPFinanceDialog_mt = Class(MPFinanceDialog, MessageDialog)

MPFinanceDialog.GUI_NAME = "MPFinanceDialog"

function MPFinanceDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or MPFinanceDialog_mt)
    self.config = nil
    return self
end

function MPFinanceDialog.isRegistered()
    return g_gui ~= nil and g_gui.guis ~= nil and g_gui.guis[MPFinanceDialog.GUI_NAME] ~= nil
        and MPFinanceDialog.INSTANCE ~= nil
end

function MPFinanceDialog.register()
    if MPFinanceDialog.isRegistered() then
        return
    end
    local dialog = MPFinanceDialog.new()
    local gui = g_gui:loadGui(MegaPatch.MOD_DIR .. "gui/MPFinanceDialog.xml", MPFinanceDialog.GUI_NAME, dialog)
    MPFinanceDialog.INSTANCE = dialog
    print(string.format("[MegaPatch] Dialog zaladowany: gui=%s, zarejestrowany=%s", tostring(gui), tostring(MPFinanceDialog.isRegistered())))
end

-- config = {
--   title = string, getText = function() -> string, okText = string, onOk = function(),
--   optionA = {getLabel = function() -> string, onClick = function()} (optional),
--   optionB = {...} (optional), canOk = function() -> bool (optional)
-- }
function MPFinanceDialog.show(config)
    MPFinanceDialog.register()
    local dialog = MPFinanceDialog.INSTANCE
    dialog.config = config
    local gui = g_gui:showDialog(MPFinanceDialog.GUI_NAME)
    if gui == nil or not dialog.mpIsOpen then
        -- rejestr okien mogl zostac przebudowany przez gre - ladujemy jeszcze raz
        print("[MegaPatch] Dialog nie otworzyl sie, ponowne ladowanie")
        MPFinanceDialog.INSTANCE = nil
        if g_gui.guis ~= nil then
            g_gui.guis[MPFinanceDialog.GUI_NAME] = nil
        end
        MPFinanceDialog.register()
        dialog = MPFinanceDialog.INSTANCE
        dialog.config = config
        gui = g_gui:showDialog(MPFinanceDialog.GUI_NAME)
        print(string.format("[MegaPatch] Drugie otwarcie: gui=%s, otwarty=%s", tostring(gui), tostring(dialog.mpIsOpen)))
    end
    if not dialog.mpIsOpen and gui ~= nil and g_gui.dialogs ~= nil then
        for _, d in ipairs(g_gui.dialogs) do
            if d == gui then
                dialog.mpIsOpen = true
                dialog:initSliders()
                dialog:refresh()
            end
        end
    end
    return dialog.mpIsOpen == true
end

function MPFinanceDialog:onOpen()
    MPFinanceDialog:superClass().onOpen(self)
    self.mpIsOpen = true
    print("[MegaPatch] Dialog otwarty: " .. tostring(self.config ~= nil and self.config.title or "?"))
    if self.config ~= nil then
        self:initSliders()
    end
    self:refresh()
end

function MPFinanceDialog:onClose()
    MPFinanceDialog:superClass().onClose(self)
    self.mpIsOpen = false
end

-- obrazek z pliku na calej powierzchni (profil bazowy gry ustawia wycinek atlasu UI)
function MPFinanceDialog.setFullImage(element, filename)
    if element.setImageFilename == nil then
        return
    end
    if element.overlay ~= nil then
        element.overlay.sliceId = nil
    end
    element:setImageFilename(filename)
    local uvs = Overlay ~= nil and Overlay.DEFAULT_UVS or {0, 0, 0, 1, 1, 0, 1, 1}
    if element.setImageUVs ~= nil then
        local states = {nil}
        if GuiOverlay ~= nil then
            for _, st in ipairs({GuiOverlay.STATE_NORMAL, GuiOverlay.STATE_DISABLED, GuiOverlay.STATE_FOCUSED, GuiOverlay.STATE_SELECTED, GuiOverlay.STATE_HIGHLIGHTED, GuiOverlay.STATE_PRESSED}) do
                if st ~= nil then
                    table.insert(states, st)
                end
            end
        end
        element:setImageUVs(nil, unpack(uvs))
        for _, st in ipairs(states) do
            pcall(element.setImageUVs, element, st, unpack(uvs))
        end
    end
    if element.setImageColor ~= nil then
        element:setImageColor(nil, 1, 1, 1, 1)
    end
end

local function setVisible(element, visible)
    if element ~= nil then
        element:setVisible(visible)
    end
end

local function setText(element, text)
    if element ~= nil then
        element:setText(text or "")
    end
end

-- suwak: dane z config.sliders[i] = {label = string|function, texts = {...}, state = n, onChange = function(n)}
function MPFinanceDialog:setupSlider(element, labelElement, def)
    if element == nil then
        return false
    end
    if def == nil then
        setVisible(element, false)
        setVisible(labelElement, false)
        return true
    end
    setVisible(element, true)
    setVisible(labelElement, true)
    local label = type(def.label) == "function" and def.label() or def.label
    setText(labelElement, label)
    if element.setTexts ~= nil then
        element:setTexts(def.texts)
        element:setState(def.state or 1, false)
    end
    return true
end

-- przy otwarciu: ustawienie suwakow (tylko raz, potem uzytkownik je przesuwa)
function MPFinanceDialog:initSliders()
    local cfg = self.config
    local sliders = cfg.sliders or {}
    local ok = true
    if cfg.layout == "split" then
        ok = self:setupSlider(self.slider1, self.sliderLabel1, sliders[1]) and ok
        ok = self:setupSlider(self.slider2, self.sliderLabel2, sliders[2]) and ok
        setVisible(self.wideSlider, false)
        setVisible(self.wideSliderLabel, false)
    else
        ok = self:setupSlider(self.wideSlider, self.wideSliderLabel, sliders[1]) and ok
        setVisible(self.slider1, false)
        setVisible(self.slider2, false)
        setVisible(self.sliderLabel1, false)
        setVisible(self.sliderLabel2, false)
    end
    -- brak elementu suwaka w tej wersji gry -> przyciski jako zapas
    self.slidersAvailable = ok
end

function MPFinanceDialog:onSliderChanged(index, element, state)
    local cfg = self.config
    local def = cfg ~= nil and cfg.sliders ~= nil and cfg.sliders[index] or nil
    if def == nil then
        return
    end
    if type(state) ~= "number" and element ~= nil and element.getState ~= nil then
        state = element:getState()
    end
    def.state = state
    if def.onChange ~= nil then
        def.onChange(state)
    end
    self:refresh()
end

function MPFinanceDialog:onSlider1Changed(state, element)
    self:onSliderChanged(1, element or self.slider1, state)
end

function MPFinanceDialog:onSlider2Changed(state, element)
    self:onSliderChanged(2, element or self.slider2, state)
end

function MPFinanceDialog:onWideSliderChanged(state, element)
    self:onSliderChanged(1, element or self.wideSlider, state)
end

function MPFinanceDialog:refresh()
    local cfg = self.config
    if cfg == nil then
        return
    end
    self.dialogTitleElement:setText(cfg.title or "")
    local split = cfg.layout == "split"
    setVisible(self.splitLayout, split)
    setVisible(self.wideLayout, not split)

    if split then
        local hasImage = cfg.image ~= nil and cfg.image ~= ""
        setVisible(self.imageElement, hasImage)
        setVisible(self.imageBg, hasImage)
        if hasImage and self.imageElement ~= nil then
            MPFinanceDialog.setFullImage(self.imageElement, cfg.image)
        end
        setText(self.detailsText, cfg.getDetails ~= nil and cfg.getDetails() or "")
        setText(self.summaryText, cfg.getText ~= nil and cfg.getText() or "")
    else
        local hasSlider = cfg.sliders ~= nil and cfg.sliders[1] ~= nil
        local text = cfg.getText ~= nil and cfg.getText() or ""
        setVisible(self.dialogTextElement, hasSlider)
        setVisible(self.wideTextFull, not hasSlider)
        setText(self.dialogTextElement, hasSlider and text or "")
        setText(self.wideTextFull, hasSlider and "" or text)
    end
    if cfg.sliders ~= nil then
        local labels = split and {self.sliderLabel1, self.sliderLabel2} or {self.wideSliderLabel}
        for i, labelElement in ipairs(labels) do
            local def = cfg.sliders[i]
            if def ~= nil then
                setText(labelElement, type(def.label) == "function" and def.label() or def.label)
            end
        end
    end

    local okText = cfg.getOkText ~= nil and cfg.getOkText() or cfg.okText
    self.yesButton:setText(okText or MPUtil.getText("megaPatch_finance_sign"))
    self.yesButton:setDisabled(cfg.canOk ~= nil and not cfg.canOk())

    -- opcje A/B: zwykle przyciski; "fallback" tylko gdy suwaki nie zaladowaly sie
    local optA = cfg.optionA
    local optB = cfg.optionB
    if self.slidersAvailable then
        if optA ~= nil and optA.fallbackOnly then optA = nil end
        if optB ~= nil and optB.fallbackOnly then optB = nil end
    end
    self.activeOptionA, self.activeOptionB = optA, optB
    local hasA = optA ~= nil
    local hasB = optB ~= nil
    self.termButton:setVisible(hasA)
    self.sep2:setVisible(hasA)
    self.downButton:setVisible(hasB)
    self.sep3:setVisible(hasB)
    if hasA then
        self.termButton:setText(optA.getLabel())
    end
    if hasB then
        self.downButton:setText(optB.getLabel())
    end
    if self.buttonsPC ~= nil and self.buttonsPC.invalidateLayout ~= nil then
        self.buttonsPC:invalidateLayout()
    end
end

function MPFinanceDialog:onClickOk()
    local cfg = self.config
    if cfg == nil or (cfg.canOk ~= nil and not cfg.canOk()) then
        return false
    end
    self:close()
    if cfg.onOk ~= nil then
        cfg.onOk()
    end
    return false
end

function MPFinanceDialog:runOption(opt)
    if opt == nil then
        return
    end
    if opt.closeOnClick then
        self:close()
        opt.onClick()
    else
        opt.onClick()
        self:refresh()
    end
end

function MPFinanceDialog:onClickTerm()
    if self.config ~= nil then
        self:runOption(self.activeOptionA)
    end
    return false
end

function MPFinanceDialog:onClickDown()
    if self.config ~= nil then
        self:runOption(self.activeOptionB)
    end
    return false
end

function MPFinanceDialog:onClickBack()
    local cfg = self.config
    self:close()
    if cfg ~= nil and cfg.onBack ~= nil then
        cfg.onBack()
    end
    return false
end
