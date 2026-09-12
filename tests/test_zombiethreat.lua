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
    function z:setRunning(v) self.runCalls = (self.runCalls or 0) + 1; self.running = v end
    function z:setUseless() self.uselessCalls = (self.uselessCalls or 0) + 1 end
    function z:getTarget() return nil end
    function z:setTarget() self.targetCalls = (self.targetCalls or 0) + 1 end
    function z:setAttackedBy() end
    function z:StopAllActionQueue() self.stopCalls = (self.stopCalls or 0) + 1 end
    function z:getPrimaryHandItem() return self.hand end
    function z:faceThisObject(o) self.facing = o end
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
assert(vb.grabbedTimer == BNS.Behaviour.grabHold,
    "the same struggle for everyone, whatever their tier")
print("grab mechanics OK")

-- 5. NPC kills zombies through attackZombie -----------------------------
local fighter = makeZ(0, 0, { brain = { id = "f", tier = BNS.Tier.THUG, health = 1.0 } })
local fb = fighter:getModData().BNS
fb.weapon = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false }
local prey = makeZ(1, 0)
-- Combat runs on engine ticks now: BNS.Combat.tick is what advances the
-- swing cycle, the magazine and the fighter's breath, so the fight is
-- driven by letting time pass rather than by zeroing a cooldown.
local ticks = 0
while not prey:isDead() and ticks < 4000 do
    BNS.Combat.tick(fighter, fb)
    BNS.Combat.attackZombie(fighter, fb, prey)
    ticks = ticks + 1
end
assert(prey:isDead(), "zombie dies to melee")
print("melee kill OK in " .. ticks .. " ticks")

fb.weapon = { item = "Base.Shotgun", dmg = 0.55, range = 7, gun = true, sound = "ShotgunShot", hit = 60 }
local prey2 = makeZ(3, 0)
fb.ammo, fb.shotTimer, fb.burstLeft, fb.aimTicks = nil, nil, nil, nil
local gunTicks = 0
while not prey2:isDead() and gunTicks < 6000 do
    BNS.Combat.tick(fighter, fb)
    BNS.Combat.attackZombie(fighter, fb, prey2)
    gunTicks = gunTicks + 1
end
assert(prey2:isDead(), "zombie dies to gunfire")
print("gun kill OK in " .. gunTicks .. " ticks")

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
for _ = 1, 240 do
    BNS.Combat.tick(sprinter, sb)
    BNS.Combat.attackZombie(sprinter, sb, prey)
end
assert(prey.health == 2.0, "no swing while running")
assert(not BNS.Combat.canAttack(sb), "canAttack says no while running")

sb.animMode = "walk"
-- A swing is a windup, a contact and a recovery, so it lands a beat
-- after it is ordered rather than on the same tick -- which is the gap
-- the player gets to step out of it.
local before = prey.health
local hitTicks = 0
while prey.health == before and hitTicks < 900 do
    BNS.Combat.tick(sprinter, sb)
    BNS.Combat.attackZombie(sprinter, sb, prey)
    hitTicks = hitTicks + 1
end
assert(prey.health < before, "walking is fine to swing from")
assert(hitTicks > 1, "and the swing has a windup rather than landing instantly")
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
BNS.Programs[BNS.Program.FIGHTZ](fighter, zb, { dist = 999 })
assert(zb.animMode ~= "run", "stops on arrival, mode is " .. tostring(zb.animMode))
local plantTicks = 0
while closeTarget.health == 2.0 and plantTicks < 900 do
    BNS.Combat.tick(fighter, zb)
    BNS.Programs[BNS.Program.FIGHTZ](fighter, zb, { dist = 999 })
    plantTicks = plantTicks + 1
end
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

-- 15. Movement orders are rationed like a zombie's -------------------------
-- (regression: a fresh path every brain tick restarts the engine's
-- movement mid-step, which is what made NPCs skate around)
local skater = makeZ(0, 0, { brain = { id = "m1", tier = BNS.Tier.THUG } })
local mb = skater:getModData().BNS
skater.pathCalls = 0

