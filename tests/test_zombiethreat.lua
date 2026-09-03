-- Offline test of BNS_ZombieThreat with stubbed PZ APIs.
math.randomseed(7)

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
function getNumActivePlayers() return 0 end
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
function getText(k) return k end
function addSound() end
function getWorld() return { getMetaGrid = function() return { getZoneAt = function() return nil end } end } end
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })

local fakeCell = { zombies = {} }
function getCell()
    return { getZombieList = function()
        return {
            size = function() return #fakeCell.zombies end,
            get = function(_, i) return fakeCell.zombies[i + 1] end,
        }
    end }
end

-- Fake IsoZombie factory
local function makeZ(x, y, opts)
    opts = opts or {}
    local z = {
        __iso = "IsoZombie", x = x, y = y, health = opts.health or 2.0,
        dead = false, modData = { BNS = opts.brain }, sounds = {}, vars = {},
    }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:isDead() return self.dead or self.health <= 0 end
    function z:getModData() return self.modData end
    function z:pathToLocationF(px, py)
        self.pathedTo = { px, py }
        self.pathCalls = (self.pathCalls or 0) + 1
    end
    function z:clearPath() self.pathCleared = (self.pathCleared or 0) + 1 end
    function z:setMoving(v) self.moving = v end
    function z:playSound(s) table.insert(self.sounds, s) end
    function z:setVariable(k, v) self.vars[k] = v end
    function z:getHealth() return self.health end
    function z:setHealth(h) self.health = h end
    function z:getOnlineID() return 1 end
    function z:setRunning() end
    return z
end

require("BNS/BNS_Core")
require("BNS/BNS_Loadouts")
require("BNS/BNS_POIs")
require("BNS/BNS_Archetypes")
require("BNS/BNS_Anim")
require("BNS/BNS_Combat")
require("BNS/BNS_Programs")
require("BNS/BNS_ZombieThreat")

local function zlist(n, d)
    local t = {}
    for i = 1, n do t[i] = { x = i, y = 0, d = d or 2 } end
    return t
end

-- 1. assess ratio rules -------------------------------------------------
assert(BNS.ZombieThreat.assess(0, 0, {}, 1) == "clear")
for n = 1, 4 do
    assert(BNS.ZombieThreat.assess(0, 0, zlist(n), 1) == "fight", "1 NPC vs " .. n .. " should fight")
end
assert(BNS.ZombieThreat.assess(0, 0, zlist(5), 1) == "flee", "1 NPC vs 5 should flee")
assert(BNS.ZombieThreat.assess(0, 0, zlist(8), 2) == "fight", "2 NPCs vs 8 should fight")
assert(BNS.ZombieThreat.assess(0, 0, zlist(9), 2) == "flee", "2 NPCs vs 9 should flee")
local v, nearest = BNS.ZombieThreat.assess(0, 0, { { x = 4, y = 0, d = 4 }, { x = 1, y = 0, d = 1 } }, 1)
assert(v == "fight" and nearest.d == 1, "nearest zombie should be picked")
print("assess ratio rules OK")

-- 2. scan: NPC shells count as allies, not threats ----------------------
local me = makeZ(0, 0, { brain = { id = "n1", role = "bandit", tier = 1 } })
local ally = makeZ(1, 1, { brain = { id = "n2", role = "bandit", tier = 1 } })
fakeCell.zombies = { me, ally, makeZ(2, 0), makeZ(0, 2), makeZ(3, 3), makeZ(50, 50) }
local brain = me:getModData().BNS
local verdict, near, centroid = BNS.ZombieThreat.scan(me, brain)
assert(verdict == "fight", "2 NPCs vs 3 zombies in radius = fight, got " .. tostring(verdict))
assert(near and near.obj, "nearest has live ref")
assert(centroid, "centroid computed")
print("scan ally/threat filtering OK")

-- 3. apply transitions --------------------------------------------------
brain.program = BNS.Program.WANDER
BNS.ZombieThreat.apply(me, brain, "fight", near, centroid)
assert(brain.program == BNS.Program.FIGHTZ and brain.resume == BNS.Program.WANDER, "fight enters FIGHTZ")
BNS.ZombieThreat.apply(me, brain, "clear", nil, nil)
assert(brain.program == BNS.Program.WANDER and brain.resume == nil, "clear restores resume")
assert(BNS.ZombieThreat.targets["n1"] == nil, "target cleared")

