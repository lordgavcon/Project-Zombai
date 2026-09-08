--***********************************************************************
-- Bandits & Survivors — fortified POIs (server)
--
-- The militia faction claims a handful of known points of interest.
-- Because map squares stream in and out, fortification is applied
-- lazily: when a square inside a claimed POI loads, its windows and
-- doors get barricaded and its containers stocked, exactly once.
-- Each claimed POI also gets a garrison of militia defender records
-- anchored to the location.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_POIs"
require "BNS/BNS_Loadouts"
require "BNS/BNS_Archetypes"
require "BNS/BNS_Persistence"
require "BNS/BNS_Spawner"
require "BNS/BNS_Signs"

BNS.Bases = {}

-- Claiming --------------------------------------------------------------

function BNS.Bases.claimPOIs()
    local opts = BNS.Options()
    if not opts.pois or not opts.militia then return end
    local state = BNS.Persistence.getState()

    local claimed = 0
    for _, base in pairs(state.bases) do
        if base then claimed = claimed + 1 end
    end
    if claimed >= opts.maxPois then return end

    -- Shuffle-pick unclaimed POIs up to the cap.
    local pool = {}
    for _, poi in ipairs(BNS.POIs) do
        if not state.bases[poi.name] then table.insert(pool, poi) end
    end
    while claimed < opts.maxPois and #pool > 0 do
        local idx = ZombRand(#pool) + 1
        local poi = table.remove(pool, idx)
        state.bases[poi.name] = {
            name = poi.name, x = poi.x, y = poi.y, z = poi.z,
            radius = poi.radius, stockedSquares = {},
        }
        claimed = claimed + 1
        BNS.Bases.createGarrison(state, poi)
        BNS.log("militia claimed POI: " .. poi.name)
    end
end

function BNS.Bases.createGarrison(state, poi)
    local squadId = "garrison_" .. poi.name
    -- Garrison flavour follows the POI's surroundings (near military
    -- sites that means ex-military; the tier stays militia-grade).
    local archetype = BNS.Archetypes.roll(poi.x, poi.y, BNS.Tier.MILITIA)
    local n = ZombRand(3, 6)
    for i = 1, n do
        local rec = BNS.Persistence.newRecord(BNS.Role.BANDIT, BNS.Tier.MILITIA,
            poi.x + ZombRand(-3, 4), poi.y + ZombRand(-3, 4), poi.z or 0)
        rec.squad = squadId
        rec.archetype = archetype
        rec.home = { x = poi.x, y = poi.y, radius = poi.radius }
        rec.program = BNS.Program.DEFEND
        rec.weapon = BNS.Spawner.rollWeapon(BNS.Tier.MILITIA, archetype)
    end
end

-- Lazy fortification ----------------------------------------------------

-- Anchoring a claim to a real building ---------------------------------
--
-- The POI list is a set of hand-placed coordinates, so a circle drawn
-- around one covers part of a building and a slice of the street: half
-- the stronghold goes unfortified and supplies end up outdoors. So a
-- claim adopts the actual building instead. "Core" then means the
-- building's own footprint -- every square of it, and nothing outside
-- it -- and the approach ring is measured from the building's centre.

local function buildingOf(square)
    if not square then return nil end
    local ok, building = pcall(function()
        if square.getBuilding then
            local b = square:getBuilding()
            if b then return b end
        end
        local room = square.getRoom and square:getRoom() or nil
        return room and room:getBuilding() or nil
    end)
    if not ok then return nil end
    return building
end

-- Footprint of a building, or nil if this build doesn't expose one.
local function buildingBounds(building)
    if not building then return nil end
    local bounds = nil
    pcall(function()
        local def = building:getDef()
        if not def then return end
        local b = { x = def:getX(), y = def:getY(), w = def:getW(), h = def:getH() }
        if def.getID then b.id = def:getID() end
        if b.x and b.y and b.w and b.h and b.w > 0 and b.h > 0 then bounds = b end
    end)
    return bounds
end

local function baseReach(base)
    if base.b then return math.max(base.b.w, base.b.h) / 2 + 2 end
    return base.radius
end

