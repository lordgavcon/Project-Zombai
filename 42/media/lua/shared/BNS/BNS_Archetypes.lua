--***********************************************************************
-- Bandits & Survivors — environment-themed bandit archetypes
--
-- Bandit groups match their surroundings: farm country breeds farmers
-- with wood axes, pitchforks and shotguns; towns produce city folk,
-- street thugs, rogue police and firefighters; military sites spawn
-- ex-military squads. Selection is *weighted by proximity*, never
-- locked: every archetype keeps a baseline weight everywhere, and the
-- environment (map zone type + distance to military sites) boosts the
-- locals. Each archetype maps onto a behaviour tier, so farmers and
-- city folk still rob, police/firefighters fight like thugs, and
-- ex-military act as raid-capable militia.
--***********************************************************************

require "BNS/BNS_Core"
require "BNS/BNS_Loadouts"
require "BNS/BNS_POIs"

BNS.Archetypes = {}

-- gunChance "sandbox" means: use the Militia firearm chance option.
BNS.Archetypes.Defs = {
    farmer = {
        tier = BNS.Tier.CIVILIAN,
        outfits = { "Farmer", "Ranger", "Redneck" },
        melee = {
            { item = "Base.WoodAxe",    dmg = 0.20, range = 1.3 },
            { item = "Base.GardenFork", dmg = 0.16, range = 1.5 },
            { item = "Base.Shovel",     dmg = 0.12, range = 1.4 },
            { item = "Base.Machete",    dmg = 0.22, range = 1.3 },
        },
        guns = {
            { item = "Base.DoubleBarrelShotgun", dmg = 0.50, range = 6, sound = "ShotgunShot", hit = 55 },
            { item = "Base.Shotgun",             dmg = 0.50, range = 7, sound = "ShotgunShot", hit = 50 },
        },
        gunChance = 30,
        warn = "UI_BNS_WarnFarmer",
    },
    cityfolk = {
        tier = BNS.Tier.CIVILIAN,
        outfits = { "Generic01", "Generic02", "Generic03", "OfficeWorker", "Shopper", "Mechanic" },
        melee = BNS.Loadouts.Melee[BNS.Tier.CIVILIAN],
        guns = {
            { item = "Base.Pistol", dmg = 0.30, range = 10, sound = "9mmShot", hit = 30 },
        },
        gunChance = 10,
    },
    thug = {
        tier = BNS.Tier.THUG,
        outfits = { "Biker", "Punk", "Redneck" },
        melee = BNS.Loadouts.Melee[BNS.Tier.THUG],
        guns = BNS.Loadouts.Guns[BNS.Tier.THUG],
        gunChance = 15,
    },
    police = {
        tier = BNS.Tier.THUG,
        outfits = { "Police", "PoliceState", "PrisonGuard" },
        melee = {
            { item = "Base.Nightstick", dmg = 0.14, range = 1.2 },
            { item = "Base.BaseballBat", dmg = 0.16, range = 1.4 },
        },
        guns = {
            { item = "Base.Pistol",  dmg = 0.30, range = 10, sound = "9mmShot",     hit = 50 },
            { item = "Base.Shotgun", dmg = 0.55, range = 7,  sound = "ShotgunShot", hit = 60 },
        },
        gunChance = 70,
        warn = "UI_BNS_WarnPolice",
    },
    firefighter = {
        tier = BNS.Tier.THUG,
        outfits = { "Fireman" },
        melee = {
            { item = "Base.Axe",     dmg = 0.26, range = 1.3 },
            { item = "Base.Crowbar", dmg = 0.16, range = 1.3 },
            { item = "Base.Sledgehammer", dmg = 0.30, range = 1.4 },
        },
        guns = nil,
        gunChance = 0,
    },
    exmilitary = {
        tier = BNS.Tier.MILITIA,
        outfits = { "ArmyCamoGreen", "ArmyCamoDesert", "Camo", "Ghillie" },
        melee = {
            { item = "Base.Machete",      dmg = 0.24, range = 1.3 },
            { item = "Base.HuntingKnife", dmg = 0.20, range = 1.1 },
        },
        guns = BNS.Loadouts.Guns[BNS.Tier.MILITIA],
        gunChance = "sandbox",
        warn = "UI_BNS_WarnMilitia",
    },
}

-- Environment weighting ---------------------------------------------------

local function zoneTypeAt(x, y)
    local ok, zone = pcall(function()
        return getWorld():getMetaGrid():getZoneAt(math.floor(x), math.floor(y), 0)
    end)
    if ok and zone and zone.getType then return zone:getType() end
    return nil
end

local RURAL_ZONES = { Farm = true, FarmLand = true }
local TOWN_ZONES  = { TownZone = true, TrailerPark = true }
local WILD_ZONES  = { Forest = true, DeepForest = true, Vegitation = true }

-- Weights at a world position. Baselines keep every archetype possible
-- everywhere; the local environment boosts its natives.
function BNS.Archetypes.weightsAt(x, y)
    local w = {
        farmer = 10, cityfolk = 10, thug = 8,
        police = 5, firefighter = 4, exmilitary = 4,
    }

    local zt = zoneTypeAt(x, y)
    if zt and RURAL_ZONES[zt] then
        w.farmer = w.farmer + 70
    elseif zt and TOWN_ZONES[zt] then
        w.cityfolk = w.cityfolk + 40
        w.thug = w.thug + 25
        w.police = w.police + 25
        w.firefighter = w.firefighter + 15
    elseif zt and WILD_ZONES[zt] then
        w.farmer = w.farmer + 30
        w.exmilitary = w.exmilitary + 10
    end

    -- Military sites pull ex-military squads, fading linearly with
    -- distance out to the site's radius.
    for _, m in ipairs(BNS.MilitaryZones or {}) do
        local d = BNS.dist(x, y, m.x, m.y)
        if d < m.radius then
            w.exmilitary = w.exmilitary + math.floor(90 * (1 - d / m.radius))
        end
    end

    if not BNS.Options().militia then w.exmilitary = 0 end
    return w
end

-- Weighted archetype roll at a position. Optional tier filter restricts
-- candidates (used when a raid or garrison needs a specific tier).
function BNS.Archetypes.roll(x, y, tier)
    local weights = BNS.Archetypes.weightsAt(x, y)
    local total = 0
    for name, weight in pairs(weights) do
        local def = BNS.Archetypes.Defs[name]
        if def and (not tier or def.tier == tier) then
            total = total + weight
        else
            weights[name] = 0
        end
    end
    if total <= 0 then
        return tier == BNS.Tier.MILITIA and "exmilitary"
            or tier == BNS.Tier.THUG and "thug" or "cityfolk"
    end
    local pick = ZombRand(total)
    for name, weight in pairs(weights) do
        if weight > 0 then
            if pick < weight then return name end
            pick = pick - weight
        end
    end
    return "cityfolk"
end

function BNS.Archetypes.get(name)
    return name and BNS.Archetypes.Defs[name] or nil
end
