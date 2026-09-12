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
require "BNS/BNS_Squads"
require "BNS/BNS_Senses"

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

-- Does the engine still hold a path for this shell?
--
-- The repath budget above assumes an order we issued is still being
-- walked. When something else drops it -- the shell's own AI changing
-- state, a blocked square, a failed path -- the budget turns into a gag:
-- the NPC stands still and we politely decline to re-order it. That is
-- what "bandits don't walk around" looks like from the outside. Asking
-- the shell settles it.
--
-- hasPath()/isPathing() are both on IsoZombie in B42, but a signature
-- that throws must not be retried on a tick (see CLAUDE.md), so the form
-- that works is probed once and remembered, and a thrower is written off
-- for the session. "Don't know" means "assume it is still walking", which
-- leaves the old budget behaviour exactly as it was.
BNS.Programs.pathProbe = nil -- nil = untried, "hasPath"/"isPathing"/false = settled

function BNS.Programs.hasEnginePath(zombie)
    if BNS.Programs.pathProbe == false then return true end
    if BNS.Programs.pathProbe then
        local ok, has = pcall(function() return zombie[BNS.Programs.pathProbe](zombie) end)
        if ok then return has == true end
        BNS.Programs.pathProbe = false
        return true
    end
    for _, name in ipairs({ "hasPath", "isPathing" }) do
        if zombie[name] then
            local ok, has = pcall(function() return zombie[name](zombie) end)
            if ok and type(has) == "boolean" then
                BNS.Programs.pathProbe = name
                return has
            end
        end
    end
    BNS.Programs.pathProbe = false
    return true
end

-- Chasing at a sprint ---------------------------------------------------
--
-- `setRunning(true)` gives a shell the zombie sprint, which is faster
-- than a person and unrunnable-from. The speed modifier pulls it back to
-- something a player can outpace by choosing their ground -- which is the
-- point: a chase you cannot lose is not a chase.
--
-- Unverified setter, so: candidate list, probed once, written off if it
-- throws, and clamped well away from zero. A speed modifier of nothing is
-- an NPC that never moves again, which is the setUseless lesson wearing a
-- different hat.
BNS.Programs.SPEED_SETTERS = { "setSpeedMod", "setPathSpeed" }
BNS.Programs.SPEED_FLOOR = 0.3
BNS.Programs.speedProbe = nil -- nil = untried, method name, false = written off

function BNS.Programs.runSpeed()
    local s = BNS.Options().runSpeed or BNS.Behaviour.runSpeed
    return math.max(math.min(s, 1.0), BNS.Programs.SPEED_FLOOR)
end

-- Only written when it changes: this runs behind every path order.
function BNS.Programs.setSpeed(zombie, brain, value)
    if BNS.Programs.speedProbe == false then return false end
    if brain.speedMod == value then return true end
    local names = BNS.Programs.speedProbe and { BNS.Programs.speedProbe }
        or BNS.Programs.SPEED_SETTERS
    for _, name in ipairs(names) do
        if zombie[name] and pcall(function() zombie[name](zombie, value) end) then
            BNS.Programs.speedProbe = name
            brain.speedMod = value
            return true
        end
    end
    BNS.Programs.speedProbe = false
    BNS.log("no usable movement-speed setter on this build; NPCs sprint at full speed")
    return false
end

function BNS.Programs.walkTo(zombie, x, y, z, run)
    local brain = BNS.brain(zombie)
    if brain then
        brain.pathCooldown = (brain.pathCooldown or 0) - 1
        local movedFar = brain.pathX == nil
            or BNS.dist(x, y, brain.pathX, brain.pathY) >= BNS.Programs.REPATH_DIST
        local gearChanged = brain.pathRun ~= (run == true)
        -- Ordered somewhere and no longer walking there: re-issue now
        -- rather than waiting out a budget meant for a shell in motion.
        local lostPath = brain.pathX ~= nil and not BNS.Programs.hasEnginePath(zombie)
        if lostPath then brain.pathLost = (brain.pathLost or 0) + 1 end
        -- Still walking the order it already has: leave it alone.
        if brain.pathCooldown > 0 and not movedFar and not gearChanged and not lostPath then
            return
        end
        brain.pathCooldown = BNS.Programs.REPATH_TICKS
        brain.pathX, brain.pathY, brain.pathRun = x, y, run == true
        brain.pathCount = (brain.pathCount or 0) + 1
        brain.stopped = nil
        -- Moving spoils a settled aim, the same way it does for a player.
        brain.aimTicks = 0
    end
    if zombie.pathToLocationF then
        zombie:pathToLocationF(x, y, z or 0)
    elseif zombie.pathToLocation then
        zombie:pathToLocation(math.floor(x), math.floor(y), z or 0)
    end
    if zombie.setRunning then zombie:setRunning(run == true) end
    if brain then
        -- A run is a person's run, not a zombie sprint.
        BNS.Programs.setSpeed(zombie, brain, run and BNS.Programs.runSpeed() or 1.0)
        BNS.Anim.set(zombie, brain, run and "run" or "walk")
    end
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
-- BNS.Senses.observe has already answered this for the tick, walls and
-- all -- noticing someone through a wall was the other half of the
-- perfect-knowledge problem.
local function noticesPlayer(zombie, ctx)
    return ctx.visible == true
