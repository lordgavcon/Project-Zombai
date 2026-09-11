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
require "BNS/BNS_Squads"
require "BNS/BNS_Anim"
require "BNS/BNS_Look"

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
    return BNS.Spawner.rollMelee(tier, archetype)
end

-- Split out because a gunner also needs one: when the last magazine runs
-- out they draw this and close (BNS.Combat.drawBackup).
function BNS.Spawner.rollMelee(tier, archetype)
    local def = BNS.Archetypes.get(archetype)
    local melee = def and def.melee or BNS.Loadouts.Melee[tier]
        or BNS.Loadouts.Melee[BNS.Tier.CIVILIAN]
    local m = BNS.Loadouts.pick(melee)
    return { item = m.item, dmg = m.dmg, range = m.range, gun = false }
end

-- A bandit's appearance is rolled once and stored on the record, so
-- they look the same after despawning and identical to every client.
-- (Hair/beard model names are left for the debug animation lab to pin
-- down in-game; BNS.Loadouts.HairStyles is empty until then.)
function BNS.Spawner.rollLook(rec, outfit)
    return {
        female = ZombRand(100) < 35,
        skin = ZombRand(4),
        hair = BNS.Loadouts.pick(BNS.Loadouts.HairStyles),
        beard = BNS.Loadouts.pick(BNS.Loadouts.Beards),
        outfit = outfit,
    }
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

    if not rec.look then rec.look = BNS.Spawner.rollLook(rec, pickOutfit(rec)) end
    local outfit = rec.look.outfit or pickOutfit(rec)
    local zombies = addZombiesInOutfit(rec.x, rec.y, rec.z or 0, 1, outfit, 50)
    if not zombies or zombies:size() == 0 then return nil end
    local zombie = zombies:get(0)

    -- Calm the engine's zombie instincts; the brain drives from here.
    -- Only what BNS.Suppress allows: the two parking calls are off by
    -- default because a parked shell cannot walk (see BNS_Core).
    if BNS.Suppress.useless and zombie.setUseless then zombie:setUseless(true) end
    if BNS.Suppress.inactive and zombie.makeInactive then zombie:makeInactive(true) end
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
        stamina = 1.0,
        squad = rec.squad,
        home = rec.home,
        stock = rec.stock,
        loot = rec.loot,
        look = rec.look,
        cooldown = 0,
        speechCooldown = 0,
    }
    rec.weapon = brain.weapon
    -- Gunners carry something for when the ammunition runs out. Rolled
    -- once and kept on the record so the same bandit always falls back to
    -- the same weapon.
    if brain.weapon and brain.weapon.gun then
        rec.backup = rec.backup or BNS.Spawner.rollMelee(rec.tier, rec.archetype)
        brain.backup = rec.backup
    end
    zombie:getModData().BNS = brain
    BNS.Anim.init(zombie, brain)
    -- Stop it looking like a corpse: living skin, no blood, real hair --
    -- and clothes. The "clothed" op runs here rather than only on the
    -- slow re-assert because an outfit name this build does not have
    -- leaves the shell naked from the first frame it is drawn.
    BNS.Look.apply(zombie, brain)
    -- Vehicle owners get their ride placed back beside them.
    if BNS.Vehicles then BNS.Vehicles.onMaterialise(zombie, brain, rec) end

    -- Show the weapon in hand -- in both hands when it takes both. The
    -- old code only ever filled the off hand for guns, and decided even
    -- that by testing for a *setter* on the item, so every rifle, axe,
    -- bat and spear was carried and swung one-handed.
    BNS.Anim.equip(zombie, brain)

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
        if rec then
            rec.live = false
            -- Standing at their vehicle? They drive off with it (the
            -- vehicle leaves the world and travels with the record).
            if BNS.Vehicles then BNS.Vehicles.onDematerialise(zombie, brain, rec) end
        end
    end
    zombie:removeFromWorld()
    zombie:removeFromSquare()
end

-- Fresh spawns ----------------------------------------------------------

-- Find an off-screen square near (but not on top of) a player.
-- Where a *new* NPC comes into the world.
--
-- Never on ground the player has streamed in: an NPC that pops into
-- existence inside the loaded area can appear in front of you, and at 40
-- tiles in an open field that is on screen. They are created as records
-- out in the unloaded world instead, and get a body only when you walk
-- far enough that their square loads (BNS.Main.boundaryTick) -- so they
-- are always found rather than conjured.
--
-- The band is not a guess at how much the game streams: each attempt
-- steps further out and the loop keeps going until it finds ground the
-- engine has *not* loaded, so it is correct whatever the streaming
-- distance turns out to be. Nothing about the square can be checked
-- (there is no square to check), which is fine -- materialise validates
-- it later, and a record that cannot be embodied where it stands moves on.
BNS.Spawner.SPAWN_MIN = 70   -- tiles from the player to start looking
BNS.Spawner.SPAWN_STEP = 25  -- how much further out each attempt goes
BNS.Spawner.SPAWN_TRIES = 12

