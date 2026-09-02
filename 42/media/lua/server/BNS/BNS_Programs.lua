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

function BNS.Programs.walkTo(zombie, x, y, z, run)
    if zombie.pathToLocationF then
        zombie:pathToLocationF(x, y, z or 0)
    elseif zombie.pathToLocation then
        zombie:pathToLocation(math.floor(x), math.floor(y), z or 0)
    end
    if zombie.setRunning then zombie:setRunning(run == true) end
    local brain = BNS.brain(zombie)
    if brain then BNS.Anim.set(zombie, brain, run and "run" or "walk") end
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

BNS.Programs[BNS.Program.WANDER] = function(zombie, brain, ctx)
    if brain.role == BNS.Role.BANDIT and noticesPlayer(zombie, ctx) then
        brain.program = BNS.Program.APPROACH
        return
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
        -- Pick a new destination: nearby drift, occasionally a long trek.
        local reach = ZombRand(100) < 15 and 300 or 40
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
        brain.fleeUntil = 600
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
    if w.gun then
        -- Keep distance and shoot; close only if the player hides.
        if ctx.dist > w.range * 0.8 then
            BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        else
            BNS.Anim.set(zombie, brain, "aim")
        end
        BNS.Combat.attack(zombie, brain, p)
    else
        if ctx.dist > (w.range or 1.3) then
            BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        else
            BNS.Anim.set(zombie, brain, "idle")
        end
        BNS.Combat.attack(zombie, brain, p)
    end
end

-- FLEE ------------------------------------------------------------------

BNS.Programs[BNS.Program.FLEE] = function(zombie, brain, ctx)
    brain.fleeUntil = (brain.fleeUntil or 600) - 1
    if brain.fleeUntil <= 0 then
        brain.fleeUntil = nil
        brain.fleeFrom = nil
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

BNS.Programs[BNS.Program.TRADE] = function(zombie, brain, ctx)
    -- Traders stand still while a customer is close, else wander slowly.
    if ctx.player and ctx.dist < 6 then
        if zombie.StopAllActionQueue then zombie:StopAllActionQueue() end
        return
    end
    BNS.Programs[BNS.Program.WANDER](zombie, brain, ctx)
end
