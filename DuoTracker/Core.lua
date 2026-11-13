-- Duo Tracker: data, comparison and sync.
local ADDON, ns = ...

local PREFIX = "DuoTrk"
local PROTO = 1
local CHUNK = 220          -- bytes of payload per addon message
local SEND_INTERVAL = 0.25 -- seconds between outgoing messages

-- The built-in pairs. Either side of a pair can be yours; the addon works out
-- which by seeing which characters log in on this account.
ns.DEFAULT_PAIRS = {
    { "Holy Cowabunga", "Burt Bacharach" },
    { "Marks Mum", "Rejis Mum" },
    { "Reji Planty", "Marjorie Dawes" },
    { "Marks Dad", "Priest Priestington" },
    { "Marks Friend", "Mooey Mooerson" },
    { "Marks Child", "Rejis Dad" },
    { "Grumpy Runt", "Dude Mcdrude" },
    { "Marks Uncle", "" }, -- Frost Mage not named yet: /duo pair Marks Uncle = Name
}

local db
local me                 -- snapshot of the character that is logged in
local partner            -- { kind = "BN", id = n } or { kind = "PARTY" }
local queue, inbox = {}, {}
local msgSeq = math.random(1, 90000)
local dirty, questDirty = false, false
local helloAt = 0
local summaryShown
local untitled = {} -- completed-quest flags that aren't real quests (no title)
local lastTry = 0
local versionWarned

local function MyVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local v = get and get(ADDON, "Version")
    return type(v) == "string" and v or "0"
end

