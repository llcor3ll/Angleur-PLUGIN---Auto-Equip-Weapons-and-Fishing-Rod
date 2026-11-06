local ADDON, ns = ...
local frame = CreateFrame("Frame")
local defaults = {
    equipPoleOnWake = true,
    restoreOnLoot = false,
    restoreOnReel = false,
    restoreOnFailedReel = false,
    restoreOnMovement = true,
    reEquipPoleOnDoubleClick = true,
    restoreOnSleep = true,
    singleRightClickReel = true,
}
local db
local savedMain, savedOff, savedTwoHand = nil, nil, false

local function persistSavedWeapons()
    if not db then return end
    db.savedMain = savedMain
    db.savedOff = savedOff
    db.savedTwoHand = savedTwoHand and true or false
end

local function loadSavedWeapons()
    if not db then return end
    savedMain = db.savedMain
    savedOff = db.savedOff
    savedTwoHand = db.savedTwoHand and true or false
end
local poleItemID, poleLink
local awake = false
local fishingCast = false
local lastRight = 0
local restoring = false
local reelBindingActive = false
local bindingOwner = CreateFrame("Frame")

local function msg(s)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffAngleur Plugin|r: "..tostring(s)) end
end

local function itemIDFromLink(link)
    if not link then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local function getItemID(slot)
    return GetInventoryItemID and GetInventoryItemID("player", slot)
end

local function getLink(slot)
    return GetInventoryItemLink and GetInventoryItemLink("player", slot)
end

local function isPole(id)
    if not id then return false end
    if C_Item and C_Item.GetItemInfoInstant then
        local _,_,_,_,_,classID,subClassID = C_Item.GetItemInfoInstant(id)
        return classID == 2 and subClassID == 20
    end
    local _,_,_,_,_,classID,subClassID = GetItemInfoInstant(id)
    return classID == 2 and subClassID == 20
end

local function eachBag(fn)
    for bag=0,4 do
        local n = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)) or (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
        for slot=1,n do
            local id = (C_Container and C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag,slot)) or (GetContainerItemID and GetContainerItemID(bag,slot))
            if id and fn(bag,slot,id) then return end
        end
    end
end

local function findPole()
    local found
    eachBag(function(bag,slot,id)
        if isPole(id) then found={bag=bag,slot=slot,id=id}; return true end
    end)
    return found
end

local function equip(item, slot)
    if not item then return false end
    -- Preserve v0.2.0 behaviour: attempt equipment changes immediately,
    -- including on combat entry. The pending retry loop handles blocked calls.
    if C_Item and C_Item.EquipItemByName then
        local ok = pcall(C_Item.EquipItemByName, item, slot)
        if ok then return true end
    end
    if EquipItemByName then
        local ok = pcall(EquipItemByName, item, slot)
        if ok then return true end
    end
    return false
end

local function saveWeapons()
    local mh, oh = getLink(16), getLink(17)
    if mh and not isPole(getItemID(16)) then
        savedMain = itemIDFromLink(mh)
        savedTwoHand = oh == nil
        savedOff = oh and itemIDFromLink(oh) or nil
        persistSavedWeapons()
    elseif isPole(getItemID(16)) then
        -- Keep the saved normal main-hand; track off-hand changes independently.
        savedOff = oh and itemIDFromLink(oh) or nil
        persistSavedWeapons()
    end
end

local restorePending = false

local function weaponsRestored()
    if not savedMain then return false end
    if getItemID(16) ~= savedMain then return false end
    if savedOff and getItemID(17) ~= savedOff then return false end
    if savedTwoHand and getItemID(17) ~= nil then return false end
    return true
end

local function restoreWeapons()
    if not savedMain then loadSavedWeapons() end
    if not savedMain then return end

    restorePending = true
    if weaponsRestored() then
        restorePending = false
        return
    end

    equip(savedMain, 16)
    if savedOff then
        C_Timer.After(0.15, function()
            if restorePending and getItemID(17) ~= savedOff then
                equip(savedOff, 17)
            end
        end)
    end
end

local function equipPole()
    if InCombatLockdown and InCombatLockdown() then return end
    if isPole(getItemID(16)) then return end
    local pole = findPole()
    if not pole then msg("No fishing pole found in your bags."); return end
    if not savedMain then saveWeapons() end
    poleItemID = pole.id
    equip(pole.id,16)
end

local function angleurAwake()
    return _G.AngleurCharacter and _G.AngleurCharacter.sleeping == false
end

-- Forward declaration is required because onSleep calls this before its definition.
local clearSingleClickReel

