--***********************************************************************
-- Bandits & Survivors — context menu (client)
--
-- Right-clicking near a survivor or trader offers Talk / Trade.
--***********************************************************************

require "BNS/BNS_Core"
require "BNS/BNS_Client"

BNS.ContextMenu = {}

local function findNPCNear(worldObjects)
    local sq = nil
    for _, obj in ipairs(worldObjects) do
        if obj and obj.getSquare then
            sq = obj:getSquare()
            if sq then break end
        end
    end
    if not sq then return nil end

    -- Search a small area around the clicked square for an NPC shell.
    local cell = getCell()
    for dx = -2, 2 do
        for dy = -2, 2 do
            local s = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
            if s then
                local movers = s:getMovingObjects()
                for i = 0, movers:size() - 1 do
                    local m = movers:get(i)
                    if BNS.isNPC(m) then return m end
                end
            end
        end
    end
    return nil
end

function BNS.ContextMenu.onFillWorldObjectContextMenu(playerIndex, context, worldObjects, test)
    if test then return end
    local npc = findNPCNear(worldObjects)
    if not npc then return end
    local brain = BNS.brain(npc)
    if not brain or brain.role == BNS.Role.BANDIT then return end

    local player = getSpecificPlayer(playerIndex)
    if not player then return end
    if BNS.dist(player:getX(), player:getY(), npc:getX(), npc:getY()) > 4 then return end

    local npcId = npc:getOnlineID()
    local label = brain.name or getText("UI_BNS_Talk")

    context:addOption(getText("UI_BNS_Talk") .. " (" .. label .. ")", nil, function()
        BNS.Client.sendCommand("talk", { npcId = npcId })
    end)

    if brain.role == BNS.Role.TRADER then
        context:addOption(getText("UI_BNS_Trade") .. " (" .. label .. ")", nil, function()
            BNS.Client.sendCommand("requestTrade", { npcId = npcId })
        end)
    end
end

Events.OnFillWorldObjectContextMenu.Add(BNS.ContextMenu.onFillWorldObjectContextMenu)