-- flee with forced no-stand (roll 100 times; count stands separately below)
local fled, stood = 0, 0
for _ = 1, 2000 do
    local b = { id = "t", tier = BNS.Tier.MILITIA, program = BNS.Program.WANDER }
    BNS.ZombieThreat.apply(me, b, "flee", near, centroid)
    if b.program == BNS.Program.FLEE then
        fled = fled + 1
        assert(b.fleeFrom and b.fleeFrom.x, "fleeFrom set")
    else
        assert(b.program == BNS.Program.FIGHTZ and b.standGround == true, "stander fights")
        stood = stood + 1
    end
end
local rate = stood / 2000 * 100
assert(rate > 10 and rate < 20, "militia stand rate ~15%, got " .. rate)
print(string.format("apply transitions OK (militia last-stand rate %.1f%%)", rate))

-- 4. grab mechanics -----------------------------------------------------
local victim = makeZ(0, 0, { brain = { id = "v", tier = BNS.Tier.CIVILIAN, health = 1.0 } })
local vb = victim:getModData().BNS
local grabbed = false
for _ = 1, 200 do
    BNS.ZombieThreat.zombieStrike(victim, vb, { x = 0.5, y = 0, d = 0.5 })
    if vb.grabbedTimer then grabbed = true break end
end
assert(grabbed, "grab eventually lands at contact range")
assert(vb.animBase == "grabbed", "grabbed anim engaged (base mode survives hit pulses)")
assert(vb.grabbedTimer == 150, "civilians held longest (150 ticks)")
print("grab mechanics OK")

-- 5. NPC kills zombies through attackZombie -----------------------------
local fighter = makeZ(0, 0, { brain = { id = "f", tier = BNS.Tier.THUG, health = 1.0 } })
local fb = fighter:getModData().BNS
fb.weapon = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false }
local prey = makeZ(1, 0)
local swings = 0
while not prey:isDead() and swings < 100 do
    fb.attackTimer = 0
    BNS.Combat.attackZombie(fighter, fb, prey)
    swings = swings + 1
end
assert(prey:isDead(), "zombie dies to melee")
print("melee kill OK in " .. swings .. " swings")

fb.weapon = { item = "Base.Shotgun", dmg = 0.55, range = 7, gun = true, sound = "ShotgunShot", hit = 60 }
local prey2 = makeZ(3, 0)
local shots = 0
while not prey2:isDead() and shots < 100 do
    fb.attackTimer = 0
    BNS.Combat.attackZombie(fighter, fb, prey2)
    shots = shots + 1
end
assert(prey2:isDead(), "zombie dies to gunfire")
print("gun kill OK in " .. shots .. " shots")

-- 6. FIGHTZ program drives at the target --------------------------------
BNS.ZombieThreat.targets["f"] = makeZ(4, 0)
fb.weapon = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false }
fb.program = BNS.Program.FIGHTZ
BNS.Programs[BNS.Program.FIGHTZ](fighter, fb, { dist = 999 })
assert(fighter.pathedTo, "FIGHTZ paths toward its zombie target")
print("FIGHTZ program OK")

-- 7. Fleeing is short and ends in a stand ---------------------------------
-- (regression: apply() used to reset fleeUntil on every ~1/s scan, and the
-- scan lures the horde along behind the NPC, so they fled forever)
local runner = makeZ(0, 0, { brain = { id = "f1", role = "bandit", tier = BNS.Tier.THUG,
    program = BNS.Program.WANDER, health = 1.0 } })
local fb = runner:getModData().BNS
fakeCell.zombies = { runner }
for i = 1, 9 do table.insert(fakeCell.zombies, makeZ(1 + i * 0.1, 0)) end

local verdict = BNS.ZombieThreat.assess(0, 0, zlist(9), 1)
assert(verdict == "flee", "9 zombies vs 1 is a flee")
fb.standGround = false
BNS.ZombieThreat.apply(runner, fb, "flee", { obj = fakeCell.zombies[2] }, { x = 5, y = 0 })
assert(fb.program == BNS.Program.FLEE, "enters FLEE")
local firstTimer = fb.fleeUntil
assert(firstTimer == BNS.Programs.FLEE_TICKS, "flee is time-boxed, got " .. tostring(firstTimer))

-- a later scan while still fleeing must NOT restart the countdown
fb.fleeUntil = firstTimer - 10
BNS.ZombieThreat.apply(runner, fb, "flee", { obj = fakeCell.zombies[2] }, { x = 5, y = 0 })
assert(fb.fleeUntil == firstTimer - 10, "the flee timer is never restarted mid-flight")

