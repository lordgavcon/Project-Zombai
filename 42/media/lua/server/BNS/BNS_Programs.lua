--***********************************************************************
-- Bandits & Survivors — brain programs (server)
--
-- Each program is a function(zombie, brain, ctx) run every brain tick.
-- ctx carries the nearest player and distance. Programs mutate
-- brain.program to transition; BNS_Brain dispatches.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Archetypes"
require "BNS/BNS_Combat"
require "BNS/BNS_Anim"

BNS.Programs = {}

-- Speech: broadcast to clients so text appears over the NPC's head.
function BNS.Say(zombie, brain, text)
    brain.speechCooldown = brain.speechCooldown or 0
    if brain.speechCooldown > 0 then return end
    brain.speechCooldown = 300
    local args = { id = zombie:getOnlineID(), text = text, x = zombie:getX(), y = zombie:getY() }
    if isServer() then
        sendServerCommand(BNS.CommandModule, "say", args)
    elseif BNS.Client and BNS.Client.showSpeech then
        BNS.Client.showSpeech(args) -- single player: call straight through
    end
end

-- Movement --------------------------------------------------------------
--
-- Command budget. A shell is moved by the engine's own pathfinder, so
-- every extra order we push at it restarts that movement mid-step --
-- which is what made NPCs skate around instead of walking. Vanilla
-- zombies get re-tasked a couple of times a second at most, so we hold
-- ourselves to the same cadence: a path is issued at most every few
-- brain ticks, and only re-issued early if the goal really moved.

BNS.Programs.REPATH_TICKS = 3   -- full brain ticks (~0.5s) between path orders
BNS.Programs.REPATH_DIST = 1.5  -- ...unless the destination moved this far

function BNS.Programs.walkTo(zombie, x, y, z, run)
    local brain = BNS.brain(zombie)
    if brain then
        brain.pathCooldown = (brain.pathCooldown or 0) - 1
        local movedFar = brain.pathX == nil
            or BNS.dist(x, y, brain.pathX, brain.pathY) >= BNS.Programs.REPATH_DIST
        local gearChanged = brain.pathRun ~= (run == true)
        -- Still walking the order it already has: leave it alone.
        if brain.pathCooldown > 0 and not movedFar and not gearChanged then
            return
        end
        brain.pathCooldown = BNS.Programs.REPATH_TICKS
        brain.pathX, brain.pathY, brain.pathRun = x, y, run == true
        brain.pathCount = (brain.pathCount or 0) + 1
        brain.stopped = nil
    end
    if zombie.pathToLocationF then
        zombie:pathToLocationF(x, y, z or 0)
    elseif zombie.pathToLocation then
        zombie:pathToLocation(math.floor(x), math.floor(y), z or 0)
    end
    if zombie.setRunning then zombie:setRunning(run == true) end
    if brain then BNS.Anim.set(zombie, brain, run and "run" or "walk") end
end

-- Come to a halt. Attacks are gated on not running, so a program that
-- wants to fight has to actually stop first.
function BNS.Programs.stopMoving(zombie, brain, mode)
    -- Halting is a one-off order, not something to repeat every tick:
    -- re-pathing a standing NPC onto its own square 60 times a second is
    -- itself a source of drift.
    if brain and brain.stopped then
        if mode and brain.animMode ~= mode then BNS.Anim.set(zombie, brain, mode) end
        return
    end
    if zombie.setRunning then zombie:setRunning(false) end
    if zombie.StopAllActionQueue then zombie:StopAllActionQueue() end
    -- Cancelling the path is the part that matters: a shell keeps walking
    -- to its last pathToLocation target forever otherwise, which is why
    -- NPCs never stood still. Re-pathing onto its own square is the
    -- fallback that works even where the clear calls don't exist.
    if zombie.clearPath then pcall(function() zombie:clearPath() end) end
    if zombie.setPath2 then pcall(function() zombie:setPath2(nil) end) end
    if zombie.pathToLocationF then
        pcall(function()
            zombie:pathToLocationF(zombie:getX(), zombie:getY(), zombie:getZ())
        end)
    end
    if zombie.setMoving then pcall(function() zombie:setMoving(false) end) end
    if brain then
        -- Forget the remembered path so the next walkTo re-issues it.
        brain.pathX, brain.pathY, brain.pathRun = nil, nil, nil
        brain.pathCooldown = 0
        brain.stopped = true
        BNS.Anim.set(zombie, brain, mode or "idle")
    end
