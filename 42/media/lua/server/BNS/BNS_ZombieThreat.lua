--***********************************************************************
-- Bandits & Survivors — zombies vs the living (server)
--
-- NPCs are alive: zombies threaten them, hurt them and can kill them,
-- and NPCs prioritise killing nearby zombies over everything else.
-- The engine never makes real zombies attack our shells, so the
-- vulnerability side is simulated here: adjacent zombies land hits
-- (with player-style flinch/grab reactions) and crowds are lured onto
-- fighting NPCs.
--
-- The overwhelm rule: 1 living NPC for every 4 zombies within a 5-tile
-- radius. Worse odds than that and the NPC flees — except for the rare
-- one who decides to stand and fight.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Combat"
require "BNS/BNS_Anim"
require "BNS/BNS_Programs"

BNS.ZombieThreat = {}

local RADIUS       = 5    -- tiles: threat/ally counting radius
local RATIO        = 4    -- zombies per living NPC before it's "overwhelmed"
local CONTACT      = 1.2  -- tiles: zombies this close claw at the NPC
local GRAB_RANGE   = 0.9  -- tiles: close enough to grab
local HIT_CHANCE   = 35   -- % per adjacent zombie per scan (~1 scan/sec)
local GRAB_CHANCE  = 20   -- % per adjacent zombie per scan
local GRAB_BONUS   = 30   -- extra hit % while the NPC is held
local ZOMBIE_DMG   = 0.08 -- brain-health damage per landed zombie hit

-- Chance (%) to stand and fight when the odds say run. Rare by design.
local STAND_CHANCE = {
    [BNS.Tier.CIVILIAN] = 5,
    [BNS.Tier.THUG]     = 10,
    [BNS.Tier.MILITIA]  = 15,
}

-- Live java refs to each NPC's current zombie target. Kept out of mod
-- data on purpose (mod data must stay serialisable).
BNS.ZombieThreat.targets = {}

-- Pure assessment, offline-testable: given hostile zombies (as {x,y,d}
-- entries already filtered to the radius) and the number of living NPCs
-- in the same radius (self included), decide clear/fight/flee.
function BNS.ZombieThreat.assess(x, y, zombies, npcCount)
    if #zombies == 0 then return "clear", nil end
    local nearest, nd = nil, math.huge
    for _, z in ipairs(zombies) do
        local d = z.d or BNS.dist(x, y, z.x, z.y)
        if d < nd then nearest, nd = z, d end
    end
    if #zombies > RATIO * math.max(npcCount, 1) then
        return "flee", nearest
    end
    return "fight", nearest
end

-- A zombie in contact range claws and grabs like it would a player.
function BNS.ZombieThreat.zombieStrike(npc, brain, entry)
    if not brain.grabbedTimer and entry.d <= GRAB_RANGE
            and ZombRand(100) < GRAB_CHANCE then
        -- Grabbed: held in a struggle, unable to move or attack until
        -- they break free. Fitter tiers shake loose faster.
        local hold = 90 -- ~1.5s
        if brain.tier == BNS.Tier.CIVILIAN then hold = 150
        elseif brain.tier == BNS.Tier.THUG then hold = 120 end
        brain.grabbedTimer = hold
        BNS.Anim.set(npc, brain, "grabbed")
        npc:playSound("ZombieAttack")
    end
    local chance = HIT_CHANCE + (brain.grabbedTimer and GRAB_BONUS or 0)
    if ZombRand(100) < chance then
        BNS.Anim.pulse(npc, brain, "hit")
        npc:playSound("MaleBeingHit")
        BNS.Combat.damageNPC(npc, brain, ZOMBIE_DMG)
    end
end

