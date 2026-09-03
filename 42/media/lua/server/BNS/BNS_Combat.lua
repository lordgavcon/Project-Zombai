--***********************************************************************
-- Bandits & Survivors — combat (server)
--
-- NPC attacks are simulated server-side: melee applies weapon damage on
-- an interval while in range; firearms roll to hit with distance
-- falloff, play their shot sound and damage a random body part. Damage
-- lands through BodyDamage so bites/scratches semantics are untouched.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Anim"

BNS.Combat = {}

-- Attacks only land while standing still or walking: nobody swings an
-- axe or lines up a shot at a dead sprint. Programs must stop first.
function BNS.Combat.canAttack(brain)
    return brain ~= nil and brain.animMode ~= "run"
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

-- Melee swing: call while brain wants to attack; enforces its own swing
-- cooldown via brain.attackTimer (ticks).
function BNS.Combat.melee(zombie, brain, player)
    brain.attackTimer = (brain.attackTimer or 0) - 1
    if brain.attackTimer > 0 then return end
    brain.attackTimer = 60 -- roughly one swing per second

    local d = BNS.dist(zombie:getX(), zombie:getY(), player:getX(), player:getY())
    local range = (brain.weapon and brain.weapon.range) or 1.3
    if d > range then return end

    BNS.Anim.pulse(zombie, brain, "swing")
    zombie:playSound("BaseballBatHit")
    -- 70% to land; blocked/dodged otherwise.
    if ZombRand(100) < 70 then
        applyDamage(player, (brain.weapon and brain.weapon.dmg) or 0.1)
    end
end

-- Simulated gunshot with distance falloff. Misses still make noise and
-- attract zombies via addSound, which keeps firefights dangerous.
function BNS.Combat.shoot(zombie, brain, player)
    brain.attackTimer = (brain.attackTimer or 0) - 1
    if brain.attackTimer > 0 then return end
    brain.attackTimer = ZombRand(90, 180) -- 1.5-3s between shots

    local w = brain.weapon
    local d = BNS.dist(zombie:getX(), zombie:getY(), player:getX(), player:getY())
    if d > w.range then return end

    BNS.Anim.pulse(zombie, brain, "shoot")
    zombie:playSound(w.sound or "9mmShot")
    addSound(zombie, zombie:getX(), zombie:getY(), zombie:getZ(), 70, 70)

    local hitChance = (w.hit or 40) * (1.0 - 0.5 * (d / w.range))
    if player:isSneaking() then hitChance = hitChance * 0.6 end
    -- The opening shot of an engagement goes wide far more often, so a
    -- shouted warning is rarely followed by an instant kill.
    if brain.firstShot then
        hitChance = hitChance * 0.5
        brain.firstShot = nil
    end
    if ZombRand(100) < hitChance then
        applyDamage(player, w.dmg or 0.3)
    end
end

function BNS.Combat.attack(zombie, brain, player)
    -- No damage before the warning shout has run its course.
    if not brain.warned then return end
    if not BNS.Combat.canAttack(brain) then return end
    if brain.weapon and brain.weapon.gun then
        BNS.Combat.shoot(zombie, brain, player)
    else
        BNS.Combat.melee(zombie, brain, player)
    end
end

-- NPC vs zombie: same swing/shot pacing and noise as anti-player
-- combat, but no warning gate or first-shot penalty (the dead don't
-- get warnings and don't dodge), and damage lands on the zombie's
-- engine health so kills go through normal zombie death.
function BNS.Combat.attackZombie(npc, brain, target)
    if not BNS.Combat.canAttack(brain) then return end
    brain.attackTimer = (brain.attackTimer or 0) - 1
    if brain.attackTimer > 0 then return end
    local w = brain.weapon or {}
    local d = BNS.dist(npc:getX(), npc:getY(), target:getX(), target:getY())
    if w.gun then
        brain.attackTimer = ZombRand(90, 180)
        if d > (w.range or 8) then return end
        BNS.Anim.pulse(npc, brain, "shoot")
        npc:playSound(w.sound or "9mmShot")
        addSound(npc, npc:getX(), npc:getY(), npc:getZ(), 70, 70)
        if ZombRand(100) < math.min((w.hit or 40) + 25, 90) then
            target:setHealth(math.max(target:getHealth() - (w.dmg or 0.3) * 2, 0))
        end
    else
        brain.attackTimer = 60
        if d > (w.range or 1.3) then return end
        BNS.Anim.pulse(npc, brain, "swing")
        npc:playSound("BaseballBatHit")
        if ZombRand(100) < 85 then
            target:setHealth(math.max(target:getHealth() - (w.dmg or 0.1) * 2, 0))
        end
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
    if brain.health <= 0.35 and brain.role == BNS.Role.BANDIT
            and brain.tier == BNS.Tier.CIVILIAN then
        brain.program = BNS.Program.FLEE -- cowards break
    end
    if brain.health <= 0 then
        zombie:setHealth(0) -- engine handles the death; brain cleanup in BNS_Brain
    end
end
