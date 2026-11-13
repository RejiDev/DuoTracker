-- Duo Tracker: the window with every pair.
local ADDON, ns = ...

local W = 880
local TOP = 58          -- space above the first pair row
local ROW_H = 38
local LINE_H = 16
local VISIBLE = 11      -- quest lines shown at once
local COL = { 12, 196, 380, 520, 650, 780 }
local HEADERS = { "Yours", "Partner's", "Guide step (you / partner)", "Quests to catch up", "Status", "Last synced" }

local frame, info, detail, more
local headers, rows, lines = {}, {}, {}
local selected, offset = nil, 0

local STATUS = {
    you = { "You're behind", 0.95, 0.63, 0.33 },
    them = { "%s is behind", 0.66, 0.78, 0.98 },
    mixed = { "Both behind", 1.00, 0.88, 0.40 },
    ok = { "In step", 0.50, 0.82, 0.76 },
    nodata = { "No data yet", 0.64, 0.67, 0.72 },
}

local function ClassColor(c)
    local col = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
    if col then return col.r, col.g, col.b end
    return 0.9, 0.9, 0.9
end

local function Text(parent, font, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    if width then
        fs:SetWidth(width)
        fs:SetWordWrap(false)
    end
    return fs
end

local function Backdrop(f, r, g, b, a)
    if not f.SetBackdrop then return end
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(r, g, b, a)
    f:SetBackdropBorderColor(0.23, 0.26, 0.32, 1)
end

local function Sub(c)
    if not (c and c.level) then return "Not seen yet" end
    return "Level " .. c.level .. ", " .. ns.XPPercent(c) .. "%"
end

local function MakeRow(i)
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(W - 16, ROW_H)
    row:SetPoint("TOPLEFT", 8, -(TOP + (i - 1) * ROW_H))
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.youName = Text(row, "GameFontNormal", COL[1], -5, 176)
    row.youSub = Text(row, "GameFontDisableSmall", COL[1], -21, 176)
    row.themName = Text(row, "GameFontNormal", COL[2], -5, 176)
    row.themSub = Text(row, "GameFontDisableSmall", COL[2], -21, 176)
    row.step = Text(row, "GameFontHighlightSmall", COL[3], -13, 132)
    row.quests = Text(row, "GameFontHighlightSmall", COL[4], -13, 122)
    row.status = Text(row, "GameFontHighlightSmall", COL[5], -13, 122)
    row.synced = Text(row, "GameFontDisableSmall", COL[6], -13, 84)
    row:SetScript("OnClick", function()
        selected, offset = i, 0
        ns.RefreshUI()
    end)
    rows[i] = row
    return row
end

local function MakeLine(i)
    local line = CreateFrame("Button", nil, detail)
    line:SetSize(W - 40, LINE_H)
    line:SetPoint("TOPLEFT", 10, -(8 + (i - 1) * LINE_H))
    line.text = Text(line, "GameFontHighlightSmall", 0, -2, W - 40)
    line:RegisterForClicks("RightButtonUp")
    line:SetScript("OnClick", function(self)
        if self.questId then ns.Ignore(self.questId) end
    end)
    lines[i] = line
    return line
end

local function Build()
    frame = CreateFrame("Frame", "DuoTrackerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(W, 400)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    Backdrop(frame, 0.11, 0.12, 0.15, 0.96)
    if UISpecialFrames then table.insert(UISpecialFrames, "DuoTrackerFrame") end

    local title = Text(frame, "GameFontNormalLarge", 12, -10)
    title:SetText("Duo Tracker")
    info = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("TOPRIGHT", -36, -14)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    for i, label in ipairs(HEADERS) do
        headers[i] = Text(frame, "GameFontDisableSmall", 8 + COL[i], -38)
        headers[i]:SetText(label)
    end

    detail = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    Backdrop(detail, 0.08, 0.09, 0.12, 1)
    detail:EnableMouseWheel(true)
    detail:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 2)
        ns.RefreshUI()
    end)
    more = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    more:SetPoint("BOTTOMRIGHT", -8, 6)
    more:SetText("Scroll for more")
    for i = 1, VISIBLE do MakeLine(i) end
    frame:Hide()
end

local function GuideLabel(c)
    if not c.guide then return "none loaded" end
    return (c.group and (c.group .. " / ") or "") .. c.guide
end

