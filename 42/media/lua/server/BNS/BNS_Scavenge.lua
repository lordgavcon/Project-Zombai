--***********************************************************************
-- Project Zombai — NPC scavenging (server)
--
-- Wandering NPCs (bandits, survivors and traders alike) loot buildings
-- for supplies and equipment. They take the valuable things — weapons,
-- ammo, food, meds — and leave evidence behind: low-value items stay in
-- the container and one or two get pulled out onto the floor, so a
-- half-emptied cupboard with junk scattered around it plainly says
-- "someone living was here". Looted spots are marked and skipped for a
-- few in-game days. Player bases are off limits — taking your stuff is
-- the raid system's job, done loudly, not by quiet wanderers.
--
-- What they take matters: bandits and survivors carry a loot pack that
-- drops on death, and traders convert barter-valued finds straight
-- into their sale stock, restocking themselves from the world.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Loadouts"
require "BNS/BNS_Persistence"
require "BNS/BNS_Anim"
require "BNS/BNS_Programs"

BNS.Scavenge = {}

local SEARCH_RADIUS    = 15  -- tiles: how far a wanderer looks for loot
local BASE_EXCLUSION   = 30  -- tiles: keep-out radius around player bases
local BASE_HIT_MIN     = 12  -- playerBases.hits confirming a base (matches BNS_Raids)
local VALUE_THRESHOLD  = 3   -- items worth at least this get taken
local TAKE_CAP         = 4   -- max items taken per container square
BNS.Scavenge.PACK_CAP  = 10  -- max items an NPC carries (BNS_Vehicles reads it)
local PACK_CAP         = BNS.Scavenge.PACK_CAP
local SCATTER_MAX      = 2   -- leftovers pulled onto the floor as evidence
local LOOT_COOLDOWN_H  = 72  -- in-game hours before a spot is worth re-looting
local RUMMAGE_TICKS    = 24  -- full brain ticks spent rifling (~4s)

-- Item valuation ---------------------------------------------------------

function BNS.Scavenge.itemValue(item)
    local v = BNS.Loadouts.BarterValues[item:getFullType()]
    if v then return v end
    local cat = item.getCategory and item:getCategory() or nil
    if cat == "Weapon" then return 8 end
    if cat == "Food" then return 3 end
    if cat == "Ammo" then return 2 end
    return 0
end

-- Target selection -------------------------------------------------------

function BNS.Scavenge.isNearPlayerBase(x, y)
    local state = BNS.Persistence.getState()
    for _, rec in pairs(state.playerBases) do
        if rec.hits >= BASE_HIT_MIN
                and BNS.dist(x, y, rec.x, rec.y) < BASE_EXCLUSION then
            return true
        end
    end
    return false
end

local function squareHasLoot(sq)
    local md = sq:getModData()
    if md and md.BNS_Looted
            and BNS.worldHours() - md.BNS_Looted < LOOT_COOLDOWN_H then
        return false
    end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        local c = obj.getContainer and obj:getContainer() or nil
        if c and c:getItems():size() > 0 then return true end
    end
    return false
end

-- Random probes beat a full area scan: cheap, and misses just mean the
-- NPC keeps wandering.
function BNS.Scavenge.findContainerSquare(zombie)
    local cell = getCell()
    if not cell then return nil end
    local cx = math.floor(zombie:getX())
    local cy = math.floor(zombie:getY())
    local cz = math.floor(zombie:getZ())
    for _ = 1, 40 do
        local x = cx + ZombRand(-SEARCH_RADIUS, SEARCH_RADIUS + 1)
        local y = cy + ZombRand(-SEARCH_RADIUS, SEARCH_RADIUS + 1)
        local sq = cell:getGridSquare(x, y, cz)
        if sq and not BNS.Scavenge.isNearPlayerBase(x, y) and squareHasLoot(sq) then
            return sq
        end
    end
    return nil
end

