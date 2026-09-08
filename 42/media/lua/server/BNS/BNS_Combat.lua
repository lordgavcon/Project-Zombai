--***********************************************************************
-- Project Zombai — combat (server)
--
-- NPC attacks are simulated server-side, but they are paced the way a
-- player's are rather than on a flat timer, because a fight the player
-- can read is a fight the player can beat.
--
-- Melee is a three-beat cycle: windup (weapon raised), contact, recovery.
-- The swing commits at windup, so stepping out of range during it makes
-- the bandit whiff -- and a whiff costs a longer recovery than a hit.
-- Heavier weapons take longer through every beat, and swinging is tiring:
-- endurance drains per swing, recovers while not swinging, and a winded
-- bandit swings slower and gives ground to get their breath back.
--
-- Firearms carry a magazine. Rounds leave it, bursts have a rate of fire
-- and a pause between them, and an empty gun means a real reload window
-- (the weapon comes down, they call for cover, and the program breaks
-- contact). Out of spare magazines, they draw their melee backup and come
-- for you. Accuracy ramps while they hold their aim on you and resets the
-- moment they move, so a bandit who has been walking shoots badly and one
-- who has been standing still shoots well.
--
-- Damage lands through BodyDamage so bite/scratch semantics are
-- untouched. Every timer here counts *engine* ticks (60/s) and is
-- decremented in exactly one place, BNS.Combat.tick, which BNS_Brain runs
-- every tick -- so a reload finishes even while its owner is running away.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Loadouts"
require "BNS/BNS_Anim"

BNS.Combat = {}

-- Tempo -----------------------------------------------------------------

-- Melee cycle in engine ticks, before the weapon's own weight is applied.
BNS.Combat.WINDUP = 20       -- weapon raised; the player can still step out
BNS.Combat.RECOVER = 45      -- after contact, before another swing can start
BNS.Combat.WHIFF_PENALTY = 1.7 -- a missed swing leaves them open for longer

-- How long a one-shot clip is held on the shell after it is triggered.
--
-- The recovery beat has to be long enough to contain the swing clip, or
-- the animation is visibly cut off part way through -- that is what
-- RECOVER being generous is for, not just pacing. The hold itself is then
-- clamped at both ends: long enough for the clip to play out, and always
-- shorter than the beat, because if BNSAnim never leaves "swing" the
-- condition never changes, the AnimNode has no edge to re-trigger on, and
-- the next swing plays nothing at all.
BNS.Combat.SWING_HOLD_MIN = 60  -- 1s; past the length of the shortest attack clip
BNS.Combat.SWING_HOLD_MAX = 110 -- ~1.8s; past the longest, so no point holding on
BNS.Combat.SHOT_HOLD_MIN = 25
BNS.Combat.SHOT_HOLD_MAX = 45
BNS.Combat.HOLD_GAP = 15        -- ticks the shell is back in its stance between clips

function BNS.Combat.clipHold(beat, minTicks, maxTicks)
    local room = beat - BNS.Combat.HOLD_GAP
    -- Correctness first: with no room for the minimum, take what there is
    -- rather than swallowing the next clip's trigger.
    if room < minTicks then return math.max(room, 6) end
    return math.min(maxTicks, room)
end

-- How much slower each weapon class is through the whole cycle. Taken
-- from the same classes the animation branches on, so what you see and
-- what you feel are the same weapon.
BNS.Combat.SwingWeight = {
    knife = 0.70, ["1handed"] = 0.90, ["2handed"] = 1.20,
    heavy = 1.50, spear = 1.15,
}

-- Endurance: a swing costs, standing still pays it back.
BNS.Combat.SWING_COST = 0.075
BNS.Combat.BREATH_RATE = 0.0035 -- per engine tick out of a swing (~5s to full)
BNS.Combat.WINDED = 0.30        -- below this they back off to breathe
BNS.Combat.TIRED_SLOWDOWN = 1.6 -- cycle multiplier when fully spent

-- Aim: how long a gunner must hold still on a target before their shot is
-- worth taking. Accuracy ramps across it from AIM_FLOOR to full.
BNS.Combat.AIM_FULL = 90 -- engine ticks (1.5s)
BNS.Combat.AIM_FLOOR = 0.45

