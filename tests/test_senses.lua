-- Offline test of what an NPC knows about where you are.
--
-- Pursuit used to read the player's live coordinates every tick, which is
-- perfect knowledge: break line of sight, cross a building, and they
-- still walked exactly to you. Nothing a player did could shake one off.
-- What is asserted here is the shape of a chase you can win: they follow
-- what they last *saw*, that memory does not move, and it runs out.
math.randomseed(53)

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
function instanceItem(id) return { id = id } end
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
require("BNS/BNS_Programs")
require("BNS/BNS_Senses")

-- Fakes ----------------------------------------------------------------
local WALL = false -- when true, nothing can see anything

local function makeNPC(brain, x, y)
    local z = { __iso = "IsoZombie", x = x or 0, y = y or 0, vars = {},
                modData = { BNS = brain }, looking = nil }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:getModData() return self.modData end
    function z:setVariable(k, v) self.vars[k] = v end
    function z:setRunning(v) self.running = v end
    function z:setSpeedMod(v) self.speed = v end
    function z:playSound() end
    function z:getOnlineID() return 1 end
    function z:pathToLocationF(px, py) self.pathedTo = { px, py } end
    function z:hasPath() return false end
    function z:setHeadLookAround(v) self.looking = v end
    function z:CanSee() return not WALL end
    return z
end

local function makePlayer(x, y)
    local p = { x = x, y = y }
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return 0 end
    function p:isDead() return false end
    function p:isSneaking() return false end
    function p:isAiming() return false end
    function p:isRunning() return false end
    return p
end

local function newBrain()
    return { id = "bns_1", role = BNS.Role.BANDIT, tier = BNS.Tier.THUG,
             health = 1.0, animMode = "idle", stamina = 1.0,
             program = BNS.Program.APPROACH,
             weapon = { item = "Base.Axe", dmg = 0.26, range = 1.3, gun = false } }
end

local function look(npc, brain, player)
    local ctx = { player = player,
                  dist = BNS.dist(npc:getX(), npc:getY(), player:getX(), player:getY()) }
    BNS.Senses.observe(npc, brain, ctx)
    return ctx
end

-- 1. Seen: they head for where you are ---------------------------------------------------
BNS.Combat.losProbe = nil
WALL = false
local brain = newBrain()
local npc, player = makeNPC(brain, 0, 0), makePlayer(10, 0)
local ctx = look(npc, brain, player)
assert(ctx.visible, "in the open they see you")
assert(ctx.goX == 10 and ctx.goY == 0, "and head for you")
assert(not ctx.lost and not ctx.stale, "nothing is lost yet")
print("sight OK")

-- 2. Behind a wall: they head for where you *were* ----------------------------------------
-- This is the whole point. The memory does not move when you do.
WALL = true
player.x, player.y = 40, 40 -- you have run off somewhere else entirely
ctx = look(npc, brain, player)
assert(not ctx.visible, "a wall stops them seeing you")
assert(ctx.goX == 10 and ctx.goY == 0,
    "they go where they last saw you, not where you are now, got "
        .. tostring(ctx.goX) .. "," .. tostring(ctx.goY))

-- A moment out of sight is a lamppost, not an escape.
assert(not ctx.lost, "one tick behind cover does not shake them")
while not ctx.lost do ctx = look(npc, brain, player) end
assert(ctx.lost, "but staying out of sight does")
assert(brain.lostFor >= BNS.Senses.GRACE, "after the grace window, got " .. brain.lostFor)
print("memory does not follow you OK (grace " .. BNS.Senses.GRACE .. " ticks)")

-- 3. And it runs out ---------------------------------------------------------------------
while not ctx.stale do ctx = look(npc, brain, player) end
assert(ctx.stale, "eventually the memory is worth nothing")
assert(brain.lostFor > BNS.Senses.MEMORY, "after MEMORY ticks")
print("memory expires OK")

-- 4. Losing you sends them searching, not chasing -----------------------------------------
WALL = false
brain = newBrain()
npc, player = makeNPC(brain, 0, 0), makePlayer(5, 0)
ctx = look(npc, brain, player)
BNS.Programs[BNS.Program.APPROACH](npc, brain, ctx)
assert(brain.program == BNS.Program.APPROACH or brain.program == BNS.Program.ATTACK
    or brain.program == BNS.Program.ROB, "while seen, they close")