-- Called from WANDER. Returns true when a loot run started.
function BNS.Scavenge.tryStart(zombie, brain)
    if not BNS.Options().scavenging then return false end
    local sq = BNS.Scavenge.findContainerSquare(zombie)
    if not sq then return false end
    brain.program = BNS.Program.SCAVENGE
    brain.scav = {
        x = sq:getX(), y = sq:getY(), z = sq:getZ(),
        containersLeft = ZombRand(1, 4),
        rummage = 0,
    }
    return true
end

-- Looting ----------------------------------------------------------------

function BNS.Scavenge.addToStock(brain, fullType, value)
    brain.stock = brain.stock or {}
    for _, s in ipairs(brain.stock) do
        if s.item == fullType then
            s.count = s.count + 1
            return
        end
    end
    table.insert(brain.stock, { item = fullType, value = value, count = 1 })
end

-- Rifle every container on the square: take the valuables (up to the
-- caps), leave the cheap stuff, and scatter a piece or two of it on the
-- floor as evidence.
function BNS.Scavenge.lootSquare(zombie, brain, sq)
    local isTrader = brain.role == BNS.Role.TRADER
    local taken = 0
    local leftovers = {}

    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        local container = obj.getContainer and obj:getContainer() or nil
        if container then
            local items = container:getItems()
            for j = items:size() - 1, 0, -1 do
                local it = items:get(j)
                local v = BNS.Scavenge.itemValue(it)
                if v >= VALUE_THRESHOLD and taken < TAKE_CAP then
                    brain.loot = brain.loot or {}
                    if isTrader and BNS.Loadouts.BarterValues[it:getFullType()] then
                        BNS.Scavenge.addToStock(brain, it:getFullType(), v)
                        container:Remove(it)
                        taken = taken + 1
                    elseif #brain.loot < PACK_CAP then
                        table.insert(brain.loot, it:getFullType())
                        container:Remove(it)
                        taken = taken + 1
                    end
                elseif v < VALUE_THRESHOLD then
                    table.insert(leftovers, { item = it, container = container })
                end
            end
        end
    end

    local scatter = math.min(#leftovers, ZombRand(SCATTER_MAX) + 1)
    for k = 1, scatter do
        local left = leftovers[k]
        left.container:Remove(left.item)
        sq:AddWorldInventoryItem(left.item:getFullType(),
            ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
    end

    sq:getModData().BNS_Looted = BNS.worldHours()
    return taken
end

-- SCAVENGE program -------------------------------------------------------

BNS.Programs[BNS.Program.SCAVENGE] = function(zombie, brain, ctx)
    local sc = brain.scav
    if not sc then
        brain.program = BNS.Program.WANDER
        return
    end
    -- Bandits still notice prey mid-scavenge.
    if BNS.isBandit(zombie) and ctx.player and ctx.dist < 8
            and not ctx.player:isSneaking() then
        brain.scav = nil
        brain.program = BNS.Program.APPROACH
        return
    end

    local d = BNS.dist(zombie:getX(), zombie:getY(), sc.x, sc.y)
    if d > 1.5 then
        BNS.Programs.walkTo(zombie, sc.x, sc.y, sc.z, false)
        return
    end

    -- At the container: stand and rifle through it for a few seconds.
    BNS.Anim.set(zombie, brain, "idle")
    sc.rummage = sc.rummage + 1
    if sc.rummage < RUMMAGE_TICKS then
        if sc.rummage % 6 == 0 then zombie:playSound("PutItemInBag") end
        return
    end
    sc.rummage = 0

    local sq = getCell() and getCell():getGridSquare(sc.x, sc.y, sc.z) or nil
    if sq then BNS.Scavenge.lootSquare(zombie, brain, sq) end

    -- Pack full: run it to the vehicle instead of looting on.
    if BNS.Vehicles and BNS.Vehicles.wantsHaul(zombie, brain) then
        brain.scav = nil
        return
    end

    sc.containersLeft = sc.containersLeft - 1
    local nxt = sc.containersLeft > 0 and BNS.Scavenge.findContainerSquare(zombie) or nil
    if nxt then
        sc.x, sc.y, sc.z = nxt:getX(), nxt:getY(), nxt:getZ()
    else
        brain.scav = nil
        brain.program = BNS.Program.WANDER
    end
end
