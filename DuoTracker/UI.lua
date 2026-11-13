-- Duo Tracker: the window. Tabs across the top; each tab lists every pair.
local ADDON, ns = ...

local W = 880
local TOP = 110          -- space above the first pair row
local ROW_H = 46
local LINE_H = 16
local VISIBLE = 9        -- detail lines shown at once
local DETAIL_H = VISIBLE * LINE_H + 16
local NOTE_H = 30        -- extra room for the note box on the Notes tab
local BAR_W = 190
-- x positions inside a row (the row is W - 16 wide)
local LEFT_EDGE, MID, RIGHT_EDGE, QUEST_EDGE = 276, 365, 454, 850

local GOLD = { 0.91, 0.78, 0.47 }
local BODY = { 0.93, 0.89, 0.82 }
local MUTED = { 0.71, 0.65, 0.55 }
local ORANGE = { 0.95, 0.63, 0.33 }
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- key, tab label, then the four column headings (%s is the partner's name)
local TABS = {
    { "overview", "Overview", "Yours", "Standing", "%s's", "Quests" },
    { "quests", "Quests", "Yours", "Standing", "%s's", "" },
    { "gear", "Gear", "Yours", "", "%s's", "Bag items" },
    { "profs", "Professions", "Yours", "", "%s's", "Can craft" },
    { "gold", "Gold", "Yours", "", "%s's", "Together" },
    { "notes", "Notes", "Yours", "", "%s's", "" },
}
local tab = "overview"
local tabButtons, noteBox = {}, nil
local frame, info, detail, more, updateButton
local headers, rows, lines = {}, {}, {}
local selected, offset = false, 0   -- selected: index of the opened pair, or false

local STATUS = {
    you = { "You're behind", 0.12, 0.10, 0.07 },
    them = { "%s is behind", 0.66, 0.78, 0.98 },
    mixed = { "Both behind", 1.00, 0.88, 0.40 },
    ok = { "In step", 0.50, 0.82, 0.76 },
    nodata = { "No data yet", 0.71, 0.65, 0.55 },
}

local function ClassColor(c)
    local col = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
    if col then return col.r, col.g, col.b end
    return BODY[1], BODY[2], BODY[3]
end

local function FS(parent, font, justify, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH(justify or "LEFT")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    return fs
end

local function Backdrop(f, r, g, b, a, edge)
    if not f.SetBackdrop then return end
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = edge or 1 })
    f:SetBackdropColor(r, g, b, a)
    f:SetBackdropBorderColor(0.54, 0.42, 0.18, 1)
end

local function Bar(row)
    local track = row:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(0.23, 0.18, 0.14, 1)
    track:SetSize(BAR_W, 5)
    local fill = row:CreateTexture(nil, "OVERLAY")
    fill:SetHeight(5)
    return track, fill
end

local function SetBar(track, fill, c, show)
    local pct = show and ns.XPPercent(c) or 0
    if show then track:Show() else track:Hide() end
    if pct <= 0 then
        fill:Hide()
    else
        fill:Show()
        fill:SetWidth(math.max(1, BAR_W * pct / 100))
        local r, g, b = ClassColor(c)
        fill:SetColorTexture(r, g, b, 1)
    end
end