WALL = true
player.x = 500 -- long gone
repeat ctx = look(npc, brain, player) until ctx.lost
brain.program = BNS.Program.APPROACH
BNS.Programs[BNS.Program.APPROACH](npc, brain, ctx)
assert(brain.program == BNS.Program.SEARCH,
    "losing sight sends them to search, got " .. tostring(brain.program))
print("losing sight starts a search OK")

-- 5. The search: walk there, look around, give up -----------------------------------------
npc.pathedTo = nil
BNS.Programs[BNS.Program.SEARCH](npc, brain, ctx)
assert(npc.pathedTo, "they walk to the last place they saw you")
assert(math.abs(npc.pathedTo[1] - 5) < 0.001,
    "which is where you were, not where you are, got " .. npc.pathedTo[1])

-- Stand them on it and let them look.
npc.x, npc.y = 5, 0
ctx = look(npc, brain, player)
BNS.Programs[BNS.Program.SEARCH](npc, brain, ctx)
assert(npc.looking == true, "on arrival they look around")
assert(brain.searchLook and brain.searchLook > 0, "for a few seconds")
assert(brain.program == BNS.Program.SEARCH, "still searching while they do")

local ticks = 0
while brain.program == BNS.Program.SEARCH and ticks < 2000 do
    ctx = look(npc, brain, player)
    BNS.Programs[BNS.Program.SEARCH](npc, brain, ctx)
    ticks = ticks + 1
end
assert(brain.program == BNS.Program.WANDER,
    "and then give up and go back to wandering, got " .. tostring(brain.program))
assert(npc.looking == false, "they stop scanning about")
assert(brain.seenX == nil, "and the memory is cleared")
assert(brain.warned == nil, "with the engagement forgotten -- the next one is fresh")
print("search then resume wandering OK")

-- 6. Spotted again mid-search: straight back to it ----------------------------------------
brain = newBrain()
brain.program = BNS.Program.SEARCH
npc = makeNPC(brain, 0, 0)
player = makePlayer(3, 0)
WALL = false
ctx = look(npc, brain, player)
BNS.Programs[BNS.Program.SEARCH](npc, brain, ctx)
assert(brain.program ~= BNS.Program.SEARCH,
    "seeing you again ends the search at once, got " .. tostring(brain.program))
print("re-spotting resumes the chase OK")

-- 7. They chase at a person's run, not a zombie sprint ------------------------------------
BNS.Programs.speedProbe = nil
brain = newBrain()
npc = makeNPC(brain, 0, 0)
BNS.Programs.walkTo(npc, 50, 50, 0, true)
assert(npc.running == true, "a chase is a run")
assert(npc.speed and npc.speed < 1.0,
    "at less than a full sprint, got " .. tostring(npc.speed))
assert(npc.speed == BNS.Programs.runSpeed(), "at the configured chase speed")

-- Walking is not slowed: the knob is about chasing.
BNS.Programs.walkTo(npc, 60, 60, 0, false)
assert(npc.speed == 1.0, "walking is left alone, got " .. tostring(npc.speed))

-- Never zero, whatever the sandbox says: a speed of nothing is an NPC
-- that never moves again.
SandboxVars.BNS.NPCRunSpeed = 0.0
assert(BNS.Programs.runSpeed() >= BNS.Programs.SPEED_FLOOR,
    "a nonsense setting is clamped, got " .. BNS.Programs.runSpeed())
SandboxVars.BNS.NPCRunSpeed = 5.0
assert(BNS.Programs.runSpeed() <= 1.0, "and so is the other end")
SandboxVars.BNS.NPCRunSpeed = nil

-- A build without the setter is written off once, not per order.
BNS.Programs.speedProbe = nil
local calls = 0
local noSpeed = makeNPC(newBrain(), 0, 0)
noSpeed.setSpeedMod = function() calls = calls + 1; error("no such method") end
noSpeed.setPathSpeed = nil
local nb = noSpeed:getModData().BNS
for i = 1, 30 do BNS.Programs.walkTo(noSpeed, 10 * i, 0, 0, true) end
assert(calls == 1, "a throwing speed setter is tried once, got " .. calls)
assert(BNS.Programs.speedProbe == false, "and locked out for the session")
BNS.Programs.speedProbe = nil
print("chase speed OK (" .. BNS.Behaviour.runSpeed .. " of a sprint)")