-- chasing something that barely moves: one order, then silence
BNS.Programs.walkTo(skater, 10, 10, 0, true)
assert(skater.pathCalls == 1, "first order goes out")
local calls = 11
for i = 1, calls - 1 do
    BNS.Programs.walkTo(skater, 10 + i * 0.05, 10, 0, true) -- drifting target
end
-- One order per REPATH_TICKS calls (~2/second), not one per call.
local allowed = math.ceil(calls / BNS.Programs.REPATH_TICKS)
assert(skater.pathCalls <= allowed,
    "small target drift is rationed: " .. skater.pathCalls .. " orders in "
    .. calls .. " calls (allowed " .. allowed .. ")")
assert(skater.pathCalls < calls / 2, "and far below one per tick")

-- a target that genuinely moves gets a fresh order immediately
local before = skater.pathCalls
BNS.Programs.walkTo(skater, 30, 30, 0, true)
assert(skater.pathCalls == before + 1, "a real move re-paths at once")

-- switching between walking and running re-issues too
before = skater.pathCalls
BNS.Programs.walkTo(skater, 30, 30, 0, false)
assert(skater.pathCalls == before + 1, "changing pace re-issues")
print("path orders rationed OK (" .. skater.pathCalls .. " orders)")

-- 16. Halting is a one-off order, not a per-tick habit ----------------------
local stander = makeZ(5, 5, { brain = { id = "m2", tier = BNS.Tier.THUG } })
local sb2 = stander:getModData().BNS
BNS.Programs.walkTo(stander, 20, 20, 0, false)
stander.pathCleared, stander.stopCalls, stander.pathCalls = 0, 0, 0
BNS.Programs.stopMoving(stander, sb2, "idle")
assert(stander.pathCleared == 1 and stander.stopCalls == 1, "the halt is issued once")
assert(sb2.stopped == true, "and recorded")
local afterStop = stander.pathCalls
for _ = 1, 20 do BNS.Programs.stopMoving(stander, sb2, "idle") end
assert(stander.pathCleared == 1, "standing still does not keep re-issuing the halt")
assert(stander.pathCalls == afterStop, "nor re-path onto its own square every tick")

-- and moving off again works
BNS.Programs.walkTo(stander, 25, 25, 0, false)
assert(sb2.stopped == nil and stander.pathCalls > afterStop, "it can walk again")
print("halt is idempotent OK")

-- 17. Zombie suppression: the real pass, not a re-implementation of it ------
-- BNS_Brain hooks the engine's events at load, and the modules it pulls in
-- want a few globals this suite has not needed until now.
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })
ModData = ModData or { getOrCreate = function() return {} end }
require("BNS/BNS_Brain")

local function makeShell(x, y, opts)
    opts = opts or {}
    local z = makeZ(x, y, { brain = opts.brain })
    z.target = opts.target or nil
    z.state = opts.state or "ZombieIdleState"
    z.locked = nil
    function z:getTarget() return self.target end
    function z:setTarget(t) self.target = t; self.targetClears = (self.targetClears or 0) + 1 end
    function z:getCurrentStateName() return self.state end
    function z:setStateMachineLocked(v) self.locked = v end
    return z
end

-- Far from anyone: the pass runs a few times a second, not sixty.
local far = makeShell(0, 0, { brain = { id = "m3", role = "bandit",
    tier = BNS.Tier.THUG, program = BNS.Program.WANDER, health = 1.0 },
    target = {} })
local farB = far:getModData().BNS
farB.suppressTick = 1
for _ = 1, 60 do
    far.target = {}
    BNS.Brain.suppress(far, farB)
end
assert(far.targetClears == 6,
    "suppression runs ~6 times a second when nobody is near, got "
        .. tostring(far.targetClears))

-- Close to a player: every tick, because the engine re-acquires inside
-- the same update and a slower cadence leaves room for a lunge.
BNS.getPlayers = function() return { { getX = function() return 1 end,
                                      getY = function() return 0 end } } end
