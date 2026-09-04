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

-- Camp noise carrying from a bandit-held POI. Played at the POI's own
-- square so it reads as distant; if this build has no world-sound call,
-- it is only played when close enough that a flat sound isn't confusing.
local AMBIENCE_SOUNDS = {
    gunshot   = "9mmShot",
    shotgun   = "ShotgunShot",
    hammering = "Hammering",
}

function BNS.Client.playAmbience(args)
    local player = getSpecificPlayer(0)
    if not player or not args then return end
    local d = BNS.dist(player:getX(), player:getY(), args.x, args.y)
    if d > 80 then return end
    local sound = AMBIENCE_SOUNDS[args.kind] or AMBIENCE_SOUNDS.gunshot
    local sq = getCell() and getCell():getGridSquare(args.x, args.y, 0) or nil
    local played = false
    if sq and getSoundManager then
        played = pcall(function()
            getSoundManager():PlayWorldSound(sound, sq, 0, 30, 1.0, true)
        end)
    end
    if not played and d < 30 then
        pcall(function() player:playSound(sound) end)
    end
end

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



    elseif command == "poiAmbience" then
        BNS.Client.playAmbience(args)

    elseif command == "debugSnapshot" then
        if BNS.DebugUI then BNS.DebugUI.onSnapshot(args) end

    elseif command == "debugResult" then
        if BNS.DebugUI then BNS.DebugUI.onResult(args) end
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