local function IsNewer(theirs, mine)
    local a, b = {}, {}
    for n in tostring(theirs):gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in tostring(mine):gmatch("%d+") do b[#b + 1] = tonumber(n) end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function Print(text)
    print("|cffe8c36a[Duo]|r " .. text)
end
ns.Print = Print

local function norm(name)
    return (tostring(name or ""):lower():gsub("%s+", ""))
end
ns.norm = norm

local function esc(s)
    return (tostring(s or ""):gsub("[%%~|%^;,:#]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function split(s, sep)
    local out, pos = {}, 1
    while true do
        local a, b = s:find(sep, pos, true)
        if not a then
            out[#out + 1] = s:sub(pos)
            break
        end
        out[#out + 1] = s:sub(pos, a - 1)
        pos = b + 1
    end
    return out
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        local d = n % 36
        s = DIGITS:sub(d + 1, d + 1) .. s
        n = (n - d) / 36
    end
    return s
end

local function nilIfEmpty(s)
    if s == nil or s == "" then return nil end
    return s
end

local function Changed()
    if ns.RefreshUI then ns.RefreshUI() end
    if ns.UpdateBadge then ns.UpdateBadge() end
end

------------------------------------------------------------------------
-- Reading this character
------------------------------------------------------------------------

local function plain(v)
    -- Guards against the client's protected ("secret") values.
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- WoW Forever characters have a first name and a surname. UnitName returns
-- them as two values, so they are joined here ("Holy", "Cowabunga").
local function FullName(unit)
    local first, last = UnitName(unit)
    first, last = plain(first), plain(last)
    if type(first) ~= "string" or first == "" then return nil end
    if type(last) == "string" and last ~= "" then return first .. " " .. last end
    return first
end

function ns.PlayerKey()
    return norm(FullName("player"))
end

local function ReadRXP()
    local R, cd = _G.RXP, _G.RXPCData
    local group, name, step, steps, guide
    if type(R) == "table" and type(R.currentGuide) == "table" and not R.currentGuide.empty then
        guide = R.currentGuide
        group, name = guide.group, guide.name
        if type(guide.steps) == "table" then steps = #guide.steps end
        if type(R.GetGuideProgress) == "function" then
            local ok, s = pcall(R.GetGuideProgress)
            if ok then step = tonumber(s) end
        end
    end
    if type(cd) == "table" then
        name = name or cd.currentGuideName
        group = group or cd.currentGuideGroup
        step = step or tonumber(cd.currentStep)
    end
    local cfg
    local profile = type(R) == "table" and type(R.settings) == "table" and R.settings.profile
    if type(profile) == "table" then
        local parts = {}
        if profile.xprate ~= nil then parts[#parts + 1] = "XP rate " .. tostring(profile.xprate) end
        if profile.enableGroupQuests ~= nil then
            parts[#parts + 1] = "group quests " .. (profile.enableGroupQuests and "on" or "off")
        end
        if type(profile.dungeons) == "table" then
            local d = {}
            for k, v in pairs(profile.dungeons) do
                if v then d[#d + 1] = tostring(k) end
            end
            table.sort(d)
            parts[#parts + 1] = "dungeons " .. (#d > 0 and table.concat(d, "+") or "none")
        end
        cfg = table.concat(parts, " / ")
    end
    return type(group) == "string" and group or nil, type(name) == "string" and name or nil,
        step, steps, nilIfEmpty(cfg), guide
end

-- Remembers which quests each RestedXP guide contains for this character.
-- Guides drop steps that don't apply to your class or race, so a quest that
-- is in your partner's copy of a guide but not in yours is class or race only.
local function LearnGuideQuests(c, group, name, guide)
    if not (guide and name and type(guide.steps) == "table") then return false end
    local label = (group or "") .. " / " .. name
    c.guides = c.guides or {}
    c.gq = c.gq or {}
    local gi
    for i, n in ipairs(c.guides) do
        if n == label then gi = i break end
    end
    if not gi then
        gi = #c.guides + 1
        c.guides[gi] = label
    end
    local added = false
    for _, step in ipairs(guide.steps) do
        if type(step) == "table" and type(step.elements) == "table" then
            for _, el in ipairs(step.elements) do
                local q = type(el) == "table" and el.questId
                if type(q) == "number" and not c.gq[q] then
                    c.gq[q] = gi
                    added = true
                end
            end
        end
    end
    return added
end

local function ScanQuests(c)
    local ids
    if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
        ids = C_QuestLog.GetAllCompletedQuestIDs()
    end
    if type(ids) ~= "table" then return false end
    local old = c.done or {}
    local done, changed, count = {}, false, 0
    for _, id in ipairs(ids) do
        done[id] = true
        count = count + 1
        if not old[id] then changed = true end
    end
    if not changed then
        local oldCount = 0
        for _ in pairs(old) do oldCount = oldCount + 1 end
        changed = oldCount ~= count
    end
    if changed or not c.done then
        c.done = done
        return true
    end
    return false
end

local lastGuideLabel
local function Snapshot(scanQuests)
    local name = FullName("player")
    if not name then return end
    local key = norm(name)
    local c = db.chars[key] or {}
    db.chars[key] = c
    me = c
    c.mine = true
    c.name = name
    local changed = false
    local function set(field, value)
        value = plain(value)
        if value ~= nil and c[field] ~= value then
            c[field] = value
            changed = true
        end
    end
    local _, class = UnitClass("player")
    set("class", class)
    set("level", UnitLevel("player"))
    set("xp", UnitXP("player"))
    set("xpmax", UnitXPMax("player"))
    local ok, group, guideName, step, steps, cfg, guide = pcall(ReadRXP)
    if ok then
        if c.group ~= group or c.guide ~= guideName or c.cfg ~= cfg then
            c.group, c.guide, c.cfg = group, guideName, cfg
            changed = true
        end
        if step then set("step", step) end
        if steps then set("steps", steps) end
        local label = guideName and ((group or "") .. " / " .. guideName)
        if label and label ~= lastGuideLabel then
            lastGuideLabel = label
            local okLearn, added = pcall(LearnGuideQuests, c, group, guideName, guide)
            if okLearn and added then
                c.qrev = time()
                questDirty = true
            end
        end
    end
    if scanQuests or not c.done then
        local okScan, questsChanged = pcall(ScanQuests, c)
        if okScan and questsChanged then
            c.qrev = time()
            questDirty = true
        end
    end
    c.qrev = c.qrev or time()
    if changed or not c.rev then
        c.rev = time()
        c.seen = time()
        dirty = true
        Changed()
    end
end

------------------------------------------------------------------------
-- Comparing a pair
------------------------------------------------------------------------

local function HasGuide(c, label)
    for _, n in ipairs(c.guides or {}) do
        if n == label then return true end
    end
    return false
end

-- Quests `have` has completed that `need` has not.
local function Needs(need, have)
    local list, hidden = {}, 0
    if not (need.done and have.done) then return list, hidden end
    for id in pairs(have.done) do
        if not need.done[id] and not db.ignored[id] and not untitled[id] then
            local gi = have.gq and have.gq[id]
            local label = gi and have.guides and have.guides[gi]
            if label and HasGuide(need, label) and not (need.gq and need.gq[id]) then
                hidden = hidden + 1 -- class or race quest: same guide, not in theirs
            else
                list[#list + 1] = id
            end
        end
    end
    table.sort(list)
    return list, hidden
end

-- Which side of the pair list belongs to this account: 1 or 2. Each known
-- character votes, so pairs with no data yet still show the right way round.
local function MySide()
    local votes = 0
    for _, p in ipairs(db.pairs) do
        local a, b = db.chars[norm(p[1])], db.chars[norm(p[2])]
        if p[1] ~= "" and a then votes = votes + (a.mine and 1 or -1) end
        if p[2] ~= "" and b then votes = votes + (b.mine and -1 or 1) end
    end
    return votes < 0 and 2 or 1
end

-- Characters are shown by class rather than by name. These are the classes of
-- the built-in pairs, used until a character has logged in and reported its own.
local KNOWN_CLASS = {
    holycowabunga = "DRUID", burtbacharach = "HUNTER", marksmum = "ROGUE", rejismum = "WARRIOR",
    rejiplanty = "WARRIOR", marjoriedawes = "ROGUE", marksdad = "WARLOCK", priestpriestington = "PRIEST",
    marksfriend = "PALADIN", mooeymooerson = "SHAMAN", markschild = "PRIEST", rejisdad = "PALADIN",
    grumpyrunt = "MAGE", dudemcdrude = "DRUID", marksuncle = "HUNTER",
}

local function ClassOf(c, name)
    return (c and c.class) or KNOWN_CLASS[norm(name)]
end

local function ClassName(token)
    local names = LOCALIZED_CLASS_NAMES_MALE
    return (names and names[token]) or (token:sub(1, 1) .. token:sub(2):lower())
end

-- "Druid", or "Druid (Holy)" when the same account has two of that class in the pair list.
local function ShortLabel(c, name, column)
    local class = ClassOf(c, name)
    if not class or name == "" then return name end
    local same = 0
    for _, p in ipairs(db.pairs) do
        local other = p[column]
        if other and other ~= "" and ClassOf(db.chars[norm(other)], other) == class then same = same + 1 end
    end
    local label = ClassName(class)
    if same > 1 then label = label .. " (" .. (name:match("^%s*(%S+)") or name) .. ")" end
    return label
end

-- Mid-sentence form of a character's long label: "your Druid", "Mark's Hunter".
function ns.Mid(c)
    local long = c and (c.long or c.name) or "?"
    return (long:gsub("^Your ", "your "))
end

function ns.Compare(index)
    local p = db.pairs[index]
    if not p then return nil end
    local nameA, nameB = p[1] or "", p[2] or ""
    local a, b = db.chars[norm(nameA)], db.chars[norm(nameB)]
    if nameA == "" then a = nil end
    if nameB == "" then b = nil end
    local columnA, columnB = 1, 2
    local swap
    if (a and a.mine) or (b and not b.mine) then
        swap = false
    elseif (b and b.mine) or (a and not a.mine) then
        swap = true
    else
        swap = MySide() == 2
    end
    if swap then
        a, b = b, a
        nameA, nameB = nameB, nameA
        columnA, columnB = 2, 1
    end
    local youLabel = ShortLabel(a, a and a.name or nameA, columnA)
    local themLabel = ShortLabel(b, b and b.name or nameB, columnB)
    local youLong = "Your " .. youLabel
    local themLong = nameB ~= "" and (ns.PartnerLabel() .. "'s " .. themLabel) or ""
    if a then a.short, a.long = youLabel, youLong end
    if b then b.short, b.long = themLabel, themLong end
    local r = {
        you = a, them = b,
        youName = a and a.name or nameA,
        themName = b and b.name or nameB,
        youLabel = youLabel, themLabel = themLabel, youLong = youLong, themLong = themLong,
        youClass = ClassOf(a, nameA), themClass = ClassOf(b, nameB),
        youNeed = {}, themNeed = {}, youHidden = 0, themHidden = 0,
        status = "nodata",
    }
    if not (a and b and a.level and b.level) then return r end
    local youBehind, themBehind = false, false
    if a.level < b.level then youBehind = true elseif b.level < a.level then themBehind = true end
    if a.guide and b.guide then
        if a.guide == b.guide and (a.group or "") == (b.group or "") then
            r.sameGuide = true
            if a.step and b.step then
                if a.step < b.step then youBehind = true elseif b.step < a.step then themBehind = true end
            end
        else
            r.guideDiff = true
        end
    end
    if a.cfg and b.cfg and a.cfg ~= b.cfg then r.cfgDiff = true end
    r.youNeed, r.youHidden = Needs(a, b)
    r.themNeed, r.themHidden = Needs(b, a)
    r.questsKnown = a.done ~= nil and b.done ~= nil
    if #r.youNeed > 0 then youBehind = true end
    if #r.themNeed > 0 then themBehind = true end
    if youBehind and themBehind then
        r.status = "mixed"
    elseif youBehind then
        r.status = "you"
    elseif themBehind then
        r.status = "them"
    else
        r.status = "ok"
    end
    return r
end

ns.esc, ns.unesc, ns.split, ns.plain, ns.Changed = esc, unesc, split, plain, Changed
function ns.Me() return me end

function ns.PartnerLabel()
    return db.partnerName or "Partner"
end

function ns.Ago(t)
    if not t then return "Never" end
    local s = time() - t
    if s < 90 then return "Just now" end
    if s < 3600 then return math.floor(s / 60) .. "m ago" end
    if s < 86400 then return math.floor(s / 3600) .. "h ago" end
    return math.floor(s / 86400) .. "d ago"
end

function ns.XPPercent(c)
    if c and c.xp and c.xpmax and c.xpmax > 0 then
        return math.floor(c.xp / c.xpmax * 100 + 0.5)
    end
    return 0
end

local titleAsked = {}
function ns.QuestTitle(id)
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
    if title and title ~= "" then return title end
    if not titleAsked[id] and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        titleAsked[id] = true
        C_QuestLog.RequestLoadQuestByID(id)
    end
    return "Quest " .. id
end

function ns.Ignore(id)
    db.ignored[id] = true
    Changed()
end

function ns.PairIndexFor(c)
    if not c then return nil end
    local key = norm(c.name)
    for i, p in ipairs(db.pairs) do
        if norm(p[1]) == key or norm(p[2]) == key then return i end
    end
end

local function SummaryLines()
    local i = ns.PairIndexFor(me)
    if not i then return nil end
    local r = ns.Compare(i)
    local lines = {}
    if r.status == "nodata" then
        local other = r.themName ~= "" and r.themLong or "your partner's character"
        lines[1] = "No data for " .. other .. " yet. It syncs when you're both online."
        return lines
    end
    lines[1] = r.youLong .. " and " .. r.themLong .. ", synced " .. ns.Ago(r.them.synced):lower() .. "."
    local a, b = r.you, r.them
    local detail = "level " .. a.level .. " vs " .. b.level
    if r.sameGuide and a.step and b.step then
        detail = detail .. ", guide step " .. a.step .. " vs " .. b.step
    end
    local head = ({
        you = "|cfff2a154You're behind:|r ",
        them = "|cffa9c8fa" .. ns.PartnerLabel() .. " is behind:|r ",
        mixed = "|cffffe066You're each behind on something:|r ",
        ok = "|cff7fd1c2In step:|r ",
    })[r.status]
    lines[#lines + 1] = head .. detail .. "."
    if r.guideDiff then
        lines[#lines + 1] = "You're on different RestedXP guides, so steps can't be compared."
    end
    local function questLine(list, who)
        if #list == 0 then return end
        local names = {}
        for n = 1, math.min(#list, 5) do names[n] = "[" .. ns.QuestTitle(list[n]) .. "]" end
        local more = #list > 5 and (" and " .. (#list - 5) .. " more") or ""
        lines[#lines + 1] = #list .. (#list == 1 and " quest for " or " quests for ") .. who ..
            " to catch up: |cfff4dda0" .. table.concat(names, " ") .. "|r" .. more
    end
    questLine(r.youNeed, "you")
    questLine(r.themNeed, ns.PartnerLabel())
    lines[#lines + 1] = "|cffa3abb8Type /duo to see all pairs.|r"
    return lines
end

ns.SummaryLines = SummaryLines
ns.MyVersion = MyVersion

local function PrintSummaryNow(onlyIfNew)
    local lines = SummaryLines()
    if not lines then
        if not onlyIfNew then Print("This character isn't in a pair. Type /duo to see all pairs.") end
        return
    end
    local text = table.concat(lines, "\n")
    if onlyIfNew and text == summaryShown then return end
    summaryShown = text
    for _, line in ipairs(lines) do Print(line) end
end

function ns.PrintSummary(onlyIfNew)
    SummaryLines() -- asks the game for any quest names it hasn't loaded yet
    C_Timer.After(1.5, function() PrintSummaryNow(onlyIfNew) end)
end

------------------------------------------------------------------------
-- Messages
------------------------------------------------------------------------

ns.handlers = {} -- extra message kinds, added by Extras.lua

local function Send(target, text)
    if not target then return end
    msgSeq = msgSeq + 1
    local n = math.ceil(#text / CHUNK)
    for i = 1, n do
        queue[#queue + 1] = { target, "M#" .. msgSeq .. "#" .. i .. "#" .. n .. "#" ..
            text:sub((i - 1) * CHUNK + 1, i * CHUNK) }
    end
end

function ns.SendToPartner(text)
    if partner then Send(partner, text) end
end

local function Pump()
    local item = table.remove(queue, 1)
    if not item then return end
    local target, text = item[1], item[2]
    if target.kind == "BN" then
        if BNSendGameData then pcall(BNSendGameData, target.id, PREFIX, text) end
    elseif target.kind == "PARTY" then
        if IsInGroup and IsInGroup() and C_ChatInfo and C_ChatInfo.SendAddonMessage then
            pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "PARTY")
        end
    end
end

local function BuildHello(wantReply)
    local parts = {}
    for key, c in pairs(db.chars) do
        parts[#parts + 1] = esc(key) .. ":" .. (c.rev or 0) .. ":" .. (c.qrev or 0)
    end
    return "H~" .. PROTO .. "~" .. (wantReply and 1 or 0) .. "~" .. table.concat(parts, ",") .. "~" .. esc(MyVersion()) ..
        "~" .. (ns.HelloExtra and ns.HelloExtra() or "")
end

local function BuildStatus(key, c)
    return table.concat({ "S", esc(key), esc(c.name), esc(c.class), c.level or 0, c.xp or 0,
        c.xpmax or 0, esc(c.group), esc(c.guide), c.step or 0, c.steps or 0, esc(c.cfg),
        c.rev or 0 }, "~")
end

local function EncodeIds(ids, gq)
    table.sort(ids)
    local out, prev = {}, 0
    for i, id in ipairs(ids) do
        local gi = gq and gq[id]
        out[i] = b36(id - prev) .. (gi and ("." .. gi) or "")
        prev = id
    end
    return table.concat(out, ",")
end

local function BuildQuests(key, c)
    local done, pending, guides = {}, {}, {}
    for id in pairs(c.done or {}) do done[#done + 1] = id end
    for id in pairs(c.gq or {}) do
        if not (c.done and c.done[id]) then pending[#pending + 1] = id end
    end
    for i, n in ipairs(c.guides or {}) do guides[i] = esc(n) end
    return table.concat({ "Q", esc(key), c.qrev or 0, table.concat(guides, "^"),
        EncodeIds(done, c.gq), EncodeIds(pending, c.gq) }, "~")
end

ns.EncodeIds = EncodeIds

local function DecodeIds(data, into, gq)
    local prev = 0
    for tok in data:gmatch("[^,]+") do
        local d, g = tok:match("^(%w+)%.?(%d*)$")
        local delta = d and tonumber(d, 36)
        if not delta then return end
        prev = prev + delta
        if into then into[prev] = true end
        if g ~= "" then gq[prev] = tonumber(g) end
    end
end

ns.DecodeIds = DecodeIds

local function SendChanges(known)
    -- Sends each of this account's characters the partner doesn't have the latest of.
    for key, c in pairs(db.chars) do
        if c.mine then
            local k = known[key]
            if not k or k.rev ~= (c.rev or 0) then Send(partner, BuildStatus(key, c)) end
            if c.done and (not k or k.qrev ~= (c.qrev or 0)) then Send(partner, BuildQuests(key, c)) end
        end
    end
end

local summaryTimer
local function AfterSync()
    db.lastSync = time()
    Changed()
    if not summaryTimer then
        summaryTimer = true
        C_Timer.After(4, function()
            summaryTimer = nil
            ns.PrintSummary(true)
        end)
    end
end

local function Handle(text, from)
    local f = split(text, "~")
    local kind = f[1]
    if kind == "H" then
        if tonumber(f[2]) ~= PROTO then return end
        local known = {}
        for entry in (f[4] or ""):gmatch("[^,]+") do
            local key, rev, qrev = entry:match("^(.-):(%d+):(%d+)$")
            if key then known[unesc(key)] = { rev = tonumber(rev), qrev = tonumber(qrev) } end
        end
        partner = from
        local theirs = f[5] and unesc(f[5])
        if theirs and IsNewer(theirs, MyVersion()) then
            ns.updateAvailable = theirs
            if not versionWarned then
                versionWarned = true
                if db.reloadedFor == theirs then
                    -- Already reloaded for this version and it still isn't here.
                    Print("|cfff2a154Update " .. theirs .. " hasn't been downloaded yet.|r The background check runs every 30 minutes; " ..
                        "to get it now, double-click \"Update Duo Tracker\" and then type /reload.")
                else
                    Print("|cfff2a154Update available:|r " .. ns.PartnerLabel() .. " has version " .. theirs ..
                        " and you have " .. MyVersion() .. ". Open /duo and click the orange button to load it.")
                end
            end
        else
            db.reloadedFor = nil
        end
        if f[3] == "1" then Send(partner, BuildHello(false)) end
        SendChanges(known)
        if ns.OnHello then ns.OnHello(f[6] or "") end
        AfterSync()
    elseif kind == "S" and #f >= 13 then
        local key = unesc(f[2])
        local c = db.chars[key]
        if c and c.mine then return end
        c = c or {}
        db.chars[key] = c
        c.name, c.class = unesc(f[3]), nilIfEmpty(unesc(f[4]))
        c.level, c.xp, c.xpmax = tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
        c.group, c.guide = nilIfEmpty(unesc(f[8])), nilIfEmpty(unesc(f[9]))
        c.step, c.steps = tonumber(f[10]), tonumber(f[11])
        if c.step == 0 then c.step = nil end
        if c.steps == 0 then c.steps = nil end
        c.cfg = nilIfEmpty(unesc(f[12]))
        c.rev = tonumber(f[13])
        c.synced = time()
        AfterSync()
    elseif kind == "Q" and #f >= 6 then
        local key = unesc(f[2])
        local c = db.chars[key]
        if c and c.mine then return end
        c = c or {}
        db.chars[key] = c
        local guides, done, gq = {}, {}, {}
        if f[4] ~= "" then
            for i, n in ipairs(split(f[4], "^")) do guides[i] = unesc(n) end
        end
        DecodeIds(f[5], done, gq)
        DecodeIds(f[6], nil, gq)
        c.guides, c.done, c.gq = guides, done, gq
        c.qrev = tonumber(f[3])
        c.synced = time()
        AfterSync()
    elseif ns.handlers[kind] then
        ns.handlers[kind](f)
        AfterSync()
    end
end

local function Receive(text, senderKey, from)
    local id, i, n, data = text:match("^M#(%d+)#(%d+)#(%d+)#(.*)$")
    if not id then return end
    i, n = tonumber(i), tonumber(n)
    local slot = senderKey .. ":" .. id
    local box = inbox[slot]
    if not box then
        box = { parts = {}, count = 0, n = n, at = time() }
        inbox[slot] = box
    end
    if not box.parts[i] then
        box.parts[i] = data
        box.count = box.count + 1
    end
    if box.count >= box.n then
        inbox[slot] = nil
        local ok, err = pcall(Handle, table.concat(box.parts), from)
        if not ok and db.debug then Print("Sync error: " .. tostring(err)) end
    end
end

------------------------------------------------------------------------
-- Finding the partner
------------------------------------------------------------------------

local function FirstWord(name)
    return norm(tostring(name or ""):match("^%s*(%S+)"))
end

-- Names of the partner's paired characters. Battle.net may report only the
-- first name, so first names are included unless one of yours shares it.
local function PairNames()
    local names, myFirst = {}, {}
    for _, c in pairs(db.chars) do
        if c.mine then myFirst[FirstWord(c.name)] = true end
    end
    for _, p in ipairs(db.pairs) do
        for n = 1, 2 do
            local key = norm(p[n])
            if key ~= "" and not (db.chars[key] and db.chars[key].mine) then
                names[key] = true
                local first = FirstWord(p[n])
                if first ~= "" and not myFirst[first] then names[first] = true end
            end
        end
    end
    return names
end

-- Returns the game account of the partner if they are online in this game.
-- With `onlyID`, checks whether that specific game account is the partner.
local function FindBNPartner(onlyID)
    if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo
            and C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo) then
        return nil
    end
    local names = PairNames()
    for i = 1, BNGetNumFriends() do
        local acc = C_BattleNet.GetFriendAccountInfo(i)
        if acc then
            for j = 1, (C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
                local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
                if g and g.isOnline and g.gameAccountID and g.clientProgram == (BNET_CLIENT_WOW or "WoW")
                    and (g.wowProjectID == nil or WOW_PROJECT_ID == nil or g.wowProjectID == WOW_PROJECT_ID)
                    and (not onlyID or g.gameAccountID == onlyID) then
                    local byTag = db.partnerTag and acc.battleTag == db.partnerTag
                    local byName = not db.partnerTag and g.characterName and names[norm(g.characterName)]
                    if byTag or byName then return g.gameAccountID, acc.battleTag end
                end
            end
        end
    end
end

local function LearnPartner(tag)
    if tag and not db.partnerTag then
        db.partnerTag = tag
        db.partnerName = db.partnerName or tag:match("^[^#]+")
    end
end

local function PartyHasPartner()
    if not (IsInGroup and IsInGroup()) then return false end
    local names = PairNames()
    for i = 1, 4 do
        local name = FullName("party" .. i)
        if name and names[norm(name)] then return true end
    end
    return false
end

local function TryHello(force)
    local id, tag = FindBNPartner()
    if id then
        if force or not partner or partner.kind ~= "BN" or partner.id ~= id or time() - helloAt > 300 then
            partner = { kind = "BN", id = id }
            helloAt = time()
            Send(partner, BuildHello(true))
        end
        return true
    end
    if PartyHasPartner() then
        if force or not partner or partner.kind ~= "PARTY" or time() - helloAt > 300 then
            partner = { kind = "PARTY" }
            helloAt = time()
            Send(partner, BuildHello(true))
        end
        return true
    end
    partner = nil
    return false
end

function ns.Sync()
    if TryHello(true) then
        Print("Syncing with " .. ns.PartnerLabel() .. ".")
    else
        Print(ns.PartnerLabel() .. " isn't online on WoW Forever, so there's nothing to sync with yet.")
    end
end

function ns.PartnerOnline()
    return partner ~= nil
end

local function Flush()
    if not (partner and me) then return end
    local key = norm(me.name)
    if dirty then Send(partner, BuildStatus(key, me)) end
    if questDirty and me.done then Send(partner, BuildQuests(key, me)) end
    dirty, questDirty = false, false
    if ns.OnFlush then ns.OnFlush() end
end

------------------------------------------------------------------------
-- Setup, events and slash commands
------------------------------------------------------------------------

local function InitDB()
    DuoTrackerDB = DuoTrackerDB or {}
    db = DuoTrackerDB
    if db.schema ~= 2 then
        db.chars = {} -- earlier versions stored characters under their first name only
        db.schema = 2
    end
    db.chars = db.chars or {}
    db.ignored = db.ignored or {}
    db.minimap = db.minimap or {}
    db.notes = db.notes or {}
    if not db.pairs then
        db.pairs = {}
        for i, p in ipairs(ns.DEFAULT_PAIRS) do db.pairs[i] = { p[1], p[2] } end
    end
    ns.db = db
end

local function FindPair(name)
    local key = norm(name)
    if key == "" then return nil end
    for i, p in ipairs(db.pairs) do
        if norm(p[1]) == key or norm(p[2]) == key then return i end
    end
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Slash(msg)
    msg = trim(msg or "")
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""
    rest = rest or ""
    if cmd == "" then
        if ns.ToggleUI then ns.ToggleUI() end
    elseif cmd == "sync" then
        ns.Sync()
    elseif cmd == "status" then
        ns.PrintSummary(false)
    elseif cmd == "pair" then
        local a, b = rest:match("^(.-)%s*=%s*(.-)$")
        a, b = a and trim(a), b and trim(b)
        if not a or a == "" or b == "" then
            Print("Use: /duo pair First Character = Second Character")
            return
        end
        local i = FindPair(a) or FindPair(b)
        if i then db.pairs[i] = { a, b } else db.pairs[#db.pairs + 1] = { a, b } end
        Print("Paired " .. a .. " with " .. b .. ".")
        Changed()
    elseif cmd == "unpair" then
        local i = FindPair(rest)
        if i then
            table.remove(db.pairs, i)
            Print("Removed the pair containing " .. rest .. ".")
            Changed()
        else
            Print("No pair contains " .. rest .. ".")
        end
    elseif cmd == "partner" then
        if rest:lower() == "reset" or rest == "" then
            db.partnerTag = nil
            Print("Partner forgotten. The next Battle.net friend seen on a paired character becomes the partner.")
        else
            db.partnerTag = rest
            db.partnerName = db.partnerName or rest:match("^[^#]+")
            Print("Partner set to " .. rest .. ".")
        end
        TryHello(true)
    elseif cmd == "name" and rest ~= "" then
        db.partnerName = rest
        Print("Your partner now shows as " .. rest .. ".")
        Changed()
    elseif cmd == "minimap" then
        db.minimap.hide = not db.minimap.hide
        if ns.ShowMinimapButton then ns.ShowMinimapButton(not db.minimap.hide) end
        Print("Minimap button " .. (db.minimap.hide and "hidden." or "shown."))
    elseif cmd == "unignore" then
        db.ignored = {}
        Print("All ignored quests are showing again.")
        Changed()
    else
        Print("/duo - open the window")
        Print("/duo status - this character's pair, in chat")
        Print("/duo sync - sync now")
        Print("/duo pair A = B - set or change a pair, /duo unpair A - remove one")
        Print("/duo name Mark - what to call your partner")
        Print("/duo partner Name#1234 - set your partner's BattleTag by hand, /duo partner reset")
        Print("/duo unignore - show ignored quests again")
        Print("/duo minimap - show or hide the minimap button")
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        InitDB()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end
        SLASH_DUOTRACKER1 = "/duo"
        SLASH_DUOTRACKER2 = "/duotracker"
        SlashCmdList["DUOTRACKER"] = Slash
        for _, e in ipairs({ "BN_CHAT_MSG_ADDON", "CHAT_MSG_ADDON", "QUEST_TURNED_IN", "PLAYER_LEVEL_UP",
            "QUEST_DATA_LOAD_RESULT", "BN_FRIEND_INFO_CHANGED", "GROUP_ROSTER_UPDATE" }) do
            pcall(events.RegisterEvent, events, e)
        end
        Snapshot(true)
        if ns.CreateMinimapButton then pcall(ns.CreateMinimapButton) end
        C_Timer.NewTicker(SEND_INTERVAL, Pump)
        local ticks = 0
        C_Timer.NewTicker(5, function()
            ticks = ticks + 1
            Snapshot(false)
            if ns.OnTick then pcall(ns.OnTick) end
            if ticks % 4 == 0 then Flush() end
            if ticks % 12 == 0 then
                TryHello(false)
                for slot, box in pairs(inbox) do
                    if time() - box.at > 120 then inbox[slot] = nil end
                end
            end
        end)
        C_Timer.After(6, function()
            Snapshot(true) -- RestedXP has loaded its guide by now
            TryHello(true)
        end)
        C_Timer.After(12, function() ns.PrintSummary(true) end)
    elseif not db then
        return
    elseif event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if prefix ~= PREFIX or type(text) ~= "string" then return end
        local id, tag = FindBNPartner(senderID)
        if not id then return end
        LearnPartner(tag)
        Receive(text, "bn" .. tostring(senderID), { kind = "BN", id = senderID })
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, channel, sender = ...
        if prefix ~= PREFIX or channel ~= "PARTY" or type(text) ~= "string" or type(sender) ~= "string" then return end
        local key = norm(sender:match("^[^-]+"))
        if not PairNames()[key] then return end
        if partner and partner.kind == "BN" then return end -- already syncing over Battle.net
        Receive(text, "p" .. key, { kind = "PARTY" })
    elseif event == "QUEST_TURNED_IN" or event == "PLAYER_LEVEL_UP" then
        C_Timer.After(2, function()
            Snapshot(true)
            Flush()
        end)
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        local id, ok = ...
        if id and ok == false then untitled[id] = true end
        Changed()
    elseif event == "BN_FRIEND_INFO_CHANGED" or event == "GROUP_ROSTER_UPDATE" then
        if not partner and time() - lastTry >= 5 then
            lastTry = time()
            TryHello(false)
        end
    end
end)
