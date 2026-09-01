--***********************************************************************
-- Project Zombai — debug UI (client)
--
-- Press F7 in debug mode (or as an MP admin) to open. Five tabs: World
-- state, live NPC list with per-NPC actions, spawn controls, one-click
-- behaviour scenarios, and the mod's event log.
--
-- This window only *asks*: every button sends a command that the server
-- re-validates in BNS_Debug.lua. The permission check here just avoids
-- showing a window that wouldn't work.
--***********************************************************************

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "BNS/BNS_Core"
require "BNS/BNS_Client"

BNS.DebugUI = ISCollapsableWindow:derive("BNS_DebugUI")

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local instance = nil

local TABS = { "World", "NPCs", "Spawn", "Scenarios", "Log" }

local SPAWN_BUTTONS = {
    { label = "Farmer",       archetype = "farmer" },
    { label = "City folk",    archetype = "cityfolk" },
    { label = "Thug",         archetype = "thug" },
    { label = "Police",       archetype = "police" },
    { label = "Firefighter",  archetype = "firefighter" },
    { label = "Ex-military",  archetype = "exmilitary" },
    { label = "Survivor",     role = "survivor" },
    { label = "Trader",       role = "trader" },
}

local SCENARIOS = {
    { name = "warning",   label = "Warning shout" },
    { name = "robbery",   label = "Robbery" },
    { name = "doors",     label = "Door rattle" },
    { name = "lockbash",  label = "Locked-door bash" },
    { name = "overwhelm", label = "Zombie overwhelm" },
    { name = "scavenge",  label = "Scavenge + evidence" },
    { name = "trade",     label = "Trader barter" },
    { name = "vehicle",   label = "Vehicle haul" },
    { name = "raid",      label = "Base raid" },
    { name = "poi",       label = "Fortify POI" },
}

local PROGRAM_CYCLE = {
    "wander", "approach", "rob", "attack", "flee",
    "defend", "scavenge", "haul", "fightz", "raid",
}

-- Access -------------------------------------------------------------------

function BNS.DebugUI.isAllowed()
    if type(getDebug) == "function" and getDebug() then return true end
    local player = getSpecificPlayer(0)
    if player and player.getAccessLevel then
        local ok, level = pcall(function() return player:getAccessLevel() end)
        if ok and level and level ~= "" and level ~= "None" then return true end
    end
    return false
end

function BNS.DebugUI.toggle()
    if instance then
        instance:close()
        return
    end
    if not BNS.DebugUI.isAllowed() then
        local player = getSpecificPlayer(0)
        if player then
            player:setHaloNote(getText("UI_BNS_DebugDenied"), 255, 120, 120, 300)
        end
        return
    end
    local w, h = 620, 480
    instance = BNS.DebugUI:new((getCore():getScreenWidth() - w) / 2,
        (getCore():getScreenHeight() - h) / 2, w, h)
    instance:initialise()
    instance:addToUIManager()
    instance:requestSnapshot()
end

-- Server replies -------------------------------------------------------------

function BNS.DebugUI.onSnapshot(args)
    if instance then instance.snap = args end
end

function BNS.DebugUI.onResult(args)
    if instance and args and args.text then
        table.insert(instance.results, 1, args.text)
        while #instance.results > 8 do table.remove(instance.results) end
    end
end

-- Window ----------------------------------------------------------------------

function BNS.DebugUI:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = getText("UI_BNS_DebugTitle")
    o.tab = "World"
    o.snap = nil
    o.results = {}
    o.selectedId = nil
    o.spawnCount = 1
    o.pollTimer = 0
    o.resizable = false
    return o
end

function BNS.DebugUI:send(command, args)
    BNS.Client.sendCommand(command, args or {})
end

function BNS.DebugUI:requestSnapshot()
    self:send("debugSnapshot")
end