end

local function arrived(zombie, brain, dist)
    if not brain.targetX then return true end
    return BNS.dist(zombie:getX(), zombie:getY(), brain.targetX, brain.targetY) < (dist or 2)
end

-- Threat perception: does this NPC currently notice the player?
local function noticesPlayer(zombie, ctx)
    if not ctx.player then return false end
    if ctx.dist > 30 then return false end
    if ctx.dist < 8 then return true end
    -- Beyond close range, sneaking players in cover go unnoticed.
    return not ctx.player:isSneaking() or ZombRand(100) < 10
end

-- WANDER ----------------------------------------------------------------

-- Wandering is a slow amble with pauses, not a forced march: on arriving
-- somewhere an NPC usually stands around for a while before picking the
-- next destination. Counted in full brain ticks (~6 per second).
BNS.Programs.REST_CHANCE = 65
BNS.Programs.REST_MIN = 60   -- ~10s
BNS.Programs.REST_MAX = 300  -- ~50s

-- Resting is only for quiet moments. "Quiet" means no zombie being
-- tracked: a nearby *player* must not count, or NPCs would never stand
-- still while you were watching them, which is the whole complaint.
-- Bandits who notice you have already switched to APPROACH above.
local function threatened(zombie, brain, ctx)
    return BNS.ZombieThreat ~= nil and BNS.ZombieThreat.targets[brain.id] ~= nil
end

BNS.Programs[BNS.Program.WANDER] = function(zombie, brain, ctx)
    if brain.role == BNS.Role.BANDIT and noticesPlayer(zombie, ctx) then
        brain.program = BNS.Program.APPROACH
        return
    end
    -- Mid-rest: stand still and look around.
    if brain.restUntil then
        brain.restUntil = brain.restUntil - 1
        if brain.restUntil > 0 and not threatened(zombie, brain, ctx) then
            BNS.Programs.stopMoving(zombie, brain, "idle")
            return
        end
        brain.restUntil = nil
    end
    -- Now and then, go loot a nearby building instead of drifting on.
    if BNS.Scavenge and ZombRand(400) == 0
            and BNS.Scavenge.tryStart(zombie, brain) then
        return
    end
    -- And keep an eye out for a usable vehicle to claim.
    if BNS.Vehicles and not brain.vehicle and ZombRand(600) == 0 then
        BNS.Vehicles.tryClaim(zombie, brain)
    end
    if arrived(zombie, brain, 3) then
        -- Arrived: usually take a breather before choosing somewhere new.
        if not threatened(zombie, brain, ctx)
                and ZombRand(100) < BNS.Programs.REST_CHANCE then
            brain.restUntil = ZombRand(BNS.Programs.REST_MIN, BNS.Programs.REST_MAX)
            brain.targetX, brain.targetY = nil, nil
            BNS.Programs.stopMoving(zombie, brain, "idle")
            return
        end
        -- Pick a new destination: nearby drift, occasionally a long trek.
        local reach = ZombRand(100) < 10 and 200 or 30
        brain.targetX = zombie:getX() + ZombRand(-reach, reach + 1)
        brain.targetY = zombie:getY() + ZombRand(-reach, reach + 1)
    end
    BNS.Programs.walkTo(zombie, brain.targetX, brain.targetY, 0, false)
end

-- APPROACH (bandits closing on a player) --------------------------------

BNS.Programs[BNS.Program.APPROACH] = function(zombie, brain, ctx)
    local p = ctx.player
    if not p or ctx.dist > 45 then
        brain.program = BNS.Program.WANDER
        return
    end
    local opts = BNS.Options()
    -- Decide intent once, when first getting close.
    if ctx.dist < 6 and not brain.intent then
        local robChance = 0
        if opts.robbery then
            if brain.tier == BNS.Tier.CIVILIAN then robChance = 65
            elseif brain.tier == BNS.Tier.THUG then robChance = 35 end
        end
        -- Nobody tries to mug someone aiming a gun at them.
        if p:isAiming() then robChance = 0 end
        brain.intent = (ZombRand(100) < robChance) and BNS.Program.ROB or BNS.Program.ATTACK
    end
    if brain.intent and ctx.dist < 4 then
        brain.program = brain.intent
        return
    end
    -- Gunners open fire before closing.
    if brain.weapon and brain.weapon.gun and ctx.dist < brain.weapon.range then
        brain.program = BNS.Program.ATTACK
        return
    end
    BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
