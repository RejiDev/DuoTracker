-- Duo Tracker: data, comparison and sync.
local ADDON, ns = ...

local PREFIX = "DuoTrk"
local PROTO = 1
-- Bytes of payload per message. The client has no call that reports these limits:
-- party addon messages take 255 bytes, Battle.net game data 4078 (less our header).
local CHUNK = { BN = 4000, PARTY = 220 }
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
local dirty = false
local helloAt = 0
local summaryShown
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

-- Redraws the window and minimap dot. A drawing error is recorded and never
-- stops the caller, so it can't hold up reading or syncing the character.
local function Changed()
    for _, name in ipairs({ "RefreshUI", "UpdateBadge" }) do
        local refresh = ns[name] or function() end
        local ok, err = pcall(refresh)
        if not ok and db then db.sync.refreshError = { at = time(), err = tostring(err) } end
    end
end

------------------------------------------------------------------------
-- Sync state: what the sync layer last did, kept in the saved variables
------------------------------------------------------------------------

-- Why a message was thrown away. Saved as keys, so the values never change.
local DROP = {
    UNKNOWN_SENDER = "unknown_sender",     -- Battle.net message from someone who isn't the partner
    PARTY_NOT_PAIRED = "party_not_paired", -- party message from a character not in the pair list
    PARTY_WHILE_BN = "party_while_bn",     -- party message while already syncing over Battle.net
    PROTO = "proto",                       -- the other side speaks a different message format
    NOT_IN_GROUP = "not_in_group",         -- a party message queued after leaving the group
    EXPIRED = "expired",                   -- a message whose parts didn't all arrive within 2 minutes
    SEND_ERROR = "send_error",             -- the client refused to send
}
ns.DROP = DROP

local DROP_TEXT = {
    [DROP.UNKNOWN_SENDER] = "a Battle.net message came from someone who isn't your partner",
    [DROP.PARTY_NOT_PAIRED] = "a party message came from a character not in the pair list",
    [DROP.PARTY_WHILE_BN] = "a party message was ignored because Battle.net sync was in use",
    [DROP.PROTO] = "the other addon uses a different message format",
    [DROP.NOT_IN_GROUP] = "a party message was left unsent after leaving the group",
    [DROP.EXPIRED] = "a message arrived incomplete",
    [DROP.SEND_ERROR] = "the game refused to send a message",
}

local function Drop(reason, detail)
    local d = db.sync.drops[reason] or { n = 0 }
    db.sync.drops[reason] = d
    d.n, d.at, d.detail = d.n + 1, time(), detail and tostring(detail) or nil
    db.sync.lastDrop = reason
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
    local group, name, step, steps
    if type(R) == "table" and type(R.currentGuide) == "table" and not R.currentGuide.empty then
        local guide = R.currentGuide
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
        step, steps, nilIfEmpty(cfg)
end

local function Snapshot()
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
    local ok, group, guideName, step, steps, cfg = pcall(ReadRXP)
    if ok then
        if c.group ~= group or c.guide ~= guideName or c.cfg ~= cfg then
            c.group, c.guide, c.cfg = group, guideName, cfg
            changed = true
        end
        if step then set("step", step) end
        if steps then set("steps", steps) end
    end
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
    PrintSummaryNow(onlyIfNew)
end

------------------------------------------------------------------------
-- Messages
------------------------------------------------------------------------

ns.handlers = {} -- extra message kinds, added by Extras.lua

local function Send(target, text)
    msgSeq = msgSeq + 1
    local size = CHUNK[target.kind]
    local n = math.ceil(#text / size)
    for i = 1, n do
        queue[#queue + 1] = { target, "M#" .. msgSeq .. "#" .. i .. "#" .. n .. "#" ..
            text:sub((i - 1) * size + 1, i * size) }
    end
end

-- Nothing is lost while the partner is offline: every hello resends what they lack.
function ns.SendToPartner(text)
    if partner then Send(partner, text) end
end

local function Pump()
    local item = table.remove(queue, 1)
    if not item then return end
    local target, text = item[1], item[2]
    if target.kind == "BN" then
        local ok, err = pcall(BNSendGameData, target.id, PREFIX, text)
        if not ok then Drop(DROP.SEND_ERROR, err) end
    elseif target.kind == "PARTY" then
        if not (IsInGroup and IsInGroup()) then
            Drop(DROP.NOT_IN_GROUP)
            return
        end
        -- Older clients return true/false, newer ones Enum.SendAddonMessageResult.
        local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "PARTY")
        local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success or 0
        if not ok or result == false or (type(result) == "number" and result ~= success) then
            Drop(DROP.SEND_ERROR, ok and ("result " .. tostring(result)) or result)
        end
    end