-- One pass over the cell's zombie list: collect real zombies and count
-- allied NPCs inside the radius, apply contact strikes and lure the
-- crowd in. Returns verdict, nearest entry, and the threat centroid.
function BNS.ZombieThreat.scan(zombie, brain)
    local cell = getCell()
    local list = cell and cell:getZombieList() or nil
    if not list then return "clear", nil, nil end

    local x, y = zombie:getX(), zombie:getY()
    local zombies, npcCount = {}, 0
    local cx, cy = 0, 0
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and not z:isDead() then
            local d = BNS.dist(x, y, z:getX(), z:getY())
            if d <= RADIUS then
                if BNS.isNPC(z) then
                    npcCount = npcCount + 1
                else
                    table.insert(zombies, { x = z:getX(), y = z:getY(), d = d, obj = z })
                    cx = cx + z:getX()
                    cy = cy + z:getY()
                end
            end
        end
    end

    for _, entry in ipairs(zombies) do
        if entry.d <= CONTACT then
            BNS.ZombieThreat.zombieStrike(zombie, brain, entry)
        elseif ZombRand(100) < 50 and entry.obj.pathToLocationF then
            -- The dead converge on the living.
            entry.obj:pathToLocationF(x, y, zombie:getZ())
        end
    end

    local verdict, nearest = BNS.ZombieThreat.assess(x, y, zombies, npcCount)
    local centroid = nil
    if #zombies > 0 then
        centroid = { x = cx / #zombies, y = cy / #zombies }
    end
    return verdict, nearest, centroid
end

-- Turn a scan verdict into a program transition. Called by BNS_Brain.
function BNS.ZombieThreat.apply(zombie, brain, verdict, nearest, centroid)
    if verdict == "clear" then
        brain.standGround = nil
        BNS.ZombieThreat.targets[brain.id] = nil
        if brain.program == BNS.Program.FIGHTZ then
            brain.program = brain.resume
                or (brain.home and BNS.Program.DEFEND or BNS.Program.WANDER)
            brain.resume = nil
        end
        return
    end

    BNS.ZombieThreat.targets[brain.id] = nearest and nearest.obj or nil

    if verdict == "flee" then
        -- Decide once per threat episode whether this one is a stander.
        if brain.standGround == nil then
            brain.standGround = ZombRand(100) < (STAND_CHANCE[brain.tier] or 5)
            if brain.standGround then
                brain.speechCooldown = 0
                BNS.Say(zombie, brain, getText("UI_BNS_LastStand"))
            end
        end
        if not brain.standGround then
            brain.resume = nil
            brain.program = BNS.Program.FLEE
            brain.fleeUntil = 600
            brain.fleeFrom = centroid
            brain.warned = nil
            brain.warnTimer = nil
            return
        end
        -- A stander treats "flee" as "fight" and falls through.
    end

    -- fight: zombies inside the radius pre-empt whatever else was going
    -- on; remember it so the NPC picks the old task back up after.
    if brain.program ~= BNS.Program.FIGHTZ and brain.program ~= BNS.Program.FLEE then
        brain.resume = brain.program
        brain.program = BNS.Program.FIGHTZ
    end
end

-- FIGHTZ program: close on the nearest zombie and put it down using the
-- NPC's real weapon. No warning shouts — the dead don't negotiate.
BNS.Programs[BNS.Program.FIGHTZ] = function(zombie, brain, ctx)
    local target = BNS.ZombieThreat.targets[brain.id]
    if not target or target:isDead() then
        -- Wait for the next scan to hand out a new target or stand down.
        BNS.Anim.set(zombie, brain, "idle")
        return
    end
    local w = brain.weapon or {}
    local d = BNS.dist(zombie:getX(), zombie:getY(), target:getX(), target:getY())
    if w.gun then
        if d > w.range then
            BNS.Programs.walkTo(zombie, target:getX(), target:getY(), target:getZ(), true)
        else
            BNS.Anim.set(zombie, brain, "aim")
        end
        BNS.Combat.attackZombie(zombie, brain, target)
    else
        if d > (w.range or 1.3) then
            BNS.Programs.walkTo(zombie, target:getX(), target:getY(), target:getZ(), true)
        end
        BNS.Combat.attackZombie(zombie, brain, target)
    end
end