end

-- ROB -------------------------------------------------------------------

local function stealFromPlayer(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local stolen = {}
    -- Take money first, then up to two random non-equipped items.
    local money = inv:getFirstTypeRecurse("Money")
    if money then
        inv:Remove(money)
        table.insert(stolen, money:getFullType())
    end
    for _ = 1, 2 do
        if items:size() == 0 then break end
        local it = items:get(ZombRand(items:size()))
        if it and not player:isEquipped(it) and not it:isFavorite() then
            inv:Remove(it)
            table.insert(stolen, it:getFullType())
        end
    end
    return stolen
end

BNS.Programs[BNS.Program.ROB] = function(zombie, brain, ctx)
    local p = ctx.player
    if not p or ctx.dist > 10 then brain.program = BNS.Program.WANDER return end
    -- Player pulled a weapon up: robbery turns into a fight.
    if p:isAiming() then
        brain.program = BNS.Program.ATTACK
        return
    end
    if ctx.dist > 2 then
        BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        BNS.Say(zombie, brain, getText("UI_BNS_RobberyDemand"))
        return
    end
    brain.robTimer = (brain.robTimer or 120) - 1 -- ~2s standoff, then take
    if brain.robTimer <= 0 then
        local stolen = stealFromPlayer(p)
        if isServer() then
            sendServerCommand(p, BNS.CommandModule, "robbed", { items = stolen })
        end
        brain.speechCooldown = 0
        BNS.Say(zombie, brain, getText("UI_BNS_RobberyDone"))
        brain.robTimer = nil
        brain.intent = nil
        brain.program = BNS.Program.FLEE
        brain.fleeUntil = BNS.Programs.FLEE_TICKS * 2
    end
end

-- ATTACK ----------------------------------------------------------------

-- Every fresh engagement opens with a warning shout and a short hold
-- during which no damage is dealt, so armed bandits telegraph danger
-- before the first shot or swing. The timer itself counts down every
-- engine tick in BNS_Brain.
local function warnLine(brain)
    local def = BNS.Archetypes.get(brain.archetype)
    if def and def.warn then return getText(def.warn) end
    if brain.tier == BNS.Tier.MILITIA then return getText("UI_BNS_WarnMilitia") end
    if brain.tier == BNS.Tier.THUG then return getText("UI_BNS_WarnThug") end
    return getText("UI_BNS_WarnCivilian")
end

function BNS.Programs.startWarning(zombie, brain)
    if brain.warned or brain.warnTimer then return end
    brain.warnTimer = 150 -- ~2.5s
    brain.firstShot = true
    brain.speechCooldown = 0
    BNS.Say(zombie, brain, warnLine(brain))
end

local function endEngagement(brain)
    brain.warned = nil
    brain.warnTimer = nil
    brain.intent = nil
    brain.program = brain.home and BNS.Program.DEFEND or BNS.Program.WANDER
end

BNS.Programs[BNS.Program.ATTACK] = function(zombie, brain, ctx)
    local p = ctx.player
    if not p or ctx.dist > 50 or p:isDead() then
        endEngagement(brain)
        return
    end
    BNS.Programs.startWarning(zombie, brain)
    local w = brain.weapon or {}
    if not brain.warned then
        -- Warning phase: gunners stand and level their weapon; melee
        -- bandits keep closing but hold their swing.
        if w.gun then
            BNS.Anim.set(zombie, brain, "aim")
        elseif ctx.dist > (w.range or 1.3) then
            BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        else
            BNS.Anim.set(zombie, brain, "idle")
        end
        return
    end
    -- Close the distance at a run, or stand and fight -- never both at
    -- once. BNS.Combat refuses to attack while running.
    if w.gun then
        if ctx.dist > w.range * 0.8 then
            BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        else
            BNS.Programs.stopMoving(zombie, brain, "aim")
            BNS.Combat.attack(zombie, brain, p)
        end
    else
        if ctx.dist > (w.range or 1.3) then
            BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        else
            BNS.Programs.stopMoving(zombie, brain, "idle")
            BNS.Combat.attack(zombie, brain, p)
        end
    end
end

-- FLEE ------------------------------------------------------------------

-- Flee timers count full brain ticks (~6 per second), not engine ticks.
BNS.Programs.FLEE_TICKS = 30     -- ~5s of running away
BNS.Programs.FLEE_COOLDOWN = 60  -- ~10s afterwards where they will not flee again

BNS.Programs[BNS.Program.FLEE] = function(zombie, brain, ctx)
    brain.fleeUntil = (brain.fleeUntil or BNS.Programs.FLEE_TICKS) - 1
    if brain.fleeUntil <= 0 then
        brain.fleeUntil = nil
        brain.fleeFrom = nil
        -- Running is over: hold a window where they stand their ground
        -- instead of immediately bolting again.
        brain.fleeCooldown = BNS.Programs.FLEE_COOLDOWN
        brain.program = BNS.Program.WANDER
        return
    end
    -- Run from the recorded threat (a zombie mob's centroid) when there
    -- is one; otherwise from the nearest player.
    local fx, fy
    if brain.fleeFrom then
        fx, fy = brain.fleeFrom.x, brain.fleeFrom.y
    elseif ctx.player then
        fx, fy = ctx.player:getX(), ctx.player:getY()
    end
    if fx then
        local dx = zombie:getX() - fx
        local dy = zombie:getY() - fy
        local d = math.max(BNS.dist(0, 0, dx, dy), 0.1)
        BNS.Programs.walkTo(zombie, zombie:getX() + dx / d * 20, zombie:getY() + dy / d * 20, 0, true)
    end
end

-- DEFEND (POI garrison) -------------------------------------------------

BNS.Programs[BNS.Program.DEFEND] = function(zombie, brain, ctx)
    local home = brain.home
    if not home then brain.program = BNS.Program.WANDER return end
    -- Call out to anyone on the approach before it comes to shooting:
    -- the player's chance to realise the place is held and turn back.
    if BNS.Signs and ctx.player and ctx.dist >= 15 and ctx.dist <= 30 then
        BNS.Signs.challenge(zombie, brain)
    end
    -- Engage players who come within the perimeter.
    if ctx.player and ctx.dist < 15 and noticesPlayer(zombie, ctx) then
        brain.program = BNS.Program.ATTACK
        return
    end
    local dHome = BNS.dist(zombie:getX(), zombie:getY(), home.x, home.y)
    if dHome > (home.radius or 12) then
        BNS.Programs.walkTo(zombie, home.x, home.y, 0, false)
    elseif ZombRand(600) == 0 then
        -- Patrol drift inside the perimeter.
        BNS.Programs.walkTo(zombie,
            home.x + ZombRand(-(home.radius or 10), (home.radius or 10) + 1),
            home.y + ZombRand(-(home.radius or 10), (home.radius or 10) + 1), 0, false)
    end
end

-- TRADE (traders/survivors idling near players) -------------------------

-- A trader you cannot catch is no use, so they plant themselves as soon
-- as a customer is in reach and turn to face them. Survivors are less
-- obliging and only stop once you are right beside them.
BNS.Programs.TRADER_STOP_DIST = 5
BNS.Programs.SURVIVOR_STOP_DIST = 3

BNS.Programs[BNS.Program.TRADE] = function(zombie, brain, ctx)
    local stopDist = (brain.role == BNS.Role.TRADER)
        and BNS.Programs.TRADER_STOP_DIST or BNS.Programs.SURVIVOR_STOP_DIST
    if ctx.player and ctx.dist < stopDist then
        BNS.Programs.stopMoving(zombie, brain, "idle")
        brain.restUntil = nil -- waiting on the customer, not resting
        if zombie.faceThisObject then
            pcall(function() zombie:faceThisObject(ctx.player) end)
        end
        return
    end
    BNS.Programs[BNS.Program.WANDER](zombie, brain, ctx)
end
