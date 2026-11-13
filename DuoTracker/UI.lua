-- Duo Tracker: the window. Tabs across the top, a different page for each.
local ADDON, ns = ...

local W = 880
local INNER = W - 16
local HALF = INNER / 2
local TOP = 90            -- where a page's content starts
local ROW_H = 46
local LINE_H = 16
local BAR_W = 190
local LEFT_EDGE, MID, RIGHT_EDGE, FAR_EDGE = 276, 365, 454, 850

local GOLD = { 0.91, 0.78, 0.47 }
local BODY = { 0.93, 0.89, 0.82 }
local MUTED = { 0.71, 0.65, 0.55 }
local ORANGE = { 0.95, 0.63, 0.33 }
local GOOD = { 0.50, 0.82, 0.76 }
local RED = { 1.00, 0.54, 0.50 }
local WHITE = "Interface\\Buttons\\WHITE8X8"
local TEMPLATE

local TABS = { { "overview", "Overview" }, { "quests", "Quests" }, { "gear", "Gear" },
    { "profs", "Professions" }, { "gold", "Gold" }, { "notes", "Notes" } }
local tab = "overview"
local frame, info, updateButton
local tabButtons, pages = {}, {}

local STATUS = {
    you = { "You're behind", 0.12, 0.10, 0.07 },
    them = { "%s is behind", 0.66, 0.78, 0.98 },
    mixed = { "Both behind", 1.00, 0.88, 0.40 },
    ok = { "In step", 0.50, 0.82, 0.76 },
    nodata = { "No data yet", 0.71, 0.65, 0.55 },
}

------------------------------------------------------------------------
-- Small building blocks
------------------------------------------------------------------------

local function ClassColor(c, class)
    class = (c and c.class) or class
    local col = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if col then return col.r, col.g, col.b end
    return BODY[1], BODY[2], BODY[3]
end

local function Colored(c, name, class)
    local r, g, b = ClassColor(c, class)
    return string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5), name or (c and (c.short or c.name)) or "?")
end

local function FS(parent, font, justify, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH(justify or "LEFT")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    return fs
end

local function Tex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r or 1, g or 1, b or 1, a or 1)
    return t
end

local function Backdrop(f, r, g, b, a, edge)
    if not f.SetBackdrop then return end
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = edge or 1 })
    f:SetBackdropColor(r, g, b, a)
    f:SetBackdropBorderColor(0.54, 0.42, 0.18, 1)
end

local function ItemTooltip(self)
    if type(self.itemId) == "number" and GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink("item:" .. self.itemId)
        GameTooltip:Show()
    end
end

local function HideTooltip()
    if GameTooltip then GameTooltip:Hide() end
end

