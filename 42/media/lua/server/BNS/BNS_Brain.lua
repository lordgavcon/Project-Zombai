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
require "BNS/BNS_Anim"
require "BNS/BNS_ZombieThreat"
require "BNS/BNS_Doors"
require "BNS/BNS_Scavenge"

BNS.Brain = {}

local TICK_DIVIDER = 10 -- run full brain logic every N engine updates

local function suppressZombie(zombie)
    -- Re-assert every tick: keep the shell from lunging, biting or
    -- aggroing like a zombie.
    zombie:setUseless(true)
    if zombie.setTarget then zombie:setTarget(nil) end
    if zombie.setAttackedBy then zombie:setAttackedBy(nil) end
end

local function updateNPC(zombie, brain)
    suppressZombie(zombie)

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

    -- Anim decay: a shell that stopped moving shouldn't keep playing a
    -- walk/run cycle (e.g. arrived at its path target between ticks).
    local x, y = zombie:getX(), zombie:getY()
    local stalled = brain.lastX and BNS.dist(x, y, brain.lastX, brain.lastY) < 0.05
    if stalled and (brain.animMode == "walk" or brain.animMode == "run") then
        BNS.Anim.set(zombie, brain, "idle")
    end
    -- Stalled bandit in a program that wants to move: probably a closed
    -- door in the way — start working it after two stalled full ticks.
    local wantsMove = brain.program == BNS.Program.WANDER
        or brain.program == BNS.Program.APPROACH
        or brain.program == BNS.Program.ATTACK
        or brain.program == BNS.Program.ROB
        or brain.program == BNS.Program.RAID
        or brain.program == BNS.Program.DEFEND
        or brain.program == BNS.Program.SCAVENGE
    -- Bandits work doors anywhere; anyone gets to open them on a loot run.
    local mayOpenDoors = BNS.isBandit(zombie)
        or brain.program == BNS.Program.SCAVENGE
    if stalled and wantsMove and mayOpenDoors and not brain.door then
        brain.stallTicks = (brain.stallTicks or 0) + 1
        if brain.stallTicks >= 2 then
            brain.stallTicks = 0
            BNS.Doors.tryStart(zombie, brain)
        end
    else
        brain.stallTicks = 0
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
    -- Engine damage numbers vary wildly by weapon; normalise to our scale.
    local amount = math.min((damage or 0.5) / 2.5, 0.9)
    BNS.Combat.damageNPC(target, brain, amount)
    -- Bandits retaliate; neutrals turn hostile if attacked. Being hit
    -- is its own warning: they still shout, but skip the hold.
    if brain.health > 0 then
        if brain.role ~= BNS.Role.BANDIT then brain.role = BNS.Role.BANDIT end
        brain.program = (brain.tier == BNS.Tier.CIVILIAN and brain.health < 0.4)
            and BNS.Program.FLEE or BNS.Program.ATTACK
        if brain.program == BNS.Program.ATTACK and not brain.warned then
            BNS.Programs.startWarning(target, brain)
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
