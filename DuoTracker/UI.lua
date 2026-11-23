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

local TABS = { { "overview", "Overview" }, { "gear", "Gear" },
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
    return e, function(text, color, itemId)
        color = color or BODY
        e[#e + 1] = { text = text, itemId = itemId, r = color[1], g = color[2], b = color[3] }
    end
end

-- A scrolling list of text lines. Hover an item line for its tooltip.
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
                line.itemId = entry.itemId
                line:Show()
            else
                line.itemId = nil
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

-- A list of every pair, one row each.
local function PairList(page, opts)
    local L = { rows = {} }
    function L:Refresh(top)
        local n = #ns.db.pairs
        local partner = ns.PartnerLabel()
        local y = top
        for i = 1, math.max(n, #self.rows) do
            local row = self.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, page)
                row:SetSize(INNER, ROW_H)
                row.bg = Tex(row, "BACKGROUND", 0, 0, 0, 0)
                row.bg:SetAllPoints()
                opts.make(row)
                self.rows[i] = row
            end
            if i > n then
                row:Hide()
            else
                row:Show()
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -y)
                y = y + ROW_H
                if i % 2 == 1 then
                    row.bg:SetColorTexture(0.165, 0.13, 0.098, 1)
                else
                    row.bg:SetColorTexture(0, 0, 0, 0)
                end
                opts.fill(row, ns.Compare(i), i, partner)
            end
        end
        return y
    end
    return L
end

local function LevelText(c, name)
    if name == "" then return "Click to choose" end
    return c and c.level and ("Level " .. c.level) or "Not seen yet"
end

------------------------------------------------------------------------
-- Choosing a character for one side of a pair
------------------------------------------------------------------------

local PICK_W, PICK_ROW, PICK_ROWS = 330, 20, 16
local picker

local function PickerEntries(index, column, mine)
    local e = {}
    local partner = ns.PartnerLabel()
    for _, cand in ipairs(ns.Candidates(mine)) do
        local c = cand.c
        local note
        if cand.pair == index then
            note = "here now"
        elseif cand.pair then
            local r = ns.Compare(cand.pair)
            local other = mine and r.themName or r.youName
            note = "with " .. (other ~= "" and ((mine and r.themLabel or r.youLabel)) or "nobody")
        else
            note = "not paired"
        end
        e[#e + 1] = {
            text = Colored(c, c.name) .. "  |cffb5a68cLevel " .. (c.level or "?") .. "|r",
            note = note,
            checked = mine and not ns.Private(c),
            toggle = mine and function(on) ns.SetShared(cand.key, on) end or nil,
            pick = function() ns.AssignSlot(index, column, c.name) end,
        }
    end
    if #e == 0 then
        e[1] = { text = mine and "No characters seen yet. Log in on each one once." or
            ("No characters from " .. partner .. " yet. They show up after a sync."), muted = true }
    end
    e[#e + 1] = { text = "Leave this side empty", muted = true, pick = function() ns.AssignSlot(index, column, "") end }
    e[#e + 1] = { text = "Remove this pair", red = true, pick = function() ns.RemovePair(index) end }
    return e
end

local function RenderPicker()
    local p = picker
    local e = PickerEntries(p.index, p.column, p.mine)
    p.offset = math.max(0, math.min(p.offset, #e - PICK_ROWS))
    local shown = math.min(#e, PICK_ROWS)
    for i = 1, PICK_ROWS do
        local row, entry = p.rows[i], e[p.offset + i]
        if entry and i <= shown then
            row:Show()
            row.name:SetText(entry.text)
            local color = entry.red and RED or entry.muted and MUTED or BODY
            row.name:SetTextColor(color[1], color[2], color[3])
            row.note:SetText(entry.note or "")
            row.pick, row.toggle = entry.pick, entry.toggle
            if entry.toggle then
                row.check:Show()
                row.check:SetChecked(entry.checked)
            else
                row.check:Hide()
            end
        else
            row:Hide()
        end
    end
    p.more:SetText(#e > PICK_ROWS and "Scroll for more" or "")
    p:SetHeight(48 + shown * PICK_ROW + (#e > PICK_ROWS and 14 or 0))
end

local function BuildPicker()
    picker = CreateFrame("Frame", "DuoTrackerPicker", frame, TEMPLATE)
    picker:SetWidth(PICK_W)
    picker:SetFrameStrata("DIALOG")
    picker:SetClampedToScreen(true)
    picker:EnableMouse(true)
    Backdrop(picker, 0.09, 0.07, 0.05, 0.98)
    picker.offset = 0
    picker.title = FS(picker, "GameFontNormal", "LEFT", GOLD)
    picker.title:SetPoint("TOPLEFT", 10, -9)
    picker.help = FS(picker, "GameFontDisableSmall", "LEFT", MUTED)
    picker.help:SetPoint("TOPLEFT", 10, -26)
    picker.rows = {}
    for i = 1, PICK_ROWS do
        local row = CreateFrame("Button", nil, picker)
        row:SetSize(PICK_W - 16, PICK_ROW)
        row:SetPoint("TOPLEFT", 8, -(42 + (i - 1) * PICK_ROW))
        local hl = Tex(row, "HIGHLIGHT", 1, 1, 1, 0.08)
        hl:SetAllPoints()
        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(20, 20)
        row.check:SetPoint("LEFT")
        row.check:SetScript("OnClick", function(self)
            if row.toggle then row.toggle(self:GetChecked() and true or false) end
        end)
        row.name = FS(row, "GameFontHighlightSmall", "LEFT")
        row.name:SetPoint("LEFT", 24, 0)
        row.note = FS(row, "GameFontDisableSmall", "RIGHT", MUTED)
        row.note:SetPoint("RIGHT", -4, 0)
        row:SetScript("OnClick", function()
            if row.pick then
                local pick = row.pick
                picker:Hide()
                pick()
            end
        end)
        picker.rows[i] = row
    end
    picker.more = FS(picker, "GameFontDisableSmall", "RIGHT", MUTED)
    picker.more:SetPoint("BOTTOMRIGHT", -8, 4)
    picker:EnableMouseWheel(true)
    picker:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, self.offset - delta * 2)
        RenderPicker()
    end)
    if UISpecialFrames then table.insert(UISpecialFrames, "DuoTrackerPicker") end
    picker:Hide()
end

-- Opens the character list for one side of pair `index`; `column` is that side's slot in the pair.
function ns.OpenPicker(anchor, index, column, mine)
    if not picker then BuildPicker() end
    if picker:IsShown() and picker.index == index and picker.mine == mine then
        picker:Hide()
        return
    end
    picker.index, picker.column, picker.mine, picker.offset = index, column, mine, 0
    picker.title:SetText(mine and "Your character for this pair" or (ns.PartnerLabel() .. "'s character for this pair"))
    picker.help:SetText(mine and ("Tick to share with " .. ns.PartnerLabel() .. ". Unticked ones stay on this PC.")
        or "Click one to put it in this pair.")
    picker:ClearAllPoints()
    if anchor then picker:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2) else picker:SetPoint("CENTER") end
    picker:Show()
    RenderPicker()
end

-- An invisible button over a name in a row; click opens the picker for that side.
local function PickButton(row, theirs)
    local b = CreateFrame("Button", nil, row)
    b:SetSize(theirs and 250 or 230, 24)
    local hl = Tex(b, "HIGHLIGHT", 1, 1, 1, 0.06)
    hl:SetAllPoints()
    b:SetScript("OnClick", function(self)
        if self.index then ns.OpenPicker(self, self.index, self.column, not theirs) end
    end)
    b:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(theirs and "Click to choose which of your partner's characters goes here." or
            "Click to choose which of your characters goes here, and which ones you share.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", HideTooltip)
    return b
end

------------------------------------------------------------------------
-- Overview: head to head
------------------------------------------------------------------------

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
    Header(page, "Synced", "RIGHT", "TOPRIGHT", FAR_EDGE)
    local list = PairList(page, {
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
            row.youPick = PickButton(row, false)
            row.youPick:SetPoint("TOPRIGHT", row, "TOPLEFT", LEFT_EDGE + 6, -2)
            row.themPick = PickButton(row, true)
            row.themPick:SetPoint("TOPLEFT", row, "TOPLEFT", RIGHT_EDGE - 6, -2)
        end,
        fill = function(row, r, i, partner)
            row.youPick.index, row.youPick.column = i, r.youColumn
            row.themPick.index, row.themPick.column = i, r.themColumn
            row.youName:SetText(r.youName ~= "" and r.youLabel or "Not set")
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
                far = ns.Ago(r.them.synced) -- when this character's data last arrived
            end
            row.step:SetText(step)
            row.far:SetText(far)
            local s = STATUS[r.status]
            row.status:SetText(s[1]:format(partner))
            row.status:SetTextColor(s[2], s[3], s[4])
            if r.status == "you" then row.pill:Show() else row.pill:Hide() end
        end,
    })
    local add = CreateFrame("Button", nil, page, TEMPLATE)
    add:SetSize(130, 22)
    Backdrop(add, 0.165, 0.13, 0.098, 1)
    add.text = FS(add, "GameFontHighlightSmall", "CENTER", GOLD)
    add.text:SetPoint("CENTER")
    add.text:SetText("+ Add a pair")
    add:SetScript("OnClick", function() ns.AddPair() end)
    local hint = FS(page, "GameFontDisableSmall", "LEFT", MUTED)
    hint:SetText("Click a character to change who's in the pair.")
    function page:Refresh()
        self.themHeader:SetText(ns.PartnerLabel() .. "'s")
        local y = list:Refresh(TOP + 20) + 8
        add:ClearAllPoints()
        add:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -y)
        hint:ClearAllPoints()
        hint:SetPoint("LEFT", add, "RIGHT", 12, 0)
        return y + 32
    end
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
            add(other.long .. " is carrying nothing for " .. ns.Mid(c) .. ".", MUTED)
        else
            add(other.long .. " is carrying (" .. #list .. "):", GOLD)
            for _, it in ipairs(list) do add("   " .. it.text, BODY, it.id) end
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
    legend:SetText("Bars run 0 to 300. The pale marker is the highest skill the character's level allows; a green bar has reached it.")
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
        if ns.FREE_MOUNT[c.class or ""] then
            s.free:SetText("Free class mount")
            s.free:SetTextColor(GOOD[1], GOOD[2], GOOD[3])
        else
            s.track:Show()
            local width = GOLD_W * math.min(gold, ns.MOUNT_COPPER) / ns.MOUNT_COPPER
            if width >= 1 then
                s.fill:Show()
                s.fill:SetWidth(width)
                local color = gold >= ns.MOUNT_COPPER and GOOD or GOLD
                s.fill:SetColorTexture(color[1], color[2], color[3], 1)
            end
        end
        return gold
    end
    local list = PairList(page, {
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
                    local who = (writer and writer.long) or (note.by ~= "" and note.by) or "Written"
                    card.by:SetText(who .. ", " .. ns.Ago(note.t):lower())
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
    updateButton:SetSize(210, 22)
    updateButton:SetPoint("TOPLEFT", 10, -10)
    Backdrop(updateButton, 0.95, 0.63, 0.33, 1)
    updateButton.text = FS(updateButton, "GameFontHighlightSmall", "CENTER", { 0.12, 0.10, 0.07 })
    updateButton.text:SetPoint("CENTER")
    updateButton:SetScript("OnClick", function()
        -- The background updater downloads new versions; a reload makes the game load them.
        ns.db.reloadedFor = ns.updateAvailable
        if ReloadUI then
            ReloadUI()
        else
            ns.Print("Type /reload to load version " .. tostring(ns.updateAvailable) .. ".")
        end
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
        b:SetScript("OnClick", function() ns.ShowTab(t[1]) end)
        tabButtons[i] = b
    end
    local rule = Tex(frame, "ARTWORK", 0.54, 0.42, 0.18, 1)
    rule:SetPoint("TOPLEFT", 2, -82)
    rule:SetPoint("TOPRIGHT", -2, -82)
    rule:SetHeight(1)

    BuildOverview()
    BuildGear()
    BuildProfs()
    BuildGold()
    BuildNotes()
    frame:Hide()
end

function ns.RefreshUI()
    if not (frame and frame:IsShown()) then return end
    if picker and picker:IsShown() then
        if picker.index > #ns.db.pairs then picker:Hide() else RenderPicker() end
    end
    local partner = ns.PartnerLabel()
    local st = ns.db.sync
    local text = (ns.PartnerOnline() and (partner .. " is online") or (partner .. " is offline")) ..
        ", last heard from " .. (st.lastIn and ns.Ago(st.lastIn.at):lower() or "never") ..
        (st.partnerVersion and (" (version " .. st.partnerVersion .. ")") or "") .. "."
    local drop = st.lastDrop and st.drops[st.lastDrop]
    if drop and time() - drop.at < 3600 then
        text = text .. "\n|cfff2a154Sync problem " .. ns.Ago(drop.at):lower() .. ": " .. ns.DropText(st.lastDrop) ..
            ". Type /duo sync for details.|r"
    end
    info:SetText(text)
    if ns.updateAvailable then
        updateButton.text:SetText("Update " .. ns.updateAvailable .. ": click to reload")
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

-- Switches the window to one of the TABS by its id ("overview", "gear", ...).
function ns.ShowTab(id)
    tab = id
    ns.RefreshUI()
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
