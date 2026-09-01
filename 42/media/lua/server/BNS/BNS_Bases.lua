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

local function baseForSquare(x, y)
    local state = BNS.Persistence.getState()
    for _, base in pairs(state.bases) do
        if BNS.dist(x, y, base.x, base.y) <= base.radius then return base end
    end
    return nil
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

local function stockContainers(square, base)
    for i = 0, square:getObjects():size() - 1 do
        local obj = square:getObjects():get(i)
        local container = obj.getContainer and obj:getContainer() or nil
        if container then
            -- One or two supply lines per container so loot spreads out.
            for _ = 1, ZombRand(1, 3) do
                local s = BNS.Loadouts.pick(BNS.Loadouts.BaseSupplies)
                if s then
                    for _ = 1, ZombRand(s.count) + 1 do
                        container:AddItem(s.item)
                    end
                end
            end
        end
    end
end

function BNS.Bases.onLoadGridsquare(square)
    if not square then return end
    local base = baseForSquare(square:getX(), square:getY())
    if not base then return end
    local key = square:getX() .. "_" .. square:getY() .. "_" .. square:getZ()
    if base.stockedSquares[key] then return end
    base.stockedSquares[key] = true

    for i = 0, square:getObjects():size() - 1 do
        barricadeObject(square, square:getObjects():get(i))
    end
    stockContainers(square, base)
end

Events.LoadGridsquare.Add(BNS.Bases.onLoadGridsquare)