local near = makeShell(0, 0, { brain = { id = "m4", role = "bandit",
    tier = BNS.Tier.THUG, program = BNS.Program.WANDER, health = 1.0 } })
local nearB = near:getModData().BNS
for _ = 1, 30 do
    near.target = {}
    BNS.Brain.suppress(near, nearB)
end
assert(near.targetClears == 30,
    "a player at arm's length gets it cleared every tick, got "
        .. tostring(near.targetClears))
print("suppression cadence OK")

-- 18. A lunge already under way is left to finish -------------------------
-- Tearing the target out from under the engine's own state every tick is
-- what left shells frozen in the lunge pose: the state could never reach
-- its end condition, so it never released the animation.
local lunging = makeShell(0, 0, { brain = { id = "m5", role = "bandit",
    tier = BNS.Tier.THUG, program = BNS.Program.WANDER, health = 1.0 },
    state = "LungeState" })
local lb = lunging:getModData().BNS
for _ = 1, 30 do
    lunging.target = {}
    BNS.Brain.suppress(lunging, lb)
end
assert((lunging.targetClears or 0) == 0,
    "the target is left alone while the state is using it, got "
        .. tostring(lunging.targetClears))
assert(lb.lunges == 1, "the lunge is counted once, not per tick")

-- The tick it ends is the tick the target goes.
lunging.state = "ZombieIdleState"
lunging.target = {}
BNS.Brain.suppress(lunging, lb)
assert(lunging.targetClears == 1, "and cleared the moment the state is over")
assert(lb.zStateTicks == nil, "with the counter reset for the next one")

-- A state that outstays any real animation is jammed, and gets broken out
-- of rather than leaving an NPC posed for ever.
lunging.state = "LungeState"
lb.zJams = nil
for _ = 1, 200 do
    lunging.target = {}
    BNS.Brain.suppress(lunging, lb)
end
assert((lb.zJams or 0) >= 1,
    "a state stuck past its welcome is broken out of, got " .. tostring(lb.zJams))
print("lunge is finished, not jammed OK")

-- 19. Standing in melee range holds the engine's state machine ------------
-- Clearing the target is a race BNS loses at contact range, so the lever
-- is upstream: with the machine locked the engine cannot switch the shell
-- into its lunge at all.
BNS.Combat.lockProbe = nil
local held = makeShell(0, 0, { brain = { id = "m6", role = "bandit",
    tier = BNS.Tier.THUG, health = 1.0 } })
local hb = held:getModData().BNS
BNS.Combat.holdState(held, hb, true)
assert(held.locked == true, "stood in reach, the state machine is held")
assert(hb.stateLocked, "and BNS knows it is holding it")
BNS.Combat.holdState(held, hb, false)
assert(held.locked == false, "released as soon as they are not")
assert(hb.stateLocked == nil, "and BNS lets go of the bookkeeping too")

-- Never held for ever: an engine flag stuck on must not park an NPC. And
-- the cap has to latch -- dropping the lock at the cap only to retake it
-- on the next tick is not a limit.
for _ = 1, BNS.Combat.LOCK_MAX + 50 do BNS.Combat.holdState(held, hb, true) end
assert(held.locked == false,
    "past LOCK_MAX the hold is dropped whatever the caller wants")
assert(hb.lockSpent, "and stays dropped rather than being retaken next tick")
-- Walking away and coming back gets a fresh budget.
BNS.Combat.holdState(held, hb, false)
assert(hb.lockSpent == nil, "leaving the standoff resets it")
BNS.Combat.holdState(held, hb, true)
assert(held.locked == true, "and the next one can hold again")
BNS.Combat.holdState(held, hb, false)

-- A build without the call is written off once, not retried per tick.
BNS.Combat.lockProbe = nil
local noLock = makeShell(0, 0, { brain = { id = "m7", role = "bandit", health = 1.0 } })
local nb = noLock:getModData().BNS
noLock.setStateMachineLocked = nil
BNS.Combat.holdState(noLock, nb, true)
assert(BNS.Combat.lockProbe == false, "a missing call is settled once")
assert(not nb.stateLocked, "and nothing pretends to be holding anything")
BNS.Combat.lockProbe = nil

