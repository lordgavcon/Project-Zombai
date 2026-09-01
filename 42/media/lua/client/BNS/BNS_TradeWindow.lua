--***********************************************************************
-- Bandits & Survivors — trade window (client)
--
-- Barter UI: left list is the trader's stock (click to add to "want"),
-- right list is the player's tradeable items (click to add to offer).
-- The window totals both sides; Make trade sends the proposal to the
-- server, which validates and executes it.
--***********************************************************************

require "ISUI/ISCollapsableWindow"
require "BNS/BNS_Core"
require "BNS/BNS_Client"

BNS.TradeWindow = ISCollapsableWindow:derive("BNS_TradeWindow")

local FONT_H = getTextManager():getFontHeight(UIFont.Small)
local instance = nil

-- Static open/close ------------------------------------------------------

function BNS.TradeWindow.open(args)
    if instance then instance:close() end
    local w, h = 520, 420
    local x = (getCore():getScreenWidth() - w) / 2
    local y = (getCore():getScreenHeight() - h) / 2
    instance = BNS.TradeWindow:new(x, y, w, h, args)
    instance:initialise()
    instance:addToUIManager()
end

function BNS.TradeWindow.onResult(args)
    if not instance then return end
    if args.ok then
        instance:close()
    end
end

-- Instance ---------------------------------------------------------------

function BNS.TradeWindow:new(x, y, w, h, args)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = getText("UI_BNS_TradeWindow") .. " - " .. (args.name or "?")
    o.npcId = args.npcId
    o.stock = args.stock or {}
    o.values = args.values or {}
    o.want = {}   -- stock index -> count
    o.offer = {}  -- array of item fullTypes
    o.resizable = false
    return o
end

function BNS.TradeWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local pad, top = 10, 40
    local listW = (self.width - pad * 3) / 2
    local listH = self.height - top - 80

    self.stockList = ISScrollingListBox:new(pad, top, listW, listH)
    self.stockList:initialise()
    self.stockList.itemheight = FONT_H + 6
    self.stockList.font = UIFont.Small
    self.stockList.doDrawItem = BNS.TradeWindow.drawStockItem
    self.stockList.onMouseDown = function(list, mx, my)
        ISScrollingListBox.onMouseDown(list, mx, my)
        self:toggleWant(list.selected)
    end
    self:addChild(self.stockList)

    self.offerList = ISScrollingListBox:new(pad * 2 + listW, top, listW, listH)
    self.offerList:initialise()
    self.offerList.itemheight = FONT_H + 6
    self.offerList.font = UIFont.Small
    self.offerList.doDrawItem = BNS.TradeWindow.drawOfferItem
    self.offerList.onMouseDown = function(list, mx, my)
        ISScrollingListBox.onMouseDown(list, mx, my)
        self:toggleOffer(list.selected)
    end
    self:addChild(self.offerList)

    local btnW, btnH = 120, 25
    self.confirmBtn = ISButton:new(self.width - btnW * 2 - pad * 2, self.height - btnH - 10,
        btnW, btnH, getText("UI_BNS_ConfirmTrade"), self, BNS.TradeWindow.onConfirm)
    self.confirmBtn:initialise()
    self:addChild(self.confirmBtn)

    self.cancelBtn = ISButton:new(self.width - btnW - pad, self.height - btnH - 10,
        btnW, btnH, getText("UI_BNS_CancelTrade"), self, BNS.TradeWindow.close)
    self.cancelBtn:initialise()
    self:addChild(self.cancelBtn)

    self:refreshLists()
end

-- Data -> list rows -------------------------------------------------------

function BNS.TradeWindow:refreshLists()
    self.stockList:clear()
    for i, entry in ipairs(self.stock) do
        local item = ScriptManager.instance:getItem(entry.item)
        local name = item and item:getDisplayName() or entry.item
        self.stockList:addItem(name, { index = i, entry = entry })
    end

    self.offerList:clear()
    local player = getSpecificPlayer(0)
    if not player then return end
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local value = self.values[it:getFullType()] or 0
        if value > 0 and not player:isEquipped(it) then
            self.offerList:addItem(it:getDisplayName(), { item = it, value = value })
        end
    end