local function Adder()
    local e = {}
    return e, function(text, questId, color, itemId)
        color = color or BODY
        e[#e + 1] = { text = text, questId = questId, itemId = itemId, r = color[1], g = color[2], b = color[3] }
    end
end

-- A scrolling list of text lines. Right-click a quest line to ignore it; hover an item line for its tooltip.
local function ListPanel(parent, width, visible, boxed)
    local p = CreateFrame("Frame", nil, parent, boxed and TEMPLATE or nil)
    p:SetSize(width, visible * LINE_H + 16)
    if boxed then Backdrop(p, 0.09, 0.07, 0.05, 1) end
    p.lines, p.entries, p.offset, p.visible = {}, {}, 0, visible
    for i = 1, visible do
        local line = CreateFrame("Button", nil, p)
        line:SetSize(width - 28, LINE_H)
        line:SetPoint("TOPLEFT", 14, -(8 + (i - 1) * LINE_H))
        line.text = FS(line, "GameFontHighlightSmall", "LEFT")
        line.text:SetPoint("LEFT")
        line.text:SetWidth(width - 28)
        line.text:SetWordWrap(false)
        line:RegisterForClicks("RightButtonUp")
        line:SetScript("OnClick", function(self)
            if self.questId then ns.Ignore(self.questId) end
        end)
        line:SetScript("OnEnter", ItemTooltip)
        line:SetScript("OnLeave", HideTooltip)
        p.lines[i] = line
    end
    p.more = FS(p, "GameFontDisableSmall", "RIGHT", MUTED)
    p.more:SetPoint("BOTTOMRIGHT", -8, 2)
    p.more:SetText("Scroll for more")
    function p:Render()
        self.offset = math.max(0, math.min(self.offset, #self.entries - self.visible))
        for i = 1, self.visible do
            local line, entry = self.lines[i], self.entries[self.offset + i]
            if entry then
                line.text:SetText(entry.text)
                line.text:SetTextColor(entry.r, entry.g, entry.b)
                line.questId, line.itemId = entry.questId, entry.itemId
                line:Show()
            else
                line.questId, line.itemId = nil, nil
                line:Hide()
            end
        end
        if #self.entries > self.visible then self.more:Show() else self.more:Hide() end
    end
    function p:Set(entries)
        self.entries = entries
        self:Render()
    end
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, self.offset - delta * 2)
        self:Render()
    end)
    return p
end

local function Page(key)
    local page = CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", 0, 0)
    page:SetPoint("TOPRIGHT", 0, 0)
    page:SetHeight(100)
    page:Hide()
    pages[key] = page
    return page
end

local function Header(page, text, justify, anchor, x)
    local fs = FS(page, "GameFontNormalSmall", justify, GOLD)
    fs:SetPoint(anchor, page, "TOPLEFT", 8 + x, -(TOP + 2))
    fs:SetText(text)
    return fs
end

-- A list of every pair, one row each. Clicking a row opens a detail list under it.
local function PairList(page, opts)
    local L = { rows = {}, selected = false }
    L.detail = ListPanel(page, INNER, opts.detailLines or 8, true)
    L.detail:Hide()
    function L:Refresh(top)
        local n = #ns.db.pairs
        local partner = ns.PartnerLabel()
        if self.selected and self.selected > n then self.selected = false end
        local y, chosen = top, nil
        self.detail:Hide()
        for i = 1, math.max(n, #self.rows) do
            local row = self.rows[i]
            if not row then
                row = CreateFrame("Button", nil, page)
                row:SetSize(INNER, ROW_H)
                row.bg = Tex(row, "BACKGROUND", 0, 0, 0, 0)
                row.bg:SetAllPoints()
                opts.make(row)
                row:SetScript("OnClick", function()
                    if self.selected == i then self.selected = false else self.selected = i end
                    self.detail.offset = 0
                    ns.RefreshUI()
                end)
                self.rows[i] = row
            end
            if i > n then
                row:Hide()
            else
                local r = ns.Compare(i)
                row:Show()
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -y)
                y = y + ROW_H
                if i == self.selected then
                    chosen = r
                    row.bg:SetColorTexture(0.91, 0.78, 0.47, 0.14)
                    self.detail:ClearAllPoints()
                    self.detail:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -y)
                    self.detail:Show()
                    y = y + self.detail:GetHeight()
                elseif i % 2 == 1 then
                    row.bg:SetColorTexture(0.165, 0.13, 0.098, 1)
                else
                    row.bg:SetColorTexture(0, 0, 0, 0)
                end
                opts.fill(row, r, i, partner)
            end
        end
        if chosen then
            local e, add = Adder()
            if chosen.themName == "" then
                add("This pair has no second character yet. Type: /duo pair " .. chosen.youName .. " = Character Name", nil, GOLD)
            elseif chosen.status == "nodata" then
                add("Waiting for data. Each character shows up once it has logged in with this addon and you've both been online.", nil, MUTED)
            else
                opts.entries(chosen, add)
            end
            self.detail:Set(e)
        end
        return y
    end
    return L
end

local function LevelText(c, name)
    if name == "" then return "/duo pair to set" end
    return c and c.level and ("Level " .. c.level) or "Not seen yet"
end

------------------------------------------------------------------------
-- Overview: head to head
------------------------------------------------------------------------

local function GuideLabel(c)
    if not c.guide then return "none loaded" end
    return (c.group and (c.group .. " / ") or "") .. c.guide
end

local function OverviewEntries(r, add)
    local partner = ns.PartnerLabel()
    local a, b = r.you, r.them
    add(a.long .. " is level " .. a.level .. " (" .. ns.XPPercent(a) .. "%), " .. b.long .. " is level " ..
        b.level .. " (" .. ns.XPPercent(b) .. "%).", nil, GOLD)
    if r.guideDiff then
        add("Different RestedXP guides, so step numbers can't be compared.", nil, ORANGE)
        add("   Yours: " .. GuideLabel(a), nil, MUTED)
        add("   " .. partner .. "'s: " .. GuideLabel(b), nil, MUTED)
    elseif r.sameGuide then
        add("Guide: " .. GuideLabel(a) .. ". Step " .. (a.step or "?") .. " and step " .. (b.step or "?") ..
            (a.steps and (" of " .. a.steps) or "") .. ".")
    else
        add("No RestedXP guide loaded on " .. ns.Mid(a.guide and b or a) .. ", so steps aren't compared.", nil, MUTED)
    end
    if r.cfgDiff then
        add("RestedXP settings differ, which can change the route.", nil, ORANGE)
        add("   Yours: " .. a.cfg, nil, MUTED)
        add("   " .. partner .. "'s: " .. b.cfg, nil, MUTED)
    end
    add("Last synced " .. ns.Ago(b.synced):lower() .. ".", nil, MUTED)
end

local function XPBar(row)
    local track = Tex(row, "ARTWORK", 0.23, 0.18, 0.14, 1)
    track:SetSize(BAR_W, 5)
    local fill = row:CreateTexture(nil, "OVERLAY")
    fill:SetHeight(5)
    return track, fill
end

local function SetXPBar(fill, c)
    local pct = ns.XPPercent(c)
    if pct <= 0 then
        fill:Hide()
    else
        fill:Show()
        fill:SetWidth(math.max(1, BAR_W * pct / 100))
        local r, g, b = ClassColor(c)
        fill:SetColorTexture(r, g, b, 1)
    end