-- ...and being attacked opens it. The lock engages exactly where a player
-- stands to shove one, and a frozen state machine has no knockdown and no
-- stagger to give: shoving a bandit simply did nothing.
BNS.Combat.lockProbe = nil
local shoved = makeShell(0, 0, { brain = { id = "m8", role = "bandit",
    tier = BNS.Tier.THUG, health = 1.0 } })
local sb = shoved:getModData().BNS
BNS.Combat.holdState(shoved, sb, true)
assert(shoved.locked == true, "held while they are being left alone")
BNS.Combat.openState(shoved, sb)
assert(shoved.locked == false, "a swing at them drops the hold at once")
assert(BNS.Combat.isOpen(sb), "and keeps it open for a moment")
-- It must stay open across the brain ticks the fight happens on, not just
-- the one the swing landed in.
for _ = 1, BNS.Combat.OPEN_TICKS - 1 do BNS.Combat.tick(shoved, sb) end
assert(BNS.Combat.isOpen(sb), "for the whole window")
BNS.Combat.tick(shoved, sb)
assert(not BNS.Combat.isOpen(sb), "and then closes on its own")
BNS.Combat.holdState(shoved, sb, false)

-- Any hit opens it, whether the build calls it a shove or not.
BNS.Combat.flagProbe = {}
local struck = makeShell(0, 0, { brain = { id = "m9", role = "bandit",
    tier = BNS.Tier.THUG, health = 1.0 } })
local kb = struck:getModData().BNS
function struck:setHealth() end
BNS.Combat.holdState(struck, kb, true)
BNS.Combat.receiveHit(struck, kb, {}, nil, 0)
assert(struck.locked == false, "being shoved opens it")
BNS.Combat.holdState(struck, kb, false)
BNS.Combat.holdState(struck, kb, true)
BNS.Combat.receiveHit(struck, kb, {}, nil, 1.5)
assert(struck.locked == false, "and so does being hit with something")
BNS.Combat.holdState(struck, kb, false)
BNS.Combat.flagProbe = {}
print("melee state hold OK")

-- 20. Friendly NPCs never attack a person ---------------------------------
-- Gated on the role, not on which program happens to be running: there is
-- no route to a survivor throwing a punch because a transition put them
-- somewhere unexpected.
local victim = { x = 1, y = 0, hits = {} }
function victim:getX() return self.x end
function victim:getY() return self.y end
function victim:getZ() return 0 end
function victim:isDead() return false end
function victim:isSneaking() return false end
function victim:isRunning() return false end
function victim:getBodyDamage()
    return {
        getBodyPart = function()
            return { AddDamage = function(_, n) table.insert(victim.hits, n) end,
                     setScratched = function() end }
        end,
        Update = function() end,
    }
end
local friendly = { id = "m8", role = BNS.Role.SURVIVOR, tier = BNS.Tier.CIVILIAN,
    health = 1.0, warned = true, animMode = "idle", stamina = 1.0,
    weapon = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false } }
local neighbour = makeZ(0, 0, { brain = friendly })
for _ = 1, 600 do
    BNS.Combat.tick(neighbour, friendly)
    BNS.Combat.attack(neighbour, friendly, victim)
