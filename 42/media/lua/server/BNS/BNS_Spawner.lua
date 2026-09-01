--***********************************************************************
-- Bandits & Survivors — spawner (server)
--
-- Materialises NPC records into IsoZombie shells and back. Shells are
-- spawned through addZombiesInOutfit so they use vanilla outfits and
-- sync to MP clients like any zombie; the brain record in mod data is
-- what makes the engine's zombie into our NPC.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Loadouts"
require "BNS/BNS_Archetypes"
require "BNS/BNS_Persistence"
require "BNS/BNS_Anim"

BNS.Spawner = {}

-- Weapon selection ------------------------------------------------------

function BNS.Spawner.rollWeapon(tier, archetype)
    local opts = BNS.Options()
    local def = BNS.Archetypes.get(archetype)

    local guns = def and def.guns or BNS.Loadouts.Guns[tier]
    local gunChance = 0
    if def then
        gunChance = def.gunChance == "sandbox" and opts.militiaGunChance or (def.gunChance or 0)
    elseif tier == BNS.Tier.MILITIA then gunChance = opts.militiaGunChance
    elseif tier == BNS.Tier.THUG then gunChance = 15 end

    if guns and ZombRand(100) < gunChance then
        local g = BNS.Loadouts.pick(guns)
        return { item = g.item, dmg = g.dmg, range = g.range, gun = true, sound = g.sound, hit = g.hit }
    end
    local melee = def and def.melee or BNS.Loadouts.Melee[tier] or BNS.Loadouts.Melee[BNS.Tier.CIVILIAN]
    local m = BNS.Loadouts.pick(melee)
    return { item = m.item, dmg = m.dmg, range = m.range, gun = false }
end

-- Shell creation --------------------------------------------------------

local function pickOutfit(rec)
    local pool
    local def = BNS.Archetypes.get(rec.archetype)
    if def then pool = def.outfits
    elseif rec.role == BNS.Role.BANDIT then pool = BNS.Loadouts.Outfits[rec.tier]
    elseif rec.role == BNS.Role.TRADER then pool = BNS.Loadouts.Outfits.trader
    else pool = BNS.Loadouts.Outfits.survivor end
    return BNS.Loadouts.pick(pool) or "Generic01"
end

-- Spawn (or respawn) the shell for a record at its saved position.
-- Returns the IsoZombie or nil if the square isn't loaded.
function BNS.Spawner.materialise(rec)
    local sq = getCell():getGridSquare(rec.x, rec.y, rec.z or 0)
    if not sq then return nil end

    local outfit = pickOutfit(rec)
    local zombies = addZombiesInOutfit(rec.x, rec.y, rec.z or 0, 1, outfit, 50)
    if not zombies or zombies:size() == 0 then return nil end
    local zombie = zombies:get(0)

    -- Calm the engine's zombie instincts; the brain drives from here.
    zombie:setUseless(true)
    zombie:makeInactive(true)
    if zombie.setNoTeeth then zombie:setNoTeeth(true) end
    zombie:setHealth(1.5)

    local brain = {
        id = rec.id,
        role = rec.role,
        tier = rec.tier,
        archetype = rec.archetype,
        name = rec.name,
        program = rec.program or BNS.Program.WANDER,
        targetX = rec.targetX,
        targetY = rec.targetY,
        health = rec.health or 1.0,
        weapon = rec.weapon or BNS.Spawner.rollWeapon(rec.tier),
        squad = rec.squad,
        home = rec.home,
        stock = rec.stock,
        cooldown = 0,
        speechCooldown = 0,
    }
    rec.weapon = brain.weapon
    zombie:getModData().BNS = brain
    BNS.Anim.init(zombie, brain)

    -- Show the weapon in hand.
    if brain.weapon and brain.weapon.item then
        local w = instanceItem(brain.weapon.item)
        if w then
            zombie:setPrimaryHandItem(w)
            if brain.weapon.gun and w.setTwoHandWeapon then
                zombie:setSecondaryHandItem(w)
            end
        end
    end

    rec.live = true
    zombie:getModData().BNS_recId = rec.id
    return zombie
end