-- run it down: they stop, and a cooldown starts
local ticks = 0
while fb.program == BNS.Program.FLEE and ticks < 500 do
    BNS.Programs[BNS.Program.FLEE](runner, fb, { player = nil, dist = 999 })
    ticks = ticks + 1
end
assert(ticks == firstTimer - 10, "flee lasts exactly its remaining ticks, got " .. ticks)
assert(fb.program == BNS.Program.WANDER, "stops running")
assert(fb.fleeCooldown and fb.fleeCooldown > 0, "a stand-your-ground window opens")

-- still outnumbered, but now they turn and fight instead of bolting again
BNS.ZombieThreat.apply(runner, fb, "flee", { obj = fakeCell.zombies[2] }, { x = 5, y = 0 })
assert(fb.program == BNS.Program.FIGHTZ,
    "after fleeing they stand and fight, got " .. tostring(fb.program))
assert(fb.standGround == true, "committed to the fight")

-- and once the area is clear the commitment resets for next time
BNS.ZombieThreat.apply(runner, fb, "clear", nil, nil)
assert(fb.standGround == nil, "next threat episode re-rolls")
print("flee is bounded and ends in a stand OK (" .. ticks .. " ticks)")

-- 8. No attacking at a dead sprint ------------------------------------------
local sprinter = makeZ(0, 0, { brain = { id = "s1", tier = BNS.Tier.THUG, health = 1.0 } })
local sb = sprinter:getModData().BNS
sb.weapon = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false }
sb.warned = true
local prey = makeZ(1, 0)
sb.animMode = "run"
sb.attackTimer = 0
BNS.Combat.attackZombie(sprinter, sb, prey)
assert(prey.health == 2.0, "no swing while running")
assert(not BNS.Combat.canAttack(sb), "canAttack says no while running")

sb.animMode = "walk"
sb.attackTimer = 0
BNS.Combat.attackZombie(sprinter, sb, prey)
assert(prey.health < 2.0, "walking is fine to swing from")
assert(BNS.Combat.canAttack(sb), "canAttack allows walking")

sb.animMode = "idle"
assert(BNS.Combat.canAttack(sb), "and standing still")
print("attacks gated on not running OK")

-- 9. FIGHTZ closes at a run, then plants before swinging ---------------------
local fighter = makeZ(0, 0, { brain = { id = "z9", tier = BNS.Tier.THUG, health = 1.0 } })
local zb = fighter:getModData().BNS
zb.weapon = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false }
zb.program = BNS.Program.FIGHTZ

local farTarget = makeZ(10, 0)
BNS.ZombieThreat.targets["z9"] = farTarget
zb.attackTimer = 0
BNS.Programs[BNS.Program.FIGHTZ](fighter, zb, { dist = 999 })
assert(zb.animMode == "run", "closes at a run")
assert(farTarget.health == 2.0, "and does not swing while closing")

local closeTarget = makeZ(1, 0)
BNS.ZombieThreat.targets["z9"] = closeTarget
zb.attackTimer = 0
BNS.Programs[BNS.Program.FIGHTZ](fighter, zb, { dist = 999 })
assert(zb.animMode ~= "run", "stops on arrival, mode is " .. tostring(zb.animMode))
assert(closeTarget.health < 2.0, "then swings")
print("FIGHTZ close-then-plant OK")

-- 10. Wandering rests instead of marching forever -------------------------
-- (regression: nothing ever cancelled a path, so shells walked to their
-- last target for ever and NPCs never stood still)
local realRand = ZombRand
local function forceRand(fn) ZombRand = fn end
local function restoreRand() ZombRand = realRand end

local ambler = makeZ(0, 0, { brain = { id = "w1", role = BNS.Role.SURVIVOR,
    tier = BNS.Tier.CIVILIAN, program = BNS.Program.WANDER, health = 1.0 } })
local wb = ambler:getModData().BNS
BNS.ZombieThreat.targets["w1"] = nil

-- arrive at the target, and take the rest branch
wb.targetX, wb.targetY = 0, 0
forceRand(function(a, b) if b then return a end return 0 end) -- rolls "rest"
BNS.Programs[BNS.Program.WANDER](ambler, wb, { player = nil, dist = 999 })
restoreRand()
assert(wb.restUntil and wb.restUntil > 0, "arriving starts a rest")
assert(wb.animMode == "idle", "and they stand idle, got " .. tostring(wb.animMode))
assert(ambler.pathCleared and ambler.pathCleared > 0, "the path is actually cancelled")
assert(wb.pathX == nil, "and the remembered path is forgotten")

