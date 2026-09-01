--***********************************************************************
-- Bandits & Survivors — combination locks (server)
--
-- Players attach a vanilla combination padlock to a door. The lock is
-- stored in the door's own mod data (persists and transmits to MP
-- clients) and the engine lock flag is set, so nobody can simply open
-- it. The owner and anyone in the owner's clan (MP faction) get quick
-- entry through a context-menu command; everyone else — bandits
-- included — has to break the door down.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"

BNS.Locks = {}

BNS.Locks.PADLOCK_TYPE = "CombinationPadlock" -- vanilla Base.CombinationPadlock
BNS.Locks.PADLOCK_FULL = "Base.CombinationPadlock"
local REACH = 3 -- tiles: how close a player must be to work a lock

-- Door helpers -----------------------------------------------------------

local function isDoorObject(obj)
    if not obj then return false end
    if instanceof(obj, "IsoDoor") then return true end
    if instanceof(obj, "IsoThumpable") and obj.isDoor and obj:isDoor() then return true end
    return false
end

function BNS.Locks.findDoorAt(x, y, z)
    local sq = getCell() and getCell():getGridSquare(x, y, z or 0) or nil
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        if isDoorObject(obj) then return obj end
    end
    return nil
end

function BNS.Locks.get(door)
    if not door or not door.getModData then return nil end
    local md = door:getModData()
    return md and md.BNS_Lock or nil
end

-- Any reason a bandit can't just pull this door open?
function BNS.Locks.isSecured(door)
    if BNS.Locks.get(door) then return true end
    if door.isLocked and door:isLocked() then return true end
    if door.isLockedByKey and door:isLockedByKey() then return true end
    if door.isBarricaded and door:isBarricaded() then return true end
    return false
end

-- Access -----------------------------------------------------------------

local function factionOf(player)
    if Faction and Faction.getPlayerFaction then
        local ok, f = pcall(function() return Faction.getPlayerFaction(player) end)
        if ok and f and f.getName then return f:getName() end
    end
    return nil
end

function BNS.Locks.canUse(player, lock)
    if not lock then return true end
    if player:getUsername() == lock.owner then return true end
    if lock.faction and factionOf(player) == lock.faction then return true end
    return false
end

-- Engine lock flag + MP sync ---------------------------------------------

local function setEngineLock(door, locked)
    if door.setLocked then pcall(function() door:setLocked(locked) end) end
    if door.setLockedByKey then pcall(function() door:setLockedByKey(locked) end) end
end

local function transmit(door)
    if door.transmitModData then pcall(function() door:transmitModData() end) end
    if door.transmitUpdatedSpriteToClients then
        pcall(function() door:transmitUpdatedSpriteToClients() end)
    end
end

local function reply(player, args)
    if isServer() then
        sendServerCommand(player, BNS.CommandModule, "lockResult", args)
    elseif BNS.Client and BNS.Client.onServerCommand then
        BNS.Client.onServerCommand(BNS.CommandModule, "lockResult", args)
    end
end

-- Called by BNS_Doors when a bandit finishes smashing a locked door.
function BNS.Locks.onDoorDestroyed(door)
    local md = door.getModData and door:getModData() or nil
    if md then md.BNS_Lock = nil end
end

-- Command handlers (dispatched from BNS_Commands) -------------------------

-- args = { x, y, z }
function BNS.Locks.attachLock(player, args)
    local door = BNS.Locks.findDoorAt(args.x, args.y, args.z)
    if not door or BNS.Locks.get(door) then return end
    if BNS.dist(player:getX(), player:getY(), args.x, args.y) > REACH then return end
    local item = player:getInventory():getFirstTypeRecurse(BNS.Locks.PADLOCK_TYPE)
    if not item then
        reply(player, { ok = false })
        return
    end
    player:getInventory():Remove(item)
    door:getModData().BNS_Lock = {
        owner = player:getUsername() or "Player",
        faction = factionOf(player),
    }
    setEngineLock(door, true)
    transmit(door)
    reply(player, { ok = true, attached = true })
end

function BNS.Locks.removeLock(player, args)
    local door = BNS.Locks.findDoorAt(args.x, args.y, args.z)
    local lock = door and BNS.Locks.get(door) or nil
    if not lock then return end
    if BNS.dist(player:getX(), player:getY(), args.x, args.y) > REACH then return end
    if not BNS.Locks.canUse(player, lock) then
        reply(player, { ok = false, denied = true })
        return
    end
    door:getModData().BNS_Lock = nil
    setEngineLock(door, false)
    transmit(door)
    player:getInventory():AddItem(BNS.Locks.PADLOCK_FULL)
    reply(player, { ok = true, removed = true })
end

-- Quick entry: clan members toggle the door straight through the lock.
function BNS.Locks.useLock(player, args)
    local door = BNS.Locks.findDoorAt(args.x, args.y, args.z)
    local lock = door and BNS.Locks.get(door) or nil
    if not lock then return end
    if BNS.dist(player:getX(), player:getY(), args.x, args.y) > REACH then return end
    if not BNS.Locks.canUse(player, lock) then
        reply(player, { ok = false, denied = true })
        return
    end
    setEngineLock(door, false)
    if door.ToggleDoor then pcall(function() door:ToggleDoor(player) end) end
    setEngineLock(door, true)
    transmit(door)
    reply(player, { ok = true })
end