end
assert(#victim.hits == 0, "a survivor stood next to you does nothing")
assert(friendly.swingPhase == nil, "and never even starts a swing")

friendly.role = BNS.Role.BANDIT -- turn hostile, as being attacked would
local swung = false
for _ = 1, 600 do
    BNS.Combat.tick(neighbour, friendly)
    BNS.Combat.attack(neighbour, friendly, victim)
    if friendly.swingPhase then swung = true end
end
assert(swung, "a hostile one in the same spot does swing")
print("friendly NPCs hold their hands OK")

-- The warning: a real shot from the gun they carry, then 4 seconds ------------------
local function makeTarget(x, y)
    local p = { x = x, y = y, hits = {} }
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return 0 end
    function p:isDead() return false end
    function p:isSneaking() return false end
    function p:getBodyDamage()
        return {
            getBodyPart = function()
                return { AddDamage = function(_, n) table.insert(p.hits, n) end,
                         setScratched = function() end }
            end,
            Update = function() end,
        }
    end
    return p
end

local gunner = { id = "g1", role = BNS.Role.BANDIT, tier = BNS.Tier.MILITIA,
                 health = 1.0, program = BNS.Program.ATTACK,
                 weapon = { item = "Base.Shotgun", gun = true, dmg = 0.5,
                            range = 8, sound = "ShotgunShot", hit = 100 } }
local gz = makeZ(10, 10, { brain = gunner })
-- The gun actually in their hands names its own sound.
gz.hand = { getSwingSound = function() return "ShotgunFire" end }
local victim = makeTarget(13, 10)

BNS.Programs.startWarning(gz, gunner, victim)
assert(#gz.sounds == 1, "the warning is a shot, not silence")
assert(gz.sounds[1] == "ShotgunFire",
    "fired with the held weapon's own sound, got " .. tostring(gz.sounds[1]))
assert(gz.vars.BNSAnim == "shoot", "and it plays the firing animation")
assert(gz.facing == victim, "aimed toward the player")
assert(#victim.hits == 0, "a warning shot never damages")
assert(gunner.warnTimer == 240, "4 seconds at 60 ticks/s, got " .. tostring(gunner.warnTimer))
assert(not gunner.warned, "and they are not yet committed")

-- Nothing lands during those 4 seconds, however often combat is called.
for _ = 1, 239 do
    gunner.warnTimer = gunner.warnTimer - 1
    BNS.Combat.tick(gz, gunner)
    BNS.Combat.attack(gz, gunner, victim)
end
assert(#victim.hits == 0, "no damage during the warning window")
gunner.warnTimer = gunner.warnTimer - 1
if gunner.warnTimer <= 0 then gunner.warnTimer = nil; gunner.warned = true end
assert(gunner.warned, "after 4 seconds they commit")

-- The warning shot came out of the magazine like any other round.
assert(gunner.ammo and gunner.ammo.left == gunner.ammo.mag - 1,
    "the warning round is spent, left " .. tostring(gunner.ammo and gunner.ammo.left))

gunner.animMode = "idle"
local fireTicks = 0
while #victim.hits == 0 and fireTicks < 2000 do
    BNS.Combat.tick(gz, gunner)
    BNS.Combat.attack(gz, gunner, victim)
    fireTicks = fireTicks + 1
end
assert(#victim.hits > 0, "and then shots land normally")
print("warning shot + 4s delay OK")

-- A second engagement does not re-warn until the first one ends.
local before = #gz.sounds
BNS.Programs.startWarning(gz, gunner, victim)
assert(#gz.sounds == before, "no second warning shot while already committed")

-- Melee bandits close in silently: nothing fired, nothing said.
local said = {}
local realSay = BNS.Say
BNS.Say = function(_, _, text) table.insert(said, text) end
local thug = { id = "t1", role = BNS.Role.BANDIT, tier = BNS.Tier.THUG,
               health = 1.0, program = BNS.Program.ATTACK, speechCooldown = 0,
               weapon = { item = "Base.BaseballBat", dmg = 0.16, range = 1.4 } }
local tz = makeZ(10, 10, { brain = thug })
BNS.Programs.startWarning(tz, thug, victim)
assert(#tz.sounds == 0, "a melee bandit fires nothing")
assert(#said == 0, "and says nothing -- they close silently")
assert(thug.warnTimer == 240, "but still holds off for the same 4 seconds")
thug.attackTimer = 0
thug.animMode = "idle"
local hitsBefore = #victim.hits
victim.x, victim.y = 10, 10
BNS.Combat.attack(tz, thug, victim)
assert(#victim.hits == hitsBefore, "and lands nothing during the hold")
BNS.Say = realSay
print("silent melee approach OK")

print("ALL TESTS PASSED")
