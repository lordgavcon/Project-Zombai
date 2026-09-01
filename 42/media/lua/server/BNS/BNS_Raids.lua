--***********************************************************************
-- Bandits & Survivors — base raids & sabotage (server)
--
-- Finds player bases (MP safehouses directly; elsewhere a heuristic
-- that watches where players repeatedly spend time), then periodically
-- sends bandit squads against them. Raiders path to the base, smash
-- barricades and player-built walls, sabotage generators and steal
-- from containers before melting away.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Archetypes"
require "BNS/BNS_Persistence"
require "BNS/BNS_Spawner"
require "BNS/BNS_Programs"

BNS.Raids = {}

-- Base detection --------------------------------------------------------

-- Heuristic samples: playerBases[key] = {x, y, hits, lastRaid}
local function sampleKey(x, y)
    return math.floor(x / 30) .. "_" .. math.floor(y / 30)
end

function BNS.Raids.samplePlayerPositions()
    local state = BNS.Persistence.getState()
    for _, p in ipairs(BNS.getPlayers()) do
        local key = sampleKey(p:getX(), p:getY())
        local rec = state.playerBases[key]
        if not rec then
            rec = { x = math.floor(p:getX()), y = math.floor(p:getY()), hits = 0, lastRaid = 0 }
            state.playerBases[key] = rec
        end
        rec.hits = rec.hits + 1
    end
    -- MP safehouses count as confirmed bases immediately.
    if SafeHouse and SafeHouse.getSafehouseList then
        local list = SafeHouse.getSafehouseList()
        for i = 0, list:size() - 1 do
            local sh = list:get(i)
            local cx = sh:getX() + math.floor(sh:getW() / 2)
            local cy = sh:getY() + math.floor(sh:getH() / 2)
            local key = sampleKey(cx, cy)
            state.playerBases[key] = state.playerBases[key]
                or { x = cx, y = cy, hits = 0, lastRaid = 0 }
            state.playerBases[key].hits = 999 -- confirmed
        end
    end
end

-- A location is a "base" once players have been sampled there often
-- enough (sampled hourly, so ~12 in-game hours of presence).
local BASE_HIT_THRESHOLD = 12

-- Raid scheduling --------------------------------------------------------

function BNS.Raids.tryLaunchRaid()
    local opts = BNS.Options()
    if not opts.raids then return end
    local state = BNS.Persistence.getState()
    local now = BNS.worldHours()

    for _, baseRec in pairs(state.playerBases) do
        if baseRec.hits >= BASE_HIT_THRESHOLD
                and now - (baseRec.lastRaid or 0) >= opts.raidCooldown
                and ZombRand(100) < 25 then
            baseRec.lastRaid = now
            BNS.Raids.launchRaid(baseRec)
            return -- at most one raid per check
        end
    end
end

function BNS.Raids.launchRaid(baseRec)
    local opts = BNS.Options()
    local tier = (opts.militia and ZombRand(100) < 50) and BNS.Tier.MILITIA or BNS.Tier.THUG
    local size = tier == BNS.Tier.MILITIA and ZombRand(3, 6) or ZombRand(2, 4)
    local squadId = "raid_" .. tostring(ZombRand(100000))
    -- Raiders come themed to the base's region (police/thugs near towns,
    -- ex-military near military country).
    local archetype = BNS.Archetypes.roll(baseRec.x, baseRec.y, tier)

    -- Stage the squad a few hundred tiles out so they arrive on foot.
    local angle = ZombRandFloat(0, 2 * math.pi)
    local sx = baseRec.x + math.floor(math.cos(angle) * 150)
    local sy = baseRec.y + math.floor(math.sin(angle) * 150)

    for i = 1, size do
        local rec = BNS.Persistence.newRecord(BNS.Role.BANDIT, tier,
            sx + ZombRand(-3, 4), sy + ZombRand(-3, 4), 0)
        rec.squad = squadId
        rec.archetype = archetype
        rec.weapon = BNS.Spawner.rollWeapon(tier, archetype)
        rec.program = BNS.Program.RAID
        rec.targetX, rec.targetY = baseRec.x, baseRec.y
        rec.raid = { x = baseRec.x, y = baseRec.y, loot = 0 }
    end
    BNS.log("raid launched on base at " .. baseRec.x .. "," .. baseRec.y
        .. " tier=" .. tier .. " size=" .. size)

    if isServer() then
        sendServerCommand(BNS.CommandModule, "raidWarning", { x = baseRec.x, y = baseRec.y })
    end
