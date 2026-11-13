-- Duo Tracker: gear, bags, professions, gold and shared notes.
local ADDON, ns = ...

local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
local SLOT_NAMES = { [1] = "Head", [2] = "Neck", [3] = "Shoulders", [5] = "Chest", [6] = "Waist", [7] = "Legs",
    [8] = "Feet", [9] = "Wrists", [10] = "Hands", [11] = "Ring", [12] = "Ring", [13] = "Trinket",
    [14] = "Trinket", [15] = "Back", [16] = "Main hand", [17] = "Off hand", [18] = "Ranged" }
-- Slots that count as "empty" once a character reaches this level.
local EXPECTED = { [5] = 1, [7] = 1, [8] = 1, [16] = 1, [6] = 10, [9] = 10, [10] = 10, [15] = 10, [3] = 20, [1] = 30 }
local EQUIP_SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_SHIELD = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
}
-- Original-game class rules. Armour: 1 cloth, 2 leather, 3 mail, 4 plate.
local ARMOR = { WARRIOR = { 3, 4 }, PALADIN = { 3, 4 }, HUNTER = { 2, 3 }, SHAMAN = { 2, 3 }, ROGUE = { 2, 2 },
    DRUID = { 2, 2 }, PRIEST = { 1, 1 }, MAGE = { 1, 1 }, WARLOCK = { 1, 1 } } -- { before 40, from 40 }
local SHIELDS = { WARRIOR = true, PALADIN = true, SHAMAN = true }
local function set(...)
    local t = {}
    for i = 1, select("#", ...) do t[select(i, ...)] = true end
    return t
end
-- Weapon subclasses: 0/1 axes, 2 bow, 3 gun, 4/5 maces, 6 polearm, 7/8 swords, 10 staff, 13 fist,
-- 15 dagger, 16 thrown, 18 crossbow, 19 wand.
local WEAPONS = {
    WARRIOR = set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18), PALADIN = set(0, 1, 4, 5, 6, 7, 8),
    HUNTER = set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18), ROGUE = set(2, 3, 4, 7, 13, 15, 16, 18),
    PRIEST = set(4, 10, 15, 19), SHAMAN = set(0, 1, 4, 5, 10, 13, 15), MAGE = set(7, 10, 15, 19),
    WARLOCK = set(7, 10, 15, 19), DRUID = set(4, 5, 10, 13, 15),
}
local MOUNT_LEVEL, MOUNT_COPPER = 40, 100 * 10000
local FREE_MOUNT = { PALADIN = true, WARLOCK = true }

local dirty, sendDue, lastSig = true, false, nil
local pendingItems = false

------------------------------------------------------------------------
-- Item lookups
------------------------------------------------------------------------

local function ItemInfo(id)
    local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not get then return nil end
    local name, link, quality, ilvl, minLevel, _, _, _, equipLoc, _, _, classID, subclassID = get(id)
    if not name then
        pendingItems = true
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        return nil
    end
    return { id = id, name = name, link = link, quality = quality or 1, ilvl = ilvl or 0,
        minLevel = minLevel or 0, equipLoc = equipLoc or "", classID = classID, subclassID = subclassID }
end
ns.ItemInfo = ItemInfo

-- An item's stats as { strength, agility, stamina, intellect, spirit, weapon DPS x 10 }.
local STAT_KEYS = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STAMINA_SHORT",
    "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPIRIT_SHORT" }
local STAT_NAMES = { "Str", "Agi", "Sta", "Int", "Spi" }

local function ReadStats(link)
    local get = (C_Item and C_Item.GetItemStats) or GetItemStats
    if not (get and link) then return nil end
    local ok, t = pcall(get, link)
    if not ok or type(t) ~= "table" then return nil end
    local out = {}
    for i, key in ipairs(STAT_KEYS) do out[i] = math.floor((tonumber(t[key]) or 0) + 0.5) end
    out[6] = math.floor((tonumber(t.ITEM_MOD_DAMAGE_PER_SECOND_SHORT) or 0) * 10 + 0.5)
    return out