-- One knob over every attack interval, so "how hard are they to fight"
-- is a single sandbox number rather than a dozen constants to keep in
-- step. It is a *speed*, so 0.5 (the default) means every swing cycle and
-- every gap between rounds takes twice as long: half the attacks in the
-- same time. It never touches accuracy, damage or how fast they walk --
-- only the pace they attack at, which is the part the player reads.
function BNS.Combat.speed()
    local s = BNS.Options().attackSpeed or 1.0
    if s <= 0 then return 1.0 end
    return s
end

-- Stretch a base interval by the current attack speed.
function BNS.Combat.interval(ticks)
    return math.max(math.floor(ticks / BNS.Combat.speed()), 1)
end

local BODY_PARTS = {
    BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
    BodyPartType.UpperArm_L, BodyPartType.UpperArm_R,
    BodyPartType.UpperLeg_L, BodyPartType.UpperLeg_R,
    BodyPartType.Hand_L, BodyPartType.Hand_R,
}

local function applyDamage(player, amount)
    local mult = BNS.Options().damageMult or 1.0
    local part = BODY_PARTS[ZombRand(#BODY_PARTS) + 1]
    local bd = player:getBodyDamage()
    local bp = bd:getBodyPart(part)
    if not bp then return end
    bp:AddDamage(amount * 30 * mult)
    if ZombRand(100) < 30 then bp:setScratched(true, true) end
    bd:Update()
    if isServer() then
        sendServerCommand(player, BNS.CommandModule, "hit", {})
    end
end

-- Attacks only land while standing still or walking: nobody swings an
-- axe or lines up a shot at a dead sprint. Programs must stop first.
function BNS.Combat.canAttack(brain)
    return brain ~= nil and brain.animMode ~= "run"
end

-- Line of sight ---------------------------------------------------------
--
-- Shooting through a wall is the fastest way to make an NPC feel like a
-- turret rather than a person. CanSee is on IsoGameCharacter in B42, but
-- a signature that throws must not be retried on a tick (CLAUDE.md), so
-- it is probed once and written off if it errors. "Don't know" means
-- "assume visible", which is the old behaviour exactly.
BNS.Combat.losProbe = nil -- nil = untried, true = usable, false = written off

function BNS.Combat.canSee(shooter, target)
    if BNS.Combat.losProbe == false then return true end
    if not shooter.CanSee then
        BNS.Combat.losProbe = false
        return true
    end
    local ok, seen = pcall(function() return shooter:CanSee(target) end)
    if not ok then
        BNS.Combat.losProbe = false
        BNS.log("CanSee unusable on this build; NPCs will not check line of sight")
        return true
    end
    BNS.Combat.losProbe = true
    return seen == true
end

-- Weapons ---------------------------------------------------------------

function BNS.Combat.swingTicks(brain, base)
    local weight = BNS.Combat.SwingWeight[BNS.Anim.weaponClass(brain.weapon)] or 1.0
    local tired = 1.0 + (1.0 - math.min(brain.stamina or 1.0, 1.0))
        * (BNS.Combat.TIRED_SLOWDOWN - 1.0)
    return math.max(BNS.Combat.interval(base * weight * tired), 4)
end

-- Magazine, reload time and burst discipline for a gun. Kept out of the
-- loadout tables so every archetype's guns share one place to tune.
function BNS.Combat.gunProfile(brain)
    local w = brain.weapon or {}
    local prof = BNS.Loadouts.Magazines[w.item] or BNS.Loadouts.MagazineDefault
    local spares = prof.spares or 1
    -- Better-equipped bandits came out with more on their belt.
    if brain.tier == BNS.Tier.MILITIA then spares = spares + 2
    elseif brain.tier == BNS.Tier.THUG then spares = spares + 1 end
    return {
        left = prof.mag, mag = prof.mag, spares = spares,
        reload = prof.reload, burst = prof.burst, rof = prof.rof,
    }
end

function BNS.Combat.ensureAmmo(brain)
    if not brain.ammo then brain.ammo = BNS.Combat.gunProfile(brain) end
    return brain.ammo
end

-- Out of magazines: the gun goes away and the backup melee comes out.
-- This is the same weapon swap a player makes, so it goes through the
-- normal hand item and animation path -- the swing that follows matches
-- what is now in their hands.
function BNS.Combat.drawBackup(zombie, brain)
    local backup = brain.backup
    if not backup then
        -- No backup rolled (an old record): fists, near enough.
        backup = { item = nil, dmg = 0.06, range = 1.1, gun = false }
    end
    brain.ammo = nil
    brain.reloadTimer = nil
    brain.burstLeft = nil
    -- Same path the spawn uses, so the off hand is filled or emptied to
    -- match what they just drew.
    BNS.Anim.equip(zombie, brain, backup)
    BNS.Say(zombie, brain, getText("UI_BNS_OutOfAmmo"))
end

-- The sound of the gun they are actually holding, rather than a fixed
-- string: a shotgun should not crack like a 9mm. Falls back to the
-- loadout's sound, then to a pistol shot, if the item exposes none.
function BNS.Combat.gunSound(zombie, brain)
    local w = brain.weapon or {}
    if zombie.getPrimaryHandItem then
        local sound = nil
        pcall(function()
            local item = zombie:getPrimaryHandItem()
            if not item then return end
            if item.getSwingSound then sound = item:getSwingSound() end
            if (not sound or sound == "") and item.getSoundName then
                sound = item:getSoundName()
            end
        end)
        if sound and sound ~= "" then return sound end
    end
    return w.sound or "9mmShot"
end

-- Per-tick bookkeeping --------------------------------------------------
--
-- Every combat timer lives here and nowhere else, so a bandit who breaks
-- contact still finishes their reload, still gets their breath back, and
-- cannot have a timer decremented twice by two callers in one tick.
function BNS.Combat.tick(zombie, brain)
    brain.stamina = brain.stamina or 1.0

    if brain.swingTimer then
        brain.swingTimer = brain.swingTimer - 1
        if brain.swingTimer <= 0 and brain.swingPhase == "recover" then
            brain.swingPhase, brain.swingTimer = nil, nil
        end
    end
    if brain.shotTimer and brain.shotTimer > 0 then
        brain.shotTimer = brain.shotTimer - 1
    end
    if brain.reloadTimer then
        brain.reloadTimer = brain.reloadTimer - 1
        if brain.reloadTimer <= 0 then
            brain.reloadTimer = nil
            local ammo = BNS.Combat.ensureAmmo(brain)
            ammo.spares = math.max(ammo.spares - 1, 0)
            ammo.left = ammo.mag
            brain.burstLeft = nil
        end
    end
    -- Breath comes back whenever they are not mid-swing.
    if not brain.swingPhase and brain.stamina < 1.0 then
        brain.stamina = math.min(brain.stamina + BNS.Combat.BREATH_RATE, 1.0)
    end
end

-- True while the NPC is doing something that should stop it attacking and
-- make its program give ground: reloading, or blown.
--
-- Being blown latches. Without that, a bandit crosses back over WINDED by
-- a hair, throws one swing that spends it again, and spends the fight
-- twitching in and out of a retreat instead of committing to either.
BNS.Combat.RECOVERED = 0.60 -- breath they must get back before re-engaging

function BNS.Combat.isBusy(brain)
    local stamina = brain.stamina or 1.0
    if stamina < BNS.Combat.WINDED then brain.blown = true end
    if brain.blown and stamina >= BNS.Combat.RECOVERED then brain.blown = nil end
    if brain.reloadTimer then return true end
    return brain.blown == true and not brain.swingPhase
end

function BNS.Combat.startReload(zombie, brain)
    local ammo = BNS.Combat.ensureAmmo(brain)
    if ammo.spares <= 0 then
        BNS.Combat.drawBackup(zombie, brain)
        return false
    end
    brain.reloadTimer = ammo.reload
    brain.aimTicks = 0
    BNS.Anim.set(zombie, brain, "idle") -- weapon comes down to work the action
    BNS.Say(zombie, brain, getText("UI_BNS_Reloading"))
    return true
end

-- Melee -----------------------------------------------------------------
--
-- resolve() is handed the target's live position so the swing can miss by
-- the target simply not being there any more, and a hit callback so the
-- same cycle drives both anti-player and anti-zombie fights.
local function meleeCycle(zombie, brain, tx, ty, range, onHit, baseChance)
    if brain.swingPhase == "recover" then return end

    if brain.swingPhase == "windup" then
        if (brain.swingTimer or 0) > 0 then return end
        -- Contact. Re-measure: a target that moved out of reach during
        -- the windup is a whiff, which is the player's way out of a swing.
        zombie:playSound("BaseballBatHit")
        brain.stamina = math.max((brain.stamina or 1.0) - BNS.Combat.SWING_COST, 0)

        local d = BNS.dist(zombie:getX(), zombie:getY(), tx, ty)
        local landed = false
        if d <= range * 1.15 then
            -- Tiring spoils aim as well as speed.
            local chance = baseChance * (0.6 + 0.4 * (brain.stamina or 1.0))
            landed = ZombRand(100) < chance
        end
        if landed then onHit() end
        brain.swingPhase = "recover"
        brain.swingTimer = BNS.Combat.swingTicks(brain, BNS.Combat.RECOVER)
        if not landed then
            brain.swingTimer = math.floor(brain.swingTimer * BNS.Combat.WHIFF_PENALTY)
        end
        brain.whiffed = not landed
        -- The clip gets the recovery beat to play out in, less the gap
        -- that puts them back in their stance before the next swing.
        BNS.Anim.pulse(zombie, brain, "swing",
            BNS.Combat.clipHold(brain.swingTimer,
                BNS.Combat.SWING_HOLD_MIN, BNS.Combat.SWING_HOLD_MAX))
        return
    end

    -- Idle: only start a swing at something actually in reach, and only
    -- with the breath to throw it.
    if (brain.stamina or 1.0) < BNS.Combat.WINDED then return end
    if BNS.dist(zombie:getX(), zombie:getY(), tx, ty) > range then return end
    brain.swingPhase = "windup"
    brain.swingTimer = BNS.Combat.swingTicks(brain, BNS.Combat.WINDUP)
    BNS.Anim.set(zombie, brain, "aim") -- weapon up, about to come down
end

function BNS.Combat.melee(zombie, brain, player)
    local w = brain.weapon or {}
    local range = w.range or 1.3
    -- A target at a dead run is harder to connect with.
    local chance = 72
    if player.isRunning then
        local ok, running = pcall(function() return player:isRunning() end)
        if ok and running then chance = chance - 18 end
    end
    meleeCycle(zombie, brain, player:getX(), player:getY(), range,
        function() applyDamage(player, w.dmg or 0.1) end, chance)
end

-- Firearms --------------------------------------------------------------

-- Accuracy ramp: how much of the weapon's hit chance a gunner has earned
-- by holding their aim. Reset by BNS.Programs.walkTo whenever they move.
function BNS.Combat.aimFactor(brain)
    local held = math.min((brain.aimTicks or 0) / BNS.Combat.AIM_FULL, 1.0)
    return BNS.Combat.AIM_FLOOR + (1.0 - BNS.Combat.AIM_FLOOR) * held
end

-- A shot fired to warn the player off: the real gun, aimed their way,
-- doing no damage. It is the telegraph -- what used to be a shouted
-- line -- so it still makes gunshot noise and still draws zombies. It
-- comes out of the magazine like any other round.
function BNS.Combat.warningShot(zombie, brain, player)
    if not (brain.weapon and brain.weapon.gun) then return false end
    if zombie.faceThisObject then
        pcall(function() zombie:faceThisObject(player) end)
    end
    local ammo = BNS.Combat.ensureAmmo(brain)
    ammo.left = math.max(ammo.left - 1, 0)
    BNS.Anim.pulse(zombie, brain, "shoot")
    zombie:playSound(BNS.Combat.gunSound(zombie, brain))
    addSound(zombie, zombie:getX(), zombie:getY(), zombie:getZ(), 70, 70)
    -- Deliberately no damage roll: the point is that it misses.
    return true
end

local function fireRound(zombie, brain, tx, ty, onHit, hitChance)
    local ammo = BNS.Combat.ensureAmmo(brain)
    ammo.left = ammo.left - 1
    zombie:playSound(BNS.Combat.gunSound(zombie, brain))
    addSound(zombie, zombie:getX(), zombie:getY(), zombie:getZ(), 70, 70)
    if ZombRand(100) < hitChance then onHit() end

    -- Burst discipline: rounds inside a burst come fast, then the gun
    -- comes down for a beat before the next one.
    brain.burstLeft = (brain.burstLeft or ammo.burst) - 1
    if brain.burstLeft > 0 then
        brain.shotTimer = BNS.Combat.interval(ammo.rof)
    else
        brain.burstLeft = nil
        brain.shotTimer = BNS.Combat.interval(
            ZombRand(math.floor(ammo.rof * 2), math.floor(ammo.rof * 5)))
    end
    -- Held inside the gap to the next round, so every round in a burst
    -- gets its own trigger instead of the first one masking the rest.
    BNS.Anim.pulse(zombie, brain, "shoot",
        BNS.Combat.clipHold(brain.shotTimer,
            BNS.Combat.SHOT_HOLD_MIN, BNS.Combat.SHOT_HOLD_MAX))
end

-- Simulated gunshot with distance falloff. Misses still make noise and
-- attract zombies via addSound, which keeps firefights dangerous.
function BNS.Combat.shoot(zombie, brain, player)
    local ammo = BNS.Combat.ensureAmmo(brain)
    if brain.reloadTimer then return end
    if ammo.left <= 0 then
        BNS.Combat.startReload(zombie, brain)
        return
    end

    local w = brain.weapon
    local d = BNS.dist(zombie:getX(), zombie:getY(), player:getX(), player:getY())
    if d > w.range then return end
    if not BNS.Combat.canSee(zombie, player) then
        brain.aimTicks = 0
        return
    end

    -- Settling the sights is what the wait is for, so it only counts
    -- while they are actually lined up on a target they can see.
    brain.aimTicks = (brain.aimTicks or 0) + 1
    if (brain.shotTimer or 0) > 0 then return end

    local hitChance = (w.hit or 40) * (1.0 - 0.5 * (d / w.range))
        * BNS.Combat.aimFactor(brain)
    if player:isSneaking() then hitChance = hitChance * 0.6 end
    fireRound(zombie, brain, player:getX(), player:getY(),
        function() applyDamage(player, w.dmg or 0.3) end, hitChance)
end

function BNS.Combat.attack(zombie, brain, player)
    -- No damage until the warning has run its course.
    if not brain.warned then return end
    if not BNS.Combat.canAttack(brain) then return end
    if brain.weapon and brain.weapon.gun then
        BNS.Combat.shoot(zombie, brain, player)
    else
        BNS.Combat.melee(zombie, brain, player)
    end
end

-- NPC vs zombie: the same cycle, the same magazine, the same breath --
-- watching a bandit run dry and switch to a machete while a crowd closes
-- is the point. No warning gate and no first-shot penalty, though (the
-- dead don't get warnings), and damage lands on the zombie's engine
-- health so kills go through normal zombie death.
function BNS.Combat.attackZombie(npc, brain, target)
    if not BNS.Combat.canAttack(brain) then return end
    local w = brain.weapon or {}
    local function hurt(scale)
        return function()
            target:setHealth(math.max(target:getHealth() - (w.dmg or 0.1) * scale, 0))
        end
    end
    if w.gun then
        local ammo = BNS.Combat.ensureAmmo(brain)
        if brain.reloadTimer then return end
        if ammo.left <= 0 then BNS.Combat.startReload(npc, brain) return end
        local d = BNS.dist(npc:getX(), npc:getY(), target:getX(), target:getY())
        if d > (w.range or 8) then return end
        brain.aimTicks = (brain.aimTicks or 0) + 1
        if (brain.shotTimer or 0) > 0 then return end
        local chance = math.min((w.hit or 40) + 25, 90) * BNS.Combat.aimFactor(brain)
        fireRound(npc, brain, target:getX(), target:getY(), hurt(2), chance)
    else
        meleeCycle(npc, brain, target:getX(), target:getY(), w.range or 1.3,
            hurt(2), 85)
    end
end

-- Players (and zombies) hurting NPCs: shells keep engine health, but we
-- track brain.health so tiers can differ in toughness and records can
-- persist wounds. Called from OnHitZombie-style hooks in BNS_Brain.
function BNS.Combat.damageNPC(zombie, brain, amount)
    local toughness = 1.0
    if brain.tier == BNS.Tier.THUG then toughness = 1.3 end
    if brain.tier == BNS.Tier.MILITIA then toughness = 1.6 end
    brain.health = (brain.health or 1.0) - amount / toughness
    -- Being hit knocks the wind out and spoils a swing in progress: a
    -- bandit caught mid-windup does not get that swing.
    brain.stamina = math.max((brain.stamina or 1.0) - 0.05, 0)
    if brain.swingPhase == "windup" then
        brain.swingPhase = "recover"
        brain.swingTimer = BNS.Combat.swingTicks(brain, BNS.Combat.RECOVER)
    end
    if brain.health <= 0.35 and brain.role == BNS.Role.BANDIT
            and brain.tier == BNS.Tier.CIVILIAN then
        brain.program = BNS.Program.FLEE -- cowards break
    end
    if brain.health <= 0 then
        zombie:setHealth(0) -- engine handles the death; brain cleanup in BNS_Brain
    end
end