end

local function BuildOverview()
    local page = Page("overview")
    Header(page, "Yours", "RIGHT", "TOPRIGHT", LEFT_EDGE)
    Header(page, "Standing", "CENTER", "TOP", MID)
    page.themHeader = Header(page, "", "LEFT", "TOPLEFT", RIGHT_EDGE)
    Header(page, "Quests", "RIGHT", "TOPRIGHT", FAR_EDGE)
    local list = PairList(page, {
        detailLines = 8,
        entries = OverviewEntries,
        make = function(row)
            row.youName = FS(row, "GameFontNormal", "RIGHT")
            row.youName:SetPoint("TOPRIGHT", row, "TOPLEFT", LEFT_EDGE, -7)
            row.youLevel = FS(row, "GameFontHighlightSmall", "RIGHT", MUTED)
            row.youLevel:SetPoint("RIGHT", row.youName, "LEFT", -8, 0)
            row.youTrack, row.youFill = XPBar(row)
            row.youTrack:SetPoint("TOPRIGHT", row, "TOPLEFT", LEFT_EDGE, -30)
            row.youFill:SetPoint("RIGHT", row.youTrack, "RIGHT")
            row.pill = Tex(row, "ARTWORK", 0.95, 0.63, 0.33, 1)
            row.status = FS(row, "GameFontHighlightSmall", "CENTER")
            row.status:SetPoint("TOP", row, "TOPLEFT", MID, -8)
            row.pill:SetPoint("TOPLEFT", row.status, "TOPLEFT", -6, 3)
            row.pill:SetPoint("BOTTOMRIGHT", row.status, "BOTTOMRIGHT", 6, -3)
            row.step = FS(row, "GameFontHighlightSmall", "CENTER", MUTED)
            row.step:SetPoint("TOP", row, "TOPLEFT", MID, -27)
            row.themName = FS(row, "GameFontNormal", "LEFT")
            row.themName:SetPoint("TOPLEFT", row, "TOPLEFT", RIGHT_EDGE, -7)
            row.themLevel = FS(row, "GameFontHighlightSmall", "LEFT", MUTED)
            row.themLevel:SetPoint("LEFT", row.themName, "RIGHT", 8, 0)
            row.themTrack, row.themFill = XPBar(row)
            row.themTrack:SetPoint("TOPLEFT", row, "TOPLEFT", RIGHT_EDGE, -30)
            row.themFill:SetPoint("LEFT", row.themTrack, "LEFT")
            row.far = FS(row, "GameFontHighlightSmall", "RIGHT", BODY)
            row.far:SetPoint("RIGHT", row, "LEFT", FAR_EDGE, 0)
        end,
        fill = function(row, r, _, partner)
            row.youName:SetText(r.youLabel)
            row.youName:SetTextColor(ClassColor(r.you, r.youClass))
            row.youLevel:SetText(LevelText(r.you, r.youName))
            SetXPBar(row.youFill, r.you)
            row.themName:SetText(r.themName ~= "" and r.themLabel or "Not set")
            row.themName:SetTextColor(ClassColor(r.them, r.themClass))
            row.themLevel:SetText(LevelText(r.them, r.themName))
            SetXPBar(row.themFill, r.them)
            local step, far = "", ""
            if r.status ~= "nodata" then
                if r.guideDiff then
                    step = "|cffe9c877Different guides|r"
                elseif r.sameGuide then
                    step = "Step " .. (r.you.step or "?") .. " / " .. (r.them.step or "?")
                else
                    step = "No guide"
                end
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
            row.step:SetText(step)
            row.far:SetText(far)
            local s = STATUS[r.status]
            row.status:SetText(s[1]:format(partner))
            row.status:SetTextColor(s[2], s[3], s[4])
            if r.status == "you" then row.pill:Show() else row.pill:Hide() end
        end,
    })
    function page:Refresh()
        self.themHeader:SetText(ns.PartnerLabel() .. "'s")
        return list:Refresh(TOP + 20) + 10
    end
end

------------------------------------------------------------------------
-- Quests: two to-do lists
------------------------------------------------------------------------

local QUEST_LINES = 22

