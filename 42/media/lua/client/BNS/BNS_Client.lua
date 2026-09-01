--***********************************************************************
-- Bandits & Survivors — client core
--
-- Receives server commands (speech, robbery, raid warnings, trade data)
-- and renders NPC speech as floating world text.
--***********************************************************************

require "BNS/BNS_Core"

BNS.Client = {}

-- Floating speech --------------------------------------------------------

local speeches = {} -- { {x, y, text, ttl} }

function BNS.Client.showSpeech(args)
    table.insert(speeches, { x = args.x, y = args.y, text = args.text, ttl = 240 })
end

local function renderSpeech()
    if #speeches == 0 then return end
    local playerIndex = 0
    for i = #speeches, 1, -1 do
        local s = speeches[i]
        s.ttl = s.ttl - 1
        if s.ttl <= 0 then
            table.remove(speeches, i)
        else
            local sx = isoToScreenX(playerIndex, s.x, s.y, 0)
            local sy = isoToScreenY(playerIndex, s.x, s.y, 0)
            local alpha = math.min(s.ttl / 60, 1.0)
            getTextManager():DrawStringCentre(UIFont.Dialogue or UIFont.Small,
                sx, sy - 120, s.text, 1.0, 1.0, 0.8, alpha)
        end
    end
end

Events.OnPostUIDraw.Add(renderSpeech)

-- Server command dispatch ------------------------------------------------

function BNS.Client.onServerCommand(module, command, args)
    if module ~= BNS.CommandModule then return end
    local player = getSpecificPlayer(0)

    if command == "say" then
        BNS.Client.showSpeech(args)

    elseif command == "robbed" then
        if player then
            player:setHaloNote(getText("UI_BNS_RobberyDone"), 255, 100, 100, 300)
        end

    elseif command == "raidWarning" then
        if player and BNS.dist(player:getX(), player:getY(), args.x, args.y) < 120 then
            player:setHaloNote(getText("UI_BNS_RaidWarning"), 255, 150, 50, 400)
            player:playSound("WindWhistling")
        end

    elseif command == "hit" then
        if player then player:playSound("BluntHit") end

    elseif command == "tradeStock" then
        if BNS.TradeWindow then BNS.TradeWindow.open(args) end

    elseif command == "tradeResult" then
        if BNS.TradeWindow then BNS.TradeWindow.onResult(args) end
        if player and not args.ok then
            player:setHaloNote(getText("UI_BNS_TradeRejected"), 255, 200, 100, 300)
        end
    end
end

Events.OnServerCommand.Add(BNS.Client.onServerCommand)

-- Client -> server bridge that also works in single player, where the
-- "server" lua runs in-process and OnClientCommand doesn't fire.
function BNS.Client.sendCommand(command, args)
    if isClient() then
        sendClientCommand(getSpecificPlayer(0), BNS.CommandModule, command, args)
    elseif BNS.Commands then
        BNS.Commands.onClientCommand(BNS.CommandModule, command, getSpecificPlayer(0), args)
    end
end
