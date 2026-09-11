-- Offline test of how NPCs fight.
--
-- The thing being tested is *rhythm*: a fight the player can read is a
-- fight the player can beat, so the assertions here are about openings --
-- the windup you can step out of, the recovery a whiff costs, the reload
-- window, the aim a bandit loses by moving, and the breath they run out
-- of. Damage numbers are sandbox-tunable and deliberately not asserted.
math.randomseed(23)

local ROOT = arg[1]
local loaded = {}
function require(name)
    if loaded[name] then return end
    loaded[name] = true
    for _, dir in ipairs({ "/shared/", "/server/" }) do
        local p = ROOT .. dir .. name .. ".lua"
        local f = io.open(p, "r")
        if f then f:close(); dofile(p); return end
    end
    error("require not found: " .. name)
end

-- PZ stubs -------------------------------------------------------------
function ZombRand(a, b) if b then return math.random(a, b - 1) end return math.random(0, a - 1) end
function ZombRandFloat(a, b) return a + math.random() * (b - a) end
function instanceof(obj, cls) return type(obj) == "table" and obj.__iso == cls end
function isServer() return false end
function isClient() return false end
function getText(k) return k end
function addSound() end
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
function getCell() return { getZombieList = function()
    return { size = function() return 0 end, get = function() return nil end }
end } end
local spawned = {}
function instanceItem(id) table.insert(spawned, id); return { id = id } end
ScriptManager = { instance = { getItem = function() return true end } }
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })

require("BNS/BNS_Core")
require("BNS/BNS_Combat")
require("BNS/BNS_Programs")

-- Fakes ----------------------------------------------------------------
local function makeNPC(brain, x, y)
    local z = {
        __iso = "IsoZombie", x = x or 0, y = y or 0, sounds = {}, vars = {},
        modData = { BNS = brain },
    }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:getModData() return self.modData end
    function z:setVariable(k, v) self.vars[k] = v end
    function z:setRunning() end
    function z:playSound(s) table.insert(self.sounds, s) end
    function z:pathToLocationF(px, py) self.pathedTo = { px, py } end
    function z:setPrimaryHandItem(it) self.hand = it end
    function z:getPrimaryHandItem() return self.hand end
    function z:setSecondaryHandItem(it) self.offHand = it end
    function z:getSecondaryHandItem() return self.offHand end
    function z:hasPath() return false end
    function z:getOnlineID() return 1 end
    function z:faceLocationF(fx, fy) self.facing = { fx, fy } end
    return z
end

local function makePlayer(x, y)
    local p = { x = x, y = y, hits = {} }
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return 0 end
    function p:isDead() return false end
    function p:isSneaking() return false end
    function p:isRunning() return false end
    function p:isAiming() return false end
    function p:getBodyDamage()
        local hits = self.hits
        return {
            getBodyPart = function() return {
                AddDamage = function(_, amount) table.insert(hits, amount) end,
                setScratched = function() end,
            } end,
            Update = function() end,
        }
    end
    return p
end

local function newBrain(weapon, tier)
    return {
        id = "c" .. tostring(math.random(1, 1e6)), tier = tier or BNS.Tier.THUG,
        role = BNS.Role.BANDIT, health = 1.0, warned = true, animMode = "idle",
        weapon = weapon, stamina = 1.0,
    }
end

-- Run the fight for n engine ticks, the way BNS_Brain does: the animation
-- pulse and the combat timers are both advanced every tick, because a
-- clip that never expires in a test would hide exactly the bug this
-- suite is here to catch.
local function step(npc, brain, target, attack)
    BNS.Anim.tick(npc, brain)
    BNS.Combat.tick(npc, brain)
    ;(attack or BNS.Combat.attack)(npc, brain, target)
end

local function run(npc, brain, target, ticks, attack)
    for _ = 1, ticks do step(npc, brain, target, attack) end
end

-- 1. A swing is a windup you can step out of --------------------------------------------
local axe = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false }
local brain = newBrain(axe)
local npc, player = makeNPC(brain, 0, 0), makePlayer(1, 0)

