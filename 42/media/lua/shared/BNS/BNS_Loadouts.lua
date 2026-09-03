--***********************************************************************
-- Bandits & Survivors — loadouts, outfits, names and barter values
--***********************************************************************

require "BNS/BNS_Core"

BNS.Loadouts = {}

-- Outfit names are vanilla zombie outfits so no custom assets are needed.
BNS.Loadouts.Outfits = {
    [BNS.Tier.CIVILIAN] = { "Generic01", "Generic02", "Generic03", "Farmer", "Mechanic" },
    [BNS.Tier.THUG]     = { "Biker", "Punk", "Redneck", "PrisonGuard" },
    [BNS.Tier.MILITIA]  = { "Camo", "ArmyCamoGreen", "ArmyCamoDesert", "Hunter" },
    survivor            = { "Generic01", "Generic04", "Backpacker", "Camper" },
    trader              = { "Trader", "Generic02", "Backpacker" },
}

-- Weapons carried and used. dmg is per landed hit against a player
-- (scaled by the sandbox damage multiplier), range in tiles.
BNS.Loadouts.Melee = {
    [BNS.Tier.CIVILIAN] = {
        { item = "Base.Plank",           dmg = 0.10, range = 1.3 },
        { item = "Base.RollingPin",      dmg = 0.08, range = 1.2 },
        { item = "Base.PipeWrench",      dmg = 0.12, range = 1.2 },
        { item = "Base.KitchenKnife",    dmg = 0.12, range = 1.1 },
        { item = "Base.BaseballBat",     dmg = 0.14, range = 1.4 },
    },
    [BNS.Tier.THUG] = {
        { item = "Base.BaseballBat",     dmg = 0.16, range = 1.4 },
        { item = "Base.Crowbar",         dmg = 0.16, range = 1.3 },
        { item = "Base.Machete",         dmg = 0.22, range = 1.3 },
        { item = "Base.Axe",             dmg = 0.24, range = 1.3 },
    },
    [BNS.Tier.MILITIA] = {
        { item = "Base.Machete",         dmg = 0.24, range = 1.3 },
        { item = "Base.Axe",             dmg = 0.26, range = 1.3 },
    },
}

-- Firearms are simulated (sound + hit roll + damage) — see BNS_Combat.
BNS.Loadouts.Guns = {
    [BNS.Tier.THUG] = {
        { item = "Base.Pistol",          dmg = 0.30, range = 10, sound = "9mmShot",     hit = 35 },
    },
    [BNS.Tier.MILITIA] = {
        { item = "Base.Pistol",          dmg = 0.30, range = 10, sound = "9mmShot",     hit = 45 },
        { item = "Base.Shotgun",         dmg = 0.55, range = 7,  sound = "ShotgunShot", hit = 60 },
        { item = "Base.AssaultRifle",    dmg = 0.40, range = 14, sound = "M16Shot",     hit = 50 },
        { item = "Base.HuntingRifle",    dmg = 0.50, range = 18, sound = "RifleShot",   hit = 55 },
    },
}

-- Loot dropped on death, item -> chance (%).
BNS.Loadouts.Drops = {
    [BNS.Tier.CIVILIAN] = {
        { item = "Base.Money",             chance = 30, count = 2 },
        { item = "Base.Cigarettes",        chance = 25 },
        { item = "Base.TinnedBeans",       chance = 20 },
        { item = "Base.WaterBottleFull",   chance = 20 },
    },
    [BNS.Tier.THUG] = {
        { item = "Base.Money",             chance = 50, count = 5 },
        { item = "Base.Cigarettes",        chance = 40 },
        { item = "Base.WhiskeyFull",       chance = 15 },
        { item = "Base.Bullets9mm",        chance = 25, count = 6 },
    },
    [BNS.Tier.MILITIA] = {
        { item = "Base.Bullets9mm",        chance = 40, count = 10 },
        { item = "Base.ShotgunShells",     chance = 30, count = 6 },
        { item = "Base.223Bullets",        chance = 30, count = 10 },
        { item = "Base.Bandage",           chance = 40, count = 2 },
        { item = "Base.CannedChili",       chance = 30 },
    },
}

-- Supplies stocked into fortified POI containers.
BNS.Loadouts.BaseSupplies = {
    { item = "Base.TinnedBeans",       count = 6 },
    { item = "Base.CannedChili",       count = 4 },
    { item = "Base.CannedCorn",        count = 4 },
    { item = "Base.WaterBottleFull",   count = 6 },
    { item = "Base.Bandage",           count = 5 },
    { item = "Base.PillsVitamins",     count = 2 },
    { item = "Base.Bullets9mm",        count = 30 },
    { item = "Base.ShotgunShells",     count = 12 },
    { item = "Base.PetrolCan",         count = 2 },
    { item = "Base.Nails",             count = 40 },
    { item = "Base.Plank",             count = 10 },
}

-- Trader stock templates: item, barter value, max count in stock.
BNS.Loadouts.TraderStock = {
    { item = "Base.Bullets9mm",        value = 2,  max = 30 },
    { item = "Base.ShotgunShells",     value = 3,  max = 12 },
    { item = "Base.Antibiotics",       value = 25, max = 2 },
    { item = "Base.Bandage",           value = 4,  max = 6 },
    { item = "Base.TinnedBeans",       value = 5,  max = 8 },
    { item = "Base.WaterBottleFull",   value = 3,  max = 6 },
    { item = "Base.Axe",               value = 30, max = 1 },
    { item = "Base.Machete",           value = 35, max = 1 },
    { item = "Base.PetrolCan",         value = 20, max = 2 },
    { item = "Base.Seeds",             value = 8,  max = 4 },
    { item = "Base.HuntingRifle",      value = 90, max = 1 },
}

-- What players' items are worth to a trader (full types not listed = 0,
-- except a small default for food/ammo categories resolved at runtime).
BNS.Loadouts.BarterValues = {
    ["Base.Money"]           = 1,
    ["Base.Cigarettes"]      = 6,
    ["Base.WhiskeyFull"]     = 15,
    ["Base.Antibiotics"]     = 25,
    ["Base.Bullets9mm"]      = 2,
    ["Base.ShotgunShells"]   = 3,
    ["Base.223Bullets"]      = 2,
    ["Base.CannedChili"]     = 5,
    ["Base.TinnedBeans"]     = 5,
    ["Base.PetrolCan"]       = 20,
    ["Base.Battery"]         = 8,
    ["Base.Bandage"]         = 4,
}

-- Hair and beard model names vary by build; the debug animation lab is
-- how these get identified in-game. Empty means "let the engine pick".
BNS.Loadouts.HairStyles = {}
BNS.Loadouts.Beards = {}

BNS.Loadouts.FirstNames = {
    "Ray", "Dale", "Earl", "Wade", "Cody", "June", "Darlene", "Tanya",
    "Marcus", "Otis", "Lena", "Ruth", "Hank", "Sal", "Vera", "Clyde",
}
BNS.Loadouts.LastNames = {
    "Hobbs", "Kane", "Mercer", "Duke", "Bryce", "Sloan", "Tate",
    "Krueger", "Boone", "Vance", "Whitaker", "Combs", "Ridley",
}

function BNS.Loadouts.randomName()
    local f = BNS.Loadouts.FirstNames[ZombRand(#BNS.Loadouts.FirstNames) + 1]
    local l = BNS.Loadouts.LastNames[ZombRand(#BNS.Loadouts.LastNames) + 1]
    return f .. " " .. l
end

function BNS.Loadouts.pick(list)
    if not list or #list == 0 then return nil end
    return list[ZombRand(#list) + 1]
end
