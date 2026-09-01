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
    function z:pathToLocationF(px, py) self.pathedTo = { px, py } end
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

print("ALL TESTS PASSED")