-- Take the building at the claim point if its square is loaded, else the
-- one belonging to the square that just streamed in near it.
local function adoptBuilding(base, square)
    if base.b then return true end
    local bounds = nil
    if getSquare then
        bounds = buildingBounds(buildingOf(getSquare(base.x, base.y, base.z or 0)))
    end
    bounds = bounds or buildingBounds(buildingOf(square))
    if not bounds then return false end

    base.b = bounds
    -- Re-centre on the building so the garrison, camp noise and the
    -- approach ring all line up with the walls a player actually sees.
    base.x = bounds.x + math.floor(bounds.w / 2)
    base.y = bounds.y + math.floor(bounds.h / 2)
    -- Squares handled under the old circle may have been misclassified;
    -- let them be reconsidered when they next stream in.
    base.stockedSquares = {}
    -- The garrison was placed around the claim point; move its anchor onto
    -- the building so defenders hold the stronghold rather than a patch of
    -- street beside it.
    local state = BNS.Persistence.getState()
    for _, rec in pairs(state.npcs or {}) do
        if rec.squad == "garrison_" .. base.name and rec.home then
            rec.home.x, rec.home.y = base.x, base.y
            rec.home.radius = math.max(bounds.w, bounds.h) / 2 + 2
        end
    end
    BNS.log(string.format("%s anchored to its building at %d,%d (%dx%d)",
        base.name, bounds.x, bounds.y, bounds.w, bounds.h))
    return true
end

-- Inside the *building*, not merely inside its bounding box: an L-shaped
-- footprint has outdoor corners, and that is exactly where supplies were
-- ending up. A square with no room is outdoors, whatever the box says.
local function insideBase(base, square)
    local b = base.b
    if not b or not square then return false end
    local x, y = square:getX(), square:getY()
    if x < b.x or y < b.y or x >= b.x + b.w or y >= b.y + b.h then return false end
    local here = buildingBounds(buildingOf(square))
    if not here then return false end
    if b.id and here.id then return here.id == b.id end
    return here.x == b.x and here.y == b.y
end
BNS.Bases.insideBase = insideBase

-- Which claimed POI owns this square, and how close in: "core" is the
-- stronghold building itself, "approach" the ring outside it that only
-- ever gets scattered evidence (never barricades or supplies).
local function baseForSquare(square)
    local x, y = square:getX(), square:getY()
    local state = BNS.Persistence.getState()
    local outer = nil
    for _, base in pairs(state.bases) do
        local d = BNS.dist(x, y, base.x, base.y)
        -- Adopt from any square near the claim point; after that,
        -- membership is the building's own footprint, not a distance --
        -- a long or L-shaped building has corners no circle covers.
        if not base.b and d <= base.radius then adoptBuilding(base, square) end
        if insideBase(base, square) then return base, "core" end
        if not outer and d <= baseReach(base) * BNS.Signs.APPROACH_MULT then
            outer = base
        end
    end
    return outer, outer and "approach" or nil
end

local function barricadeObject(square, obj, player0)
    -- Metal-bar barricade both sides where possible: sturdy, and it
    -- reads clearly as "someone lives here".
    if not (instanceof(obj, "IsoWindow") or instanceof(obj, "IsoDoor")) then return end
    if IsoBarricade and IsoBarricade.AddBarricadeToObject then
        local barricade = IsoBarricade.AddBarricadeToObject(obj, false)
        if barricade then
            for _ = 1, 3 do barricade:addPlank(nil, nil) end
        end
    end
end

-- Supply ids are resolved against the running build once, so a line whose
-- item B42 renamed is dropped rather than rejected on every AddItem.
local resolvedSupplies = nil
local function supplies()
    if not resolvedSupplies then
        resolvedSupplies = BNS.Loadouts.filter(BNS.Loadouts.BaseSupplies)
    end
    return resolvedSupplies
end

-- Where the supplies go ------------------------------------------------
--
-- A stronghold's stores belong in containers, not strewn across the
-- floor. Squares stream in one at a time, so each stocking square looks
-- for a real container on itself first, then in the surrounding few
-- tiles, and only when a stronghold has nothing to store things in does
-- the garrison put a crate down.

local CONTAINER_SEARCH   = 3  -- tiles to look for an existing container
local MAX_CRATES         = 4  -- crates a garrison will haul in per POI
local MAX_SUPPLY_LINES   = 24 -- total stocked lines per POI
local MAX_LINES_PER_CONT = 3  -- so one shelf doesn't hold the whole camp

-- Crate sprites vary by build and tileset, so the name is not guessed at
-- once: each candidate is checked against the sprite manager, the object
-- is only kept if it really yields a container, and whichever works is
-- remembered. If none does, supplies simply wait for a real container --
-- putting them on the floor is the thing we are fixing.
BNS.Bases.CrateSprites = {
    "carpentry_01_16", "carpentry_01_17",
    "crated_01_08", "crated_01_09",
    "location_military_generic_01_16",
    "industry_railroad_01_32",
}
BNS.Bases.crateSprite = nil