end

-- WANDER ----------------------------------------------------------------

-- Wandering is a slow amble with pauses, not a forced march: on arriving
-- somewhere an NPC stands around for a few seconds, has a look about for
-- whoever might be out there, and then picks somewhere new. Counted in
-- full brain ticks (~6 per second).
--
-- The balance here is the whole program. It used to rest two arrivals in
-- three for up to fifty seconds at a time, and a squad's destinations
-- came out of a ten-tile bubble centred on an anchor that follows its own
-- members -- so the destination routinely landed on the tile the bandit
-- was already standing on. They "arrived" at once, rolled a rest, and
-- stood there: a bandit in a squad moved two percent of the time, which
-- from the outside is a bandit that does not walk at all.
BNS.Programs.REST_CHANCE = 35
BNS.Programs.REST_MIN = 30   -- ~5s
BNS.Programs.REST_MAX = 120  -- ~20s

-- Somewhere nearer than this is not somewhere to go. Without it a
-- destination can be the tile underfoot.
BNS.Programs.WANDER_MIN = 8
BNS.Programs.WANDER_REACH = 30  -- usual drift for a bandit with no group
BNS.Programs.WANDER_TREK = 200  -- and the occasional long walk

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
    -- Mid-rest: stand still and look around. Not while the group has
    -- left them behind, though -- catching up comes first.
    if brain.restUntil then
        brain.restUntil = brain.restUntil - 1
        if brain.restUntil > 0 and not threatened(zombie, brain, ctx)
                and not BNS.Squads.strayed(brain, zombie:getX(), zombie:getY()) then
            BNS.Programs.stopMoving(zombie, brain, "idle")
            -- A pause is a look round, not a nap: the same scan SEARCH
            -- uses when it arrives somewhere. It is also the honest
            -- animation for a bandit who is between errands and would
            -- very much like to find somebody.
            BNS.Senses.lookAround(zombie, true)
            return
        end
        brain.restUntil = nil
        BNS.Senses.lookAround(zombie, false)
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
    -- Someone in the group decides it is time to move on, and then the
    -- whole group goes -- rather than one bandit wandering off alone.
    local x, y = zombie:getX(), zombie:getY()
    BNS.Squads.arrived(brain, x, y)
    BNS.Squads.maybeTrek(brain)

    if arrived(zombie, brain, 3) then
        -- Arrived: sometimes take a breather before choosing somewhere new.
        local sx, sy, urgent = BNS.Squads.wanderTarget(brain, x, y)
        if not urgent and not threatened(zombie, brain, ctx)
                and ZombRand(100) < BNS.Programs.REST_CHANCE then
            brain.restUntil = ZombRand(BNS.Programs.REST_MIN, BNS.Programs.REST_MAX)
            brain.targetX, brain.targetY = nil, nil
            BNS.Programs.stopMoving(zombie, brain, "idle")
            return
        end
        if sx then
            -- In a squad: destinations come from the group's bubble, so
            -- staying together is where they choose to go rather than a
            -- correction dragged out of them afterwards.
            brain.targetX, brain.targetY = sx, sy
        else
            -- Alone: nearby drift, occasionally a long trek -- and never
            -- a destination they are already standing on.
            local reach = ZombRand(100) < 10
                and BNS.Programs.WANDER_TREK or BNS.Programs.WANDER_REACH
            brain.targetX, brain.targetY = BNS.scatterPoint(x, y, x, y,
                reach, BNS.Programs.WANDER_MIN)
        end
    elseif BNS.Squads.strayed(brain, x, y) then
        -- Wandered out of the group's reach part way to somewhere else.
        -- Abandon that errand and rejoin: a bandit alone in the open is
        -- not what a squad is for.
        local sx, sy = BNS.Squads.wanderTarget(brain, x, y)
        if sx then
            brain.targetX, brain.targetY = sx, sy
            brain.restUntil = nil
        end
    end
    BNS.Programs.walkTo(zombie, brain.targetX, brain.targetY, 0, false)
end

-- APPROACH (bandits closing on a player) --------------------------------