end

-- What each class wants from gear, as weights for the five stats above.
local MELEE = { WARRIOR = { 1, 0.5, 0.7, 0, 0 }, PALADIN = { 1, 0.3, 0.7, 0.3, 0 }, HUNTER = { 0.2, 1, 0.6, 0.3, 0.1 },
    ROGUE = { 0.5, 1, 0.6, 0, 0 }, DRUID = { 0.8, 0.8, 0.7, 0.1, 0.1 }, SHAMAN = { 0.8, 0.6, 0.6, 0.4, 0.1 } }
local CASTER = { PRIEST = { 0, 0, 0.5, 1, 1 }, MAGE = { 0, 0, 0.5, 1, 0.6 }, WARLOCK = { 0, 0, 1, 0.8, 0.5 },
    DRUID = { 0, 0, 0.5, 1, 0.9 }, SHAMAN = { 0, 0, 0.5, 1, 0.6 }, PALADIN = { 0, 0, 0.6, 1, 0.6 } }

-- Pure casters and pure fighters are fixed. Druids, Shamans and Paladins are
-- read from the gear they wear: more intellect and spirit than strength and agility means caster.
local function IsCaster(c)
    local class = c.class
    if not MELEE[class] then return true end
    if not CASTER[class] then return false end
    local fight, cast = 0, 0
    for _, e in pairs(c.x.eq) do
        local st = e[3]
        if st then
            fight = fight + st[1] + st[2]
            cast = cast + st[4] + st[5]
        end
    end
    return cast > fight
end

local function Score(weights, stats)
    local total = 0
    for i = 1, 5 do total = total + weights[i] * stats[i] end
    return total
end