local function onWake()
    awake = true
    if db.equipPoleOnWake then
        saveWeapons()
        C_Timer.After(0.25, equipPole)
    end
end

local function onSleep()
    awake = false
    clearSingleClickReel()
    if db.restoreOnSleep then restoreWeapons() end
end

local registerAngleurCallbacks

local function hookAngleur()
    if type(_G.Angleur_SetSleep) == "function" and not frame.hooked then
        hooksecurefunc("Angleur_SetSleep", function()
            if angleurAwake() then onWake() else onSleep() end
        end)
        frame.hooked = true
        registerAngleurCallbacks()
        if angleurAwake() then onWake() end
        msg("Connected to Angleur.")
    end
end

local function isFishingSpell(spellID)
    if spellID == 7620 or spellID == 131474 or spellID == 131476 then return true end
    if spellID and GetSpellInfo then
        local name = GetSpellInfo(spellID)
        if name and name:lower() == "fishing" then return true end
    end
    return false
end

local function restoreAfterFailedReel(unit, spellID)
    -- Failed/interrupted reels leave the fishing rod equipped.
end

clearSingleClickReel = function()
    if not reelBindingActive then return end
    if not (InCombatLockdown and InCombatLockdown()) and ClearOverrideBindings then
        ClearOverrideBindings(bindingOwner)
        reelBindingActive = false
    end
end

local function enableSingleClickReel()
    if not db or not db.singleRightClickReel or not awake then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if SetOverrideBinding then
        -- One physical right-click sends the soft-target interact command while
        -- Angleur reports an active fishing channel.
        SetOverrideBinding(bindingOwner, true, "BUTTON2", "INTERACTTARGET")
        reelBindingActive = true
    end
end

local function handleFishingFailureMessage(message)
    -- Fishing failure messages must not trigger weapon restoration.
end

local function onAngleurStopFishing()
    -- Ending a reel must not restore normal weapons; keep the fishing rod equipped.
end

registerAngleurCallbacks = function()
    if not EventRegistry or not EventRegistry.RegisterCallback or frame.angleurCallbacksRegistered then return end
    local ok1 = pcall(EventRegistry.RegisterCallback, EventRegistry, "Angleur_StopFishing", function()
        fishingCast = false
        clearSingleClickReel()
        onAngleurStopFishing()
    end, frame)
    local ok2 = pcall(EventRegistry.RegisterCallback, EventRegistry, "Angleur_StartFishing", function()
        fishingCast = true
        enableSingleClickReel()
    end, frame)
    if ok1 then
        frame.angleurCallbacksRegistered = true
        msg("Connected to Angleur fishing start/stop events.")
    end
end

local optionsPanel
local optionsCategory

local function refreshOptions()
    if not optionsPanel or not db then return end
    for key, checkbox in pairs(optionsPanel.checkboxes or {}) do
        checkbox:SetChecked(db[key] and true or false)
    end
end

