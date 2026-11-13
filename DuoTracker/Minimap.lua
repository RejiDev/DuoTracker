-- Duo Tracker: the minimap button.
local ADDON, ns = ...

local ICON = "Interface\\AddOns\\DuoTracker\\icon"
local DOT = "Interface\\AddOns\\DuoTracker\\dot"
local button, dot, viaLib

local function OnClick(_, mouseButton)
    if mouseButton == "RightButton" then
        ns.Sync()
    else
        ns.ToggleUI()
    end
end

local function FillTooltip(tt)
    tt:AddLine("Duo Tracker")
    local lines = ns.SummaryLines()
    if lines then
        for i = 1, #lines - 1 do tt:AddLine(lines[i], 1, 1, 1, true) end -- last line is the /duo hint
    else
        tt:AddLine("This character isn't in a pair.", 1, 1, 1)
    end
    if ns.updateAvailable then tt:AddLine("Update available: " .. ns.updateAvailable, 0.95, 0.63, 0.33) end
    tt:AddLine("Left-click to open. Right-click to sync now.", 0.71, 0.65, 0.55)
end

-- Orange dot when the character you're on is behind.
function ns.UpdateBadge()
    if not dot then return end
    local i = ns.PairIndexFor(ns.db.chars[ns.norm(UnitName("player"))])
    local r = i and ns.Compare(i)
    if r and (r.status == "you" or r.status == "mixed") then dot:Show() else dot:Hide() end
end

function ns.ShowMinimapButton(show)
    if viaLib then
        local icons = LibStub("LibDBIcon-1.0")
        if show then icons:Show("DuoTracker") else icons:Hide("DuoTracker") end
    elseif button then
        if show then button:Show() else button:Hide() end
    end
end

function ns.CreateMinimapButton()
    local db = ns.db
    -- Use the shared minimap-button library when another addon has loaded it,
    -- so this button behaves like the rest and joins any button collector.
    local broker = LibStub and LibStub("LibDataBroker-1.1", true)
    local icons = LibStub and LibStub("LibDBIcon-1.0", true)
    if broker and icons then
        local object = broker:NewDataObject("DuoTracker", {
            type = "launcher", text = "Duo Tracker", icon = ICON,
            OnClick = OnClick, OnTooltipShow = FillTooltip,
        })
        icons:Register("DuoTracker", object, db.minimap)
        viaLib = true
        button = icons.GetMinimapButton and icons:GetMinimapButton("DuoTracker")
    elseif Minimap then
        button = CreateFrame("Button", "DuoTrackerMinimapButton", Minimap)
        button:SetSize(28, 28)
        button:SetFrameStrata("MEDIUM")
        button:SetFrameLevel(8)
        button:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -6, 6)
        local tex = button:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(ICON)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetScript("OnClick", OnClick)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            FillTooltip(GameTooltip)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        if db.minimap.hide then button:Hide() end
    end
    if button then
        dot = button:CreateTexture(nil, "OVERLAY", nil, 7)
        dot:SetTexture(DOT)
        dot:SetSize(12, 12)
        dot:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
        dot:Hide()
        ns.UpdateBadge()
    end
end
