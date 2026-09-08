--***********************************************************************
-- Bandits & Survivors — brain dispatcher (server)
--
-- Hooks OnZombieUpdate to drive NPC shells, keeps the engine's zombie
-- instincts suppressed, routes player weapon hits into NPC health, and
-- handles NPC death (loot + record removal).
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Persistence"
require "BNS/BNS_Spawner"
require "BNS/BNS_Programs"
require "BNS/BNS_Combat"
require "BNS/BNS_Anim"
require "BNS/BNS_ZombieThreat"
require "BNS/BNS_Doors"
require "BNS/BNS_Scavenge"
require "BNS/BNS_Vehicles"
require "BNS/BNS_Look"

BNS.Brain = {}

local TICK_DIVIDER = 10 -- run full brain logic every N engine updates

-- Keeping the shell from acting like a zombie does not need doing sixty
-- times a second, and setTarget(nil) every frame fights the engine's own
-- movement bookkeeping. Re-assert a few times a second instead, and only
-- clear state that is actually set.
--
-- Except with a player in reach. A zombie that acquires a target close
-- enough goes into its lunge, and ten ticks is long enough for that to
-- start and be seen -- which is what "bandits with guns start zombie
-- lunging at the player" was. Inside LUNGE_GUARD the target is cleared
-- every tick, which is the only cadence that beats the engine to it. The
-- cost is one getTarget() read per tick per NPC while a player is
-- practically on top of them, and a write only when there is something
-- to clear.
local SUPPRESS_EVERY = 10 -- engine ticks
local LUNGE_GUARD = 8     -- tiles: inside this, suppress every tick

-- States the engine puts a zombie into that an NPC must never be in. A
-- shell that reaches one has acquired a target behind our back; clearing
-- it is what ends the state.
local ZOMBIE_STATES = { "lunge", "thump", "bite", "attack" }

local function inZombieState(zombie)
    local state = BNS.Combat.stateName(zombie)
    if not state then return false end
    for _, needle in ipairs(ZOMBIE_STATES) do
        if state:find(needle, 1, true) then return true end
    end
    return false
end

local function suppressZombie(zombie, brain)
    local _, dist = BNS.nearestPlayer(zombie:getX(), zombie:getY())
    local urgent = dist ~= nil and dist < LUNGE_GUARD
    brain.suppressTick = (brain.suppressTick or ZombRand(SUPPRESS_EVERY)) - 1
    if not urgent and brain.suppressTick > 0 then return end
    brain.suppressTick = SUPPRESS_EVERY
    -- setUseless was re-asserted here several times a second on nothing
    -- but a guess about what it does. It is off by default now: see
    -- BNS.Suppress in BNS_Core.
    if BNS.Suppress.useless and zombie.setUseless then zombie:setUseless(true) end
    if not BNS.Suppress.clearTarget then return end
    if zombie.getTarget and zombie.setTarget then
        if zombie:getTarget() ~= nil then zombie:setTarget(nil) end
    elseif zombie.setTarget then
        zombie:setTarget(nil)
    end
    if zombie.setAttackedBy then zombie:setAttackedBy(nil) end
    if zombie.setThumpTarget then pcall(function() zombie:setThumpTarget(nil) end) end
    -- Already in one: count it so the debug probe can say whether any of
    -- this is working, and put the shell back under our own orders.
    if urgent and inZombieState(zombie) then
        brain.lunges = (brain.lunges or 0) + 1
        BNS.Programs.stopMoving(zombie, brain, brain.animBase or "idle")
    end
end