BNS.Programs[BNS.Program.APPROACH] = function(zombie, brain, ctx)
    local p = ctx.player
    -- Lost them first, and only then "too far to bother": giving up
    -- because of a distance they cannot see is the perfect knowledge this
    -- was all meant to remove.
    if ctx.lost then
        brain.program = BNS.Program.SEARCH
        return
    end
    if not p or (ctx.knownDist or ctx.dist) > 45 then
        brain.program = BNS.Program.WANDER
        return
    end
    local opts = BNS.Options()
    -- Decide intent once, when first getting close.
    if ctx.dist < 6 and not brain.intent then
        -- Every bandit robs on the same odds. Tier used to decide this
        -- outright -- militia never robbed at all -- which made "will
        -- this one talk or shoot" a different question per tier.
        local robChance = opts.robbery and BNS.Behaviour.robChance or 0
        -- Nobody tries to mug someone aiming a gun at them.
        if p:isAiming() then robChance = 0 end
        brain.intent = (ZombRand(100) < robChance) and BNS.Program.ROB or BNS.Program.ATTACK
    end
    if brain.intent and ctx.dist < 4 then
        brain.program = brain.intent
        return
    end
    -- Gunners open fire before closing -- at something they can see.
    if ctx.visible and brain.weapon and brain.weapon.gun
            and ctx.dist < brain.weapon.range then
        brain.program = BNS.Program.ATTACK
        return
    end
    BNS.Programs.walkTo(zombie, ctx.goX, ctx.goY, ctx.goZ, true)
end

-- SEARCH ----------------------------------------------------------------
--
-- They saw you, they lost you, and all they have is the last place they
-- saw you standing. Walk there, look around, give up. This is the whole
-- reason a player can now break contact: before it, pursuit read live
-- coordinates every tick and nothing you did shook anyone off.

BNS.Programs[BNS.Program.SEARCH] = function(zombie, brain, ctx)
    -- Spotted again: straight back to it, wherever they were headed.
    if ctx.visible then
        BNS.Senses.lookAround(zombie, false)
        brain.searchLook = nil
        brain.program = brain.intent or BNS.Program.APPROACH
        return
    end
    -- Nothing left to go on.
    if ctx.stale or not ctx.goX then
        BNS.Senses.lookAround(zombie, false)
        BNS.Senses.forget(brain)
        brain.intent, brain.warned, brain.warnTimer = nil, nil, nil
        brain.program = brain.home and BNS.Program.DEFEND or BNS.Program.WANDER
        return
    end

    local d = BNS.dist(zombie:getX(), zombie:getY(), ctx.goX, ctx.goY)
    if d > 2 and not brain.searchLook then
        -- Still on the way. At a jog, not a sprint: they are looking for
        -- someone, not chasing them.
        BNS.Programs.walkTo(zombie, ctx.goX, ctx.goY, ctx.goZ, true)
        return
    end

    -- Arrived. Stand and look about for a few seconds.
    brain.searchLook = (brain.searchLook or BNS.Behaviour.searchLook) - BNS.Senses.TICK
    BNS.Programs.stopMoving(zombie, brain, "idle")
    BNS.Senses.lookAround(zombie, true)
    if brain.searchLook <= 0 then
        BNS.Senses.lookAround(zombie, false)
        BNS.Senses.forget(brain)
        brain.intent, brain.warned, brain.warnTimer = nil, nil, nil
        brain.program = brain.home and BNS.Program.DEFEND or BNS.Program.WANDER
    end
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
    if ctx.lost then brain.program = BNS.Program.SEARCH return end
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

-- Every fresh engagement opens with a hold during which no damage is
-- dealt, so a bandit telegraphs danger before the first shot or swing.
-- The timer itself counts down every engine tick in BNS_Brain.

-- How long a bandit holds off after the warning, in engine ticks
-- (BNS_Brain counts warnTimer down every tick, 60/s).
BNS.Programs.WARN_TICKS = 240 -- 4 seconds

-- The telegraph before a bandit commits. An armed bandit puts a round
-- past you from the gun they are actually carrying -- no damage, but
-- real gunshot noise, which also brings zombies. A bandit with only a
-- melee weapon closes the distance silently: the hold is the same four
-- seconds either way, so the tell is that they are coming for you, not
-- that they said so.
function BNS.Programs.startWarning(zombie, brain, player)
    if brain.warned or brain.warnTimer then return end
    brain.warnTimer = BNS.Programs.WARN_TICKS
    if player and brain.weapon and brain.weapon.gun then
        BNS.Combat.warningShot(zombie, brain, player)
    end
end

local function endEngagement(brain)
    brain.warned = nil
    brain.warnTimer = nil
    brain.intent = nil
    brain.program = brain.home and BNS.Program.DEFEND or BNS.Program.WANDER
end