local function spriteExists(name)
    if not IsoSpriteManager or not IsoSpriteManager.instance then return false end
    local ok, sprite = pcall(function() return IsoSpriteManager.instance:getSprite(name) end)
    return ok and sprite ~= nil
end

local function containerOf(obj)
    if not obj or not obj.getContainer then return nil end
    local ok, c = pcall(function() return obj:getContainer() end)
    if ok then return c end
    return nil
end

-- Every container on a square, so a shelf and a counter both get used.
local function containersOn(square)
    local out = {}
    if not square or not square.getObjects then return out end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local c = containerOf(objects:get(i))
        if c then table.insert(out, c) end
    end
    return out
end

-- Nearest containers within a few tiles of the square being stocked, and
-- never outside the stronghold: a shelf across the street is not the
-- garrison's, and supplies left there read as loot lying outdoors.
local function containersNear(square, base)
    local found = containersOn(square)
    if #found > 0 then return found end
    if not getSquare then return found end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for r = 1, CONTAINER_SEARCH do
        for dx = -r, r do
            for dy = -r, r do
                -- Only the ring at this radius, so nearer squares win.
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = getSquare(x + dx, y + dy, z)
                    if sq and insideBase(base, sq) then
                        local here = containersOn(sq)
                        if #here > 0 then return here end
                    end
                end
            end
        end
    end
    return found
end

-- Put a crate down and hand back its container, or nil if this build
-- gives us no sprite that works as one.
local function placeCrate(square, base)
    if (base.crates or 0) >= MAX_CRATES then return nil end
    if not IsoObject or not IsoObject.new then return nil end

    local candidates = BNS.Bases.crateSprite
        and { BNS.Bases.crateSprite } or BNS.Bases.CrateSprites
    for _, name in ipairs(candidates) do
        if spriteExists(name) then
            local obj
            local ok = pcall(function()
                obj = IsoObject.new(square, name, name)
                square:AddSpecialObject(obj)
                if obj.transmitCompleteItemToServer then
                    obj:transmitCompleteItemToServer()
                end
            end)
            local container = ok and containerOf(obj) or nil
            if container then
                if not BNS.Bases.crateSprite then
                    BNS.Bases.crateSprite = name
                    BNS.log("stocking POI crates with sprite " .. name)
                end
                base.crates = (base.crates or 0) + 1
                return container
            end
            -- Placed something that is not a container: take it back out
            -- rather than leaving furniture scattered around the POI.
            if obj then
                pcall(function() square:transmitRemoveItemFromSquare(obj) end)
                pcall(function() square:RemoveTileObject(obj) end)
            end
        end
    end
    return nil
end

local function fill(container, base, lines)
    for _ = 1, lines do
        if (base.supplyLines or 0) >= MAX_SUPPLY_LINES then return end
        local s = BNS.Loadouts.pick(supplies())
        if not s then return end
        for _ = 1, ZombRand(s.count) + 1 do
            container:AddItem(s.item)
        end
        base.supplyLines = (base.supplyLines or 0) + 1
    end
end

local function stockContainers(square, base)
    base.supplyLines = base.supplyLines or 0
    if base.supplyLines >= MAX_SUPPLY_LINES then return end
    -- Belt and braces: nothing is ever stocked on a square that is not
    -- inside the stronghold, however this got called.
    if not insideBase(base, square) then return end

    local found = containersNear(square, base)
    if #found == 0 then
        -- Nothing to store things in nearby: haul a crate in.
        local crate = placeCrate(square, base)
        if not crate then return end
        found = { crate }
    end
    for _, container in ipairs(found) do
        fill(container, base, ZombRand(1, MAX_LINES_PER_CONT + 1))
        if (base.supplyLines or 0) >= MAX_SUPPLY_LINES then return end
    end
end

function BNS.Bases.onLoadGridsquare(square)
    if not square then return end
    local base, zone = baseForSquare(square)
    if not base then return end
    local key = square:getX() .. "_" .. square:getY() .. "_" .. square:getZ()
    base.stockedSquares = base.stockedSquares or {}
    if base.stockedSquares[key] then return end
    base.stockedSquares[key] = true

    -- Only the stronghold itself is fortified and stocked.
    if zone == "core" then
        for i = 0, square:getObjects():size() - 1 do
            barricadeObject(square, square:getObjects():get(i))
        end
        stockContainers(square, base)
    end
    -- Both rings show that someone lives here.
    BNS.Signs.decorateSquare(square, base, zone)
end

Events.LoadGridsquare.Add(BNS.Bases.onLoadGridsquare)