end

-- Sabotage helpers -------------------------------------------------------

local function findSabotageTarget(zombie, radius)
    local cx, cy, cz = math.floor(zombie:getX()), math.floor(zombie:getY()), math.floor(zombie:getZ())
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = getCell():getGridSquare(cx + dx, cy + dy, cz)
            if sq then
                for i = 0, sq:getObjects():size() - 1 do
                    local obj = sq:getObjects():get(i)
                    -- Player-built structures and barricades are targets.
                    if instanceof(obj, "IsoThumpable") then return obj end
                    if instanceof(obj, "IsoGenerator") and obj:isActivated() then return obj end
                    if obj.getBarricadeForCharacter then
                        local bar = obj:getBarricadeForCharacter(nil)
                        if bar then return bar end
                    end
                end
            end
        end
    end
    return nil
end

local function sabotage(zombie, brain, obj)
    brain.attackTimer = (brain.attackTimer or 0) - 1
    if brain.attackTimer > 0 then return end
    brain.attackTimer = 90

    zombie:playSound("BreakDoor")
    if instanceof(obj, "IsoGenerator") then
        obj:setActivated(false)
        obj:setCondition(math.max(obj:getCondition() - 20, 0))
    elseif obj.Damage then
        obj:Damage(15)
    elseif obj.setHealth and obj.getHealth then
        obj:setHealth(obj:getHealth() - 100)
        if obj:getHealth() <= 0 and obj.destroy then obj:destroy() end
    end
end

local function stealFromNearbyContainer(zombie, brain)
    local sq = zombie:getCurrentSquare()
    if not sq then return false end
    for i = 0, sq:getObjects():size() - 1 do
        local obj = sq:getObjects():get(i)
        local container = obj.getContainer and obj:getContainer() or nil
        if container and container:getItems():size() > 0 then
            local items = container:getItems()
            local it = items:get(ZombRand(items:size()))
            if it then
                container:Remove(it)
                brain.raid.loot = (brain.raid.loot or 0) + 1
                return true
            end
        end
    end
    return false
end

-- RAID program -----------------------------------------------------------

BNS.Programs[BNS.Program.RAID] = function(zombie, brain, ctx)
    local raid = brain.raid
    if not raid then brain.program = BNS.Program.WANDER return end

    -- Defenders shooting back take priority.
    if ctx.player and ctx.dist < 10 and ctx.player:isAiming() then
        brain.program = BNS.Program.ATTACK
        return
    end

    local dBase = BNS.dist(zombie:getX(), zombie:getY(), raid.x, raid.y)
    if dBase > 8 then
        BNS.Programs.walkTo(zombie, raid.x, raid.y, 0, true)
        return
    end

    -- Inside the base area: break things, steal, then withdraw.
    local target = findSabotageTarget(zombie, 6)
    if target then
        local tx = target.getX and target:getX() or raid.x
        local ty = target.getY and target:getY() or raid.y
        if BNS.dist(zombie:getX(), zombie:getY(), tx, ty) > 1.6 then
            BNS.Programs.walkTo(zombie, tx, ty, 0, true)
        else
            sabotage(zombie, brain, target)
        end
        return
    end

    if stealFromNearbyContainer(zombie, brain) then return end

    -- Wander within the base looking for more, then eventually leave.
    raid.duration = (raid.duration or 1800) - 1
    if raid.duration <= 0 or (brain.raid.loot or 0) >= 6 then
        brain.raid = nil
        brain.program = BNS.Program.FLEE
        brain.fleeUntil = 1200
    elseif ZombRand(120) == 0 then
        BNS.Programs.walkTo(zombie,
            raid.x + ZombRand(-6, 7), raid.y + ZombRand(-6, 7), 0, false)
    end
end
