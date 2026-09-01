-- Offline test of BNS_Archetypes weighting/rolling with stubbed PZ APIs.
math.randomseed(42)

-- PZ global stubs ------------------------------------------------------
local loaded = {}
local ROOT = arg[1]
function require(name)
    if loaded[name] then return end
    loaded[name] = true
    local paths = { ROOT .. "/shared/" .. name .. ".lua", ROOT .. "/server/" .. name .. ".lua" }
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then f:close(); dofile(p); return end
    end
    error("require not found: " .. name)
end
function ZombRand(a, b)
    if b then return math.random(a, b - 1) end
    return math.random(0, a - 1)
end
function ZombRandFloat(a, b) return a + math.random() * (b - a) end
function instanceof() return false end
function isServer() return false end
function isClient() return false end
function getNumActivePlayers() return 0 end
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
SandboxVars = { BNS = {} }

-- Zone stub: rural quadrant, town quadrant, else nil
local currentZone = nil
function getWorld()
    return { getMetaGrid = function()
        return { getZoneAt = function(_, x, y, z)
            if not currentZone then return nil end
            return { getType = function() return currentZone end }
        end }
    end }
end

require("BNS/BNS_Core")
require("BNS/BNS_Loadouts")
require("BNS/BNS_POIs")
require("BNS/BNS_Archetypes")

local function tally(x, y, zone, tier, n)
    currentZone = zone
    local counts = {}
    for _ = 1, n do
        local a = BNS.Archetypes.roll(x, y, tier)
        counts[a] = (counts[a] or 0) + 1
    end
    return counts
end

local function show(label, counts)
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    print(label .. ": " .. table.concat(parts, " "))
end

local N = 5000
show("Farm zone            ", tally(8000, 11000, "Farm", nil, N))
show("Town zone            ", tally(8069, 11753, "TownZone", nil, N))
show("Forest zone          ", tally(7000, 9000, "Forest", nil, N))
show("No zone (open)       ", tally(9000, 9000, nil, nil, N))
show("At military base     ", tally(4432, 10786, nil, nil, N))
show("Edge of military rad ", tally(4432 + 550, 10786, nil, nil, N))
show("Militia-tier @ mil   ", tally(4432, 10786, nil, BNS.Tier.MILITIA, N))
show("Thug-tier in town    ", tally(8069, 11753, "TownZone", BNS.Tier.THUG, N))
show("Civ-tier on farm     ", tally(8000, 11000, "Farm", BNS.Tier.CIVILIAN, N))

-- Militia disabled: exmilitary must vanish even at the base.
SandboxVars.BNS.MilitiaEnabled = false
local c = tally(4432, 10786, nil, nil, N)
assert(not c.exmilitary, "exmilitary should not spawn with militia disabled")
show("Militia OFF @ base   ", c)
-- Militia-tier request with militia off must still return a valid fallback.
local fb = BNS.Archetypes.roll(4432, 10786, BNS.Tier.MILITIA)
assert(fb == "exmilitary", "tier fallback should be exmilitary, got " .. tostring(fb))
print("fallback (militia off, MILITIA tier): " .. fb)

-- Weapon-table sanity: every archetype rolls valid weapons.
SandboxVars.BNS.MilitiaEnabled = true
for name, def in pairs(BNS.Archetypes.Defs) do
    assert(def.melee and #def.melee > 0, name .. " has no melee pool")
    for _, m in ipairs(def.melee) do assert(m.item and m.dmg and m.range, name .. " bad melee entry") end
    if def.guns then
        for _, g in ipairs(def.guns) do assert(g.item and g.dmg and g.range and g.sound and g.hit, name .. " bad gun entry") end
    end
    assert(def.outfits and #def.outfits > 0, name .. " has no outfits")
end
print("archetype defs OK")
print("ALL TESTS PASSED")