-- Bandits come in groups, always, and the same size of group whoever
-- they are. A lone one is the *survivor* of a group, not how they arrive.

-- Scatter a squad member around the picked point without letting them
-- drift onto streamed ground: the picked square being unloaded says
-- nothing about the one two tiles east of it, and the guarantee is per
-- NPC, not per group.
function BNS.Spawner.scatter(x, y)
    for _ = 1, 6 do
        local sx = x + ZombRand(-2, 3)
        local sy = y + ZombRand(-2, 3)
        if not BNS.squareLoaded(sx, sy, 0) then return sx, sy end
    end
    return x, y -- the picked square itself is known good
end

local function pickSpawnSquare(player)
    for attempt = 1, BNS.Spawner.SPAWN_TRIES do
        local angle = ZombRandFloat(0, 2 * math.pi)
        local reach = BNS.Spawner.SPAWN_MIN
            + (attempt - 1) * BNS.Spawner.SPAWN_STEP
            + ZombRand(BNS.Spawner.SPAWN_STEP)
        local x = math.floor(player:getX() + math.cos(angle) * reach)
        local y = math.floor(player:getY() + math.sin(angle) * reach)
        if not BNS.squareLoaded(x, y, 0) then return x, y end
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
    -- Bandits travel together. Every group gets a squad id and an entry
    -- in state.squads, which is what marks it as one BNS_Squads keeps
    -- together -- garrisons and raid parties deliberately have neither,
    -- because they already have somewhere to be.
    local squadSize = ZombRand(BNS.Behaviour.squadMin, BNS.Behaviour.squadMax + 1)
    local squadId = "squad_" .. tostring(ZombRand(1000000))
    BNS.Squads.create(BNS.Persistence.getState(), squadId, x, y)
    local made = 0
    for i = 1, squadSize do
        -- Checked per member, not per group: a squad of five must not be
        -- able to walk the record pool past its ceiling in one call.
        if BNS.Persistence.count() >= BNS.recordCeiling() then break end
        local sx, sy = BNS.Spawner.scatter(x, y)
        local rec = BNS.Persistence.newRecord(BNS.Role.BANDIT, tier, sx, sy, 0)
        rec.squad = squadId
        rec.archetype = archetype
        rec.weapon = BNS.Spawner.rollWeapon(tier, archetype)
        made = made + 1
        -- Deliberately not materialised here: the square is unloaded by
        -- construction, and the boundary gives them a body when the
        -- player reaches them.
    end
    if made == 0 then
        -- The ceiling stopped every member: do not leave an empty squad
        -- behind for the anchor pass to carry around the map.
        BNS.Persistence.getState().squads[squadId] = nil
        return
    end
    BNS.log("spawned bandit group archetype=" .. archetype .. " tier=" .. tier
        .. " size=" .. made .. " at " .. x .. "," .. y)
end

-- Spawn a neutral survivor or trader near the player.
function BNS.Spawner.spawnSurvivorNear(player)
    if BNS.Persistence.count() >= BNS.recordCeiling() then return end
    local x, y = pickSpawnSquare(player)
    if not x then return end
    local opts = BNS.Options()
    local isTrader = opts.traders and ZombRand(100) < 40
    local role = isTrader and BNS.Role.TRADER or BNS.Role.SURVIVOR
    local rec = BNS.Persistence.newRecord(role, BNS.Tier.CIVILIAN, x, y, 0)
    rec.weapon = BNS.Spawner.rollWeapon(BNS.Tier.CIVILIAN)
    if isTrader then
        rec.stock = {}
        for _, s in ipairs(BNS.Loadouts.filter(BNS.Loadouts.TraderStock)) do
            if ZombRand(100) < 60 then
                table.insert(rec.stock, { item = s.item, value = s.value, count = ZombRand(s.max) + 1 })
            end
        end
    end
    -- Virtual by construction, like bandits: the square is unloaded, and
    -- the boundary embodies them when the player gets there.
    BNS.log("spawned " .. role .. " at " .. x .. "," .. y)
end

-- Death -----------------------------------------------------------------

function BNS.Spawner.dropLoot(zombie, brain)
    local sq = zombie:getCurrentSquare()
    if not sq then return end
    local drops = BNS.Loadouts.Drops[brain.tier]
    if drops then
        for _, d in ipairs(drops) do
            local id = BNS.Loadouts.item(d.item)
            if id and ZombRand(100) < d.chance then
                for _ = 1, (d.count or 1) do
                    sq:AddWorldInventoryItem(id, 0.2, 0.2, 0)
                end
            end
        end
    end
    -- Their weapon always drops.
    if brain.weapon and brain.weapon.item then
        local wid = BNS.Loadouts.item(brain.weapon.item)
        if wid then sq:AddWorldInventoryItem(wid, 0.3, 0.3, 0) end
    end
    -- Everything they scavenged drops too.
    if brain.loot then
        for _, fullType in ipairs(brain.loot) do
            local id = BNS.Loadouts.item(fullType)
            if id then sq:AddWorldInventoryItem(id, 0.4, 0.4, 0) end
        end
    end
end
