--***********************************************************************
-- Bandits & Survivors — combination-lock context menu (client)
--
-- Right-click a door: attach a combination padlock, and on a locked
-- door open/close it (quick entry for the lock's owner and their clan)
-- or remove the lock. Everything is validated server-side; this menu
-- only offers what the server will accept.
--***********************************************************************

require "BNS/BNS_Core"
require "BNS/BNS_Client"

BNS.LockMenu = {}

local PADLOCK_TYPE = "CombinationPadlock"

local function isDoorObject(obj)
    if not obj then return false end
    if instanceof(obj, "IsoDoor") then return true end
    if instanceof(obj, "IsoThumpable") and obj.isDoor and obj:isDoor() then return true end
    return false
end

local function findDoor(worldObjects)
    for _, obj in ipairs(worldObjects) do
        if isDoorObject(obj) then return obj end
        -- Doors are often reported via their square's object list.
        if obj and obj.getSquare then
            local sq = obj:getSquare()
            if sq then
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    if isDoorObject(objs:get(i)) then return objs:get(i) end
                end
            end
        end
    end
    return nil
end

local function lockOf(door)
    local md = door.getModData and door:getModData() or nil
    return md and md.BNS_Lock or nil
end

-- Client-side mirror of the server's access check, for menu display
-- only — the server re-validates every command.
local function canUse(player, lock)
    if player:getUsername() == lock.owner then return true end
    if lock.faction and Faction and Faction.getPlayerFaction then
        local ok, f = pcall(function() return Faction.getPlayerFaction(player) end)
        if ok and f and f.getName and f:getName() == lock.faction then return true end
    end
    return false
end

function BNS.LockMenu.onFillWorldObjectContextMenu(playerIndex, context, worldObjects, test)
    if test then return end
    local door = findDoor(worldObjects)
    if not door then return end
    local player = getSpecificPlayer(playerIndex)
    if not player then return end
    local sq = door:getSquare()
    if not sq then return end
    if BNS.dist(player:getX(), player:getY(), sq:getX(), sq:getY()) > 3 then return end

    local coords = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
    local lock = lockOf(door)

    if not lock then
        if player:getInventory():containsTypeRecurse(PADLOCK_TYPE) then
            context:addOption(getText("UI_BNS_AttachLock"), nil, function()
                BNS.Client.sendCommand("attachLock", coords)
            end)
        end
        return
    end

    if canUse(player, lock) then
        context:addOption(getText("UI_BNS_UseLock"), nil, function()
            BNS.Client.sendCommand("useLock", coords)
        end)
        context:addOption(getText("UI_BNS_RemoveLock"), nil, function()
            BNS.Client.sendCommand("removeLock", coords)
        end)
    else
        local opt = context:addOption(getText("UI_BNS_LockedDoor"), nil, nil)
        if opt then opt.notAvailable = true end
    end
end

Events.OnFillWorldObjectContextMenu.Add(BNS.LockMenu.onFillWorldObjectContextMenu)