-- Footwork ---------------------------------------------------------------
--
-- Give ground: walk to a point directly away from something, capped so a
-- bandit backs off rather than bolting. Used for the beat after a swing,
-- for a gunner whose magazine is empty, and for one who has let the
-- player walk inside their weapon's useful range.
function BNS.Programs.backAway(zombie, brain, fromX, fromY, tiles, run)
    local dx = zombie:getX() - fromX
    local dy = zombie:getY() - fromY
    local d = math.max(BNS.dist(0, 0, dx, dy), 0.1)
    BNS.Programs.walkTo(zombie,
        zombie:getX() + dx / d * tiles,
        zombie:getY() + dy / d * tiles, zombie:getZ(), run == true)
end

-- How close a gunner lets a player get before giving ground rather than
-- standing there being hit, as a fraction of the weapon's range. A
-- shotgun is happy much closer than a hunting rifle is.
BNS.Programs.STANDOFF_MIN = 0.30
BNS.Programs.STANDOFF_KEEP = 0.60

-- The chance a melee bandit uses their recovery beat to step out rather
-- than stand in your face. Not every swing, or they never close.
BNS.Programs.STEP_BACK_CHANCE = 40

-- Within this of a player, a stopped shell has its engine state machine
-- held still so it cannot lunge (BNS.Combat.holdState). Wide enough to
-- cover any melee exchange, narrow enough that a shell with somewhere to
-- be is never held.
BNS.Programs.MELEE_HOLD_DIST = 2.5

BNS.Programs[BNS.Program.ATTACK] = function(zombie, brain, ctx)
    local p = ctx.player
    -- Out of sight long enough to count: go and look where they were,
    -- rather than walking to coordinates nobody can see. Checked before
    -- the give-up distance, which is measured from what they know.
    if ctx.lost then
        brain.program = BNS.Program.SEARCH
        return
    end
    if not p or (ctx.knownDist or ctx.dist) > 50 or p:isDead() then
        endEngagement(brain)
        return
    end
    BNS.Programs.startWarning(zombie, brain, p)
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

    -- Reloading or blown: get off the line first, fight after. This is
    -- the window the whole magazine model exists to create.
    if BNS.Combat.isBusy(brain) then
        if not brain.reloadTimer then
            BNS.Say(zombie, brain, getText("UI_BNS_Winded"))
        end
        if ctx.dist < 8 then
            BNS.Programs.backAway(zombie, brain, p:getX(), p:getY(), 8, true)
        else
            BNS.Programs.stopMoving(zombie, brain, "idle")
        end
        return
    end

    -- Close the distance at a run, or stand and fight -- never both at
    -- once. BNS.Combat refuses to attack while running.
    if w.gun then
        local range = w.range or 10
        if ctx.dist <= BNS.Combat.SHOVE_RANGE then
            -- Someone in your face is not a shooting problem, it is a
            -- get-off-me problem. A zombie's answer at this range is a
            -- lunge; a person's is a shove and then the weapon back up.
            BNS.Programs.stopMoving(zombie, brain, "aim")
            if not BNS.Combat.shove(zombie, brain, p) then
                BNS.Programs.backAway(zombie, brain, p:getX(), p:getY(),
                    range * BNS.Programs.STANDOFF_KEEP, true)
            end
        elseif ctx.dist < range * BNS.Programs.STANDOFF_MIN then
            -- Let a player walk into your muzzle and you lose the gun's
            -- whole advantage: open the range back up instead.
            BNS.Programs.backAway(zombie, brain, p:getX(), p:getY(),
                range * BNS.Programs.STANDOFF_KEEP, true)
        elseif ctx.dist > range * 0.8 then
            BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        else
            BNS.Programs.stopMoving(zombie, brain, "aim")
            BNS.Combat.attack(zombie, brain, p)
        end
        return
    end

    local reach = w.range or 1.3
    if ctx.dist > reach then
        BNS.Programs.walkTo(zombie, p:getX(), p:getY(), p:getZ(), true)
        return
    end
    -- In reach. The recovery beat after a swing is the opening the
    -- player gets, so spend some of it stepping out of theirs rather
    -- than standing toe to toe -- which is what trading blows looks
    -- like from the outside.
    if brain.swingPhase == "recover" and not brain.steppedBack
            and ZombRand(100) < BNS.Programs.STEP_BACK_CHANCE then
        brain.steppedBack = true
        BNS.Programs.backAway(zombie, brain, p:getX(), p:getY(), 2, false)
        return
    end
    if brain.swingPhase ~= "recover" then brain.steppedBack = nil end
    -- Halt, but leave the animation alone once a swing is under way: the
    -- cycle owns it from the windup to the end of the recovery.
    BNS.Programs.stopMoving(zombie, brain, brain.swingPhase and nil or "idle")
    BNS.Combat.attack(zombie, brain, p)
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
