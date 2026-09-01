-- Offline test of BNS_Doors + BNS_Locks with stubbed PZ APIs.
math.randomseed(11)

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

function ZombRand(a, b) if b then return math.random(a, b - 1) end return math.random(0, a - 1) end
function instanceof(obj, cls) return type(obj) == "table" and obj.__iso == cls end
function isServer() return false end
function isClient() return false end
function getNumActivePlayers() return 0 end
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
function getText(k) return k end
function getWorld() return { getMetaGrid = function() return { getZoneAt = function() return nil end } end } end
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
Faction = {
    getPlayerFaction = function(p)
        if p.faction then return { getName = function() return p.faction end } end
        return nil
    end,
}

local worldSounds = {}
function addSound(_, x, y, z, radius, vol) table.insert(worldSounds, { radius = radius, vol = vol }) end

-- Grid of fake squares --------------------------------------------------
local grid = {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function square(x, y, z)
    local k = key(x, y, z)
    if not grid[k] then
        local sq = { x = x, y = y, z = z, objects = {} }
        function sq:getX() return self.x end
        function sq:getY() return self.y end
        function sq:getZ() return self.z end
        function sq:getObjects()
            return { size = function() return #sq.objects end, get = function(_, i) return sq.objects[i + 1] end }
        end
        function sq:transmitRemoveItemFromSquare(obj) end
        function sq:RemoveTileObject(obj)
            for i, o in ipairs(sq.objects) do if o == obj then table.remove(sq.objects, i) end end
        end
        grid[k] = sq
    end
    return grid[k]
end

function getCell()
    return {
        getGridSquare = function(_, x, y, z) return square(x, y, z) end,
        getZombieList = function() return { size = function() return 0 end, get = function() end } end,
    }
end

local function makeDoor(x, y, z, hp)
    local d = { __iso = "IsoDoor", open = false, locked = false, modData = {}, sounds = {}, toggles = 0, destroyed = false }
    if hp then
        d.hp = hp
        function d:getHealth() return self.hp end
        function d:setHealth(v) self.hp = v end
        function d:getMaxHealth() return hp end
    end
    function d:IsOpen() return self.open end
    function d:ToggleDoor(chr) self.toggles = self.toggles + 1; self.open = not self.open end
    function d:getModData() return self.modData end
    function d:getSquare() return square(x, y, z) end
    function d:isLocked() return self.locked end
    function d:setLocked(v) self.locked = v end
    function d:isLockedByKey() return self.lockedKey or false end
    function d:setLockedByKey(v) self.lockedKey = v end
    function d:isBarricaded() return false end
    function d:destroy()
        self.destroyed = true
        square(x, y, z):RemoveTileObject(d)
    end
    function d:transmitModData() end
    table.insert(square(x, y, z).objects, d)
    return d
end

local function makeNPC(x, y, tier, program)
    local z = { __iso = "IsoZombie", x = x, y = y, sounds = {}, vars = {},
        modData = { BNS = { id = "b1", role = "bandit", tier = tier, program = program } } }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:getModData() return self.modData end
    function z:playSound(s) table.insert(self.sounds, s) end
    function z:setVariable(k, v) self.vars[k] = v end
    function z:isDead() return false end
    return z
end

local function makePlayer(name, faction, hasPadlock)
    local p = { name = name, faction = faction, items = {}, x = 10, y = 10 }
    if hasPadlock then p.items["CombinationPadlock"] = { fullType = "Base.CombinationPadlock" } end
    function p:getUsername() return self.name end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getInventory()
        return {
            getFirstTypeRecurse = function(_, t) return p.items[t] end,
            containsTypeRecurse = function(_, t) return p.items[t] ~= nil end,
            Remove = function(_, item)
                for k, v in pairs(p.items) do if v == item then p.items[k] = nil end end
            end,
            AddItem = function(_, full) p.items[full:gsub("^Base%.", "")] = { fullType = full } end,
        }
    end
    return p
end

require("BNS/BNS_Core")
require("BNS/BNS_Loadouts")
require("BNS/BNS_POIs")
require("BNS/BNS_Archetypes")
require("BNS/BNS_Anim")
require("BNS/BNS_Locks")
require("BNS/BNS_Doors")

local function countSounds(list, name)
    local n = 0
    for _, s in ipairs(list) do if s == name then n = n + 1 end end
    return n
end

-- 1. Unlocked door: delay + rattle noise, then open ---------------------
local door = makeDoor(11, 10, 0)
local npc = makeNPC(10, 10, BNS.Tier.THUG, BNS.Program.APPROACH)
local brain = npc:getModData().BNS
assert(BNS.Doors.tryStart(npc, brain), "door attempt should start")
assert(brain.door and not brain.door.bash and brain.door.timer == 180, "3s open timer set")
local ticks = 0
while brain.door and ticks < 1000 do
    BNS.Doors.tick(npc, brain)
    ticks = ticks + 1
end
assert(ticks == 180, "opened after exactly the delay, got " .. ticks)
assert(door.open and door.toggles == 1, "door toggled open once")
local rattles = countSounds(npc.sounds, "ZombieThumpGeneric")
assert(rattles == 3, "one rattle per second during 3s delay, got " .. rattles)
assert(#worldSounds >= 3, "rattles registered as world sounds for players/zombies")
print("unlocked door: delay + rattle + open OK (" .. rattles .. " rattles)")

-- 2. Locked door, wandering bandit: gives up ----------------------------
local lockedDoor = makeDoor(21, 20, 0)
lockedDoor.modData.BNS_Lock = { owner = "Alice", faction = "Wolves" }
local wanderer = makeNPC(20, 20, BNS.Tier.THUG, BNS.Program.WANDER)
local wb = wanderer:getModData().BNS
wb.program = BNS.Program.WANDER
wb.targetX, wb.targetY = 100, 100
assert(not BNS.Doors.tryStart(wanderer, wb), "wanderer gives up on locked door")
assert(wb.door == nil and wb.targetX == nil, "wanderer repaths instead")
print("locked door vs wanderer OK")

-- 3. Locked door, pursuing militia: damage-based break-in ---------------
-- Helper: run a full bash attempt, return bash count (or nil if door survived).
local function bashItDown(npc2, brain2, doorObj, maxTicks)
    assert(BNS.Doors.tryStart(npc2, brain2), "pursuer starts bashing")
    assert(brain2.door and brain2.door.bash, "bash mode engaged")
    local t = 0
    while brain2.door and t < (maxTicks or 20000) do
        BNS.Doors.tick(npc2, brain2)
        t = t + 1
    end
    return countSounds(npc2.sounds, "ZombieThumpGeneric"), t
end

worldSounds = {}
local raider = makeNPC(20, 20, BNS.Tier.MILITIA, BNS.Program.RAID)
local rb = raider:getModData().BNS
rb.program = BNS.Program.RAID
local bashes = bashItDown(raider, rb, lockedDoor)
assert(lockedDoor.destroyed, "door broken down")
assert(lockedDoor.modData.BNS_Lock == nil, "lock destroyed with the door")
-- Default 300 HP door, 60 dmg/bash unarmed militia = 5 bashes.
assert(bashes == 5, "militia: 300HP door / 60dmg = 5 bashes, got " .. bashes)
assert(countSounds(raider.sounds, "WoodDoorBreak") == 1, "break sound played")
local loud = 0
for _, s in ipairs(worldSounds) do if s.radius >= 25 then loud = loud + 1 end end
assert(loud >= 5, "every bash is street-loud")
print("locked door vs militia raider OK (" .. bashes .. " bashes)")

-- 3b. Stronger doors take much longer -----------------------------------
local metalDoor = makeDoor(41, 40, 0, 1500)
metalDoor.modData.BNS_Lock = { owner = "Alice" }
local raider2 = makeNPC(40, 40, BNS.Tier.MILITIA, BNS.Program.RAID)
local rb2 = raider2:getModData().BNS
rb2.program = BNS.Program.RAID
local metalBashes = bashItDown(raider2, rb2, metalDoor)
assert(metalDoor.destroyed, "metal door eventually falls")
assert(metalBashes == 25, "1500HP door / 60dmg = 25 bashes, got " .. metalBashes)
print("strong door OK (" .. metalBashes .. " bashes, 5x a plain door)")

-- 3c. Axe bonus -----------------------------------------------------------
local woodDoor2 = makeDoor(51, 50, 0, 300)
woodDoor2.modData.BNS_Lock = { owner = "Alice" }
local chopper = makeNPC(50, 50, BNS.Tier.MILITIA, BNS.Program.RAID)
local cb = chopper:getModData().BNS
cb.program = BNS.Program.RAID
cb.weapon = { item = "Base.WoodAxe", dmg = 0.2, range = 1.3, gun = false }
local axeBashes = bashItDown(chopper, cb, woodDoor2)
assert(woodDoor2.destroyed and axeBashes == 4, "axe: 300/90 = 4 bashes, got " .. axeBashes)
print("axe breaching bonus OK (" .. axeBashes .. " bashes)")

-- 3d. Partial damage persists (virtual-pool door) -------------------------
local plainDoor = makeDoor(61, 60, 0) -- no health API -> mod data pool
plainDoor.modData.BNS_Lock = { owner = "Alice" }
local b1 = makeNPC(60, 60, BNS.Tier.CIVILIAN, BNS.Program.ATTACK):getModData().BNS
b1.program = BNS.Program.ATTACK
local n1a = makeNPC(60, 60, BNS.Tier.CIVILIAN, BNS.Program.ATTACK)
b1 = n1a:getModData().BNS
b1.program = BNS.Program.ATTACK
assert(BNS.Doors.tryStart(n1a, b1))
for _ = 1, 90 * 3 + 3 do BNS.Doors.tick(n1a, b1) end -- ~3 bashes then interrupted
BNS.Doors.abort(b1)
assert(plainDoor.modData.BNS_DoorHP and plainDoor.modData.BNS_DoorHP < 300,
    "partial damage recorded in mod data")
local hpLeft = plainDoor.modData.BNS_DoorHP
local n1b = makeNPC(60, 60, BNS.Tier.CIVILIAN, BNS.Program.ATTACK)
local b1b = n1b:getModData().BNS
b1b.program = BNS.Program.ATTACK
local resumeBashes = bashItDown(n1b, b1b, plainDoor)
assert(plainDoor.destroyed, "second attempt finishes the weakened door")
assert(resumeBashes == math.ceil(hpLeft / 25), "resume needs only remaining HP worth of bashes")
print("partial door damage persists OK (" .. hpLeft .. " HP left, " .. resumeBashes .. " to finish)")

-- 3e. Leaving pursuit stops the bashing -----------------------------------
local d5 = makeDoor(71, 70, 0, 100000)
d5.modData.BNS_Lock = { owner = "Alice" }
local quitter = makeNPC(70, 70, BNS.Tier.THUG, BNS.Program.ATTACK)
local qb = quitter:getModData().BNS
qb.program = BNS.Program.ATTACK
assert(BNS.Doors.tryStart(quitter, qb))
for _ = 1, 100 do BNS.Doors.tick(quitter, qb) end
qb.program = BNS.Program.WANDER -- target lost
BNS.Doors.tick(quitter, qb)
assert(qb.door == nil and not d5.destroyed, "bashing stops when pursuit ends")
print("pursuit-exit abort OK")

-- 3f. Unbreachable door: give up after the cap ----------------------------
local vault = makeDoor(81, 80, 0, 100000)
vault.modData.BNS_Lock = { owner = "Alice" }
local stubborn = makeNPC(80, 80, BNS.Tier.MILITIA, BNS.Program.RAID)
local sb = stubborn:getModData().BNS
sb.program = BNS.Program.RAID
local capBashes = bashItDown(stubborn, sb, vault)
assert(not vault.destroyed, "vault door survives")
assert(capBashes == 60, "gives up after 60 bashes, got " .. capBashes)
assert(sb.door == nil, "bandit walked away")
print("give-up cap OK (" .. capBashes .. " bashes then quit)")

-- 4. Locks: attach / access / quick entry / remove ----------------------
local homeDoor = makeDoor(10, 11, 0)
local alice = makePlayer("Alice", "Wolves", true)
BNS.Locks.attachLock(alice, { x = 10, y = 11, z = 0 })
local lock = BNS.Locks.get(homeDoor)
assert(lock and lock.owner == "Alice" and lock.faction == "Wolves", "lock attached with owner+clan")
assert(alice.items["CombinationPadlock"] == nil, "padlock consumed")
assert(homeDoor.locked and homeDoor.lockedKey, "engine lock flags set")

local bob = makePlayer("Bob", "Wolves", false)      -- clanmate
local eve = makePlayer("Eve", "Raiders", false)     -- outsider
assert(BNS.Locks.canUse(alice, lock), "owner can use")
assert(BNS.Locks.canUse(bob, lock), "clanmate can use")
assert(not BNS.Locks.canUse(eve, lock), "outsider cannot use")

BNS.Locks.useLock(bob, { x = 10, y = 11, z = 0 })
assert(homeDoor.open, "clanmate quick entry opens the door")
assert(homeDoor.locked, "lock stays engaged after quick entry")
homeDoor.open = false
BNS.Locks.useLock(eve, { x = 10, y = 11, z = 0 })
assert(not homeDoor.open, "outsider refused")

BNS.Locks.removeLock(eve, { x = 10, y = 11, z = 0 })
assert(BNS.Locks.get(homeDoor), "outsider cannot remove the lock")
BNS.Locks.removeLock(bob, { x = 10, y = 11, z = 0 })
assert(BNS.Locks.get(homeDoor) == nil and not homeDoor.locked, "clanmate removed lock")
assert(bob.items["CombinationPadlock"], "padlock returned on removal")
print("combination lock attach/access/remove OK")

-- 5. Abort clears state --------------------------------------------------
local d2 = makeDoor(31, 30, 0)
local n2 = makeNPC(30, 30, BNS.Tier.CIVILIAN, BNS.Program.APPROACH)
local b2 = n2:getModData().BNS
b2.program = BNS.Program.APPROACH
assert(BNS.Doors.tryStart(n2, b2))
BNS.Doors.abort(b2)
assert(b2.door == nil, "abort clears door state")
assert(not d2.open, "aborted door stays shut")
print("abort OK")

print("ALL TESTS PASSED")