local function Describe(stats, ilvl, showDps)
    if stats then
        local parts = {}
        if showDps and stats[6] > 0 then parts[#parts + 1] = string.format("%.1f DPS", stats[6] / 10) end
        for i = 1, 5 do
            if stats[i] > 0 then parts[#parts + 1] = stats[i] .. " " .. STAT_NAMES[i] end
        end
        if #parts > 0 then return table.concat(parts, ", ") end
    end
    return "item level " .. (ilvl or 0)
end

local function BestArmor(class, level)
    local a = ARMOR[class]
    if not a then return 1 end
    return (level or 1) >= 40 and a[2] or a[1]
end

-- strict: can the class equip it at all. Otherwise: is it the kind of item the class would want.
local function CanUse(class, level, item, strict)
    if not EQUIP_SLOTS[item.equipLoc] then return false end
    if item.classID == 4 then
        local sub = item.subclassID or 0
        if sub == 0 or item.equipLoc == "INVTYPE_CLOAK" then return true end
        if sub == 6 then return SHIELDS[class] == true end
        if sub >= 1 and sub <= 4 then
            local best = BestArmor(class, level)
            return sub <= best and (strict or sub >= best - 1)
        end
        return false
    elseif item.classID == 2 then
        return WEAPONS[class] ~= nil and WEAPONS[class][item.subclassID or -1] == true
    end
    return false
end

-- Would `item` be an upgrade for the character? Returns nil when it isn't the
-- kind of thing they'd use, else: isUpgrade, what it offers, what they wear now (nil if the slot is empty).
local function Judge(c, item, stats)
    local class = c.class
    local caster = IsCaster(c)
    local weights = (caster and CASTER or MELEE)[class]
    local loc = item.equipLoc
    local slots = EQUIP_SLOTS[loc]
    local weapon = item.classID == 2

    local function worn(slot)
        local e = c.x.eq[slot]
        if not e then return nil end
        return ItemInfo(e[1]), e[3], e[2]
    end
    local mainInfo = worn(16)
    local offInfo = worn(17)
    if (weapon or slots[1] == 17) and ((c.x.eq[16] and not mainInfo) or (c.x.eq[17] and not offInfo)) then
        return nil -- the game hasn't loaded what they're holding yet
    end
    local mainLoc, offLoc = mainInfo and mainInfo.equipLoc, offInfo and offInfo.equipLoc

    -- Only like for like: no one-handers for someone using a two-hander, and so on.
    if loc == "INVTYPE_2HWEAPON" then
        if mainLoc and mainLoc ~= "INVTYPE_2HWEAPON" then return nil end
    elseif loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONMAINHAND" then
        if mainLoc == "INVTYPE_2HWEAPON" then return nil end
    elseif loc == "INVTYPE_WEAPONOFFHAND" then
        if not (offLoc == "INVTYPE_WEAPONOFFHAND" or offLoc == "INVTYPE_WEAPON") then return nil end
    elseif loc == "INVTYPE_SHIELD" then
        if mainLoc == "INVTYPE_2HWEAPON" or (offLoc and offLoc ~= "INVTYPE_SHIELD") then return nil end
    elseif loc == "INVTYPE_HOLDABLE" then
        if not caster or mainLoc == "INVTYPE_2HWEAPON" or (offLoc and offLoc ~= "INVTYPE_HOLDABLE") then return nil end
    end

    -- Weapons the character actually hits with are judged on damage. Everything
    -- else, including a caster's staff or a fighter's bow, is judged on stats.
    local ranged = slots[1] == 18
    local byDps = weapon and ((class == "HUNTER" and ranged) or (not caster and class ~= "HUNTER" and not ranged) or
        (caster and loc == "INVTYPE_RANGEDRIGHT"))
    local function measure(st)
        if not st then return nil end
        if byDps then return st[6] end
        return Score(weights, st)
    end

    local mine = measure(stats)
    local lowest, lowestStats, lowestLevel, empty
    for _, slot in ipairs(slots) do
        local info, st, ilvl = worn(slot)
        if not c.x.eq[slot] then
            empty = true
        else
            local m = measure(st)
            if lowest == nil or (m or -1) < (lowest or -1) then
                lowest, lowestStats, lowestLevel = m or false, st, ilvl
            end
        end
    end
    local offer = Describe(stats, item.ilvl, byDps)
    if empty then
        -- A caster still shouldn't pick up a weapon with nothing on it for them.
        if weapon and not byDps and mine == 0 then return nil end
        return true, offer, nil
    end
    local now = Describe(lowestStats, lowestLevel, byDps)
    local upgrade
    if mine and lowest then
        if mine == 0 and lowest == 0 then
            upgrade = item.ilvl > (lowestLevel or 0)
        else
            upgrade = mine > lowest
        end
    elseif mine then
        upgrade = mine > 0 and item.ilvl > (lowestLevel or 0)
    elseif weapon and not byDps then
        upgrade = false -- can't tell whether it has the right stats
    else
        upgrade = item.ilvl > (lowestLevel or 0)
    end
    return upgrade, offer, now
end

------------------------------------------------------------------------
-- Collecting this character
------------------------------------------------------------------------

local function Collect()
    local me = ns.Me()
    if not me then return end
    pendingItems = false
    local x = { gold = ns.plain(GetMoney and GetMoney()) or 0, eq = {}, bag = {}, bagStats = {}, profs = {}, skills = {},
        craft = (me.x and me.x.craft) or {} }
    for _, slot in ipairs(SLOTS) do
        local id = GetInventoryItemID and GetInventoryItemID("player", slot)
        if id then
            local info = ItemInfo(id)
            local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
            local detailed = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
            local ilvl = link and detailed and detailed(link) or (info and info.ilvl)
            x.eq[slot] = { id, ns.plain(ilvl) or 0, ReadStats(link) }
        end
    end
    if C_Container and C_Container.GetContainerNumSlots then
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
                local it = C_Container.GetContainerItemInfo(bag, slot)
                if it and it.itemID and not it.isBound then
                    local info = ItemInfo(it.itemID)
                    if info and EQUIP_SLOTS[info.equipLoc] and info.quality >= 1 then
                        x.bag[it.itemID] = true
                        x.bagStats[it.itemID] = ReadStats(it.hyperlink)
                    end
                end
            end
        end
    end
    if GetProfessions and GetProfessionInfo then
        local list = { GetProfessions() }
        for i = 1, 6 do
            local index = list[i]
            if index then
                local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
                if type(skillLine) == "number" then x.skills[skillLine] = true end
                if name then
                    x.profs[#x.profs + 1] = { name, rank or 0, maxRank or 0 }
                    if i <= 2 then x.np = (x.np or 0) + 1 end -- the first two are the main professions
                end
            end
        end
    end
    -- Skill ids, so profession quests are only compared when both characters have the profession.
    if C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
        for i = 1, C_SkillInfo.GetNumSkillLines() do
            local line = C_SkillInfo.GetSkillLineInfo(i)
            if line and not line.isHeader and type(line.skillID) == "number" then x.skills[line.skillID] = true end
        end
    end
    local sig = ns.BuildExtras("", x, 0)
    if sig ~= lastSig or not me.x then
        lastSig = sig
        me.x = x
        me.xrev = time()
        sendDue = true
        ns.Changed()
    end
    dirty = pendingItems -- look again once the game has loaded the missing item data
end

-- Recipes can only be read while a profession window is open.
local function CollectRecipes()
    local me = ns.Me()
    local T = C_TradeSkillUI
    if not (me and me.x and T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return end
    local added = false
    for _, recipe in ipairs(T.GetAllRecipeIDs() or {}) do
        local info = T.GetRecipeInfo(recipe)
        if info and info.learned then
            local out
            if T.GetRecipeOutputItemData then
                local data = T.GetRecipeOutputItemData(recipe)
                out = data and data.itemID
            end
            if not out and T.GetRecipeSchematic then
                local schematic = T.GetRecipeSchematic(recipe, false)
                out = schematic and schematic.outputItemID
            end
            if out and not me.x.craft[out] then
                me.x.craft[out] = true
                added = true
            end
        end
    end
    if added then
        lastSig = nil
        dirty = true
    end
end

------------------------------------------------------------------------
-- Sync
------------------------------------------------------------------------

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    return out
end

function ns.BuildExtras(key, x, rev)
    local eq, profs = {}, {}
    for _, slot in ipairs(SLOTS) do
        local e = x.eq[slot]
        if e then eq[#eq + 1] = slot .. "." .. e[1] .. "." .. e[2] end
    end
    for i, p in ipairs(x.profs) do profs[i] = ns.esc(p[1]) .. ":" .. p[2] .. ":" .. p[3] end
    local eqStats, bagStats = {}, {}
    for _, slot in ipairs(SLOTS) do
        local e = x.eq[slot]
        if e and e[3] then eqStats[#eqStats + 1] = slot .. ":" .. table.concat(e[3], ".") end
    end
    local bagIds = keys(x.bagStats or {})
    table.sort(bagIds)
    for _, id in ipairs(bagIds) do bagStats[#bagStats + 1] = id .. ":" .. table.concat(x.bagStats[id], ".") end
    return table.concat({ "X", ns.esc(key), rev, x.gold or 0, table.concat(eq, ","),
        ns.EncodeIds(keys(x.bag)), table.concat(profs, ","), ns.EncodeIds(keys(x.craft)), x.np or 0, table.concat(eqStats, ","), table.concat(bagStats, ","),
        ns.EncodeIds(keys(x.skills or {})) }, "~")
end

ns.handlers.X = function(f)
    if #f < 8 then return end
    local key = ns.unesc(f[2])
    local c = ns.db.chars[key]
    if c and c.mine then return end
    c = c or {}
    ns.db.chars[key] = c
    local x = { gold = tonumber(f[4]) or 0, eq = {}, bag = {}, bagStats = {}, profs = {}, craft = {} }
    for slot, id, ilvl in f[5]:gmatch("(%d+)%.(%d+)%.(%d+)") do
        x.eq[tonumber(slot)] = { tonumber(id), tonumber(ilvl) }
    end
    ns.DecodeIds(f[6], x.bag, {})
    for entry in f[7]:gmatch("[^,]+") do
        local name, rank, max = entry:match("^(.-):(%d+):(%d+)$")
        if name then x.profs[#x.profs + 1] = { ns.unesc(name), tonumber(rank), tonumber(max) } end
    end
    ns.DecodeIds(f[8], x.craft, {})
    x.np = tonumber(f[9]) or math.min(2, #x.profs)
    local function stats(text)
        local out = {}
        for n in text:gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return #out == 6 and out or nil
    end
    for slot, text in (f[10] or ""):gmatch("(%d+):([%d%.]+)") do
        local e = x.eq[tonumber(slot)]
        if e then e[3] = stats(text) end
    end
    x.bagStats = {}
    for id, text in (f[11] or ""):gmatch("(%d+):([%d%.]+)") do x.bagStats[tonumber(id)] = stats(text) end
    if f[12] then -- absent from versions before 1.7.0
        x.skills = {}
        ns.DecodeIds(f[12], x.skills, {})
    end
    c.x, c.xrev = x, tonumber(f[3])
    c.synced = time()
end

function ns.PairKey(index)
    local p = ns.db.pairs[index]
    if not p then return nil end
    local a, b = ns.norm(p[1]), ns.norm(p[2])
    if a > b then a, b = b, a end
    return a .. "+" .. b
end

local function NoteMessage(key, note)
    return table.concat({ "N", ns.esc(key), note.t or 0, ns.esc(note.by), ns.esc(note.text) }, "~")
end

ns.handlers.N = function(f)
    if #f < 5 then return end
    local key, t = ns.unesc(f[2]), tonumber(f[3]) or 0
    local old = ns.db.notes[key]
    if not old or (old.t or 0) < t then
        ns.db.notes[key] = { t = t, by = ns.unesc(f[4]), text = ns.unesc(f[5]) }
    end
end

function ns.SetNote(index, text)
    local key = ns.PairKey(index)
    local me = ns.Me()
    if not (key and me) then return end
    text = tostring(text or ""):gsub("[%c]", " "):sub(1, 200)
    local note = { t = time(), by = me.name, text = text }
    ns.db.notes[key] = note
    ns.SendToPartner(NoteMessage(key, note))
    ns.Changed()
end

function ns.HelloExtra()
    local parts = {}
    for key, c in pairs(ns.db.chars) do
        if c.xrev then parts[#parts + 1] = ns.esc(key) .. ":" .. c.xrev end
    end
    return table.concat(parts, ",")
end

function ns.OnHello(extra)
    local known = {}
    for entry in extra:gmatch("[^,]+") do
        local key, rev = entry:match("^(.-):(%d+)$")
        if key then known[ns.unesc(key)] = tonumber(rev) end
    end
    for key, c in pairs(ns.db.chars) do
        if c.mine and c.x and known[key] ~= c.xrev then
            ns.SendToPartner(ns.BuildExtras(key, c.x, c.xrev))
        end
    end
    for key, note in pairs(ns.db.notes) do ns.SendToPartner(NoteMessage(key, note)) end
    sendDue = false
end

function ns.OnTick()
    if dirty then Collect() end
end

local lastSend = 0
function ns.OnFlush()
    local me = ns.Me()
    if sendDue and me and me.x and time() - lastSend >= 60 then
        lastSend = time()
        sendDue = false
        ns.SendToPartner(ns.BuildExtras(ns.norm(me.name), me.x, me.xrev))
    end
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "SKILL_LINES_CHANGED",
    "GET_ITEM_INFO_RECEIVED", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_SHOW" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event)
    if not ns.db then return end
    if event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_SHOW" then
        pcall(CollectRecipes)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if ns.RefreshUI then ns.RefreshUI() end
    end
    dirty = true
end)

------------------------------------------------------------------------
-- What the window shows
------------------------------------------------------------------------

ns.SLOTS, ns.SLOT_NAMES = SLOTS, SLOT_NAMES

-- "ok", "low" (well below the character's level), "empty" (should be filled by now) or "none".
function ns.SlotState(c, slot)
    local e = c.x.eq[slot]
    local level = c.level or 1
    if e then
        return (e[2] > 0 and e[2] <= level - 8) and "low" or "ok", e[1], e[2]
    end
    if EXPECTED[slot] and level >= EXPECTED[slot] then return "empty" end
    return "none"
end

function ns.GearSummary(c)
    if not (c and c.x) then return nil end
    local sum, count, weakest, weakestLevel = 0, 0, nil, nil
    local empty, low = {}, {}
    local level = c.level or 1
    for _, slot in ipairs(SLOTS) do
        local e = c.x.eq[slot]
        if e then
            sum, count = sum + e[2], count + 1
            if not weakestLevel or e[2] < weakestLevel then weakest, weakestLevel = slot, e[2] end
            if e[2] > 0 and e[2] <= level - 8 then low[#low + 1] = SLOT_NAMES[slot] .. " " .. e[2] end
        elseif EXPECTED[slot] and level >= EXPECTED[slot] then
            empty[#empty + 1] = SLOT_NAMES[slot]
        end
    end
    return { avg = count > 0 and math.floor(sum / count + 0.5) or 0, weakest = weakest and SLOT_NAMES[weakest],
        weakestLevel = weakestLevel, empty = empty, low = low }
end

local function Wearables(forChar, fromChar, ids, knownStats)
    local list = {}
    if not (forChar and fromChar and forChar.x and fromChar.x and forChar.class) then return nil end
    for id in pairs(ids) do
        local item = ItemInfo(id)
        if item and CanUse(forChar.class, forChar.level, item) and item.minLevel <= (forChar.level or 1) + 2 then
            local stats = (knownStats and knownStats[id]) or ReadStats("item:" .. id)
            local upgrade, offer, now = Judge(forChar, item, stats)
            if upgrade then
                local text = (item.link or item.name) .. "  " .. SLOT_NAMES[EQUIP_SLOTS[item.equipLoc][1]] .. ": " .. offer ..
                    (now and (" (wearing " .. now .. ")") or " (slot empty)")
                if item.minLevel > (forChar.level or 1) then text = text .. ", needs level " .. item.minLevel end
                if fromChar.class and not CanUse(fromChar.class, fromChar.level, item, true) then
                    text = text .. ". " .. (fromChar.long or fromChar.name) .. " can't use it"
                end
                list[#list + 1] = { id = id, text = text }
            end
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Unbound items in fromChar's bags that forChar could use.
function ns.HandMeDowns(forChar, fromChar)
    local x = fromChar and fromChar.x
    return Wearables(forChar, fromChar, x and x.bag or {}, x and x.bagStats)
end

-- Things fromChar knows how to make that would be an upgrade for forChar.
function ns.CanCraft(forChar, fromChar)
    return Wearables(forChar, fromChar, fromChar and fromChar.x and fromChar.x.craft or {}, nil)
end

function ns.SkillCap(level)
    level = level or 1
    if level >= 35 then return 300 end
    if level >= 20 then return 225 end
    if level >= 10 then return 150 end
    if level >= 5 then return 75 end
    return 0
end

function ns.Money(copper)
    copper = copper or 0
    local g, s = math.floor(copper / 10000), math.floor(copper % 10000 / 100)
    if g > 0 then return g .. "g " .. s .. "s" end
    return s .. "s " .. (copper % 100) .. "c"
end

function ns.MountLine(c)
    if not (c and c.x) then return nil end
    local gold = c.x.gold or 0
    if FREE_MOUNT[c.class or ""] then
        return ns.Money(gold) .. ". Gets a free mount from a class quest at level " .. MOUNT_LEVEL .. "."
    end
    if gold >= MOUNT_COPPER then
        return ns.Money(gold) .. ". Enough for the level " .. MOUNT_LEVEL .. " mount (100g)."
    end
    return ns.Money(gold) .. ". " .. math.floor(gold / MOUNT_COPPER * 100) .. "% of the 100g mount at level " ..
        MOUNT_LEVEL .. ", " .. ns.Money(MOUNT_COPPER - gold) .. " to go."
end