local function BuildQuests()
    local page = Page("quests")
    page.leftTitle = FS(page, "GameFontNormal", "LEFT", GOLD)
    page.leftTitle:SetPoint("TOPLEFT", 22, -(TOP + 4))
    page.rightTitle = FS(page, "GameFontNormal", "LEFT", GOLD)
    page.rightTitle:SetPoint("TOPLEFT", 22 + HALF, -(TOP + 4))
    page.left = ListPanel(page, HALF, QUEST_LINES)
    page.left:SetPoint("TOPLEFT", 8, -(TOP + 20))
    page.right = ListPanel(page, HALF, QUEST_LINES)
    page.right:SetPoint("TOPLEFT", 8 + HALF, -(TOP + 20))
    local divider = Tex(page, "ARTWORK", 0.54, 0.42, 0.18, 1)
    divider:SetPoint("TOPLEFT", 8 + HALF, -(TOP + 2))
    divider:SetSize(1, QUEST_LINES * LINE_H + 34)

    local function column(mine)
        local e, add = Adder()
        local clear, waiting = {}, {}
        for i = 1, #ns.db.pairs do
            local r = ns.Compare(i)
            local c, other = r.you, r.them
            local need, hidden = r.youNeed, r.youHidden
            if not mine then c, other, need, hidden = r.them, r.you, r.themNeed, r.themHidden end
            if r.status == "nodata" or not r.questsKnown then
                local name = mine and r.youLabel or r.themLabel
                if name ~= "" then waiting[#waiting + 1] = name end
            elseif #need == 0 then
                clear[#clear + 1] = c.short
            else
                add(Colored(c) .. "  |cfff2a154" .. #need .. " to catch up with " .. ns.Mid(other) .. "|r")
                for _, id in ipairs(need) do add("     " .. ns.QuestTitle(id), id) end
                if hidden > 0 then add("     " .. hidden .. (hidden == 1 and " class or race quest hidden" or " class or race quests hidden"), nil, MUTED) end
                add("")
            end
        end
        local function names(label, list, color)
            for i = 1, #list, 3 do
                add((i == 1 and label or "     ") .. table.concat(list, ", ", i, math.min(i + 2, #list)) ..
                    (i + 2 < #list and "," or ""), nil, color)
            end
        end
        if #clear > 0 then names("Nothing to do on: ", clear, GOOD) end
        if #waiting > 0 then names("Not synced yet: ", waiting, MUTED) end
        if #e == 0 then add("No pairs yet.", nil, MUTED) end
        return e
    end
    function page:Refresh()
        self.leftTitle:SetText("For you to do")
        self.rightTitle:SetText("For " .. ns.PartnerLabel() .. " to do")
        self.left:Set(column(true))
        self.right:Set(column(false))
        return TOP + 20 + QUEST_LINES * LINE_H + 16 + 22
    end
    local hint = FS(page, "GameFontDisableSmall", "LEFT", MUTED)
    hint:SetPoint("TOPLEFT", 22, -(TOP + 20 + QUEST_LINES * LINE_H + 18))
    hint:SetText("Right-click a quest to ignore it. Scroll a list with the mouse wheel.")
end

------------------------------------------------------------------------
-- Gear: every slot for one pair
------------------------------------------------------------------------

local function FirstWord(name)
    return tostring(name or ""):match("^%s*(%S+)") or ""
end

local function BuildGear()
    local page = Page("gear")
    page.chips, page.selected = {}, nil
    local CHIP_W = (INNER - 3 * 6) / 4
    local panelTop = TOP + 60

    local function panel(x)
        local p = { rows = {} }
        p.name = FS(page, "GameFontNormal", "LEFT")
        p.name:SetPoint("TOPLEFT", x + 14, -panelTop)
        p.summary = FS(page, "GameFontHighlightSmall", "RIGHT", MUTED)
        p.summary:SetPoint("TOPRIGHT", page, "TOPLEFT", x + HALF - 14, -panelTop)
        for i, slot in ipairs(ns.SLOTS) do
            local row = CreateFrame("Button", nil, page)
            row:SetSize(HALF - 28, 15)
            row:SetPoint("TOPLEFT", x + 14, -(panelTop + 20 + (i - 1) * 15))
            row.slot = FS(row, "GameFontHighlightSmall", "LEFT", MUTED)
            row.slot:SetPoint("LEFT")
            row.slot:SetText(ns.SLOT_NAMES[slot])
            row.item = FS(row, "GameFontHighlightSmall", "LEFT")
            row.item:SetPoint("LEFT", 76, 0)
            row.item:SetWidth(HALF - 28 - 76 - 30)
            row.item:SetWordWrap(false)
            row.level = FS(row, "GameFontHighlightSmall", "RIGHT")
            row.level:SetPoint("RIGHT")
            row:SetScript("OnEnter", ItemTooltip)
            row:SetScript("OnLeave", HideTooltip)
            p.rows[i] = row
        end
        p.gifts = ListPanel(page, HALF, 4)
        p.gifts:SetPoint("TOPLEFT", x, -(panelTop + 20 + #ns.SLOTS * 15 + 4))
        return p
    end
    page.a, page.b = panel(8), panel(8 + HALF)
    local divider = Tex(page, "ARTWORK", 0.54, 0.42, 0.18, 1)
    divider:SetPoint("TOPLEFT", 8 + HALF, -panelTop)
    divider:SetSize(1, 20 + #ns.SLOTS * 15 + 4 + 4 * LINE_H + 16)

    local function fill(p, c, name, other)
        p.name:SetText(name ~= "" and name or "Not set")
        p.name:SetTextColor(ClassColor(c))
        local g = ns.GearSummary(c)
        p.summary:SetText(g and ("level " .. (c.level or "?") .. ", item level " .. g.avg) or
            (c and "Gear not synced yet" or "Not seen yet"))
        for i, slot in ipairs(ns.SLOTS) do
            local row = p.rows[i]
            row.itemId = nil
            if not g then
                row.item:SetText("")
                row.level:SetText("")
            else
                local state, id, ilvl = ns.SlotState(c, slot)
                if state == "empty" then
                    row.item:SetText("Empty")
                    row.item:SetTextColor(RED[1], RED[2], RED[3])
                    row.level:SetText("")
                elseif state == "none" then
                    row.item:SetText("-")
                    row.item:SetTextColor(0.45, 0.41, 0.35)
                    row.level:SetText("")
                else
                    local item = ns.ItemInfo(id)
                    local color = state == "low" and ORANGE or BODY
                    row.item:SetText(item and (state == "low" and item.name or item.link or item.name) or ("Item " .. id))
                    row.item:SetTextColor(color[1], color[2], color[3])
                    row.level:SetText(ilvl > 0 and ilvl or "")
                    row.level:SetTextColor(color[1], color[2], color[3])
                    row.itemId = id
                end
            end
        end
        local e, add = Adder()
        local list = c and other and ns.HandMeDowns(c, other)
        if not list then
            add("")
        elseif #list == 0 then
            add(other.long .. " is carrying nothing for " .. ns.Mid(c) .. ".", nil, MUTED)
        else
            add(other.long .. " is carrying (" .. #list .. "):", nil, GOLD)
            for _, it in ipairs(list) do add("   " .. it.text, nil, BODY, it.id) end
        end
        p.gifts:Set(e)
    end

    function page:Refresh()
        local n = #ns.db.pairs
        if not self.selected or self.selected > n then
            self.selected = ns.PairIndexFor(ns.db.chars[ns.PlayerKey()]) or 1
        end
        for i = 1, math.max(n, #self.chips) do
            local chip = self.chips[i]
            if not chip then
                chip = CreateFrame("Button", nil, page)
                chip:SetSize(CHIP_W, 22)
                chip:SetPoint("TOPLEFT", 8 + ((i - 1) % 4) * (CHIP_W + 6), -(TOP + 4 + math.floor((i - 1) / 4) * 26))
                chip.bg = Tex(chip, "BACKGROUND")
                chip.bg:SetAllPoints()
                chip.text = FS(chip, "GameFontHighlightSmall", "CENTER")
                chip.text:SetPoint("CENTER")
                chip:SetScript("OnClick", function()
                    self.selected = i
                    self.a.gifts.offset, self.b.gifts.offset = 0, 0
                    ns.RefreshUI()
                end)
                self.chips[i] = chip
            end
            if i > n then
                chip:Hide()
            else
                local r = ns.Compare(i)
                chip:Show()
                chip.text:SetText(r.youLabel .. (r.themName ~= "" and (" + " .. r.themLabel) or ""))
                if i == self.selected then
                    chip.bg:SetColorTexture(0.54, 0.42, 0.18, 1)
                    chip.text:SetTextColor(1, 0.95, 0.79)
                else
                    chip.bg:SetColorTexture(0.165, 0.13, 0.098, 1)
                    chip.text:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
                end
            end
        end
        local r = ns.Compare(self.selected)
        if r then
            fill(self.a, r.you, r.youLabel, r.them)
            fill(self.b, r.them, r.themName ~= "" and r.themLabel or "", r.you)
        end
        return panelTop + 20 + #ns.SLOTS * 15 + 4 + 4 * LINE_H + 16 + 10
    end
end

------------------------------------------------------------------------
-- Professions: skill bars with a marker for what the level allows
------------------------------------------------------------------------

local PROF_W = 150

local function ProfEntries(r, add)
    for _, c in ipairs({ r.you, r.them }) do
        if not c.x then
            add(c.long .. ": professions haven't synced yet.", nil, MUTED)
        elseif #c.x.profs == 0 then
            add(c.long .. ": no professions.", nil, GOLD)
        else
            local cap = ns.SkillCap(c.level)
            add(c.long .. " (level " .. (c.level or "?") .. ", can reach " .. cap .. "):", nil, GOLD)
            for _, p in ipairs(c.x.profs) do
                local text = "   " .. p[1] .. " " .. p[2] .. " / " .. p[3]
                if p[2] >= cap and cap > 0 then
                    add(text .. ". At the limit for this level.", nil, GOOD)
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
        add(fromChar.long .. " can craft for " .. ns.Mid(forChar) .. " (" .. #list .. "):", nil, GOLD)
        for _, it in ipairs(list) do add("   " .. it.text, nil, BODY, it.id) end
    end
    craft(r.you, r.them)
    craft(r.them, r.you)
    add("Recipes are read when a profession window is opened, so open each one once.", nil, MUTED)
end

local function BuildProfs()
    local page = Page("profs")
    Header(page, "Yours", "RIGHT", "TOPRIGHT", 420)
    page.themHeader = Header(page, "", "LEFT", "TOPLEFT", 444)
    local function bars(row, mirrored)
        local set = {}
        for i = 1, 2 do
            local y = -9 - (i - 1) * 17
            local b = {}
            b.track = Tex(row, "ARTWORK", 0.23, 0.18, 0.14, 1)
            b.track:SetSize(PROF_W, 7)
            b.fill = row:CreateTexture(nil, "OVERLAY")
            b.fill:SetHeight(7)
            b.cap = Tex(row, "OVERLAY", 1, 0.95, 0.79, 1)
            b.cap:SetSize(2, 13)
            b.label = FS(row, "GameFontHighlightSmall", mirrored and "RIGHT" or "LEFT", BODY)
            if mirrored then
                b.track:SetPoint("TOPRIGHT", row, "TOPLEFT", 270, y - 3)
                b.fill:SetPoint("RIGHT", b.track, "RIGHT")
                b.label:SetPoint("TOPRIGHT", row, "TOPLEFT", 112, y)
            else
                b.track:SetPoint("TOPLEFT", row, "TOPLEFT", 594, y - 3)
                b.fill:SetPoint("LEFT", b.track, "LEFT")
                b.label:SetPoint("TOPLEFT", row, "TOPLEFT", 752, y)
            end
            set[i] = b
        end
        return set
    end
    local function setBars(set, c, mirrored)
        local profs = c and c.x and c.x.profs
        local primary = profs and math.min(c.x.np or 2, #profs, 2) or 0
        local cap = ns.SkillCap(c and c.level)
        for i = 1, 2 do
            local b, p = set[i], profs and i <= primary and profs[i]
            if p then
                b.track:Show()
                b.cap:Show()
                b.cap:ClearAllPoints()
                local offset = PROF_W * math.min(cap, 300) / 300
                if mirrored then
                    b.cap:SetPoint("CENTER", b.track, "RIGHT", -offset, 0)
                else
                    b.cap:SetPoint("CENTER", b.track, "LEFT", offset, 0)
                end
                local width = PROF_W * math.min(p[2], 300) / 300
                if width >= 1 then
                    b.fill:Show()
                    b.fill:SetWidth(width)
                    local color = (cap > 0 and p[2] >= cap) and GOOD or GOLD
                    b.fill:SetColorTexture(color[1], color[2], color[3], 1)
                else
                    b.fill:Hide()
                end
                b.label:SetText(p[1] .. " " .. p[2])
                b.label:SetTextColor(BODY[1], BODY[2], BODY[3])
            else
                b.track:Hide()
                b.cap:Hide()
                b.fill:Hide()
                local text = ""
                if i == 1 then
                    if not c then text = "" elseif not profs then text = "Not synced" elseif primary == 0 then text = "No main professions" end
                end
                b.label:SetText(text)
                b.label:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
            end
        end
    end
    local list = PairList(page, {
        detailLines = 9,
        entries = ProfEntries,
        make = function(row)
            row.youName = FS(row, "GameFontNormal", "RIGHT")
            row.youName:SetPoint("RIGHT", row, "LEFT", 420, 0)
            row.themName = FS(row, "GameFontNormal", "LEFT")
            row.themName:SetPoint("LEFT", row, "LEFT", 444, 0)
            row.youBars, row.themBars = bars(row, true), bars(row, false)
        end,
        fill = function(row, r)
            row.youName:SetText(r.youLabel)
            row.youName:SetTextColor(ClassColor(r.you, r.youClass))
            row.themName:SetText(r.themName ~= "" and r.themLabel or "Not set")
            row.themName:SetTextColor(ClassColor(r.them, r.themClass))
            setBars(row.youBars, r.you, true)
            setBars(row.themBars, r.them, false)
        end,
    })
    local legend = FS(page, "GameFontDisableSmall", "LEFT", MUTED)
    legend:SetText("Bars run 0 to 300. The pale marker is the highest skill the character's level allows; a green bar has reached it. Click a pair for cooking, first aid, fishing and what each can craft for the other.")
    legend:SetWidth(INNER - 28)
    function page:Refresh()
        self.themHeader:SetText(ns.PartnerLabel() .. "'s")
        local y = list:Refresh(TOP + 20)
        legend:ClearAllPoints()
        legend:SetPoint("TOPLEFT", 22, -(y + 8))
        return y + 44
    end
end

------------------------------------------------------------------------
-- Gold: bars towards the mount
------------------------------------------------------------------------

local GOLD_W = 170
local MOUNT_COPPER = 100 * 10000
local FREE_MOUNT = { PALADIN = true, WARLOCK = true }

local function GoldEntries(r, add)
    for _, c in ipairs({ r.you, r.them }) do
        local line = ns.MountLine(c)
        if line then add(c.long .. ": " .. line) else add(c.long .. ": gold hasn't synced yet.", nil, MUTED) end
    end
end

local function BuildGold()
    local page = Page("gold")
    Header(page, "Yours, towards the 100g mount", "RIGHT", "TOPRIGHT", 408)
    page.themHeader = Header(page, "", "LEFT", "TOPLEFT", 424)
    Header(page, "Together", "RIGHT", "TOPRIGHT", FAR_EDGE + 6)
    local function side(row, mirrored)
        local s = {}
        s.name = FS(row, "GameFontNormal", mirrored and "RIGHT" or "LEFT")
        s.amount = FS(row, "GameFontHighlightSmall", mirrored and "RIGHT" or "LEFT", BODY)
        s.track = Tex(row, "ARTWORK", 0.23, 0.18, 0.14, 1)
        s.track:SetSize(GOLD_W, 11)
        s.fill = row:CreateTexture(nil, "OVERLAY")
        s.fill:SetHeight(11)
        s.free = FS(row, "GameFontHighlightSmall", mirrored and "RIGHT" or "LEFT", GOOD)
        if mirrored then
            s.name:SetPoint("RIGHT", row, "LEFT", 168, 0)
            s.amount:SetPoint("RIGHT", row, "LEFT", 230, 0)
            s.track:SetPoint("RIGHT", row, "LEFT", 408, 0)
            s.fill:SetPoint("RIGHT", s.track, "RIGHT")
            s.free:SetPoint("RIGHT", row, "LEFT", 408, 0)
        else
            s.track:SetPoint("LEFT", row, "LEFT", 424, 0)
            s.fill:SetPoint("LEFT", s.track, "LEFT")
            s.free:SetPoint("LEFT", row, "LEFT", 424, 0)
            s.amount:SetPoint("LEFT", row, "LEFT", 602, 0)
            s.name:SetPoint("LEFT", row, "LEFT", 664, 0)
            s.name:SetWidth(130)
            s.name:SetWordWrap(false)
        end
        return s
    end
    local function setSide(s, c, name)
        s.name:SetText(name ~= "" and name or "Not set")
        s.name:SetTextColor(ClassColor(c))
        s.track:Hide()
        s.fill:Hide()
        s.free:SetText("")
        s.amount:SetText("")
        if not (c and c.x) then
            s.free:SetText(c and "Not synced" or "")
            s.free:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
            return 0
        end
        local gold = c.x.gold or 0
        s.amount:SetText(ns.Money(gold))
        if FREE_MOUNT[c.class or ""] then
            s.free:SetText("Free class mount")
            s.free:SetTextColor(GOOD[1], GOOD[2], GOOD[3])
        else
            s.track:Show()
            local width = GOLD_W * math.min(gold, MOUNT_COPPER) / MOUNT_COPPER
            if width >= 1 then
                s.fill:Show()
                s.fill:SetWidth(width)
                local color = gold >= MOUNT_COPPER and GOOD or GOLD
                s.fill:SetColorTexture(color[1], color[2], color[3], 1)
            end
        end
        return gold
    end
    local list = PairList(page, {
        detailLines = 2,
        entries = GoldEntries,
        make = function(row)
            row.you, row.them = side(row, true), side(row, false)
            row.total = FS(row, "GameFontHighlightSmall", "RIGHT", GOLD)
            row.total:SetPoint("RIGHT", row, "LEFT", FAR_EDGE + 6, 0)
        end,
        fill = function(row, r)
            local a = setSide(row.you, r.you, r.youLabel)
            local b = setSide(row.them, r.them, r.themName ~= "" and r.themLabel or "")
            row.total:SetText((r.you and r.you.x and r.them and r.them.x) and ns.Money(a + b) or "")
        end,
    })
    local legend = FS(page, "GameFontDisableSmall", "LEFT", MUTED)
    function page:Refresh()
        self.themHeader:SetText(ns.PartnerLabel() .. "'s")
        local y = list:Refresh(TOP + 20)
        local total, count = 0, 0
        for _, c in pairs(ns.db.chars) do
            if c.x then total, count = total + (c.x.gold or 0), count + 1 end
        end
        legend:SetText("A full bar is 100g, the level 40 mount; green means there's enough. All " .. count ..
            " synced characters together: " .. ns.Money(total) .. ".")
        legend:ClearAllPoints()
        legend:SetPoint("TOPLEFT", 22, -(y + 8))
        return y + 30
    end
end

------------------------------------------------------------------------
-- Notes: a card per pair
------------------------------------------------------------------------

local CARD_H = 80

local function BuildNotes()
    local page = Page("notes")
    page.cards, page.editing = {}, nil
    local CARD_W = (INNER - 10) / 2
    local box = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetMaxLetters(200)
    box:SetSize(CARD_W - 36, 20)
    box:Hide()
    local function stop()
        page.editing = nil
        box:ClearFocus()
        box:Hide()
        ns.RefreshUI()
    end
    box:SetScript("OnEnterPressed", function(self)
        if page.editing then ns.SetNote(page.editing, self:GetText()) end
        stop()
    end)
    box:SetScript("OnEscapePressed", stop)
    page.box = box
    local hint = FS(page, "GameFontDisableSmall", "LEFT", MUTED)
    hint:SetText("Click a card to write or change its note. Press Enter to save, Escape to cancel. Your partner sees it after the next sync.")

    function page:Refresh()
        local n = #ns.db.pairs
        if self.editing and self.editing > n then self.editing = nil end
        for i = 1, math.max(n, #self.cards) do
            local card = self.cards[i]
            if not card then
                card = CreateFrame("Button", nil, page, TEMPLATE)
                card:SetSize(CARD_W, CARD_H)
                card:SetPoint("TOPLEFT", 8 + ((i - 1) % 2) * (CARD_W + 10), -(TOP + 8 + math.floor((i - 1) / 2) * (CARD_H + 8)))
                Backdrop(card, 0.165, 0.13, 0.098, 1)
                card.names = FS(card, "GameFontNormal", "LEFT")
                card.names:SetPoint("TOPLEFT", 12, -9)
                card.text = FS(card, "GameFontHighlightSmall", "LEFT", BODY)
                card.text:SetPoint("TOPLEFT", 12, -28)
                card.text:SetWidth(CARD_W - 24)
                card.text:SetHeight(26)
                card.text:SetJustifyV("TOP")
                card.by = FS(card, "GameFontDisableSmall", "LEFT", MUTED)
                card.by:SetPoint("BOTTOMLEFT", 12, 8)
                card:SetScript("OnClick", function()
                    self.editing = i
                    local note = ns.db.notes[ns.PairKey(i) or ""]
                    box:SetParent(card)
                    box:ClearAllPoints()
                    box:SetPoint("BOTTOMLEFT", 18, 6)
                    box:SetText(note and note.text or "")
                    box:Show()
                    box:SetFocus()
                    ns.RefreshUI()
                end)
                self.cards[i] = card
            end
            if i > n then
                card:Hide()
            else
                local r = ns.Compare(i)
                local note = ns.db.notes[ns.PairKey(i) or ""]
                card:Show()
                card.names:SetText(Colored(r.you, r.youLong, r.youClass) .. (r.themName ~= "" and
                    (" |cffb5a68cand|r " .. Colored(r.them, r.themLong, r.themClass)) or ""))
                if note and note.text ~= "" then
                    card.text:SetText(note.text)
                    card.text:SetTextColor(BODY[1], BODY[2], BODY[3])
                    local writer = ns.db.chars[ns.norm(note.by)]
                    card.by:SetText((writer and writer.long or note.by or "?") .. ", " .. ns.Ago(note.t):lower())
                else
                    card.text:SetText("No note. Click to write one.")
                    card.text:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
                    card.by:SetText("")
                end
                if self.editing == i then card.by:SetText("") end
            end
        end
        if not self.editing then box:Hide() end
        local y = TOP + 8 + math.ceil(n / 2) * (CARD_H + 8)
        hint:ClearAllPoints()
        hint:SetPoint("TOPLEFT", 22, -(y + 2))
        return y + 26
    end
end

------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------

local function Build()
    TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
    frame = CreateFrame("Frame", "DuoTrackerFrame", UIParent, TEMPLATE)
    frame:SetSize(W, 400)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
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

    updateButton = CreateFrame("Button", nil, frame, TEMPLATE)
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

    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(120, 24)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 124, -58)
        b.bg = Tex(b, "BACKGROUND")
        b.bg:SetAllPoints()
        b.text = FS(b, "GameFontHighlightSmall", "CENTER")
        b.text:SetPoint("CENTER")
        b.text:SetText(t[2])
        b:SetScript("OnClick", function()
            tab = t[1]
            ns.RefreshUI()
        end)
        tabButtons[i] = b
    end
    local rule = Tex(frame, "ARTWORK", 0.54, 0.42, 0.18, 1)
    rule:SetPoint("TOPLEFT", 2, -82)
    rule:SetPoint("TOPRIGHT", -2, -82)
    rule:SetHeight(1)

    BuildOverview()
    BuildQuests()
    BuildGear()
    BuildProfs()
    BuildGold()
    BuildNotes()
    frame:Hide()
end

function ns.RefreshUI()
    if not (frame and frame:IsShown()) then return end
    local partner = ns.PartnerLabel()
    info:SetText((ns.PartnerOnline() and (partner .. " is online. ") or (partner .. " is offline. ")) ..
        "Last sync: " .. ns.Ago(ns.db.lastSync):lower() .. ".")
    if ns.updateAvailable then
        updateButton.text:SetText("Update available: " .. ns.updateAvailable)
        updateButton:Show()
    else
        updateButton:Hide()
    end
    for i, t in ipairs(TABS) do
        local b, page = tabButtons[i], pages[t[1]]
        if t[1] == tab then
            b.bg:SetColorTexture(0.54, 0.42, 0.18, 1)
            b.text:SetTextColor(1, 0.95, 0.79)
            page:Show()
            local height = page:Refresh()
            page:SetHeight(height)
            frame:SetHeight(height)
        else
            b.bg:SetColorTexture(0.165, 0.13, 0.098, 1)
            b.text:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
            page:Hide()
        end
    end
end

function ns.ToggleUI()
    if not frame then Build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        ns.RefreshUI()
    end
end