-- 8. They react to gunshots and other loud noises ------------------------------------------
-- A noise is a *place*, which is what the sight memory already holds, so
-- hearing a shot and losing sight of someone land in the same slot and
-- are answered by the same search.
local function hearer(x, y, program)
    local b = newBrain()
    b.program = program or BNS.Program.WANDER
    local n = makeNPC(b, x, y)
    return n, b
end

WALL = true
local near, nb = hearer(5, 0)
assert(BNS.Senses.hear(near, nb, 0, 0, 0, BNS.Behaviour.gunshotHeard),
    "a shot going off next to them is heard")
assert(nb.program == BNS.Program.SEARCH, "and sends them to look")
assert(nb.seenX == 0 and nb.seenY == 0,
    "at where the noise came from, got " .. tostring(nb.seenX) .. "," .. tostring(nb.seenY))
assert((nb.lostFor or 0) > BNS.Senses.GRACE,
    "aged past the grace window, so it reads as somewhere to check rather "
        .. "than someone they can see")
assert(nb.restUntil == nil, "and it interrupts a rest")

-- The search then behaves exactly as it does for a lost sighting.
local ctx = look(near, nb, makePlayer(900, 900))
assert(ctx.goX == 0 and ctx.goY == 0, "the search heads for the noise")
assert(not ctx.stale, "which is still worth walking to")
print("gunshots are investigated OK")

-- Too far away to hear at all.
local far, fb = hearer(500, 0)
assert(not BNS.Senses.hear(far, fb, 0, 0, 0, BNS.Behaviour.gunshotHeard),
    "a shot on the other side of town is not heard")
assert(fb.program == BNS.Program.WANDER, "and changes nothing")

-- The odds fall off with distance, so a shot brings the street rather
-- than the district, and two bandits at the same range do not move like
-- one animal.
local underfoot, edge = 0, 0
for _ = 1, 600 do
    if BNS.Senses.hears(1, 60) then underfoot = underfoot + 1 end
    if BNS.Senses.hears(59, 60) then edge = edge + 1 end
end
assert(underfoot > edge, "closer is likelier: " .. underfoot .. " vs " .. edge)
assert(edge > 0, "but the edge of a noise is not silent")
assert(underfoot <= 600, "sanity")
print("hearing falls off with distance OK (" .. underfoot .. " vs " .. edge .. " of 600)")

-- Already in a fight: a bang somewhere is not news.
local fighting, fgb = hearer(3, 0, BNS.Program.ATTACK)
assert(not BNS.Senses.hear(fighting, fgb, 0, 0, 0, BNS.Behaviour.gunshotHeard),
    "someone mid-fight does not wander off to investigate")
assert(fgb.program == BNS.Program.ATTACK, "they stay in it")

-- Watching you with their own eyes beats hearing something.
local watching, wb = hearer(3, 0)
WALL = false
look(watching, wb, makePlayer(4, 0))
assert(not BNS.Senses.hear(watching, wb, 0, 0, 0, BNS.Behaviour.gunshotHeard),
    "eyes on you already is better information than a noise")
WALL = true
print("noise is ignored when there is better information OK")

-- 9. Neutrals leave rather than investigate ------------------------------------------------
-- A trader walking towards a firefight is not a person, it is a target.
local trader, tb = hearer(6, 0)
tb.role = BNS.Role.TRADER
assert(BNS.Senses.hear(trader, tb, 0, 0, 0, BNS.Behaviour.gunshotHeard),
    "they hear it too")
assert(tb.program == BNS.Program.FLEE, "and get out, got " .. tostring(tb.program))
assert(tb.fleeFrom and tb.fleeFrom.x == 0, "away from the noise, not towards it")
assert(tb.seenX == nil, "they are not going to go and look at it")
print("neutrals leave, hostiles look OK")

print("ALL TESTS PASSED")