local function MakeRow(i)
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(W - 16, ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()

    -- Yours: reads right to left, towards the middle
    row.youName = FS(row, "GameFontNormal", "RIGHT")
    row.youName:SetPoint("TOPRIGHT", row, "TOPLEFT", LEFT_EDGE, -7)
    row.youLevel = FS(row, "GameFontHighlightSmall", "RIGHT", MUTED)
    row.youLevel:SetPoint("RIGHT", row.youName, "LEFT", -8, 0)
    row.youSub = FS(row, "GameFontHighlightSmall", "RIGHT", MUTED)
    row.youSub:SetPoint("TOPRIGHT", row, "TOPLEFT", LEFT_EDGE, -26)
    row.youTrack, row.youFill = Bar(row)
    row.youTrack:SetPoint("TOPRIGHT", row, "TOPLEFT", LEFT_EDGE, -30)
    row.youFill:SetPoint("RIGHT", row.youTrack, "RIGHT")

    -- Middle
    row.pill = row:CreateTexture(nil, "ARTWORK")
    row.pill:SetColorTexture(0.95, 0.63, 0.33, 1)
    row.status = FS(row, "GameFontHighlightSmall", "CENTER")
    row.status:SetPoint("TOP", row, "TOPLEFT", MID, -8)
    row.pill:SetPoint("TOPLEFT", row.status, "TOPLEFT", -6, 3)
    row.pill:SetPoint("BOTTOMRIGHT", row.status, "BOTTOMRIGHT", 6, -3)
    row.step = FS(row, "GameFontHighlightSmall", "CENTER", MUTED)
    row.step:SetPoint("TOP", row, "TOPLEFT", MID, -27)

    -- Partner's: reads left to right
    row.themName = FS(row, "GameFontNormal", "LEFT")
    row.themName:SetPoint("TOPLEFT", row, "TOPLEFT", RIGHT_EDGE, -7)
    row.themLevel = FS(row, "GameFontHighlightSmall", "LEFT", MUTED)
    row.themLevel:SetPoint("LEFT", row.themName, "RIGHT", 8, 0)
    row.themSub = FS(row, "GameFontHighlightSmall", "LEFT", MUTED)
    row.themSub:SetPoint("TOPLEFT", row, "TOPLEFT", RIGHT_EDGE, -26)
    row.themTrack, row.themFill = Bar(row)
    row.themTrack:SetPoint("TOPLEFT", row, "TOPLEFT", RIGHT_EDGE, -30)
    row.themFill:SetPoint("LEFT", row.themTrack, "LEFT")

    row.far = FS(row, "GameFontHighlightSmall", "RIGHT", BODY)
    row.far:SetPoint("RIGHT", row, "LEFT", QUEST_EDGE, 0)

    -- Notes tab: the note runs under both names
    row.note = FS(row, "GameFontHighlightSmall", "CENTER", BODY)
    row.note:SetPoint("TOP", row, "TOPLEFT", MID, -26)
    row.note:SetWidth(W - 80)
    row.note:SetWordWrap(false)

    row:SetScript("OnClick", function()
        if selected == i then selected = false else selected = i end
        offset = 0
        if noteBox then noteBox:Hide() end
        ns.RefreshUI()
    end)
    rows[i] = row
    return row
end

local function MakeLine(i)
    local line = CreateFrame("Button", nil, detail)
    line:SetSize(W - 60, LINE_H)
    line:SetPoint("TOPLEFT", 32, -(8 + (i - 1) * LINE_H))
    line.text = FS(line, "GameFontHighlightSmall", "LEFT")
    line.text:SetPoint("LEFT")
    line.text:SetWidth(W - 60)
    line.text:SetWordWrap(false)
    line:RegisterForClicks("RightButtonUp")
    line:SetScript("OnClick", function(self)
        if self.questId then ns.Ignore(self.questId) end
    end)
    line:SetScript("OnEnter", function(self)
        if type(self.itemId) == "number" and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetHyperlink("item:" .. self.itemId)
            GameTooltip:Show()
        end
    end)
    line:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    lines[i] = line
    return line
end

local function Build()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    frame = CreateFrame("Frame", "DuoTrackerFrame", UIParent, template)
    frame:SetSize(W, 400)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    Backdrop(frame, 0.118, 0.094, 0.07, 0.97, 2)
    if UISpecialFrames then table.insert(UISpecialFrames, "DuoTrackerFrame") end

    local title = FS(frame, "GameFontNormalLarge", "CENTER", GOLD)
    title:SetPoint("TOP", 0, -10)
    pcall(title.SetFont, title, "Fonts\\MORPHEUS.TTF", 22, "")
    if title.GetFont and not title:GetFont() and GameFontNormalLarge then title:SetFontObject(GameFontNormalLarge) end
    title:SetText("Duo Tracker")
    info = FS(frame, "GameFontHighlightSmall", "CENTER", MUTED)
    info:SetPoint("TOP", 0, -36)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    updateButton = CreateFrame("Button", nil, frame, template)
    updateButton:SetSize(150, 22)
    updateButton:SetPoint("TOPLEFT", 10, -10)
    Backdrop(updateButton, 0.95, 0.63, 0.33, 1)
    updateButton.text = FS(updateButton, "GameFontHighlightSmall", "CENTER", { 0.12, 0.10, 0.07 })
    updateButton.text:SetPoint("CENTER")
    updateButton:SetScript("OnClick", function()
        ns.Print("Version " .. tostring(ns.updateAvailable) .. " is available and you have " .. ns.MyVersion() .. ".")
        ns.Print("Double-click \"Update Duo Tracker\" on your desktop, then type /reload here.")
    end)
    updateButton:Hide()

    -- Tabs across the top
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(120, 24)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 124, -58)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.text = FS(b, "GameFontHighlightSmall", "CENTER")
        b.text:SetPoint("CENTER")
        b.text:SetText(t[2])
        b:SetScript("OnClick", function()
            tab, offset = t[1], 0
            if noteBox then noteBox:Hide() end
            ns.RefreshUI()
        end)
        tabButtons[i] = b
    end
    local rule = frame:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.54, 0.42, 0.18, 1)
    rule:SetPoint("TOPLEFT", 2, -82)
    rule:SetPoint("TOPRIGHT", -2, -82)
    rule:SetHeight(1)

    headers[1] = FS(frame, "GameFontNormalSmall", "RIGHT", GOLD)
    headers[1]:SetPoint("TOPRIGHT", frame, "TOPLEFT", 8 + LEFT_EDGE, -90)
    headers[2] = FS(frame, "GameFontNormalSmall", "CENTER", GOLD)
    headers[2]:SetPoint("TOP", frame, "TOPLEFT", 8 + MID, -90)
    headers[3] = FS(frame, "GameFontNormalSmall", "LEFT", GOLD)
    headers[3]:SetPoint("TOPLEFT", frame, "TOPLEFT", 8 + RIGHT_EDGE, -90)
    headers[4] = FS(frame, "GameFontNormalSmall", "RIGHT", GOLD)
    headers[4]:SetPoint("TOPRIGHT", frame, "TOPLEFT", 8 + QUEST_EDGE, -90)

    detail = CreateFrame("Frame", nil, frame, template)
    detail:SetSize(W - 16, DETAIL_H)
    Backdrop(detail, 0.09, 0.07, 0.05, 1)
    detail:EnableMouseWheel(true)
    detail:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 2)
        ns.RefreshUI()
    end)
    more = FS(detail, "GameFontDisableSmall", "RIGHT", MUTED)
    more:SetPoint("TOPRIGHT", -8, -6)
    more:SetText("Scroll for more")
    for i = 1, VISIBLE do MakeLine(i) end

    noteBox = CreateFrame("EditBox", nil, detail, "InputBoxTemplate")
    noteBox:SetSize(W - 120, 20)
    noteBox:SetPoint("BOTTOMLEFT", 40, 10)
    noteBox:SetAutoFocus(false)
    noteBox:SetMaxLetters(200)
    noteBox:SetScript("OnEnterPressed", function(self)
        if selected then ns.SetNote(selected, self:GetText()) end
        self:ClearFocus()
    end)
    noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    noteBox:Hide()
    frame:Hide()
