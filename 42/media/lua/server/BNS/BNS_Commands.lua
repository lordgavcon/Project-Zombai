--***********************************************************************
-- Bandits & Survivors — client command handlers (server)
--
-- Trading is server-authoritative: the client only ever sends "I want
-- to trade with NPC X" and "here is my offer"; the server validates
-- item values and moves the items, so MP clients can't forge trades.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Loadouts"
require "BNS/BNS_Persistence"
require "BNS/BNS_Programs"
require "BNS/BNS_Locks"

BNS.Commands = {}

local function findNPCByOnlineId(onlineId)
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        local z = zombies:get(i)
        if z:getOnlineID() == onlineId and BNS.isNPC(z) then return z end
    end
    return nil
end

local function reply(player, command, args)
    if isServer() then
        sendServerCommand(player, BNS.CommandModule, command, args)
    elseif BNS.Client and BNS.Client.onServerCommand then
        BNS.Client.onServerCommand(BNS.CommandModule, command, args)
    end
end

-- Value of a player item to a trader.
function BNS.Commands.itemValue(fullType)
    return BNS.Loadouts.BarterValues[fullType] or 0
end

-- requestTrade -> tradeStock ---------------------------------------------

function BNS.Commands.requestTrade(player, args)
    local zombie = findNPCByOnlineId(args.npcId)
    if not zombie then return end
    local brain = BNS.brain(zombie)
    if not brain or brain.role ~= BNS.Role.TRADER or not brain.stock then return end
    if BNS.dist(player:getX(), player:getY(), zombie:getX(), zombie:getY()) > 4 then return end

    reply(player, "tradeStock", {
        npcId = args.npcId,
        name = brain.name,
        stock = brain.stock,
        values = BNS.Loadouts.BarterValues,
    })
end

-- doTrade ----------------------------------------------------------------

-- args = { npcId, offer = { fullType, ... }, want = { {index, count}, ... } }
function BNS.Commands.doTrade(player, args)
    local zombie = findNPCByOnlineId(args.npcId)
    if not zombie then return end
    local brain = BNS.brain(zombie)
    if not brain or brain.role ~= BNS.Role.TRADER or not brain.stock then return end
    if BNS.dist(player:getX(), player:getY(), zombie:getX(), zombie:getY()) > 4 then return end

    -- Cost of what the player wants.
    local cost = 0
    for _, w in ipairs(args.want or {}) do
        local entry = brain.stock[w.index]
        if not entry or (w.count or 0) > entry.count or (w.count or 0) < 1 then
            reply(player, "tradeResult", { ok = false })
            return
        end
        cost = cost + entry.value * w.count
    end

    -- Verify the player actually holds the offered items, and their value.
    local inv = player:getInventory()
    local offered, value = {}, 0
    for _, fullType in ipairs(args.offer or {}) do
        local it = inv:getFirstTypeRecurse(fullType:gsub("^Base%.", ""))
        if not it or offered[it] then
            reply(player, "tradeResult", { ok = false })
            return
        end
        offered[it] = true
        value = value + BNS.Commands.itemValue(fullType)
    end

    if cost == 0 or value < cost then
        reply(player, "tradeResult", { ok = false })
        return
    end

    -- Execute: player pays...
    for it, _ in pairs(offered) do
        inv:Remove(it)
    end
    -- ...and receives.
    for _, w in ipairs(args.want or {}) do
        local entry = brain.stock[w.index]
        entry.count = entry.count - w.count
        local id = BNS.Loadouts.item(entry.item)
        for _ = 1, w.count do
            if id then inv:AddItem(id) end
        end
    end
    -- Compact sold-out lines and persist the new stock.
    for i = #brain.stock, 1, -1 do
        if brain.stock[i].count <= 0 then table.remove(brain.stock, i) end
    end
    local rec = BNS.Persistence.getState().npcs[brain.id]
    if rec then rec.stock = brain.stock end

    BNS.Say(zombie, brain, getText("UI_BNS_TradeAccepted"))
    reply(player, "tradeResult", { ok = true, stock = brain.stock })
end

-- talk --------------------------------------------------------------------

local SURVIVOR_LINES = {
    "Stay safe out there.",
    "Seen a militia crew holed up down the road. I'd steer clear.",
    "The dead are thicker every week.",
    "Got nothing worth taking, friend.",
    "Heard gunfire east of here last night.",
}

function BNS.Commands.talk(player, args)
    local zombie = findNPCByOnlineId(args.npcId)
    if not zombie then return end
    local brain = BNS.brain(zombie)
    if not brain or brain.role == BNS.Role.BANDIT then return end
    brain.speechCooldown = 0
    BNS.Say(zombie, brain, SURVIVOR_LINES[ZombRand(#SURVIVOR_LINES) + 1])
end

-- Dispatch ----------------------------------------------------------------

function BNS.Commands.onClientCommand(module, command, player, args)
    if module ~= BNS.CommandModule then return end
    -- Debug commands carry their own admin/debug-mode gate.
    if BNS.Debug and BNS.Debug.handle(command, player, args) then return end
    if command == "requestTrade" then BNS.Commands.requestTrade(player, args)
    elseif command == "doTrade" then BNS.Commands.doTrade(player, args)
    elseif command == "talk" then BNS.Commands.talk(player, args)
    elseif command == "attachLock" then BNS.Locks.attachLock(player, args)
    elseif command == "removeLock" then BNS.Locks.removeLock(player, args)
    elseif command == "useLock" then BNS.Locks.useLock(player, args)
    end
end

Events.OnClientCommand.Add(BNS.Commands.onClientCommand)