-- Remove a live shell, keeping the record (virtualisation).
function BNS.Spawner.dematerialise(zombie)
    BNS.Persistence.syncFromShell(zombie)
    local brain = BNS.brain(zombie)
    if brain then
        local rec = BNS.Persistence.getState().npcs[brain.id]
        if rec then rec.live = false end
    end
    zombie:removeFromWorld()
    zombie:removeFromSquare()
end

-- Fresh spawns ----------------------------------------------------------

-- Find an off-screen square near (but not on top of) a player.
local function pickSpawnSquare(player)
    for _ = 1, 10 do
        local angle = ZombRandFloat(0, 2 * math.pi)
        local distArea = ZombRand(40, 80)
        local x = math.floor(player:getX() + math.cos(angle) * distArea)
        local y = math.floor(player:getY() + math.sin(angle) * distArea)
        local sq = getCell():getGridSquare(x, y, 0)
        if sq and sq:isFree(false) and not sq:isSolidTrans() then
            return x, y
        end
    end
    return nil
end

-- Spawn a bandit group near the player. The archetype is rolled from
-- the spawn location's environment (farm country → farmers, towns →
-- city folk/police/firefighters, military sites → ex-military), and
-- the whole squad shares it.
function BNS.Spawner.spawnBanditNear(player)
    local x, y = pickSpawnSquare(player)
    if not x then return end
    local archetype = BNS.Archetypes.roll(x, y)
    local def = BNS.Archetypes.get(archetype)
    local tier = def and def.tier or BNS.Tier.CIVILIAN
    local squadSize = 1
    local squadId = nil
    if tier == BNS.Tier.MILITIA then
        squadSize = ZombRand(2, 5)
        squadId = "squad_" .. tostring(ZombRand(100000))
    elseif tier == BNS.Tier.THUG and ZombRand(100) < 40 then
        squadSize = 2
        squadId = "squad_" .. tostring(ZombRand(100000))
    end
    for i = 1, squadSize do
        local rec = BNS.Persistence.newRecord(BNS.Role.BANDIT, tier, x + ZombRand(-2, 3), y + ZombRand(-2, 3), 0)
        rec.squad = squadId
        rec.archetype = archetype
        rec.weapon = BNS.Spawner.rollWeapon(tier, archetype)
        BNS.Spawner.materialise(rec)
    end
    BNS.log("spawned bandit group archetype=" .. archetype .. " tier=" .. tier
        .. " size=" .. squadSize .. " at " .. x .. "," .. y)
end

-- Spawn a neutral survivor or trader near the player.
function BNS.Spawner.spawnSurvivorNear(player)
    local x, y = pickSpawnSquare(player)
    if not x then return end
    local opts = BNS.Options()
    local isTrader = opts.traders and ZombRand(100) < 40
    local role = isTrader and BNS.Role.TRADER or BNS.Role.SURVIVOR
    local rec = BNS.Persistence.newRecord(role, BNS.Tier.CIVILIAN, x, y, 0)
    rec.weapon = BNS.Spawner.rollWeapon(BNS.Tier.CIVILIAN)
    if isTrader then
        rec.stock = {}
        for _, s in ipairs(BNS.Loadouts.TraderStock) do
            if ZombRand(100) < 60 then
                table.insert(rec.stock, { item = s.item, value = s.value, count = ZombRand(s.max) + 1 })
            end
        end
    end
    BNS.Spawner.materialise(rec)
    BNS.log("spawned " .. role .. " at " .. x .. "," .. y)
end

-- Death -----------------------------------------------------------------

function BNS.Spawner.dropLoot(zombie, brain)
    local drops = BNS.Loadouts.Drops[brain.tier]
    local sq = zombie:getCurrentSquare()
    if not drops or not sq then return end
    for _, d in ipairs(drops) do
        if ZombRand(100) < d.chance then
            for _ = 1, (d.count or 1) do
                sq:AddWorldInventoryItem(d.item, 0.2, 0.2, 0)
            end
        end
    end
    -- Their weapon always drops.
    if brain.weapon and brain.weapon.item then
        sq:AddWorldInventoryItem(brain.weapon.item, 0.3, 0.3, 0)
    end
end
