-- Duo Tracker: who is paired with whom, which of your characters are shared,
-- and who counts as the partner. Every pair edit goes through ns.SetPairs and
-- every sender asks ns.Private before putting one of your characters on the wire.
local ADDON, ns = ...
local norm, esc, unesc = ns.norm, ns.esc, ns.unesc

------------------------------------------------------------------------
-- Looking pairs up
------------------------------------------------------------------------

-- Index of the pair holding this character name, or nil.
function ns.FindPair(name)
    local key = norm(name)
    if key == "" then return nil end
    for i, p in ipairs(ns.db.pairs) do
        if norm(p[1]) == key or norm(p[2]) == key then return i end
    end
end

function ns.PairIndexFor(c)
    return c and ns.FindPair(c.name)
end

-- One of your characters that you have not ticked for sharing. Its data,
-- and its name, never leave this PC.
function ns.Private(c)
    return c ~= nil and c.mine == true and c.shared ~= true
end

------------------------------------------------------------------------
-- Who is the partner
------------------------------------------------------------------------

local function FirstWord(name)
    return norm(tostring(name or ""):match("^%s*(%S+)"))
end

-- Names the partner's characters go by: every name in a pair that isn't yours,
-- and every character the partner has shared. Battle.net may report only the
-- first name, so first names are included unless one of yours shares it.
function ns.PairNames()
    local db = ns.db
    local names, myFirst = {}, {}
    for _, c in pairs(db.chars) do
        if c.mine then myFirst[FirstWord(c.name)] = true end
    end
    local function add(name)
        local key = norm(name)
        if key == "" or (db.chars[key] and db.chars[key].mine) then return end
        names[key] = true
        local first = FirstWord(name)
        if first ~= "" and not myFirst[first] then names[first] = true end
    end
    for _, p in ipairs(db.pairs) do
        add(p[1])
        add(p[2])
    end
    for _, c in pairs(db.chars) do
        if not c.mine then add(c.name) end
    end
    return names
end

-- A party member is the partner when the name is one of theirs or, once the
-- partner's BattleTag is known, when the game says the unit is that account.
local function IsPartnerUnit(unit)
    local full = ns.FullName(unit)
    if not full then return false end
    if ns.PairNames()[norm(full)] then return true end
    local tag = ns.db.partnerTag
    local guid = tag and UnitGUID and ns.plain(UnitGUID(unit))
    local info = guid and C_BattleNet and C_BattleNet.GetAccountInfoByGUID and C_BattleNet.GetAccountInfoByGUID(guid)
    return type(info) == "table" and ns.plain(info.battleTag) == tag
end

-- Whether the partner is in your party; with a name, whether that party member is the partner.
function ns.PartnerInParty(name)
    if not (IsInGroup and IsInGroup()) then return false end
    if name ~= nil and type(name) ~= "string" then return false end
    for i = 1, 4 do
        local unit = "party" .. i
        local full = ns.FullName(unit)
        if full and (name == nil or norm(full) == norm(name) or norm(UnitName(unit)) == norm(name))
            and IsPartnerUnit(unit) then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- The pair list, shared with the partner: the latest edit wins
------------------------------------------------------------------------

local function Encode(list)
    local parts = {}
    for i, p in ipairs(list) do parts[i] = esc(p[1]) .. ":" .. esc(p[2]) end
    return table.concat(parts, ",")
end