local function DetailEntries(r)
    local e = {}
    local function add(text, questId, red, green, blue)
        e[#e + 1] = { text = text, questId = questId, r = red or 0.9, g = green or 0.91, b = blue or 0.93 }
    end
    local partner = ns.PartnerLabel()
    if r.themName == "" then
        add("This pair has no second character yet. Type: /duo pair " .. r.youName .. " = Character Name", nil, 0.91, 0.76, 0.42)
        return e
    end
    if r.status == "nodata" then
        add("Waiting for data. Each character shows up once it has logged in with this addon and you've both been online.", nil, 0.64, 0.67, 0.72)
        return e
    end
    if r.guideDiff then
        add("Different RestedXP guides, so step numbers can't be compared.", nil, 0.91, 0.76, 0.42)
        add("   Yours: " .. GuideLabel(r.you), nil, 0.64, 0.67, 0.72)
        add("   " .. partner .. "'s: " .. GuideLabel(r.them), nil, 0.64, 0.67, 0.72)
    elseif not (r.you.guide and r.them.guide) then
        add("No RestedXP guide loaded on " .. (r.you.guide and r.themName or r.youName) .. ", so steps aren't compared.", nil, 0.64, 0.67, 0.72)
    end
    if r.cfgDiff then
        add("RestedXP settings differ, which can change the route.", nil, 0.91, 0.76, 0.42)
        add("   Yours: " .. r.you.cfg, nil, 0.64, 0.67, 0.72)
        add("   " .. partner .. "'s: " .. r.them.cfg, nil, 0.64, 0.67, 0.72)
    end
    if not r.questsKnown then
        add("Quest lists haven't synced for this pair yet.", nil, 0.64, 0.67, 0.72)
        return e
    end
    local function section(list, hidden, heading)
        local note = hidden > 0 and ("  " .. hidden .. " class or race quests hidden.") or ""
        if #list == 0 then
            add(heading .. ": nothing." .. note, nil, 0.50, 0.82, 0.76)
            return
        end
        add(heading .. " (" .. #list .. "). Right-click a quest to ignore it." .. note, nil, 0.91, 0.76, 0.42)
        for _, id in ipairs(list) do add("   " .. ns.QuestTitle(id), id) end
    end
    section(r.youNeed, r.youHidden, r.youName .. " needs")
    section(r.themNeed, r.themHidden, r.themName .. " needs")
    return e
end

function ns.RefreshUI()
    if not (frame and frame:IsShown()) then return end
    local db = ns.db
    local partner = ns.PartnerLabel()
    local n = #db.pairs
    if not selected or selected > n then selected = ns.PairIndexFor(ns.db.chars[ns.norm(UnitName("player"))]) or 1 end

    HEADERS[2] = partner .. "'s"
    headers[2]:SetText(HEADERS[2])
    headers[3]:SetText("Guide step (you / " .. partner .. ")")
    info:SetText((ns.PartnerOnline() and (partner .. " is online. ") or (partner .. " is offline. ")) ..
        "Last sync: " .. ns.Ago(db.lastSync):lower() .. "." ..
        (ns.updateAvailable and ("  |cfff2a154Update available: " .. ns.updateAvailable .. "|r") or ""))

    local chosen
    for i = 1, math.max(n, #rows) do
        local row = rows[i] or MakeRow(i)
        if i > n then
            row:Hide()
        else
            local r = ns.Compare(i)
            if i == selected then chosen = r end
            row:Show()
            if i == selected then
                row.bg:SetColorTexture(0.91, 0.76, 0.42, 0.16)
            elseif i % 2 == 1 then
                row.bg:SetColorTexture(1, 1, 1, 0.04)
            else
                row.bg:SetColorTexture(0, 0, 0, 0)
            end
            row.youName:SetText(r.youName)
            row.youName:SetTextColor(ClassColor(r.you))
            row.youSub:SetText(Sub(r.you))
            row.themName:SetText(r.themName ~= "" and r.themName or "Not set")
            row.themName:SetTextColor(ClassColor(r.them))
            row.themSub:SetText(r.themName ~= "" and Sub(r.them) or "/duo pair to set")

            local step, quests = "-", "-"
            if r.status ~= "nodata" then
                if r.guideDiff then
                    step = "|cffe8c36aDifferent guides|r"
                elseif r.sameGuide then
                    step = (r.you.step or "?") .. " / " .. (r.them.step or "?")
                else
                    step = "No guide"
                end
                if not r.questsKnown then
                    quests = "Not synced"
                elseif #r.youNeed > 0 and #r.themNeed > 0 then
                    quests = "You " .. #r.youNeed .. ", " .. partner .. " " .. #r.themNeed
                elseif #r.youNeed > 0 then
                    quests = "You need " .. #r.youNeed
                elseif #r.themNeed > 0 then
                    quests = partner .. " needs " .. #r.themNeed
                else
                    quests = "None"
                end
            end
            row.step:SetText(step)
            row.quests:SetText(quests)
            local s = STATUS[r.status]
            row.status:SetText(s[1]:format(partner))
            row.status:SetTextColor(s[2], s[3], s[4])
            row.synced:SetText(r.them and ns.Ago(r.them.synced) or "Never")
        end
    end

    local detailTop = TOP + n * ROW_H + 8
    local detailH = VISIBLE * LINE_H + 16
    frame:SetHeight(detailTop + detailH + 8)
    detail:ClearAllPoints()
    detail:SetPoint("TOPLEFT", 8, -detailTop)
    detail:SetSize(W - 16, detailH)

    local entries = chosen and DetailEntries(chosen) or {}
    offset = math.max(0, math.min(offset, #entries - VISIBLE))
    for i = 1, VISIBLE do
        local line, entry = lines[i], entries[offset + i]
        if entry then
            line.text:SetText(entry.text)
            line.text:SetTextColor(entry.r, entry.g, entry.b)
            line.questId = entry.questId
            line:Show()
        else
            line.questId = nil
            line:Hide()
        end
    end
    if #entries > VISIBLE then more:Show() else more:Hide() end
end

function ns.ToggleUI()
    if not frame then Build() end
    if frame:IsShown() then
        frame:Hide()
    else
        selected, offset = nil, 0
        frame:Show()
        ns.RefreshUI()
    end
end