local function updateNPC(zombie, brain)
    suppressZombie(zombie, brain)

    brain.tick = (brain.tick or ZombRand(TICK_DIVIDER)) + 1
    -- Combat timers must count every tick for smooth attack pacing.
    if brain.speechCooldown and brain.speechCooldown > 0 then
        brain.speechCooldown = brain.speechCooldown - 1
    end
    -- Warning shout hold: no damage until it runs out.
    if brain.warnTimer then
        brain.warnTimer = brain.warnTimer - 1
        if brain.warnTimer <= 0 then
            brain.warnTimer = nil
            brain.warned = true
        end
    end
    BNS.Anim.tick(zombie, brain)
    BNS.Look.tick(zombie, brain)
    -- Swing cycle, magazine, reload and breath. Every combat timer is
    -- decremented here and nowhere else, so a reload finishes even while
    -- its owner is walking away and no timer can be counted down twice.
    BNS.Combat.tick(zombie, brain)
    -- Flat on their back: nothing to do but get up. No swinging, no
    -- shooting, no walking anywhere, and no working a door. The engine
    -- owns the fall and the get-up, including the animation -- the
    -- overlays deliberately do not cover the on-ground states.
    if BNS.Combat.isDown(brain) then
        if not brain.wentDown then
            brain.wentDown = true
            BNS.Programs.stopMoving(zombie, brain, "idle")
            BNS.Doors.abort(brain)
        end
        return
    end
    brain.wentDown = nil
    -- Held by a zombie: struggle in place, no moving or attacking until
    -- the grip breaks (the ~1/s threat scan below keeps applying the
    -- crowd's scratches while held).
    local held = false
    if brain.grabbedTimer then
        brain.grabbedTimer = brain.grabbedTimer - 1
        if brain.grabbedTimer <= 0 then
            brain.grabbedTimer = nil
            BNS.Anim.set(zombie, brain, "idle")
        else
            held = true
        end
    end
    -- Door work: rattling one open, or bashing a secured one down.
    -- Combat and being grabbed trump housebreaking.
    local doorBusy = false
    if brain.door then
        if held or brain.program == BNS.Program.FIGHTZ
                or brain.program == BNS.Program.FLEE then
            BNS.Doors.abort(brain)
        else
            doorBusy = BNS.Doors.tick(zombie, brain)
        end
    end
    if brain.tick % TICK_DIVIDER ~= 0 then
        if held or doorBusy then return end
        -- Between full ticks, keep attacking if mid-fight.
        if brain.program == BNS.Program.ATTACK then
            local p = BNS.nearestPlayer(zombie:getX(), zombie:getY())
            if p then BNS.Combat.attack(zombie, brain, p) end
        elseif brain.program == BNS.Program.FIGHTZ then
            local t = BNS.ZombieThreat.targets[brain.id]
            if t and not t:isDead() then BNS.Combat.attackZombie(zombie, brain, t) end
        end
        return
    end

    -- The window after a flee where they hold their ground.
    if brain.fleeCooldown and brain.fleeCooldown > 0 then
        brain.fleeCooldown = brain.fleeCooldown - 1
    end

    -- Zombie threat scan roughly once per second (full ticks are one
    -- per TICK_DIVIDER engine ticks).
    brain.threatTick = (brain.threatTick or ZombRand(6)) + 1
    if brain.threatTick >= 6 then
        brain.threatTick = 0
        local verdict, nearest, centroid = BNS.ZombieThreat.scan(zombie, brain)
        BNS.ZombieThreat.apply(zombie, brain, verdict, nearest, centroid)
    end
    if held then return end

    if doorBusy then
        BNS.Persistence.syncFromShell(zombie)
        return
    end

    local player, dist = BNS.nearestPlayer(zombie:getX(), zombie:getY())
    local ctx = { player = player, dist = dist or 999999 }

    -- Survivors and traders don't fight players — but they do fight
    -- zombies, and zombies scare everyone.
    if brain.role ~= BNS.Role.BANDIT
            and brain.program ~= BNS.Program.FLEE
            and brain.program ~= BNS.Program.FIGHTZ
            and brain.program ~= BNS.Program.SCAVENGE
            and brain.program ~= BNS.Program.TRADE then
        brain.program = BNS.Program.TRADE
    end

    -- Out of combat, the warning state resets so the next engagement
    -- opens with a fresh shout.
    if brain.program == BNS.Program.WANDER or brain.program == BNS.Program.FLEE
            or brain.program == BNS.Program.DEFEND then
        brain.warned = nil
        brain.warnTimer = nil
    end

    local program = BNS.Programs[brain.program] or BNS.Programs[BNS.Program.WANDER]
    program(zombie, brain, ctx)

    local x, y = zombie:getX(), zombie:getY()
    local stalled = brain.lastX and BNS.dist(x, y, brain.lastX, brain.lastY) < 0.05
    brain.stallTicks = stalled and ((brain.stallTicks or 0) + 1) or 0

    -- Anim decay: a shell that has genuinely stopped shouldn't keep
    -- playing a walk cycle. But one slow tick is not "stopped" -- calling
    -- it idle while the engine is still walking the character is exactly
    -- what reads as sliding, so wait for a few, or for a real halt.
    if (brain.stopped or brain.stallTicks >= 3)
            and (brain.animMode == "walk" or brain.animMode == "run") then
        BNS.Anim.set(zombie, brain, "idle")
    end
    -- Stalled bandit in a program that wants to move: probably a closed
    -- door in the way — start working it after a few stalled full ticks.
    local wantsMove = brain.program == BNS.Program.WANDER
        or brain.program == BNS.Program.APPROACH
        or brain.program == BNS.Program.ATTACK
        or brain.program == BNS.Program.ROB
        or brain.program == BNS.Program.RAID
        or brain.program == BNS.Program.DEFEND
        or brain.program == BNS.Program.SCAVENGE
        or brain.program == BNS.Program.HAUL
    -- Bandits work doors anywhere; anyone gets to open them on a loot run.
    local mayOpenDoors = BNS.isBandit(zombie)
        or brain.program == BNS.Program.SCAVENGE
        or brain.program == BNS.Program.HAUL
    if stalled and wantsMove and mayOpenDoors and not brain.door
            and brain.stallTicks >= 3 then
        brain.stallTicks = 0
        BNS.Doors.tryStart(zombie, brain)
    end
    brain.lastX, brain.lastY = x, y

    -- Trickle position back into the persistent record.
    if brain.tick % (TICK_DIVIDER * 30) == 0 then
        BNS.Persistence.syncFromShell(zombie)
    end
end

function BNS.Brain.onZombieUpdate(zombie)
    local brain = BNS.brain(zombie)
    if not brain then return end
    if zombie:isDead() then return end
    updateNPC(zombie, brain)
end

-- Player weapons hitting NPC shells ------------------------------------

function BNS.Brain.onWeaponHitCharacter(attacker, target, weapon, damage)
    if not BNS.isNPC(target) then return end
    local brain = BNS.brain(target)
    -- A shove is not an attack. It puts them on the floor, and what
    -- happens to them there -- a swing, a stomp -- is what does the
    -- damage. Pushing was landing full weapon damage, which made shoving
    -- a bandit to death a real tactic and nothing like how a fight with a
    -- person goes. A push at someone already down is a stomp, and stomps
    -- hurt: that is the one case this passes straight through.
    BNS.Combat.receiveHit(target, brain, attacker, weapon, damage)
    -- Bandits retaliate; neutrals turn hostile if attacked -- and being
    -- shoved is an assault too, so it commits them the same way a hit
    -- does even though it costs them no health. Being hit is its own
    -- warning: they still shout, but skip the hold.
    if brain.health > 0 then
        if brain.role ~= BNS.Role.BANDIT then brain.role = BNS.Role.BANDIT end
        brain.program = (brain.tier == BNS.Tier.CIVILIAN and brain.health < 0.4)
            and BNS.Program.FLEE or BNS.Program.ATTACK
        -- Being shot at is its own warning: they skip the telegraph
        -- entirely rather than firing one back over your head first.
        if brain.program == BNS.Program.ATTACK and not brain.warned then
            brain.warnTimer = nil
            brain.warned = true
        end
    end
end

-- Death -----------------------------------------------------------------

function BNS.Brain.onZombieDead(zombie)
    local brain = BNS.brain(zombie)
    if not brain then return end
    BNS.Spawner.dropLoot(zombie, brain)
    BNS.Persistence.remove(brain.id)
    BNS.ZombieThreat.targets[brain.id] = nil
    if isServer() then
        sendServerCommand(BNS.CommandModule, "npcDead", { id = brain.id })
    end
end

Events.OnZombieUpdate.Add(BNS.Brain.onZombieUpdate)
Events.OnWeaponHitCharacter.Add(BNS.Brain.onWeaponHitCharacter)
Events.OnZombieDead.Add(BNS.Brain.onZombieDead)