BNS.Combat.attack(npc, brain, player)
assert(brain.swingPhase == "windup", "the swing starts by raising the weapon")
assert(#player.hits == 0, "and nothing lands on the tick it starts")
assert(npc.vars.BNSAnim == "aim", "the weapon is visibly up during the windup")
local windup = brain.swingTimer
assert(windup > 1, "the windup is a real window, got " .. tostring(windup))

-- Step out of reach before contact: the swing commits and whiffs.
player.x = 6
run(npc, brain, player, windup + 1)
assert(#player.hits == 0, "stepping out of a committed swing avoids it")
assert(brain.whiffed, "and it is recorded as a whiff")
local whiffRecovery = brain.swingTimer
assert(brain.swingPhase == "recover", "leaving them in recovery")
print("swing windup can be stepped out of OK (" .. windup .. " tick windup)")

-- 2. A whiff costs more recovery than a hit ---------------------------------------------
local hitBrain = newBrain(axe)
local hitNpc, victim = makeNPC(hitBrain, 0, 0), makePlayer(1, 0)
local landed = false
for _ = 1, 600 do
    step(hitNpc, hitBrain, victim)
    if #victim.hits > 0 and hitBrain.swingPhase == "recover" and not hitBrain.whiffed then
        landed = true
        break
    end
end
assert(landed, "a swing at a target that stays put lands")
assert(hitBrain.swingTimer < whiffRecovery,
    "a whiff leaves them open longer than a hit: " .. hitBrain.swingTimer
        .. " vs " .. whiffRecovery)
print("whiff penalty OK")

-- 3. Heavier weapons swing slower -------------------------------------------------------
local function windupFor(item)
    local b = newBrain({ item = item, dmg = 0.2, range = 1.3, gun = false })
    local n, t = makeNPC(b, 0, 0), makePlayer(1, 0)
    BNS.Combat.attack(n, b, t)
    return b.swingTimer
end
local knife = windupFor("Base.HuntingKnife")
local bat = windupFor("Base.BaseballBat")
local heavy = windupFor("Base.Sledgehammer")
assert(knife < bat and bat < heavy,
    "knife < bat < sledge, got " .. knife .. " / " .. bat .. " / " .. heavy)
print("weapon weight sets the tempo OK (" .. knife .. "/" .. bat .. "/" .. heavy .. ")")

-- 4. Swinging is tiring, and a blown bandit gives ground --------------------------------
local tireBrain = newBrain(axe)
local tireNpc, dummy = makeNPC(tireBrain, 0, 0), makePlayer(1, 0)
run(tireNpc, tireBrain, dummy, 2000)
assert(tireBrain.stamina < 1.0, "a sustained fight costs breath")
-- Drive them to properly blown and check the program backs off.
tireBrain.stamina = 0.05
tireBrain.swingPhase, tireBrain.swingTimer = "windup", 10
assert(not BNS.Combat.isBusy(tireBrain),
    "a swing already thrown is finished, not abandoned half way")
tireBrain.swingPhase, tireBrain.swingTimer = nil, nil
assert(BNS.Combat.isBusy(tireBrain), "blown counts as busy")
assert(tireBrain.blown, "and latches, so they commit to catching their breath")
tireBrain.stamina = BNS.Combat.WINDED + 0.01
assert(BNS.Combat.isBusy(tireBrain),
    "crossing back over the line by a hair does not send them straight back in")
tireBrain.stamina = BNS.Combat.RECOVERED
assert(not BNS.Combat.isBusy(tireBrain), "a real breather does")
print("endurance and the blown latch OK")

-- The ATTACK program turns "busy" into distance rather than standing there.
local backBrain = newBrain(axe)
backBrain.blown = true
backBrain.stamina = 0.1
local backNpc, chaser = makeNPC(backBrain, 10, 10), makePlayer(11, 10)
BNS.Programs[BNS.Program.ATTACK](backNpc, backBrain, { player = chaser, dist = 1 })
assert(backNpc.pathedTo, "a blown bandit moves")
local away = BNS.dist(backNpc.pathedTo[1], backNpc.pathedTo[2], chaser.x, chaser.y)
assert(away > 1, "and moves away from the player, not into them (" .. away .. ")")
print("blown bandits break contact OK")

-- 5. Guns run out, reload, and eventually go to the backup ------------------------------
local pistol = { item = "Base.Pistol", dmg = 0.3, range = 10, gun = true,
                 sound = "9mmShot", hit = 60 }
local gb = newBrain(pistol, BNS.Tier.THUG)
gb.backup = { item = "Base.Machete", dmg = 0.22, range = 1.3, gun = false }
local gunner, target = makeNPC(gb, 0, 0), makePlayer(5, 0)

local ammo = BNS.Combat.ensureAmmo(gb)
local mag, spares = ammo.mag, ammo.spares
assert(mag > 1 and spares >= 1, "a pistol carries a magazine and spares")

-- Fire the magazine dry.
local shots = 0
while ammo.left > 0 and shots < 20000 do
    local before = ammo.left
    step(gunner, gb, target)
    if ammo.left < before then shots = shots + 1 end
    if shots > mag then break end
end
assert(shots == mag, "the whole magazine is fired, got " .. shots)

-- The next attack starts a reload rather than another shot.
step(gunner, gb, target)
assert(gb.reloadTimer and gb.reloadTimer > 0, "an empty gun reloads")
-- The weapon comes down to work the action. The variable itself may
-- still be showing the last shot for a beat -- a pulse plays out before
-- the sustained mode underneath it takes over -- so the contract is the
-- base mode, which is what the shell settles to.
assert(gb.animBase == "idle", "with the weapon down while they work the action")
local hitsAtReload = #target.hits
run(gunner, gb, target, gb.reloadTimer - 1)
assert(#target.hits == hitsAtReload, "nothing is fired during the reload window")
BNS.Combat.tick(gunner, gb)
assert(not gb.reloadTimer, "the reload finishes on time")
assert(ammo.left == mag, "with a full magazine")
assert(ammo.spares == spares - 1, "and one fewer spare")
print("magazine + reload window OK (" .. mag .. " rounds, " .. spares .. " spares)")

-- The program breaks contact for the length of the reload.
gb.reloadTimer = 100
local closeTarget = makePlayer(1, 0)
gunner.x, gunner.y = 0, 0
BNS.Programs[BNS.Program.ATTACK](gunner, gb, { player = closeTarget, dist = 1 })
assert(gunner.pathedTo, "a reloading gunner moves")
assert(BNS.dist(gunner.pathedTo[1], gunner.pathedTo[2], closeTarget.x, closeTarget.y) > 1,
    "away from the player")
gb.reloadTimer = nil

-- Burn every spare: they draw the melee backup and come for you.
-- (Planted, not still running from the reload above -- combat refuses to
-- act mid-sprint, which is the program's job to resolve.)
ammo.spares = 0
ammo.left = 0
gb.animMode = "idle"
BNS.Combat.attack(gunner, gb, target)
assert(gb.weapon.gun == false, "out of ammo entirely, the gun goes away")
assert(gb.weapon.item == "Base.Machete", "and the rolled backup comes out")
assert(gunner.hand and gunner.hand.id == "Base.Machete", "in their actual hand")
assert(gunner.vars.Weapon == "knife",
    "with the animation following the new weapon, got " .. tostring(gunner.vars.Weapon))
print("out of ammo -> melee backup OK")

-- 6. Aim has to be held, and moving loses it --------------------------------------------
local ab = newBrain({ item = "Base.HuntingRifle", dmg = 0.5, range = 18, gun = true,
                      sound = "RifleShot", hit = 55 }, BNS.Tier.MILITIA)
local sniper, mark = makeNPC(ab, 0, 0), makePlayer(8, 0)
assert(BNS.Combat.aimFactor(ab) == BNS.Combat.AIM_FLOOR,
    "a bandit who just moved shoots at the floor accuracy")
for _ = 1, BNS.Combat.AIM_FULL do
    BNS.Anim.tick(sniper, ab)
    BNS.Combat.tick(sniper, ab)
    BNS.Combat.shoot(sniper, ab, mark)
end
assert(BNS.Combat.aimFactor(ab) > BNS.Combat.AIM_FLOOR + 0.4,
    "holding still on a target settles the shot, got " .. BNS.Combat.aimFactor(ab))
-- One path order and the aim is gone again.
BNS.Programs.walkTo(sniper, 20, 20, 0, true)
assert(ab.aimTicks == 0, "moving loses a settled aim")
assert(BNS.Combat.aimFactor(ab) == BNS.Combat.AIM_FLOOR, "back to the floor")
print("aim ramp OK")

-- 7. Line of sight gates the shot, and a build without it is not punished ---------------
BNS.Combat.losProbe = nil
local blind = makeNPC(newBrain(pistol), 0, 0)
local lb = blind:getModData().BNS
function blind:CanSee() return false end
local hidden = makePlayer(4, 0)
run(blind, lb, hidden, 400, BNS.Combat.attack)
assert(#hidden.hits == 0, "nothing is fired at a target behind a wall")
assert((lb.aimTicks or 0) == 0, "and no aim is settled on one")

-- A CanSee that throws is written off once, not called every tick.
BNS.Combat.losProbe = nil
local calls = 0
local thrower = makeNPC(newBrain(pistol), 0, 0)
local tb = thrower:getModData().BNS
function thrower:CanSee() calls = calls + 1; error("wrong signature") end
run(thrower, tb, makePlayer(4, 0), 200)
assert(calls == 1, "a throwing CanSee is called once, got " .. calls)
assert(BNS.Combat.losProbe == false, "and locked out for the session")
BNS.Combat.losProbe = nil
print("line of sight OK")

-- 8. Gunners shove what is in their face, and keep their distance -----------------------
-- A zombie's answer to someone stood on top of it is a lunge. A gunner's
-- is to push them off and bring the weapon back up.
BNS.Combat.flagProbe = {}
BNS.Combat.setterProbe = {}
local sb = newBrain(pistol)
sb.ammo = BNS.Combat.gunProfile(sb)
local standoff = makeNPC(sb, 20, 20)
local rusher = makePlayer(21, 20) -- right on top of them
local shoved = { staggered = false }
function rusher:setStaggerBack(v) shoved.staggered = v end
-- The engine's own shove is NEVER used: setPerformingShoveAnimation puts
-- a firearm-carrying shell into the ballistics path, which reads the
-- player aiming reticle, indexes it at -1 for a zombie, and takes the
-- game down. If this is ever called again, this test fails.
function standoff:setPerformingShoveAnimation()
    error("setPerformingShoveAnimation crashes the game on a shell")
end
function standoff:setPerformingAttackAnimation()
    error("engine combat-action flags crash the game on a shell")
end
local healthBefore = #rusher.hits

BNS.Programs[BNS.Program.ATTACK](standoff, sb, { player = rusher, dist = 1 })
assert(standoff.vars.BNSAnim == "swing", "the push plays a BNS clip of our own")
assert(shoved.staggered, "and the player is staggered by it")
assert(#rusher.hits == healthBefore, "a shove does them no damage, both ways round")
assert(sb.shoveTimer > 0, "with a cooldown, so it is not a stun-lock")

-- On cooldown they open the range instead of standing there.
standoff.pathedTo = nil
local pushes = sb.shoveTimer
BNS.Programs[BNS.Program.ATTACK](standoff, sb, { player = rusher, dist = 1 })
assert(sb.shoveTimer <= pushes, "no second shove while it is on cooldown")
assert(standoff.pathedTo, "they give ground instead")

-- Further out but still inside the standoff band: back away, don't shove.
sb.shoveTimer = 0
standoff.pathedTo = nil
local closer = makePlayer(22, 20)
BNS.Programs[BNS.Program.ATTACK](standoff, sb, { player = closer, dist = 2.5 })
assert(sb.shoveTimer == 0, "past arm's length they do not shove")
assert(standoff.pathedTo, "they move")
assert(BNS.dist(standoff.pathedTo[1], standoff.pathedTo[2], closer.x, closer.y)
    > BNS.dist(standoff.x, standoff.y, closer.x, closer.y),
    "opening the range rather than closing it")

-- A setter is not a getter. BNS.Combat.flag calls with no arguments, so
-- pointing it at a setter threw a Kahlua stack trace per shove and then
-- reported a perfectly good method as "unusable on this build".
BNS.Combat.setterProbe = {}
local strict = {}
local got = nil
function strict:setStaggerBack(v)
    if v == nil then error("expected 1 argument, got 0") end
    got = v
end
assert(BNS.Combat.applyFlag(strict, "setStaggerBack", true), "the setter is called")
assert(got == true, "with its argument, got " .. tostring(got))
assert(not BNS.Combat.applyFlag(strict, "notAMethod", true), "a missing method is a no")

local throws, calls = {}, 0
function throws:setBumpDone() calls = calls + 1; error("no such signature") end
for _ = 1, 50 do BNS.Combat.applyFlag(throws, "setBumpDone", false) end
assert(calls == 1, "a setter that throws is called once, got " .. calls)
BNS.Combat.setterProbe = {}
print("gunner shove and standoff OK")

-- A shell must never look to the engine like it is aiming a firearm ------------------
-- This is the crash: B42 gives an aiming character a BallisticsController,
-- that controller reads the player aiming reticle, and a zombie's player
-- index is -1 -- ArrayIndexOutOfBoundsException, straight to the desktop.
BNS.Combat.setterProbe = {}
local armed = makeNPC(newBrain(pistol), 0, 0)
local state = { aiming = true, controller = {}, target = {} }
function armed:isAiming() return state.aiming end
function armed:setIsAiming(v) state.aiming = v end
function armed:getBallisticsController() return state.controller end
function armed:releaseBallisticsController() state.controller = nil end
function armed:getBallisticsTarget() return state.target end
function armed:releaseBallisticsTarget() state.target = nil end

BNS.Combat.disarmBallistics(armed)
assert(state.aiming == false, "a shell is never left aiming a firearm")
assert(state.controller == nil, "its ballistics controller is released")
assert(state.target == nil, "and so is its ballistics target")

-- Nothing to clear means nothing is called.
local touched = 0
function armed:releaseBallisticsController() touched = touched + 1 end
function armed:releaseBallisticsTarget() touched = touched + 1 end
BNS.Combat.disarmBallistics(armed)
assert(touched == 0, "an already-clear shell is left alone, got " .. touched)

-- A build without any of it is not punished for it.
BNS.Combat.setterProbe = {}
local bare = makeNPC(newBrain(pistol), 0, 0)
BNS.Combat.disarmBallistics(bare) -- must not throw
print("ballistics guard OK")

-- 9. Attack speed is one knob over every interval ---------------------------------------
-- The sandbox default is half speed: NPCs swing and shoot at half the
-- rate they otherwise would, which is what gives a player time to read a
-- windup and step out of it. It must not touch anything else.
assert(BNS.Options().attackSpeed == 0.5, "half speed is the shipped default")

-- Both beats of the cycle, measured straight off the tempo function so
-- the comparison is not at the mercy of whether a swing happened to land.
local function beatsAt(speed)
    SandboxVars.BNS.NPCAttackSpeed = speed
    local b = newBrain({ item = "Base.Axe", dmg = 0.2, range = 1.3, gun = false })
    return BNS.Combat.swingTicks(b, BNS.Combat.WINDUP),
           BNS.Combat.swingTicks(b, BNS.Combat.RECOVER)
end
local fullWind, fullRecover = beatsAt(1.0)
local halfWind, halfRecover = beatsAt(0.5)
-- Doubled to within the tick the interval is floored to.
local function doubled(half, full, what)
    assert(math.abs(half - full * 2) <= 1,
        "half speed doubles the " .. what .. ": " .. half .. " vs " .. full)
end
doubled(halfWind, fullWind, "windup")
doubled(halfRecover, fullRecover, "recovery")

-- And it really is visible on a live swing, not just in the arithmetic.
SandboxVars.BNS.NPCAttackSpeed = 0.5
local slowB = newBrain({ item = "Base.Axe", dmg = 0.2, range = 1.3, gun = false })
local slowN, slowT = makeNPC(slowB, 0, 0), makePlayer(1, 0)
BNS.Combat.attack(slowN, slowB, slowT)
assert(slowB.swingTimer == halfWind,
    "a swing ordered at half speed takes the slow windup")

local function shotGapAt(speed)
    SandboxVars.BNS.NPCAttackSpeed = speed
    math.randomseed(5) -- the between-burst pause is rolled, so pin it
    local b = newBrain(pistol)
    local n, t = makeNPC(b, 0, 0), makePlayer(5, 0)
    BNS.Combat.ensureAmmo(b)
    step(n, b, t) -- first round goes immediately
    return b.shotTimer
end
local fullGap = shotGapAt(1.0)
local halfGap = shotGapAt(0.5)
doubled(halfGap, fullGap, "gap between rounds")
SandboxVars.BNS.NPCAttackSpeed = nil

-- Accuracy, damage and the aim ramp are deliberately untouched by it.
SandboxVars.BNS.NPCAttackSpeed = 0.25
local slowBrain = newBrain(pistol)
slowBrain.aimTicks = BNS.Combat.AIM_FULL
local fastFactor = BNS.Combat.aimFactor(slowBrain)
SandboxVars.BNS.NPCAttackSpeed = 2.0
assert(BNS.Combat.aimFactor(slowBrain) == fastFactor,
    "attack speed does not change how well they shoot, only how often")
SandboxVars.BNS.NPCAttackSpeed = nil
print("attack speed knob OK (x2 intervals at 0.5)")

-- 10. The swing clip gets the recovery beat, and always lets go of it ------------------
-- Two failures, opposite ends of the same number. Too short and the
-- animation is cut off mid-swing, which is what it looked like in game.
-- Too long and BNSAnim never leaves "swing" between swings: the
-- condition never changes, the node has no edge to re-trigger on, and
-- the *next* swing plays nothing at all.
SandboxVars.BNS.NPCAttackSpeed = nil -- shipped default (0.5)
local clipBrain = newBrain(axe)
local clipNpc, clipTarget = makeNPC(clipBrain, 0, 0), makePlayer(1, 0)
BNS.Combat.attack(clipNpc, clipBrain, clipTarget)
run(clipNpc, clipBrain, clipTarget, clipBrain.swingTimer + 1) -- to contact
assert(clipNpc.vars.BNSAnim == "swing", "contact plays the swing clip")
local hold, recovery = clipBrain.animPulse, clipBrain.swingTimer
assert(hold >= BNS.Combat.SWING_HOLD_MIN,
    "held long enough for the clip to finish, got " .. hold)
assert(hold < recovery,
    "and let go before the next swing (" .. hold .. " held vs " .. recovery .. " beat)")

-- Watch a whole second swing arrive and confirm the variable actually
-- left "swing" in between, which is the part that re-triggers the node.
local sawStance = false
for _ = 1, recovery + 400 do
    step(clipNpc, clipBrain, clipTarget)
    if clipNpc.vars.BNSAnim ~= "swing" then sawStance = true end
    if sawStance and clipNpc.vars.BNSAnim == "swing" then break end
end
assert(sawStance, "the shell returns to its stance between swings")
assert(clipNpc.vars.BNSAnim == "swing", "and the next swing re-triggers the clip")
print("swing clip hold OK (" .. hold .. " of a " .. recovery .. " tick beat)")

-- Rounds in a burst each get their own trigger too.
local burstBrain = newBrain({ item = "Base.AssaultRifle", dmg = 0.4, range = 14,
                              gun = true, sound = "M16Shot", hit = 50 }, BNS.Tier.MILITIA)
local burstNpc, burstTarget = makeNPC(burstBrain, 0, 0), makePlayer(6, 0)
BNS.Combat.ensureAmmo(burstBrain)
run(burstNpc, burstBrain, burstTarget, 1)
assert(burstBrain.animPulse < burstBrain.shotTimer + 1,
    "a shot clip does not run past the next round")
print("burst clip hold OK")

-- 11. Two-handed weapons are carried in two hands ---------------------------------------
-- The old spawn code filled the off hand only for guns, and decided even
-- that by testing whether a *setter* existed on the item -- so rifles,
-- axes, bats and spears were all carried and swung one-handed.
local function equipped(item, gun)
    local b = newBrain({ item = item, dmg = 0.2, range = 1.3, gun = gun or false })
    local n = makeNPC(b, 0, 0)
    BNS.Anim.equip(n, b)
    return n
end
BNS.Anim.twoHandProbe = false -- no isTwoHandWeapon on this fake build: use the class
for _, two in ipairs({ "Base.BaseballBat", "Base.Axe", "Base.Sledgehammer",
                       "Base.GardenFork" }) do
    local n = equipped(two)
    assert(n.hand, two .. " is in the primary hand")
    assert(n.offHand == n.hand, two .. " is held in both hands")
end
local rifle = equipped("Base.AssaultRifle", true)
assert(rifle.offHand == rifle.hand, "long guns are shouldered with both hands")
for _, one in ipairs({ "Base.KitchenKnife", "Base.RollingPin" }) do
    local n = equipped(one)
    assert(n.hand, one .. " is in the primary hand")
    assert(n.offHand == nil, one .. " leaves the off hand free")
end
local pistolNpc = equipped("Base.Pistol", true)
assert(pistolNpc.offHand == nil, "a pistol is a one-handed weapon")

-- Swapping releases the hand the old weapon was using.
local swapBrain = newBrain({ item = "Base.AssaultRifle", dmg = 0.4, range = 14,
                             gun = true, sound = "M16Shot", hit = 50 })
local swapNpc = makeNPC(swapBrain, 0, 0)
BNS.Anim.equip(swapNpc, swapBrain)
assert(swapNpc.offHand ~= nil, "the rifle takes both hands")
swapBrain.backup = { item = "Base.KitchenKnife", dmg = 0.12, range = 1.1, gun = false }
BNS.Combat.drawBackup(swapNpc, swapBrain)
assert(swapNpc.hand.id == "Base.KitchenKnife", "the knife is drawn")
assert(swapNpc.offHand == nil, "and the hand that held the rifle lets go")

-- Where the build does answer for itself, the item wins over the class.
BNS.Anim.twoHandProbe = nil
local scripted = newBrain({ item = "Base.RollingPin", dmg = 0.08, range = 1.2 })
local scriptedNpc = makeNPC(scripted, 0, 0)
local realInstance = instanceItem
instanceItem = function(id) return { id = id, isTwoHandWeapon = function() return true end } end
BNS.Anim.equip(scriptedNpc, scripted)
instanceItem = realInstance
assert(scriptedNpc.offHand == scriptedNpc.hand,
    "an item that says it is two-handed is held that way whatever the class says")
BNS.Anim.twoHandProbe = nil
print("two-handed grip OK")

-- 12. A bandit on the floor is out of the fight -----------------------------------------
-- Being knocked over used to change nothing: they kept swinging from
-- their back, because canAttack only ever asked whether they were
-- sprinting.
BNS.Combat.flagProbe = {}
local downBrain = newBrain(axe)
local downNpc, downFoe = makeNPC(downBrain, 0, 0), makePlayer(1, 0)
BNS.Combat.attack(downNpc, downBrain, downFoe) -- start a swing
assert(downBrain.swingPhase == "windup")
BNS.Combat.goDown(downNpc, downBrain)
assert(BNS.Combat.isDown(downBrain), "they are on the floor")
assert(not BNS.Combat.canAttack(downBrain), "and cannot attack from there")
assert(downBrain.swingPhase == nil, "the swing they were mid-way through is dropped")
run(downNpc, downBrain, downFoe, 100)
assert(#downFoe.hits == 0, "nothing lands while they are down")

-- A gun is no different, and a reload does not finish on your back.
local downGun = newBrain(pistol)
local downGunner, downMark = makeNPC(downGun, 0, 0), makePlayer(5, 0)
BNS.Combat.ensureAmmo(downGun)
downGun.reloadTimer = 90
BNS.Combat.goDown(downGunner, downGun)
assert(downGun.reloadTimer == nil, "the magazine change is dropped too")
run(downGunner, downGun, downMark, 100)
assert(#downMark.hits == 0, "and no shots are fired from the floor")

-- They get up on their own: the state always expires.
run(downNpc, downBrain, downFoe, BNS.Combat.GETUP_TICKS + 5)
assert(not BNS.Combat.isDown(downBrain), "they get back up")
assert(BNS.Combat.canAttack(downBrain), "and can fight again")
print("downed bandits do not fight OK")

-- An engine flag that never clears must not park them for good. This is
-- the setUseless lesson: an unverified answer gets a deadline.
BNS.Combat.flagProbe = {}
local stuckBrain = newBrain(axe)
local stuckNpc = makeNPC(stuckBrain, 0, 0)
function stuckNpc:isKnockedDown() return true end -- and never stops saying so
local downTicks = 0
while downTicks < BNS.Combat.DOWN_MAX * 2 do
    step(stuckNpc, stuckBrain, downFoe)
    downTicks = downTicks + 1
    if downTicks > BNS.Combat.DOWN_MAX and not BNS.Combat.isDown(stuckBrain) then break end
end
assert(not BNS.Combat.isDown(stuckBrain),
    "a flag stuck on true stops being believed rather than downing them for ever")
print("downed state has a deadline OK (" .. downTicks .. " ticks)")

-- 13. A shove knocks them over; it does not hurt them -----------------------------------
-- Shoving landed full weapon damage, so a player could push a bandit to
-- death without ever swinging at them.
BNS.Combat.flagProbe = {}
local shover = { shoving = true, stomping = false }
function shover:isPerformingShoveAnimation() return self.shoving end
function shover:isPerformingStompAnimation() return self.stomping end
assert(BNS.Combat.isShove(shover, nil, 0), "a push is read as a shove")
shover.shoving = false
shover.stomping = true
assert(not BNS.Combat.isShove(shover, nil, 0), "a stomp is not a shove")
assert(BNS.Combat.isStomp(shover), "and is read as a stomp")

-- Builds that answer neither fall back to the damage the hit carried.
BNS.Combat.flagProbe = {}
local silent = {}
assert(BNS.Combat.isShove(silent, nil, 0), "no damage means a push")
assert(not BNS.Combat.isShove(silent, nil, 1.4), "damage means a swing")
assert(not BNS.Combat.isShove(silent, nil, nil),
    "an unknown damage is never guessed into a shove -- that would make them immune")
print("shove and stomp are told apart OK")

-- ...and the rule the hit event applies, end to end.
BNS.Combat.flagProbe = {}
local victimBrain = newBrain(axe)
local victimNpc = makeNPC(victimBrain, 0, 0)
function victimNpc:setHealth() end
local pusher = {}
function pusher:isPerformingShoveAnimation() return true end
function pusher:isPerformingStompAnimation() return false end

local startHealth = victimBrain.health
assert(BNS.Combat.receiveHit(victimNpc, victimBrain, pusher, nil, 2.0) == "shoved",
    "a shove is a shove even when the engine hands it a damage number")
assert(victimBrain.health == startHealth, "and costs them no health")
assert(BNS.Combat.isDown(victimBrain), "it puts them on the floor instead")

-- A stomp on someone already down is exactly what should hurt.
local stomper = {}
function stomper:isPerformingShoveAnimation() return false end
function stomper:isPerformingStompAnimation() return true end
assert(BNS.Combat.receiveHit(victimNpc, victimBrain, stomper, nil, 1.0) == "hurt",
    "stomping a downed bandit hurts them")
assert(victimBrain.health < startHealth, "and takes health off")

-- So is a weapon swing at one.
local swung = victimBrain.health
assert(BNS.Combat.receiveHit(victimNpc, victimBrain, silent, nil, 2.0) == "hurt",
    "a swing at a downed bandit hurts them")
assert(victimBrain.health < swung, "and takes health off")

-- Pushing them again while they are already down is a stomp, not a free
-- reset: there is no shoving a bandit to death.
local floored = victimBrain.health
assert(BNS.Combat.receiveHit(victimNpc, victimBrain, pusher, nil, 1.0) == "hurt",
    "a push at someone already on the floor is a stomp")
assert(victimBrain.health < floored, "which hurts")
print("hit rule OK (shove floors, weapons and stomps hurt)")

-- One push is one fall. The engine keeps reporting a shell as down for
-- longer than BNS holds them there, so the poll that watches for
-- knockdowns BNS did not cause would read "down" again the moment they
-- stood up and start the whole thing over -- a bandit stumbling again
-- and again off a single shove for as long as the player stayed near.
BNS.Combat.flagProbe = {}
local onceBrain = newBrain(axe)
local onceNpc = makeNPC(onceBrain, 0, 0)
function onceNpc:setHealth() end
-- The engine's account of the knockdown, which outlasts BNS's timer by a
-- good margin and then stops of its own accord, exactly as a real get-up
-- does.
onceNpc.engineDownFor = BNS.Combat.GETUP_TICKS + 80
function onceNpc:getCurrentStateName()
    if self.engineDownFor > 0 then
        self.engineDownFor = self.engineDownFor - 1
        return "ZombieOnGroundState"
    end
    return "IdleState"
end

assert(BNS.Combat.receiveHit(onceNpc, onceBrain, pusher, nil, 0) == "shoved")
local falls, wasDown = 1, true
for _ = 1, BNS.Combat.GETUP_TICKS * 6 do
    step(onceNpc, onceBrain, makePlayer(1, 0))
    local down = BNS.Combat.isDown(onceBrain)
    if down and not wasDown then falls = falls + 1 end
    wasDown = down
end
assert(falls == 1, "one push knocks them over once, not " .. falls .. " times")
assert(not BNS.Combat.isDown(onceBrain), "and they are up at the end of it")

-- ...and they can be pushed over again afterwards. The guard is on the
-- engine's echo, not on being shoved: a second real push is a second
-- knockdown.
assert(BNS.Combat.receiveHit(onceNpc, onceBrain, pusher, nil, 0) == "shoved",
    "a later push still floors them")
assert(BNS.Combat.isDown(onceBrain), "one push, one fall -- every time")

-- An engine that never stops saying "down" must not turn into a bandit
-- falling over on a loop either: the deadline disbelieves the answer
-- until the engine changes its mind, rather than re-arming on a timer.
BNS.Combat.flagProbe = {}
local loopBrain = newBrain(axe)
local loopNpc = makeNPC(loopBrain, 0, 0)
function loopNpc:isKnockedDown() return true end
BNS.Combat.goDown(loopNpc, loopBrain)
local loopFalls, loopWas = 1, true
for _ = 1, BNS.Combat.DOWN_MAX * 3 do
    step(loopNpc, loopBrain, makePlayer(1, 0))
    local down = BNS.Combat.isDown(loopBrain)
    if down and not loopWas then loopFalls = loopFalls + 1 end
    loopWas = down
end
assert(loopFalls == 1,
    "a stuck flag stops being believed for good, not once every DOWN_MAX ("
        .. loopFalls .. " falls)")
print("one push is one fall OK")

-- 14. They swing at what they are looking at --------------------------------------------
-- A shell points wherever the engine last left it, usually the way it was
-- walking, and nothing turned it towards what it was hitting -- so
-- bandits swung with their back to the player.
BNS.Combat.faceProbe = nil
local faceBrain = newBrain(axe)
local faceNpc, faceFoe = makeNPC(faceBrain, 10, 10), makePlayer(11, 10)
BNS.Combat.attack(faceNpc, faceBrain, faceFoe)
assert(faceNpc.facing, "starting a swing squares them up")
assert(faceNpc.facing[1] == faceFoe.x and faceNpc.facing[2] == faceFoe.y,
    "at the target, not somewhere else")

-- Circle them mid-swing and the blow still lands facing you.
faceNpc.facing = nil
faceFoe.x, faceFoe.y = 10, 11
run(faceNpc, faceBrain, faceFoe, faceBrain.swingTimer + 1)
assert(faceNpc.facing, "they keep turning through the windup and at contact")
assert(faceNpc.facing[1] == 10 and faceNpc.facing[2] == 11,
    "towards where the target moved to")

-- Facing is an engine command, so it is rationed like the others rather
-- than re-asserted every tick.
local faceCalls = 0
faceNpc.faceLocationF = function(self, fx, fy) faceCalls = faceCalls + 1 end
faceBrain.swingPhase, faceBrain.swingTimer = nil, nil
run(faceNpc, faceBrain, faceFoe, 120)
assert(faceCalls > 0, "they do turn")
assert(faceCalls < 120 / 2, "but not on every tick, got " .. faceCalls .. " in 120")
print("facing the target OK (" .. faceCalls .. " turns in 120 ticks)")

-- A build with no usable call is written off once, not retried per tick.
BNS.Combat.faceProbe = nil
local blindTurns = 0
local noFace = makeNPC(newBrain(axe), 0, 0)
noFace.faceLocationF = function() blindTurns = blindTurns + 1; error("no such method") end
local nfBrain = noFace:getModData().BNS
run(noFace, nfBrain, makePlayer(1, 0), 200)
assert(blindTurns == 1, "a throwing face call is tried once, got " .. blindTurns)
assert(BNS.Combat.faceProbe == false, "and locked out for the session")
BNS.Combat.faceProbe = nil
print("face-call lockout OK")

-- 15. Being hit staggers them ------------------------------------------------------------
-- Without an interruption a fight is two damage numbers trading with no
-- way to win a moment: nothing a player does buys them the next hit.
BNS.Combat.setterProbe = {}
local stagBrain = newBrain(axe)
local stagNpc, stagFoe = makeNPC(stagBrain, 0, 0), makePlayer(1, 0)
local leaned = false
function stagNpc:setStaggerBack(v) leaned = v end
function stagNpc:setHealth() end

BNS.Combat.attack(stagNpc, stagBrain, stagFoe)
assert(stagBrain.swingPhase == "windup", "they are mid-swing")
BNS.Combat.receiveHit(stagNpc, stagBrain, silent, nil, 2.0)
assert(BNS.Combat.isStaggered(stagBrain), "a solid hit staggers them")
assert(stagBrain.swingPhase == nil, "and takes the swing they were part way through")
assert(stagNpc.vars.BNSAnim == "hit", "the flinch plays")
assert(leaned, "and the engine leans them back where it can")
assert(not BNS.Combat.canAttack(stagBrain), "they cannot attack while off their beat")
assert(BNS.Combat.isBusy(stagBrain), "and programs treat them as busy")

-- Nothing lands from them while it lasts, and then it passes.
local hitsAt = #stagFoe.hits
run(stagNpc, stagBrain, stagFoe, BNS.Combat.STAGGER_TICKS - 2)
assert(#stagFoe.hits == hitsAt, "nothing of theirs lands mid-stagger")
assert(BNS.Combat.isStaggered(stagBrain), "still staggered just before it ends")
run(stagNpc, stagBrain, stagFoe, 4)
assert(not BNS.Combat.isStaggered(stagBrain), "and it passes on its own")
assert(BNS.Combat.canAttack(stagBrain), "leaving them able to fight again")

-- A heavy hit always staggers; a light one is a roll, so it must at least
-- be possible both ways rather than a certainty dressed up as a chance.
assert(BNS.Combat.staggersFrom(BNS.Combat.STAGGER_HEAVY),
    "a heavy hit always knocks them off their beat")
local light, staggered = 0, 0
for _ = 1, 400 do
    light = light + 1
    if BNS.Combat.staggersFrom(0.02) then staggered = staggered + 1 end
end
assert(staggered > 0 and staggered < light,
    "a glancing one sometimes does and sometimes does not, got " .. staggered)

-- Someone already on the floor is past staggering.
local downed = newBrain(axe)
local downedNpc = makeNPC(downed, 0, 0)
BNS.Combat.goDown(downedNpc, downed)
assert(not BNS.Combat.stagger(downedNpc, downed),
    "you cannot stagger someone who is already down")
assert(not BNS.Combat.isStaggered(downed), "they stay down rather than becoming staggered")
print("stagger OK (" .. BNS.Combat.STAGGER_TICKS .. " ticks)")

-- 16. Every tier fights by the same rules -------------------------------------------------
-- Tiers used to fork the rules: only civilians ran when hurt, so a
-- wounded thug fought to the death every time and read as a different
-- creature rather than a tougher person.
for _, tier in ipairs({ BNS.Tier.CIVILIAN, BNS.Tier.THUG, BNS.Tier.MILITIA }) do
    local b = newBrain(axe, tier)
    local n = makeNPC(b, 0, 0)
    function n:setHealth() end
    b.health = BNS.Behaviour.fleeHealth + 0.01
    BNS.Combat.damageNPC(n, b, 0.02)
    assert(b.program == BNS.Program.FLEE,
        "tier " .. tier .. " breaks off when badly hurt, like everyone else")
end
-- Toughness is the one thing a tier still changes, and it only scales how
-- fast that same threshold arrives.
local soft = newBrain(axe, BNS.Tier.CIVILIAN)
local hard = newBrain(axe, BNS.Tier.MILITIA)
local softNpc, hardNpc = makeNPC(soft, 0, 0), makeNPC(hard, 0, 0)
function softNpc:setHealth() end
function hardNpc:setHealth() end
BNS.Combat.damageNPC(softNpc, soft, 0.2)
BNS.Combat.damageNPC(hardNpc, hard, 0.2)
assert(hard.health > soft.health, "a militiaman takes the same hit better")
print("tiers share their rules OK")

-- 17. Taking a hit spoils a swing in progress -------------------------------------------
local hurtBrain = newBrain(axe)
local hurtNpc, foe = makeNPC(hurtBrain, 0, 0), makePlayer(1, 0)
BNS.Combat.attack(hurtNpc, hurtBrain, foe)
assert(hurtBrain.swingPhase == "windup")
function hurtNpc:setHealth() end
BNS.Combat.damageNPC(hurtNpc, hurtBrain, 0.1)
assert(hurtBrain.swingPhase == "recover", "a hit mid-windup costs them the swing")
assert(#foe.hits == 0, "which never lands")
print("interrupting a swing OK")

print("ALL TESTS PASSED")