function BNS.DebugUI:createChildren()
    ISCollapsableWindow.createChildren(self)
    local pad = 8
    local top = 40

    -- Tab strip
    self.tabButtons = {}
    local tabW = 96
    for i, name in ipairs(TABS) do
        local btn = ISButton:new(pad + (i - 1) * (tabW + 4), top - 18, tabW, 20, name,
            self, function(_, button) self.tab = button.internal end)
        btn.internal = name
        btn:initialise()
        self:addChild(btn)
        table.insert(self.tabButtons, btn)
    end

    local listY = top + 10
    local listH = self.height - listY - 116

    -- Main list (reused by World / NPCs / Log tabs)
    self.list = ISScrollingListBox:new(pad, listY, self.width - pad * 2, listH)
    self.list:initialise()
    self.list.itemheight = FONT_H + 4
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = BNS.DebugUI.drawRow
    self.list.onMouseDown = function(list, mx, my)
        ISScrollingListBox.onMouseDown(list, mx, my)
        local row = list.items[list.selected]
        if row and row.item and row.item.id then self.selectedId = row.item.id end
    end
    self:addChild(self.list)

    -- Action buttons live below the list; visibility depends on the tab.
    self.buttons = {}
    local function addButton(label, w, col, row, fn)
        local btn = ISButton:new(pad + col * (w + 4), self.height - 100 + row * 24,
            w, 20, label, self, fn)
        btn:initialise()
        btn:setVisible(false)
        self:addChild(btn)
        table.insert(self.buttons, btn)
        return btn
    end

    -- NPC actions
    self.npcButtons = {
        addButton("Go to", 90, 0, 0, function() self:npcAction("debugTeleport", { bring = false }) end),
        addButton("Bring here", 90, 1, 0, function() self:npcAction("debugTeleport", { bring = true }) end),
        addButton("Kill", 90, 2, 0, function() self:npcAction("debugKill") end),
        addButton("Next program", 110, 3, 0, function() self:cycleProgram() end),
        addButton("Give vehicle", 110, 4, 0, function() self:npcAction("debugVehicle") end),
        addButton("Swarm it", 90, 0, 1, function() self:npcAction("debugZombies", { count = 8 }) end),
        addButton("Clear all NPCs", 110, 1, 1, function() self:send("debugClear") end),
        addButton("Overlay on/off", 110, 2, 1, function()
            if BNS.DebugOverlay then BNS.DebugOverlay.toggle() end
        end),
    }

    -- Spawn actions
    self.spawnButtons = {}
    for i, spec in ipairs(SPAWN_BUTTONS) do
        local col = (i - 1) % 4
        local row = math.floor((i - 1) / 4)
        table.insert(self.spawnButtons, addButton(spec.label, 110, col, row, function()
            self:send("debugSpawn", {
                archetype = spec.archetype,
                role = spec.role or "bandit",
                count = self.spawnCount,
            })
        end))
    end
    table.insert(self.spawnButtons, addButton("Count: 1", 90, 0, 2, function(_, btn)
        self.spawnCount = self.spawnCount >= 5 and 1 or self.spawnCount + 1
        btn:setTitle("Count: " .. self.spawnCount)
    end))
    table.insert(self.spawnButtons, addButton("Raid me", 90, 1, 2, function() self:send("debugRaid") end))
    table.insert(self.spawnButtons, addButton("Fortify POI", 90, 2, 2, function() self:send("debugPOI") end))
    table.insert(self.spawnButtons, addButton("Loot box", 90, 3, 2, function() self:send("debugLootBox") end))
    table.insert(self.spawnButtons, addButton("Horde", 90, 4, 2, function()
        self:send("debugZombies", { count = 10 })
    end))

    -- Scenario buttons
    self.scenarioButtons = {}
    for i, sc in ipairs(SCENARIOS) do
        local col = (i - 1) % 4
        local row = math.floor((i - 1) / 4)
        table.insert(self.scenarioButtons, addButton(sc.label, 140, col, row, function()
            self:send("debugScenario", { name = sc.name })
        end))
    end

    self:refreshButtons()
end