end

local function GuideLabel(c)
    if not c.guide then return "none loaded" end
    return (c.group and (c.group .. " / ") or "") .. c.guide
end

local GOOD = { 0.50, 0.82, 0.76 }

local function GearEntries(r, add)
    for _, c in ipairs({ r.you, r.them }) do
        local g = ns.GearSummary(c)
        if not g then
            add(c.name .. ": gear hasn't synced yet.", nil, MUTED)
        else
            add(c.name .. ": average item level " .. g.avg ..
                (g.weakest and (". Weakest slot: " .. g.weakest .. " (item level " .. g.weakestLevel .. ").") or "."), nil, GOLD)
            if #g.empty > 0 then add("   Empty: " .. table.concat(g.empty, ", "), nil, { 0.95, 0.63, 0.33 }) end
            if #g.low > 0 then add("   Well below level " .. (c.level or "?") .. ": " .. table.concat(g.low, ", "), nil, { 0.95, 0.63, 0.33 }) end
        end
    end
    local function bags(forChar, fromChar)
        local list = ns.HandMeDowns(forChar, fromChar)
        if not list then return end
        if #list == 0 then
            add("Nothing in " .. fromChar.name .. "'s bags for " .. forChar.name .. ".", nil, MUTED)
            return
        end
        add("In " .. fromChar.name .. "'s bags for " .. forChar.name .. " (" .. #list .. "):", nil, GOLD)
        for _, it in ipairs(list) do add("   " .. it.text, nil, BODY, it.id) end
    end
    bags(r.you, r.them)
    bags(r.them, r.you)
end

local function ProfEntries(r, add)
    for _, c in ipairs({ r.you, r.them }) do
        if not c.x then
            add(c.name .. ": professions haven't synced yet.", nil, MUTED)
        elseif #c.x.profs == 0 then
            add(c.name .. ": no professions.", nil, GOLD)
        else
            local cap = ns.SkillCap(c.level)
            add(c.name .. " (level " .. (c.level or "?") .. ", can reach " .. cap .. "):", nil, GOLD)
            for _, p in ipairs(c.x.profs) do
                local text = "   " .. p[1] .. " " .. p[2] .. " / " .. p[3]
                if p[2] >= cap and cap > 0 then
                    add(text .. ". At the cap for this level.", nil, GOOD)
                else
                    add(text .. ". " .. (cap - p[2]) .. " behind." ..
                        (p[3] < cap and " Needs the next rank from a trainer." or ""), nil, BODY)
                end
            end
        end
    end
    local function craft(forChar, fromChar)
        local list = ns.CanCraft(forChar, fromChar)
        if not list or #list == 0 then return end
        add(fromChar.name .. " can craft for " .. forChar.name .. " (" .. #list .. "):", nil, GOLD)
        for _, it in ipairs(list) do add("   " .. it.text, nil, BODY, it.id) end
    end
    craft(r.you, r.them)
    craft(r.them, r.you)
    add("Recipes are read when a profession window is opened, so open each one once.", nil, MUTED)
end

local function GoldEntries(r, add)
    local total, known = 0, true
    for _, c in ipairs({ r.you, r.them }) do
        local line = ns.MountLine(c)
        if line then
            add(c.name .. ": " .. line)
            total = total + (c.x.gold or 0)
        else
            add(c.name .. ": gold hasn't synced yet.", nil, MUTED)
            known = false
        end
    end
    if known then add("Together: " .. ns.Money(total) .. ".", nil, GOLD) end
end

local function NoteEntries(index, add)
    local note = ns.db.notes[ns.PairKey(index) or ""]
    if note and note.text ~= "" then
        add(note.text)
        add("Written by " .. (note.by or "?") .. ", " .. ns.Ago(note.t):lower() .. ".", nil, MUTED)
    else
        add("No note for this pair yet.", nil, MUTED)
    end
    add("Type below and press Enter. Your partner sees it after the next sync.", nil, MUTED)
end

local function OverviewEntries(r, add)
    local partner = ns.PartnerLabel()
    local a, b = r.you, r.them
    add(a.name .. " is level " .. a.level .. " (" .. ns.XPPercent(a) .. "%), " .. b.name .. " is level " ..
        b.level .. " (" .. ns.XPPercent(b) .. "%).", nil, GOLD)
    if r.guideDiff then
        add("Different RestedXP guides, so step numbers can't be compared.", nil, ORANGE)
        add("   Yours: " .. GuideLabel(a), nil, MUTED)
        add("   " .. partner .. "'s: " .. GuideLabel(b), nil, MUTED)
    elseif r.sameGuide then
        add("Guide: " .. GuideLabel(a) .. ". Step " .. (a.step or "?") .. " and step " .. (b.step or "?") ..
            (a.steps and (" of " .. a.steps) or "") .. ".")
    else
        add("No RestedXP guide loaded on " .. (a.guide and b.name or a.name) .. ", so steps aren't compared.", nil, MUTED)
    end
    if r.cfgDiff then
        add("RestedXP settings differ, which can change the route.", nil, ORANGE)
        add("   Yours: " .. a.cfg, nil, MUTED)
        add("   " .. partner .. "'s: " .. b.cfg, nil, MUTED)
    end
    add("Last synced " .. ns.Ago(b.synced):lower() .. ". The other tabs have quests, gear, professions, gold and notes.", nil, MUTED)
end

local function QuestEntries(r, add)
    if not r.questsKnown then
        add("Quest lists haven't synced for this pair yet.", nil, MUTED)
        return
    end
    local function section(list, hidden, name)
        local note = hidden > 0 and ("  " .. hidden .. " class or race quests hidden.") or ""
        if #list == 0 then
            add(name .. " needs no quests." .. note, nil, GOOD)
            return
        end
        add(name .. " needs " .. #list .. (#list == 1 and " quest." or " quests.") ..
            " Right-click one to ignore it." .. note, nil, GOLD)
        for _, id in ipairs(list) do add("   " .. ns.QuestTitle(id), id) end
    end
    section(r.youNeed, r.youHidden, r.youName)
    section(r.themNeed, r.themHidden, r.themName)
end

local function DetailEntries(r, index)
    local e = {}
    local function add(text, questId, color, itemId)
        color = color or BODY
        e[#e + 1] = { text = text, questId = questId, itemId = itemId, r = color[1], g = color[2], b = color[3] }
    end
    if r.themName == "" then
        add("This pair has no second character yet. Type: /duo pair " .. r.youName .. " = Character Name", nil, GOLD)
    elseif tab == "notes" then
        NoteEntries(index, add)
    elseif r.status == "nodata" then
        add("Waiting for data. Each character shows up once it has logged in with this addon and you've both been online.", nil, MUTED)
    elseif tab == "gear" then
        GearEntries(r, add)
    elseif tab == "profs" then
        ProfEntries(r, add)
    elseif tab == "gold" then
        GoldEntries(r, add)
    elseif tab == "quests" then
        QuestEntries(r, add)
    else
        OverviewEntries(r, add)
    end
    return e
end

local function Count(list)
    return list and #list or 0
end

-- Fills the parts of a row that change with the tab.
local function FillRow(row, r, index, partner)
    local known = r.status ~= "nodata"
    local youSub, themSub, far, note = "", "", "", ""
    local showStanding = tab == "overview" or tab == "quests"
    local overview = tab == "overview"

    if tab == "overview" then
        if known then
            if not r.questsKnown then
                far = "Not synced"
            elseif #r.youNeed > 0 and #r.themNeed > 0 then
                far = "You " .. #r.youNeed .. ", " .. partner .. " " .. #r.themNeed
            elseif #r.youNeed > 0 then
                far = "You need " .. #r.youNeed
            elseif #r.themNeed > 0 then
                far = partner .. " needs " .. #r.themNeed
            else
                far = "None"
            end
        end
    elseif tab == "quests" then
        if known and r.questsKnown then
            youSub = #r.youNeed == 0 and "Nothing to catch up" or (#r.youNeed .. " to catch up")
            themSub = #r.themNeed == 0 and "Nothing to catch up" or (#r.themNeed .. " to catch up")
        elseif known then
            youSub, themSub = "Not synced", "Not synced"
        end
    elseif tab == "gear" then
        local function sub(c)
            local g = ns.GearSummary(c)
            if not g then return c and "Not synced" or "" end
            return "Item level " .. g.avg .. (g.weakest and (", weakest " .. g.weakest .. " " .. g.weakestLevel) or "")
        end
        youSub, themSub = sub(r.you), sub(r.them)
        if known then
            local n = Count(ns.HandMeDowns(r.you, r.them)) + Count(ns.HandMeDowns(r.them, r.you))
            far = n > 0 and ("|cfff2a154" .. n .. " to hand over|r") or "Nothing"
        end
    elseif tab == "profs" then
        local function sub(c)
            if not (c and c.x) then return c and "Not synced" or "" end
            local parts = {}
            for i, p in ipairs(c.x.profs) do parts[i] = p[1] .. " " .. p[2] end
            return #parts > 0 and table.concat(parts, ", ") or "No professions"
        end
        youSub, themSub = sub(r.you), sub(r.them)
        if known then
            local n = Count(ns.CanCraft(r.you, r.them)) + Count(ns.CanCraft(r.them, r.you))
            far = n > 0 and ("|cfff2a154" .. n .. " upgrades|r") or "Nothing"
        end
    elseif tab == "gold" then
        local function sub(c)
            if not (c and c.x) then return c and "Not synced" or "" end
            return ns.Money(c.x.gold)
        end
        youSub, themSub = sub(r.you), sub(r.them)
        if r.you and r.you.x and r.them and r.them.x then
            far = ns.Money((r.you.x.gold or 0) + (r.them.x.gold or 0))
        end
    elseif tab == "notes" then
        local n = ns.db.notes[ns.PairKey(index) or ""]
        note = n and n.text ~= "" and n.text or "|cffb5a68cNo note|r"
    end

    row.youSub:SetText(youSub)
    row.themSub:SetText(themSub)
    row.far:SetText(far)
    row.note:SetText(note)
    row.youLevel:SetText(r.you and r.you.level and ("Level " .. r.you.level) or "Not seen yet")
    row.themLevel:SetText(r.themName == "" and "/duo pair to set" or
        (r.them and r.them.level and ("Level " .. r.them.level) or "Not seen yet"))
    SetBar(row.youTrack, row.youFill, r.you, overview)
    SetBar(row.themTrack, row.themFill, r.them, overview)

    local step = ""
    if overview and known then
        if r.guideDiff then
            step = "|cffe9c877Different guides|r"
        elseif r.sameGuide then
            step = "Step " .. (r.you.step or "?") .. " / " .. (r.them.step or "?")
        else
            step = "No guide"
        end
    end
    row.step:SetText(step)
    if showStanding then
        local s = STATUS[r.status]
        row.status:SetText(s[1]:format(partner))
        row.status:SetTextColor(s[2], s[3], s[4])
        if r.status == "you" then row.pill:Show() else row.pill:Hide() end
    else
        row.status:SetText("")
        row.pill:Hide()
    end
end

function ns.RefreshUI()
    if not (frame and frame:IsShown()) then return end
    local db = ns.db
    local partner = ns.PartnerLabel()
    local n = #db.pairs
    if selected and selected > n then selected = false end

    info:SetText((ns.PartnerOnline() and (partner .. " is online. ") or (partner .. " is offline. ")) ..
        "Last sync: " .. ns.Ago(db.lastSync):lower() .. ".")
    if ns.updateAvailable then
        updateButton.text:SetText("Update available: " .. ns.updateAvailable)
        updateButton:Show()
    else
        updateButton:Hide()
    end
    for i, t in ipairs(TABS) do
        local b = tabButtons[i]
        if t[1] == tab then
            b.bg:SetColorTexture(0.54, 0.42, 0.18, 1)
            b.text:SetTextColor(1, 0.95, 0.79)
            for h = 1, 4 do headers[h]:SetText((t[h + 2]:format(partner))) end
        else
            b.bg:SetColorTexture(0.165, 0.13, 0.098, 1)
            b.text:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
        end
    end

    local detailH = DETAIL_H + (tab == "notes" and NOTE_H or 0)
    local y, chosen = TOP, nil
    detail:Hide()
    for i = 1, math.max(n, #rows) do
        local row = rows[i] or MakeRow(i)
        if i > n then
            row:Hide()
        else
            local r = ns.Compare(i)
            row:Show()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -y)
            y = y + ROW_H
            if i == selected then
                chosen = r
                row.bg:SetColorTexture(0.91, 0.78, 0.47, 0.14)
                detail:ClearAllPoints()
                detail:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -y)
                detail:SetHeight(detailH)
                detail:Show()
                y = y + detailH
            elseif i % 2 == 1 then
                row.bg:SetColorTexture(0.165, 0.13, 0.098, 1)
            else
                row.bg:SetColorTexture(0, 0, 0, 0)
            end
            row.youName:SetText(r.youName)
            row.youName:SetTextColor(ClassColor(r.you))
            row.themName:SetText(r.themName ~= "" and r.themName or "Not set")
            row.themName:SetTextColor(ClassColor(r.them))
            FillRow(row, r, i, partner)
        end
    end
    frame:SetHeight(y + 10)

    if chosen and tab == "notes" and chosen.themName ~= "" then
        if not noteBox:IsShown() then
            local note = db.notes[ns.PairKey(selected) or ""]
            noteBox:SetText(note and note.text or "")
            noteBox:Show()
        end
    else
        noteBox:Hide()
    end

    local entries = chosen and DetailEntries(chosen, selected) or {}
    offset = math.max(0, math.min(offset, #entries - VISIBLE))
    for i = 1, VISIBLE do
        local line, entry = lines[i], entries[offset + i]
        if entry then
            line.text:SetText(entry.text)
            line.text:SetTextColor(entry.r, entry.g, entry.b)
            line.questId = entry.questId
            line.itemId = entry.itemId
            line:Show()
        else
            line.questId, line.itemId = nil, nil
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
        offset = 0
        frame:Show()
        ns.RefreshUI()
    end
end
