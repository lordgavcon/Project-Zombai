-- Offline test of BNS_Vehicles with stubbed PZ APIs.
math.randomseed(31)

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
function ZombRandFloat(a, b) return a + math.random() * (b - a) end
function instanceof(obj, cls) return type(obj) == "table" and obj.__iso == cls end
function isServer() return false end
function isClient() return false end
function getNumActivePlayers() return 0 end
function getText(k) return k end
function addSound() end
function getWorld() return { getMetaGrid = function() return { getZoneAt = function() return nil end } end } end
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
IsoDirections = { S = "S" }

-- World stubs -----------------------------------------------------------
local grid = {}
local vehicles = {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function square(x, y, z)
    local k = key(x, y, z)
    if not grid[k] then
        local sq = { x = x, y = y, z = z, objects = {}, floor = {}, modData = {} }
        function sq:getX() return self.x end
        function sq:getY() return self.y end
        function sq:getZ() return self.z end
        function sq:getModData() return self.modData end
        function sq:getObjects()
            return { size = function() return #sq.objects end, get = function(_, i) return sq.objects[i + 1] end }
        end
        function sq:AddWorldInventoryItem(fullType) table.insert(sq.floor, fullType) end
        grid[k] = sq
    end
    return grid[k]
end
function getCell()
    return {
        getGridSquare = function(_, x, y, z) return square(x, y, z) end,
        getZombieList = function() return { size = function() return 0 end, get = function() end } end,
        getVehicles = function() return { size = function() return #vehicles end, get = function(_, i) return vehicles[i + 1] end } end,
    }
end

local function makeVehicle(x, y, opts)
    opts = opts or {}
    local v = { x = x, y = y, modData = {}, trunkItems = {}, removed = false,
        engineWorks = opts.engineWorks ~= false, hasTrunk = opts.hasTrunk ~= false }
    function v:getX() return self.x end
    function v:getY() return self.y end
    function v:getModData() return self.modData end
    function v:getScriptName() return opts.script or "Base.CarNormal" end
    function v:isEngineWorking() return self.engineWorks end
    function v:permanentlyRemove()
        self.removed = true
        for i, o in ipairs(vehicles) do if o == v then table.remove(vehicles, i) end end
    end
    if v.hasTrunk then
        local trunk = {
            getItems = function()
                return {
                    size = function() return #v.trunkItems end,
                    get = function(_, i)
                        local ft = v.trunkItems[i + 1]
                        return { getFullType = function() return ft end }
                    end,
                }
            end,
            AddItem = function(_, ft) table.insert(v.trunkItems, ft) end,
        }
        function v:getPartById(id)
            if id == "TruckBed" then return { getItemContainer = function() return trunk end } end
            return nil
        end
    else
        function v:getPartById() return nil end
    end
    table.insert(vehicles, v)
    return v
end

local spawnedScripts = {}
function addVehicleDebug(script, dir, unused, sq)
    table.insert(spawnedScripts, script)
    return makeVehicle(sq:getX(), sq:getY(), { script = script })
end

local function makeNPC(x, y, id, squad)
    local z = { __iso = "IsoZombie", x = x, y = y, sounds = {}, vars = {},
        modData = { BNS = { id = id or "v1", role = "bandit", tier = 2, program = "wander", squad = squad } } }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:getModData() return self.modData end
    function z:playSound(s) table.insert(self.sounds, s) end
    function z:setVariable() end
    function z:isDead() return false end
    function z:getCurrentSquare() return square(math.floor(self.x), math.floor(self.y), 0) end
    function z:setRunning() end
    return z
end

require("BNS/BNS_Core")
require("BNS/BNS_Loadouts")
require("BNS/BNS_POIs")
require("BNS/BNS_Archetypes")
require("BNS/BNS_Persistence")
require("BNS/BNS_Anim")
require("BNS/BNS_Combat")
require("BNS/BNS_Programs")
require("BNS/BNS_Scavenge")
require("BNS/BNS_Vehicles")

-- 1. Claiming rules -------------------------------------------------------
local npc = makeNPC(10, 10, "n1")
local brain = npc:getModData().BNS
local wreck = makeVehicle(12, 10, { engineWorks = false })
local owned = makeVehicle(14, 10); owned.modData.BNS_Owner = "someone"
local good = makeVehicle(16, 10)
assert(BNS.Vehicles.tryClaim(npc, brain), "claims the working unowned vehicle")
assert(good.modData.BNS_Owner == "n1", "ownership marked on the vehicle")
assert(brain.vehicle and brain.vehicle.x == 16, "brain records the vehicle")
assert(wreck.modData.BNS_Owner == nil and owned.modData.BNS_Owner == "someone",
    "wrecks and owned vehicles untouched")

-- near a player base: never claimed
local state = BNS.Persistence.getState()
state.playerBases["pb"] = { x = 500, y = 500, hits = 999, lastRaid = 0 }
local npcB = makeNPC(510, 500, "n2")
makeVehicle(505, 500)
assert(not BNS.Vehicles.tryClaim(npcB, npcB:getModData().BNS), "base driveway vehicles are safe")

-- sandbox off: no claiming
SandboxVars.BNS.NPCVehiclesEnabled = false
local npcC = makeNPC(16, 12, "n3")
assert(not BNS.Vehicles.tryClaim(npcC, npcC:getModData().BNS), "toggle disables claiming")
SandboxVars.BNS.NPCVehiclesEnabled = true
print("claiming rules OK")

-- 2. Haul: full pack -> HAUL -> trunk -------------------------------------
brain.loot = {}
for i = 1, BNS.Scavenge.PACK_CAP do brain.loot[i] = "Base.TinnedBeans" end
assert(BNS.Vehicles.wantsHaul(npc, brain), "full pack triggers hauling")
assert(brain.program == BNS.Program.HAUL, "program is HAUL")
-- far away: walks toward the vehicle
BNS.Programs[BNS.Program.HAUL](npc, brain, { dist = 999 })
assert(#brain.loot == BNS.Scavenge.PACK_CAP, "nothing stowed while walking")
-- at the vehicle: stows the pack
npc.x, npc.y = 16, 10
BNS.Programs[BNS.Program.HAUL](npc, brain, { dist = 999 })
assert(#brain.loot == 0, "pack emptied")
assert(#good.trunkItems == BNS.Scavenge.PACK_CAP, "trunk holds the haul")
assert(brain.program == BNS.Program.WANDER, "back to wandering")
print("haul to trunk OK")

-- 2b. postHaul is honoured -------------------------------------------------
brain.loot = { "Base.Axe" }
brain.program = BNS.Program.HAUL
brain.postHaul = BNS.Program.FLEE
BNS.Programs[BNS.Program.HAUL](npc, brain, { dist = 999 })
assert(brain.program == BNS.Program.FLEE and brain.postHaul == nil, "postHaul respected")
print("postHaul OK")

-- 3. Trunk cap: overflow stays in the pack ---------------------------------
for i = 1, 40 - #good.trunkItems do table.insert(good.trunkItems, "Base.Plank") end
brain.loot = { "Base.Antibiotics", "Base.Antibiotics" }
BNS.Vehicles.stow(npc, brain, good)
assert(#brain.loot == 2, "full trunk keeps items in the pack")
print("trunk cap OK")

-- 4. No-trunk fallback: pile beside the vehicle -----------------------------
local flatbedless = makeVehicle(30, 30, { hasTrunk = false })
local npc4 = makeNPC(30, 30, "n4")
local b4 = npc4:getModData().BNS
b4.loot = { "Base.Shovel" }
BNS.Vehicles.stow(npc4, b4, flatbedless)
assert(#b4.loot == 0 and square(30, 30, 0).floor[1] == "Base.Shovel", "fallback pile works")
print("no-trunk fallback OK")

-- 5. Virtual travel speed ---------------------------------------------------
local recWalk = { x = 0, y = 0, targetX = 1000, targetY = 0 }
BNS.Persistence.virtualStep(recWalk)
assert(math.abs(recWalk.x - 60) < 0.01, "on foot: 60 tiles/tick")
local recDrive = { x = 0, y = 0, targetX = 1000, targetY = 0,
    vehicle = { x = 0, y = 0, script = "Base.CarNormal" }, aboard = true }
BNS.Persistence.virtualStep(recDrive)
assert(math.abs(recDrive.x - 300) < 0.01, "driving: 300 tiles/tick")
assert(recDrive.vehicle.x == 300, "vehicle rides along")
print("virtual travel speed OK")

-- 6/7. Dematerialise/materialise round-trip ---------------------------------
local traveller = makeNPC(50, 50, "n5")
local tb = traveller:getModData().BNS
local car = makeVehicle(51, 50, { script = "Base.PickUpTruck" })
car.modData.BNS_Owner = "n5"
car.trunkItems = { "Base.Antibiotics", "Base.Shotgun" }
tb.vehicle = { x = 51, y = 50, script = "Base.PickUpTruck" }
local rec = { id = "n5", x = 50, y = 50 }
BNS.Vehicles.onDematerialise(traveller, tb, rec)
assert(rec.aboard == true, "adjacent NPC boards")
assert(car.removed, "vehicle leaves the world with them")
assert(#rec.trunk == 2 and rec.trunk[1] == "Base.Antibiotics", "trunk mirrored into the record")

rec.x, rec.y = 800, 800
local traveller2 = makeNPC(800, 800, "n5")
local tb2 = traveller2:getModData().BNS
spawnedScripts = {}
BNS.Vehicles.onMaterialise(traveller2, tb2, rec)
assert(spawnedScripts[1] == "Base.PickUpTruck", "vehicle respawned where they surface")
local newCar = BNS.Vehicles.findOwned(tb2, 800, 800, 10)
assert(newCar and #newCar.trunkItems == 2, "trunk contents survive the trip")
assert(rec.trunk == nil, "record trunk cleared after refill")

-- not adjacent: vehicle stays parked
local walker = makeNPC(100, 100, "n6")
local wbrain = walker:getModData().BNS
local parked = makeVehicle(130, 100)
parked.modData.BNS_Owner = "n6"
wbrain.vehicle = { x = 130, y = 100, script = "Base.CarNormal" }
local wrec = { id = "n6", x = 100, y = 100 }
BNS.Vehicles.onDematerialise(walker, wbrain, wrec)
assert(wrec.aboard == false and not parked.removed, "distant vehicle stays parked")
print("board/park round-trip OK")

-- 8. Raid convoy -------------------------------------------------------------
require("BNS/BNS_Spawner")
require("BNS/BNS_Raids")
spawnedScripts = {}
local realZombRand = ZombRand
ZombRand = function(a, b) if b then return a end return 0 end -- forces convoy roll
BNS.Raids.launchRaid({ x = 2000, y = 2000, hits = 999, lastRaid = 0 })
ZombRand = realZombRand
assert(spawnedScripts[1] == "Base.PickUpTruck", "raid brings a truck")
local convoyMembers = 0
for _, r in pairs(BNS.Persistence.getState().npcs) do
    if r.raid and r.vehicle and r.vehicle.script == "Base.PickUpTruck" then
        convoyMembers = convoyMembers + 1
    end
end
assert(convoyMembers >= 2, "squad members share the convoy, got " .. convoyMembers)
print("raid convoy OK")

print("ALL TESTS PASSED")