local function Decode(text)
    local list = {}
    for entry in text:gmatch("[^,]+") do
        local a, b = entry:match("^([^:]*):([^:]*)$")
        if not a then return nil end
        list[#list + 1] = { unesc(a), unesc(b) }
    end
    return list
end

ns.EncodePairs = Encode

local function PairsMessage()
    return "P~" .. (ns.db.pairsRev or 0) .. "~" .. Encode(ns.db.pairs)
end

-- Starts sharing one of your characters. The only way one becomes shared.
-- Returns true when it wasn't shared before, so the caller knows to say hello.
local function ShareOn(key)
    local c = ns.db.chars[key]
    if not (c and c.mine) or c.shared == true then return false end
    c.shared = true
    ns.db.forget[key] = nil
    return true
end

local function Copy()
    local list = {}
    for i, p in ipairs(ns.db.pairs) do list[i] = { p[1], p[2] } end
    return list
end

-- The one way the pair list changes on this side. Revisions are server time, so
-- the two PCs' clocks don't matter; an edit always beats the revision it replaces.
function ns.SetPairs(list)
    local db = ns.db
    db.pairs = list
    db.pairsRev = math.max(GetServerTime(), (db.pairsRev or 0) + 1)
    db.pairsBy = "you"
    local newlyShared = false
    for _, p in ipairs(list) do
        -- A character you pair is a character you share.
        for n = 1, 2 do newlyShared = ShareOn(norm(p[n])) or newlyShared end
    end
    ns.SendToPartner(PairsMessage())
    ns.Changed()
    if newlyShared then ns.TryHello(true) end -- the hello exchange sends what the partner lacks
end

-- Equal revisions with different lists: both sides keep the larger encoding, so they agree.
ns.handlers.P = function(f)
    local rev, text = tonumber(f[2]), f[3] or ""
    local list = rev and Decode(text)
    if not list then return end
    local db = ns.db
    local mine = db.pairsRev or 0
    if rev > mine or (rev == mine and text > Encode(db.pairs)) then
        db.pairs, db.pairsRev, db.pairsBy = list, rev, "partner"
    end
end

-- Puts a character into one side of a pair, taking it out of any other pair first.
function ns.AssignSlot(index, column, name)
    local list = Copy()
    if not list[index] then return end
    local key = norm(name)
    if key ~= "" then
        for _, p in ipairs(list) do
            for n = 1, 2 do
                if norm(p[n]) == key then p[n] = "" end
            end
        end
    end
    list[index][column] = name or ""
    ns.SetPairs(list)
end

function ns.AddPair()
    local list = Copy()
    list[#list + 1] = { "", "" }
    ns.SetPairs(list)
end

function ns.RemovePair(index)
    local list = Copy()
    if not list[index] then return end
    table.remove(list, index)
    ns.SetPairs(list)
end

-- /duo pair A = B: replaces the pair holding either name, or adds one.
function ns.PairUp(a, b)
    local list = Copy()
    local i = ns.FindPair(a) or ns.FindPair(b)
    if i then list[i] = { a, b } else list[#list + 1] = { a, b } end
    ns.SetPairs(list)
end

------------------------------------------------------------------------
-- Sharing your characters
------------------------------------------------------------------------

-- Ticks or unticks one of your characters. Unticking tells the partner's addon
-- to forget it and takes it out of its pair, so its name stops going out too.
function ns.SetShared(key, on)
    local db = ns.db
    local c = db.chars[key]
    if not (c and c.mine) then return end
    if on then
        if ShareOn(key) then
            ns.Changed()
            ns.TryHello(true) -- the hello exchange sends what the partner lacks
        end
        return
    end
    c.shared = false
    db.forget[key] = true
    ns.SendToPartner("F~" .. esc(key))
    local list, changed = Copy(), false
    for _, p in ipairs(list) do
        for n = 1, 2 do
            if norm(p[n]) == key then p[n], changed = "", true end
        end
    end
    if changed then ns.SetPairs(list) else ns.Changed() end
end

-- The partner unticked one of their characters.
ns.handlers.F = function(f)
    local key = f[2] and unesc(f[2])
    local c = key and ns.db.chars[key]
    if c and not c.mine then ns.db.chars[key] = nil end
end

-- On each hello: repeat forget requests the partner still holds, drop the ones
-- they have acted on, and send the pair list.
ns.helloHooks[#ns.helloHooks + 1] = function(known)
    local db = ns.db
    for key in pairs(db.forget) do
        if known[key] then ns.SendToPartner("F~" .. esc(key)) else db.forget[key] = nil end
    end
    ns.SendToPartner(PairsMessage())
end

-- Characters for the picker: yours (mine = true) or the partner's, with the pair each is in.
function ns.Candidates(mine)
    local out = {}
    for key, c in pairs(ns.db.chars) do
        if (c.mine == true) == mine and c.name then
            out[#out + 1] = { key = key, c = c, pair = ns.FindPair(c.name) }
        end
    end
    table.sort(out, function(x, y)
        if (x.c.level or 0) ~= (y.c.level or 0) then return (x.c.level or 0) > (y.c.level or 0) end
        return x.key < y.key
    end)
    return out
end

-- A character logging in for the first time is shared only if it is already in a pair.
function ns.DefaultShared(c)
    if c.shared == nil then c.shared = ns.FindPair(c.name) ~= nil end
end

-- Saved data from before 1.10.0: your paired characters stay shared, the rest
-- become private and the partner is asked to forget them. A pair list changed
-- by hand counts as edited now, so it isn't lost to the partner's defaults.
function ns.MigratePairs()
    local db = ns.db
    db.forget = db.forget or {}
    if (db.schema or 0) >= 3 then return end
    for key, c in pairs(db.chars) do
        if c.mine then
            c.shared = ns.FindPair(c.name) ~= nil
            if not c.shared then db.forget[key] = true end
        end
    end
    if Encode(db.pairs) ~= Encode(ns.DEFAULT_PAIRS) then
        db.pairsRev, db.pairsBy = GetServerTime(), "you"
    end
    db.schema = 3
end

-- Sharing and pairs in plain words, for /duo sync.
function ns.PairsReport()
    local db = ns.db
    local shared, private = 0, {}
    for _, c in pairs(db.chars) do
        if c.mine then
            if ns.Private(c) then private[#private + 1] = c.name else shared = shared + 1 end
        end
    end
    table.sort(private)
    local waiting = 0
    for _ in pairs(db.forget) do waiting = waiting + 1 end
    local lines = {}
    lines[1] = "Sharing " .. shared .. " of your " .. (shared + #private) .. " characters" ..
        (#private > 0 and (" (private: " .. table.concat(private, ", ") .. ")") or "") .. "." ..
        (waiting > 0 and (" Waiting for " .. ns.PartnerLabel() .. "'s addon to forget " .. waiting .. ".") or "")
    lines[2] = #db.pairs .. " pairs, " .. ((db.pairsRev or 0) > 0 and ("last changed by " ..
        (db.pairsBy == "partner" and ns.PartnerLabel() or "you") .. " " .. ns.Ago(db.pairsRev):lower())
        or "never changed from the built-in list") .. "."
    return lines
end