local function createOptionsPanel()
    if optionsPanel then
        refreshOptions()
        return
    end

    local p = CreateFrame("Frame")
    p.name = "Angleur Plugin - Auto Equip"
    optionsPanel = p

    local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Angleur Plugin - Auto Equip")

    local subtitle = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Configure automatic weapon and fishing rod behaviour.")

    local opts = {
        {"equipPoleOnWake", "Equip fishing rod on Angleur wake"},
        {"restoreOnMovement", "Restore weapons when you start moving"},
        {"reEquipPoleOnDoubleClick", "Double-right-click while awake: re-equip rod"},
        {"restoreOnSleep", "Restore weapons when Angleur sleeps"},
        {"singleRightClickReel", "Single right-click to reel while fishing (no bobber hover)"},
    }

    p.checkboxes = {}
    for i, option in ipairs(opts) do
        local key, label = option[1], option[2]
        local checkbox = CreateFrame("CheckButton", nil, p, "InterfaceOptionsCheckButtonTemplate")
        checkbox:SetPoint("TOPLEFT", 16, -68 - ((i - 1) * 34))
        checkbox.Text:SetText(label)
        checkbox:SetScript("OnClick", function(self)
            db[key] = self:GetChecked() and true or false

            -- Apply a reel-binding toggle immediately if fishing is already underway.
            if key == "singleRightClickReel" then
                if db[key] and awake and fishingCast then
                    enableSingleClickReel()
                else
                    clearSingleClickReel()
                end
            end
        end)
        p.checkboxes[key] = checkbox
    end

    p:SetScript("OnShow", refreshOptions)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(p, p.name)
        Settings.RegisterAddOnCategory(optionsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(p)
    end

    refreshOptions()
end

local function openOptionsPanel()
    createOptionsPanel()

    -- Open the registered Blizzard AddOns settings page; never show a custom popup.
    if Settings and Settings.OpenToCategory and optionsCategory then
        Settings.OpenToCategory(optionsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory and optionsPanel then
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    else
        msg("Open Options > AddOns > Angleur Plugin - Auto Equip to change settings.")
    end
end

SLASH_ANGLEURPLUGINAUTOEQUIP1 = "/angplugin"
SlashCmdList.ANGLEURPLUGINAUTOEQUIP = openOptionsPanel

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
frame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
frame:RegisterEvent("UNIT_SPELLCAST_FAILED")
frame:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
frame:RegisterEvent("PLAYER_STARTED_MOVING")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent",function(self,event,...)
    if event=="ADDON_LOADED" then
        local name=...
        if name==ADDON then
            AngleurPluginDB=AngleurPluginDB or {}
            db=AngleurPluginDB
            for k,v in pairs(defaults) do if db[k]==nil then db[k]=v end end
            if db.singleRightClickReel == nil then
                if db.rightClickReel ~= nil then
                    db.singleRightClickReel = db.rightClickReel
                else
                    db.singleRightClickReel = true
                end
            end
            -- This plugin keeps the fishing rod equipped after failed or looted reels.
            db.restoreOnLoot = false
            db.restoreOnReel = false
            db.restoreOnFailedReel = false
            loadSavedWeapons()
            createOptionsPanel()
            hookAngleur()
            registerAngleurCallbacks()
        elseif name=="Angleur" then hookAngleur(); registerAngleurCallbacks() end
    elseif event=="PLAYER_ENTERING_WORLD" then
        C_Timer.After(2,function() hookAngleur(); registerAngleurCallbacks() end)
    elseif event=="PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        if slot == 16 or slot == 17 then
            saveWeapons()
        end
    elseif event=="PLAYER_REGEN_DISABLED" then
        -- Keep v0.2.0 combat behaviour: restore normal weapons on combat entry.
        restoreWeapons()
        clearSingleClickReel()
        fishingCast = false
    elseif event=="PLAYER_REGEN_ENABLED" then
        if restorePending then restoreWeapons() end
    elseif event=="PLAYER_STARTED_MOVING" then
        if awake and db.restoreOnMovement then
            restoreWeapons()
            clearSingleClickReel()
        end
    elseif event=="CHAT_MSG_SYSTEM" then
        local message = ...
        handleFishingFailureMessage(message)
    elseif event=="LOOT_CLOSED" then
        -- Keep the rod equipped after looting a catch.
    elseif event=="UNIT_SPELLCAST_CHANNEL_START" then
        local unit=...
        if unit=="player" then fishingCast=true end
    elseif event=="UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit, _, spellID = ...
        if unit=="player" then
            fishingCast=false
            -- Keep the rod equipped when the fishing channel ends.
        end
    elseif event=="UNIT_SPELLCAST_INTERRUPTED" or event=="UNIT_SPELLCAST_FAILED" or event=="UNIT_SPELLCAST_FAILED_QUIET" then
        local unit, _, spellID = ...
        restoreAfterFailedReel(unit, spellID)
        clearSingleClickReel()
    elseif event=="GLOBAL_MOUSE_DOWN" then
        local button=...
        if button=="RightButton" and awake and db.reEquipPoleOnDoubleClick and not (InCombatLockdown and InCombatLockdown()) then
            local now=GetTime()
            if now-lastRight <= 0.4 then
                lastRight=0
                C_Timer.After(0.15,equipPole)
            else lastRight=now end
        end
    end
end)


-- Equipment retry loop retained from v0.2.0.
local restorePoll = 0
local movementPoll = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    -- Also poll movement to catch Angleur equipping the rod after movement began.
    movementPoll = movementPoll + elapsed
    if movementPoll >= 0.05 then
        movementPoll = 0
        if awake and db and db.restoreOnMovement
            and IsPlayerMoving and IsPlayerMoving()
            and isPole(getItemID(16)) then
            clearSingleClickReel()
            restoreWeapons()
        end
    end

    if not restorePending then return end
    restorePoll = restorePoll + elapsed
    if restorePoll < 0.25 then return end
    restorePoll = 0

    if weaponsRestored() then
        restorePending = false
    else
        equip(savedMain, 16)
        if savedOff and getItemID(17) ~= savedOff then
            equip(savedOff, 17)
        end
    end
end)