-- while resting they stay put
local restLen = wb.restUntil
ambler.pathedTo = nil
for _ = 1, restLen - 1 do
    BNS.Programs[BNS.Program.WANDER](ambler, wb, { player = nil, dist = 999 })
end
assert(wb.restUntil == 1, "rest counts down, at " .. tostring(wb.restUntil))
assert(wb.animMode == "idle", "still idle throughout the rest")

-- rest over: they move again
forceRand(function(a, b) if b then return a end return 99 end) -- rolls "no rest"
BNS.Programs[BNS.Program.WANDER](ambler, wb, { player = nil, dist = 999 })
restoreRand()
assert(wb.restUntil == nil, "rest ends")
assert(wb.animMode == "walk", "and they amble off walking, got " .. tostring(wb.animMode))
print("wander rests then resumes OK (rest " .. restLen .. " ticks)")

-- 11. A player standing nearby must not suppress resting -------------------
local watched = makeZ(0, 0, { brain = { id = "w2", role = BNS.Role.SURVIVOR,
    tier = BNS.Tier.CIVILIAN, program = BNS.Program.WANDER, health = 1.0 } })
local wb2 = watched:getModData().BNS
wb2.targetX, wb2.targetY = 0, 0
forceRand(function(a, b) if b then return a end return 0 end)
BNS.Programs[BNS.Program.WANDER](watched, wb2, { player = makeZ(2, 0), dist = 2 })
restoreRand()
assert(wb2.restUntil and wb2.restUntil > 0,
    "they still rest while a player watches from 2 tiles away")

-- but a tracked zombie cancels the rest
BNS.ZombieThreat.targets["w2"] = makeZ(1, 0)
BNS.Programs[BNS.Program.WANDER](watched, wb2, { player = nil, dist = 999 })
assert(wb2.restUntil == nil, "a zombie nearby ends the rest")
BNS.ZombieThreat.targets["w2"] = nil
print("rest suppressed by zombies, not by players OK")

-- 12. walkTo does not restart an unchanged path ------------------------------
local walker = makeZ(0, 0, { brain = { id = "w3", tier = BNS.Tier.CIVILIAN } })
local w3 = walker:getModData().BNS
walker.pathCalls = 0
BNS.Programs.walkTo(walker, 10, 10, 0, false)
BNS.Programs.walkTo(walker, 10, 10, 0, false)
BNS.Programs.walkTo(walker, 10, 10, 0, false)
assert(walker.pathCalls == 1, "same destination is issued once, got " .. walker.pathCalls)
BNS.Programs.walkTo(walker, 11, 10, 0, false)
assert(walker.pathCalls == 2, "a new destination is issued")
print("walkTo path churn avoided OK")

-- 13. Traders hold still for a customer ---------------------------------------
local trader = makeZ(0, 0, { brain = { id = "t1", role = BNS.Role.TRADER,
    tier = BNS.Tier.CIVILIAN, program = BNS.Program.TRADE, health = 1.0 } })
local tb = trader:getModData().BNS
tb.restUntil = 50
local customer = makeZ(3, 0)
BNS.Programs[BNS.Program.TRADE](trader, tb, { player = customer, dist = 3 })
assert(tb.animMode == "idle", "trader stops for a customer at 3 tiles")
assert(trader.pathCleared and trader.pathCleared > 0, "and cancels its path")
assert(tb.restUntil == nil, "waiting on the customer, not resting")

-- out of reach: back to wandering
trader.pathCalls = 0
forceRand(function(a, b) if b then return a end return 99 end)
tb.targetX, tb.targetY = 50, 50
BNS.Programs[BNS.Program.TRADE](trader, tb, { player = customer, dist = 20 })
restoreRand()
assert(tb.animMode == "walk", "wanders again once nobody is close")

-- 14. Survivors only stop when you are right beside them -----------------------
local survivor = makeZ(0, 0, { brain = { id = "s2", role = BNS.Role.SURVIVOR,
    tier = BNS.Tier.CIVILIAN, program = BNS.Program.TRADE, health = 1.0 } })
local sv = survivor:getModData().BNS
forceRand(function(a, b) if b then return a end return 99 end)
sv.targetX, sv.targetY = 50, 50
BNS.Programs[BNS.Program.TRADE](survivor, sv, { player = customer, dist = 4 })
restoreRand()
assert(sv.animMode == "walk", "a survivor keeps going at 4 tiles")
BNS.Programs[BNS.Program.TRADE](survivor, sv, { player = customer, dist = 2 })
assert(sv.animMode == "idle", "but stops when you are beside them")
print("trader/survivor stopping distances OK")

print("ALL TESTS PASSED")
