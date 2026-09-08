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
    function z:hasPath() return false end
    function z:getOnlineID() return 1 end
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

-- Run the fight for n engine ticks, the way BNS_Brain does.
local function run(npc, brain, target, ticks, attack)
    attack = attack or BNS.Combat.attack
    for _ = 1, ticks do
        BNS.Combat.tick(npc, brain)
        attack(npc, brain, target)
    end
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
    BNS.Combat.tick(hitNpc, hitBrain)
    BNS.Combat.attack(hitNpc, hitBrain, victim)
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
    BNS.Combat.tick(gunner, gb)
    BNS.Combat.attack(gunner, gb, target)
    if ammo.left < before then shots = shots + 1 end
    if shots > mag then break end
end
assert(shots == mag, "the whole magazine is fired, got " .. shots)

-- The next attack starts a reload rather than another shot.
BNS.Combat.tick(gunner, gb)
BNS.Combat.attack(gunner, gb, target)
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
ammo.spares = 0
ammo.left = 0
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

-- 8. Gunners keep their distance --------------------------------------------------------
local sb = newBrain(pistol)
sb.ammo = BNS.Combat.gunProfile(sb)
local standoff = makeNPC(sb, 20, 20)
local rusher = makePlayer(21, 20) -- well inside a pistol's 10 tiles
BNS.Programs[BNS.Program.ATTACK](standoff, sb, { player = rusher, dist = 1 })
assert(standoff.pathedTo, "a player in their face makes them move")
assert(BNS.dist(standoff.pathedTo[1], standoff.pathedTo[2], rusher.x, rusher.y)
    > BNS.dist(standoff.x, standoff.y, rusher.x, rusher.y),
    "opening the range rather than closing it")
print("gunner standoff OK")

-- 9. Taking a hit spoils a swing in progress --------------------------------------------
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