end

function BNS.TradeWindow:toggleWant(selected)
    local row = self.stockList.items[selected]
    if not row or not row.item then return end
    local idx = row.item.index
    local cur = self.want[idx] or 0
    if cur >= row.item.entry.count then
        self.want[idx] = nil -- cycled past stock: reset
    else
        self.want[idx] = cur + 1
    end
end

function BNS.TradeWindow:toggleOffer(selected)
    local row = self.offerList.items[selected]
    if not row or not row.item then return end
    row.item.offered = not row.item.offered
end

-- Totals ------------------------------------------------------------------

function BNS.TradeWindow:totals()
    local cost = 0
    for idx, count in pairs(self.want) do
        local entry = self.stock[idx]
        if entry then cost = cost + entry.value * count end
    end
    local value = 0
    for _, row in ipairs(self.offerList.items) do
        if row.item and row.item.offered then value = value + row.item.value end
    end
    return cost, value
end

-- Rendering ---------------------------------------------------------------

function BNS.TradeWindow.drawStockItem(list, y, item, alt)
    local win = list.parent
    local wanted = win.want[item.item.index] or 0
    if list.selected == item.index then
        list:drawRect(0, y, list:getWidth(), list.itemheight, 0.3, 0.7, 0.35, 0.15)
    end
    local text = item.text .. " x" .. item.item.entry.count
        .. "  (" .. getText("UI_BNS_TradeValue") .. " " .. item.item.entry.value .. ")"
    if wanted > 0 then text = "[" .. wanted .. "] " .. text end
    local r = wanted > 0 and 0.6 or 0.9
    list:drawText(text, 6, y + 3, r, 1, r, 1, list.font)
    return y + list.itemheight
end

function BNS.TradeWindow.drawOfferItem(list, y, item, alt)
    if list.selected == item.index then
        list:drawRect(0, y, list:getWidth(), list.itemheight, 0.3, 0.7, 0.35, 0.15)
    end
    local text = item.text .. "  (" .. getText("UI_BNS_TradeValue") .. " " .. item.item.value .. ")"
    if item.item.offered then text = "[+] " .. text end
    local g = item.item.offered and 0.6 or 0.9
    list:drawText(text, 6, y + 3, g, 1, g, 1, list.font)
    return y + list.itemheight
end

function BNS.TradeWindow:render()
    ISCollapsableWindow.render(self)
    local pad = 10
    local listW = (self.width - pad * 3) / 2
    self:drawText(getText("UI_BNS_TraderStock"), pad, 24, 1, 1, 1, 1, UIFont.Small)
    self:drawText(getText("UI_BNS_YourOffer"), pad * 2 + listW, 24, 1, 1, 1, 1, UIFont.Small)

    local cost, value = self:totals()
    local ok = value >= cost and cost > 0
    local r, g = ok and 0.5 or 1.0, ok and 1.0 or 0.5
    self:drawText(getText("UI_BNS_TradeValue") .. ": " .. value .. " / " .. cost,
        pad, self.height - 32, r, g, 0.5, 1, UIFont.Small)
end

-- Actions -----------------------------------------------------------------

function BNS.TradeWindow:onConfirm()
    local offer = {}
    for _, row in ipairs(self.offerList.items) do
        if row.item and row.item.offered then
            table.insert(offer, row.item.item:getFullType())
        end
    end
    local want = {}
    for idx, count in pairs(self.want) do
        table.insert(want, { index = idx, count = count })
    end
    BNS.Client.sendCommand("doTrade", { npcId = self.npcId, offer = offer, want = want })
end

function BNS.TradeWindow:close()
    self:removeFromUIManager()
    if instance == self then instance = nil end
end
