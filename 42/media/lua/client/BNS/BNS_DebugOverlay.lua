--***********************************************************************
-- Project Zombai — debug overlay (client)
--
-- Draws each NPC's current program, health and archetype above their
-- head, so behaviour can be watched instead of inferred: you see
-- WANDER flip to APPROACH, the ATTACK warning hold, FIGHTZ when zombies
-- close in, FLEE when the 4:1 rule trips, SCAVENGE and HAUL on a loot
-- run. Toggled from the debug UI (NPCs tab).
--***********************************************************************

require "BNS/BNS_Core"

BNS.DebugOverlay = {}
BNS.DebugOverlay.enabled = false

local COLOURS = {
    wander   = { 0.8, 0.8, 0.8 },
    approach = { 1.0, 0.8, 0.4 },
    rob      = { 1.0, 0.7, 0.3 },
    attack   = { 1.0, 0.4, 0.4 },
    flee     = { 1.0, 1.0, 0.4 },
    defend   = { 0.8, 0.6, 1.0 },
    trade    = { 0.6, 1.0, 0.9 },
    fightz   = { 0.6, 0.8, 1.0 },
    scavenge = { 0.6, 1.0, 0.6 },
    haul     = { 0.5, 0.9, 0.8 },
    raid     = { 1.0, 0.5, 0.2 },
}

function BNS.DebugOverlay.toggle()
    BNS.DebugOverlay.enabled = not BNS.DebugOverlay.enabled
    local player = getSpecificPlayer(0)
    if player then
        player:setHaloNote(BNS.DebugOverlay.enabled and "BNS overlay ON" or "BNS overlay OFF",
            200, 255, 200, 200)
    end
    return BNS.DebugOverlay.enabled
end

local function drawNPC(zombie, brain)
    local sx = isoToScreenX(0, zombie:getX(), zombie:getY(), zombie:getZ())
    local sy = isoToScreenY(0, zombie:getX(), zombie:getY(), zombie:getZ())
    if sx < -100 or sy < -100
            or sx > getCore():getScreenWidth() + 100
            or sy > getCore():getScreenHeight() + 100 then
        return
    end

    local text = tostring(brain.program or "?")
    if brain.grabbedTimer then text = text .. " GRABBED"
    elseif brain.door then text = text .. " DOOR"
    elseif brain.warnTimer then text = text .. " WARNING" end

    local c = COLOURS[brain.program] or { 1, 1, 1 }
    local tm = getTextManager()
    tm:DrawStringCentre(UIFont.Small, sx, sy - 150, text, c[1], c[2], c[3], 1)

    local sub = string.format("%s  hp %d%%%s",
        tostring(brain.archetype or brain.role or "?"),
        math.floor((brain.health or 1) * 100),
        (brain.loot and #brain.loot > 0) and ("  pack " .. #brain.loot) or "")
    tm:DrawStringCentre(UIFont.Small, sx, sy - 136, sub, 0.75, 0.75, 0.75, 1)

    if brain.vehicle then
        tm:DrawStringCentre(UIFont.Small, sx, sy - 122, "car", 0.5, 0.9, 0.8, 1)
    end
end

local function render()
    if not BNS.DebugOverlay.enabled then return end
    local cell = getCell()
    if not cell then return end
    local list = cell:getZombieList()
    if not list then return end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if BNS.isNPC(z) and not z:isDead() then
            local brain = BNS.brain(z)
            if brain then drawNPC(z, brain) end
        end
    end
end

Events.OnPostUIDraw.Add(render)