function BNS.DebugUI:npcAction(command, extra)
    if not self.selectedId then
        BNS.DebugUI.onResult({ text = "select an NPC first" })
        return
    end
    local args = { id = self.selectedId }
    for k, v in pairs(extra or {}) do args[k] = v end
    self:send(command, args)
end

function BNS.DebugUI:cycleProgram()
    if not self.selectedId then
        BNS.DebugUI.onResult({ text = "select an NPC first" })
        return
    end
    local current = nil
    for _, npc in ipairs(self.snap and self.snap.npcs or {}) do
        if npc.id == self.selectedId then current = npc.program end
    end
    local nextIdx = 1
    for i, name in ipairs(PROGRAM_CYCLE) do
        if name == current then nextIdx = (i % #PROGRAM_CYCLE) + 1 end
    end
    self:send("debugProgram", { id = self.selectedId, program = PROGRAM_CYCLE[nextIdx] })
end

function BNS.DebugUI:refreshButtons()
    local function show(list, visible)
        for _, btn in ipairs(list) do btn:setVisible(visible) end
    end
    show(self.npcButtons, self.tab == "NPCs")
    show(self.spawnButtons, self.tab == "Spawn")
    show(self.scenarioButtons, self.tab == "Scenarios")
end

-- Rows -------------------------------------------------------------------------

function BNS.DebugUI.drawRow(list, y, item, alt)
    if list.selected == item.index then
        list:drawRect(0, y, list:getWidth(), list.itemheight, 0.3, 0.7, 0.35, 0.15)
    end
    local data = item.item or {}
    local r, g, b = 0.9, 0.9, 0.9
    if data.colour then r, g, b = data.colour[1], data.colour[2], data.colour[3] end
    list:drawText(item.text, 6, y + 2, r, g, b, 1, list.font)
    return y + list.itemheight
end

local PROGRAM_COLOURS = {
    attack   = { 1.0, 0.4, 0.4 },
    rob      = { 1.0, 0.7, 0.3 },
    fightz   = { 0.6, 0.8, 1.0 },
    flee     = { 1.0, 1.0, 0.4 },
    raid     = { 1.0, 0.5, 0.2 },
    scavenge = { 0.6, 1.0, 0.6 },
    haul     = { 0.5, 0.9, 0.8 },
    defend   = { 0.8, 0.6, 1.0 },
}

function BNS.DebugUI:rebuildList()
    self.list:clear()
    local snap = self.snap
    if not snap then
        self.list:addItem("waiting for server snapshot...", {})
        return
    end

    if self.tab == "World" then
        local c = snap.counts
        self.list:addItem(string.format("NPCs: %d live, %d virtual  |  bandits %d, survivors %d, traders %d",
            c.live, c.virtual, c.bandit or 0, c.survivor or 0, c.trader or 0), {})
        self.list:addItem("world hour: " .. tostring(snap.hours), {})
        self.list:addItem("", {})
        self.list:addItem("-- sandbox options (click to toggle booleans) --", {})
        local names = {}
        for name, _ in pairs(snap.options) do table.insert(names, name) end
        table.sort(names)
        for _, name in ipairs(names) do
            local v = snap.options[name]
            self.list:addItem("  " .. name .. " = " .. tostring(v),
                { option = name, value = v })
        end
        self.list:addItem("", {})
        self.list:addItem("-- fortified POIs (" .. #snap.bases .. ") --", {})
        for _, base in ipairs(snap.bases) do
            self.list:addItem(string.format("  %s  (%d,%d) %dm", base.name, base.x, base.y, base.dist), {})
        end
        self.list:addItem("", {})
        self.list:addItem("-- detected player bases (" .. #snap.playerBases .. ") --", {})
        for _, pb in ipairs(snap.playerBases) do
            self.list:addItem(string.format("  (%d,%d) hits %d, %dm, next raid in %dh",
                pb.x, pb.y, pb.hits, pb.dist, pb.raidIn), {})
        end

    elseif self.tab == "NPCs" then
        if #snap.npcs == 0 then
            self.list:addItem("no NPCs - use the Spawn tab", {})
        end
        for _, npc in ipairs(snap.npcs) do
            local flags = ""
            if npc.vehicle then flags = flags .. " [car]" end
            if npc.door then flags = flags .. " [door]" end
            if npc.grabbed then flags = flags .. " [grabbed]" end
            if npc.warned then flags = flags .. " [warned]" end
            if not npc.live then flags = flags .. " [virtual]" end
            local text = string.format("%-16s %-11s %-11s hp%3d%% %4dm  pack %d%s",
                npc.name or "?", npc.archetype or npc.role, npc.program or "?",
                math.floor((npc.health or 1) * 100), npc.dist, npc.loot, flags)
            self.list:addItem(text, { id = npc.id, colour = PROGRAM_COLOURS[npc.program] })
        end

    elseif self.tab == "Log" then
        for _, entry in ipairs(snap.log or {}) do
            self.list:addItem(string.format("[%dh] %s", entry.h or 0, entry.text), {})
        end

    elseif self.tab == "Spawn" then
        self.list:addItem("Spawn NPCs near you. Archetypes force their loadout and outfit;", {})
        self.list:addItem("count > 1 spawns them as a squad.", {})
        self.list:addItem("", {})
        self.list:addItem("Live NPCs: " .. snap.counts.live .. "   Virtual: " .. snap.counts.virtual, {})

    elseif self.tab == "Scenarios" then
        self.list:addItem("Each button stages a behaviour so you can watch it happen.", {})
        self.list:addItem("Turn the overlay on (NPCs tab) to see programs above heads.", {})
        self.list:addItem("", {})
        for _, line in ipairs(self.results) do
            self.list:addItem("  " .. line, { colour = { 0.7, 1.0, 0.7 } })
        end
    end
end

function BNS.DebugUI:onOptionClick()
    local row = self.list.items[self.list.selected]
    if not row or not row.item or not row.item.option then return end
    local v = row.item.value
    if type(v) == "boolean" then
        self:send("debugOption", { name = row.item.option, value = not v })
    end
end

-- Frame ---------------------------------------------------------------------------

function BNS.DebugUI:prerender()
    ISCollapsableWindow.prerender(self)
    self.pollTimer = self.pollTimer - 1
    if self.pollTimer <= 0 then
        self.pollTimer = 60 -- ~1s
        self:requestSnapshot()
    end
    self:refreshButtons()
    self:rebuildList()
    for _, btn in ipairs(self.tabButtons) do
        btn.backgroundColor.a = (btn.internal == self.tab) and 0.9 or 0.4
    end
end

function BNS.DebugUI:render()
    ISCollapsableWindow.render(self)
    local footer = self.results[1]
    if footer then
        self:drawText(footer, 10, self.height - 20, 0.7, 1.0, 0.7, 1, UIFont.Small)
    end
end

function BNS.DebugUI:onMouseDown(x, y)
    ISCollapsableWindow.onMouseDown(self, x, y)
    if self.tab == "World" then self:onOptionClick() end
    return true
end

function BNS.DebugUI:close()
    self:removeFromUIManager()
    if instance == self then instance = nil end
end

-- Opening --------------------------------------------------------------------------

local function onKeyPressed(key)
    if key == Keyboard.KEY_F7 then BNS.DebugUI.toggle() end
end
Events.OnKeyPressed.Add(onKeyPressed)

-- Backup entry point: right-click yourself.
local function onFillContextMenu(playerIndex, context, worldObjects, test)
    if test then return end
    if not BNS.DebugUI.isAllowed() then return end
    local player = getSpecificPlayer(playerIndex)
    if not player then return end
    for _, obj in ipairs(worldObjects) do
        local sq = obj and obj.getSquare and obj:getSquare() or nil
        if sq and BNS.dist(player:getX(), player:getY(), sq:getX(), sq:getY()) < 2 then
            context:addOption(getText("UI_BNS_DebugOpen"), nil, BNS.DebugUI.toggle)
            return
        end
    end
end
Events.OnFillWorldObjectContextMenu.Add(onFillContextMenu)