end

local function BuildHello(wantReply)
    local parts = {}
    for key, c in pairs(db.chars) do
        parts[#parts + 1] = esc(key) .. ":" .. (c.rev or 0) .. ":0" -- third field was quests (before 1.8.0)
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
        if tonumber(f[2]) ~= PROTO then
            Drop(DROP.PROTO, f[2])
            return
        end
        local known = {}
        for entry in (f[4] or ""):gmatch("[^,]+") do
            local key, rev = entry:match("^(.-):(%d+):%d+$")
            if key then known[unesc(key)] = { rev = tonumber(rev) } end
        end
        partner = from
        local theirs = f[5] and unesc(f[5])
        db.sync.partnerVersion = theirs
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
        local whole = table.concat(box.parts)
        db.sync.lastIn = { at = time(), kind = whole:match("^[^~]*") }
        local ok, err = pcall(Handle, whole, from)
        if not ok then db.sync.handlerError = { at = time(), err = tostring(err) } end
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

-- Who a Battle.net game account belongs to, for the record of rejected messages.
local function DescribeBN(id)
    for i = 1, (BNGetNumFriends and BNGetNumFriends() or 0) do
        local acc = C_BattleNet.GetFriendAccountInfo(i)
        for j = 1, (acc and C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
            local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if g and g.gameAccountID == id then
                return tostring(acc.battleTag) .. " on " .. tostring(g.characterName) ..
                    " (" .. tostring(g.clientProgram) .. ", project " .. tostring(g.wowProjectID) .. ")"
            end
        end
    end
    return "game account " .. tostring(id) .. ", not a Battle.net friend"
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
            db.sync.lastHelloOut = time()
            Send(partner, BuildHello(true))
        end
        db.sync.found = { how = "bn", at = time() }
        return true
    end
    if PartyHasPartner() then
        if force or not partner or partner.kind ~= "PARTY" or time() - helloAt > 300 then
            partner = { kind = "PARTY" }
            helloAt = time()
            db.sync.lastHelloOut = time()
            Send(partner, BuildHello(true))
        end
        db.sync.found = { how = "party", at = time() }
        return true
    end
    if partner or not db.sync.found or db.sync.found.how ~= "none" then
        db.sync.found = { how = "none", at = time() }
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
    for _, line in ipairs(ns.SyncReport()) do Print(line) end
end

-- The sync state in plain words, one line each, for /duo sync.
function ns.SyncReport()
    local st, who = db.sync, ns.PartnerLabel()
    local lines = {}
    local found = st.found
    local how = found and ({ bn = "found over Battle.net", party = "found in your party",
        none = "not found online" })[found.how] or "not looked for yet"
    lines[#lines + 1] = "Partner " .. how .. (found and (" (" .. ns.Ago(found.at):lower() .. ")") or "") ..
        ", BattleTag " .. tostring(db.partnerTag or "not learned yet") .. "."
    lines[#lines + 1] = "Last hello sent " .. ns.Ago(st.lastHelloOut):lower() .. "; last message from " .. who .. " " ..
        (st.lastIn and (ns.Ago(st.lastIn.at):lower() .. " (" .. tostring(st.lastIn.kind) .. ")") or "never") .. "."
    lines[#lines + 1] = who .. "'s version " .. tostring(st.partnerVersion or "unknown") .. ", yours " .. MyVersion() ..
        ". Waiting to send: " .. #queue .. " part(s)."
    local reasons = {}
    for _, reason in pairs(DROP) do reasons[#reasons + 1] = reason end
    table.sort(reasons)
    for _, reason in ipairs(reasons) do
        local d = st.drops[reason]
        if d then
            lines[#lines + 1] = "Dropped " .. d.n .. "x, last " .. ns.Ago(d.at):lower() .. ": " .. DROP_TEXT[reason] ..
                (d.detail and (" [" .. d.detail .. "]") or "") .. "."
        end
    end
    if st.handlerError then
        lines[#lines + 1] = "Error reading a message " .. ns.Ago(st.handlerError.at):lower() .. ": " .. st.handlerError.err
    end
    if st.refreshError then
        lines[#lines + 1] = "Error drawing the window " .. ns.Ago(st.refreshError.at):lower() .. ": " .. st.refreshError.err
    end
    return lines
end

function ns.DropText(reason) return DROP_TEXT[reason] end

function ns.PartnerOnline()
    return partner ~= nil
end

local function Flush()
    if not (partner and me) then return end
    local key = norm(me.name)
    if dirty then Send(partner, BuildStatus(key, me)) end
    dirty = false
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
    -- Quest lists were dropped in 1.8.0; clear what earlier versions saved.
    db.ignored = nil
    for _, c in pairs(db.chars) do c.done, c.gq, c.guides, c.qrev, c.race = nil, nil, nil, nil, nil end
    db.minimap = db.minimap or {}
    db.sync = db.sync or {}
    db.sync.drops = db.sync.drops or {}
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
    else
        Print("/duo - open the window")
        Print("/duo status - this character's pair, in chat")
        Print("/duo sync - sync now")
        Print("/duo pair A = B - set or change a pair, /duo unpair A - remove one")
        Print("/duo name Mark - what to call your partner")
        Print("/duo partner Name#1234 - set your partner's BattleTag by hand, /duo partner reset")
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
            "BN_FRIEND_INFO_CHANGED", "GROUP_ROSTER_UPDATE" }) do
            pcall(events.RegisterEvent, events, e)
        end
        Snapshot()
        if ns.CreateMinimapButton then pcall(ns.CreateMinimapButton) end
        C_Timer.NewTicker(SEND_INTERVAL, Pump)
        local ticks = 0
        C_Timer.NewTicker(5, function()
            ticks = ticks + 1
            Snapshot()
            if ns.OnTick then pcall(ns.OnTick) end
            if ticks % 4 == 0 then Flush() end
            if ticks % 12 == 0 then
                TryHello(false)
                for slot, box in pairs(inbox) do
                    if time() - box.at > 120 then
                        inbox[slot] = nil
                        Drop(DROP.EXPIRED, box.count .. " of " .. box.n .. " parts")
                    end
                end
            end
        end)
        C_Timer.After(6, function()
            Snapshot() -- RestedXP has loaded its guide by now
            TryHello(true)
        end)
        C_Timer.After(12, function() ns.PrintSummary(true) end)
    elseif not db then
        return
    elseif event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if prefix ~= PREFIX or type(text) ~= "string" then return end
        local id, tag = FindBNPartner(senderID)
        if not id then
            Drop(DROP.UNKNOWN_SENDER, DescribeBN(senderID))
            return
        end
        LearnPartner(tag)
        Receive(text, "bn" .. tostring(senderID), { kind = "BN", id = senderID })
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, channel, sender = ...
        if prefix ~= PREFIX or channel ~= "PARTY" or type(text) ~= "string" or type(sender) ~= "string" then return end
        local key = norm(sender:match("^[^-]+"))
        if not PairNames()[key] then
            Drop(DROP.PARTY_NOT_PAIRED, sender)
            return
        end
        if partner and partner.kind == "BN" then
            Drop(DROP.PARTY_WHILE_BN, sender)
            return
        end
        Receive(text, "p" .. key, { kind = "PARTY" })
    elseif event == "QUEST_TURNED_IN" or event == "PLAYER_LEVEL_UP" then
        C_Timer.After(2, function()
            Snapshot()
            Flush()
        end)
    elseif event == "BN_FRIEND_INFO_CHANGED" or event == "GROUP_ROSTER_UPDATE" then
        if not partner and time() - lastTry >= 5 then
            lastTry = time()
            TryHello(false)
        end
    end
end)
