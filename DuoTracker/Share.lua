-- Duo Tracker: quest sharing with the partner's paired character in your party.
-- A quest you accept is shared with them; a quest they share with you is accepted.
local ADDON, ns = ...

-- What sharing last did, saved as keys so the values never change.
local SHARE = {
    SHARED = "shared",           -- sent to the party
    ACCEPTED = "accepted",       -- the partner's shared quest was accepted here
    NO_PARTNER = "no_partner",   -- the partner's character isn't in your party
    NOT_SHAREABLE = "not_shareable", -- the game says this quest can't be shared
    COMBAT = "combat",           -- held until combat ends (the game blocks sharing in combat)
    FROM_PARTNER = "from_partner", -- not shared back: it came from the partner
    OFF = "off",                 -- switched off with /duo share
}
ns.SHARE = SHARE

local SHARE_TEXT = {
    [SHARE.SHARED] = "shared with your party",
    [SHARE.ACCEPTED] = "accepted from your partner",
    [SHARE.NO_PARTNER] = "not shared: your partner's character isn't in your party",
    [SHARE.NOT_SHAREABLE] = "not shared: the game says it can't be shared",
    [SHARE.COMBAT] = "waiting for combat to end before sharing",
    [SHARE.FROM_PARTNER] = "not shared back: it came from your partner",
    [SHARE.OFF] = "not shared: quest sharing is off",
}

local held = {}       -- quest ids to share once combat ends
local fromPartner = {} -- quest ids the partner shared with us, so they aren't shared back

local function Title(id)
    local get = C_QuestLog and C_QuestLog.GetTitleForQuestID
    local t = get and ns.plain(get(id))
    return type(t) == "string" and t or ("quest " .. tostring(id))
end

local function Record(cause, id)
    local st = ns.db.share
    st.last = { cause = cause, id = id, title = id and Title(id) or nil, at = time() }
    st.counts[cause] = (st.counts[cause] or 0) + 1
end

local function LogIndex(id)
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then return C_QuestLog.GetLogIndexForQuestID(id) end
    if GetQuestLogIndexByID then return GetQuestLogIndexByID(id) end
end

-- The game shares the quest selected in the quest log, so the selection is
-- moved to this quest and put back afterwards.
local function Select(id, index)
    if C_QuestLog and C_QuestLog.SetSelectedQuest then
        local before = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest() or 0
        C_QuestLog.SetSelectedQuest(id)
        return function() C_QuestLog.SetSelectedQuest(before or 0) end
    end
    local before = GetQuestLogSelection and GetQuestLogSelection() or 0
    SelectQuestLogEntry(index)
    return function() SelectQuestLogEntry(before or 0) end
end

local function Push(id)
    local st = ns.db.share
    if not st.on then return Record(SHARE.OFF, id) end
    if fromPartner[id] then
        fromPartner[id] = nil
        return Record(SHARE.FROM_PARTNER, id)
    end
    if not ns.PartyHasPartner() then return Record(SHARE.NO_PARTNER, id) end
    if InCombatLockdown and InCombatLockdown() then
        held[id] = true
        return Record(SHARE.COMBAT, id)
    end
    local index = LogIndex(id)
    if not index or index == 0 then return Record(SHARE.NOT_SHAREABLE, id) end
    local restore = Select(id, index)
    local pushable
    if C_QuestLog and C_QuestLog.IsPushableQuest then
        pushable = C_QuestLog.IsPushableQuest(id)
    else
        pushable = GetQuestLogPushable and GetQuestLogPushable()
    end
    if pushable then QuestLogPushQuest() end
    restore()
    Record(pushable and SHARE.SHARED or SHARE.NOT_SHAREABLE, id)
end

-- Whether a unit, or a name the game gave, is one of the partner's paired characters in your party.
local function IsPartnerUnit(unit)
    return UnitIsPlayer(unit) and UnitInParty(unit) and ns.PairNames()[ns.norm(ns.FullName(unit))] or false
end

local function IsPartnerName(name)
    if type(name) ~= "string" then return false end
    local names = ns.PairNames()
    if not names[ns.norm(name)] then return false end
    for i = 1, 4 do
        local unit = "party" .. i
        local full = ns.FullName(unit)
        if full and (ns.norm(full) == ns.norm(name) or ns.norm(UnitName(unit)) == ns.norm(name))
            and names[ns.norm(full)] then
            return true
        end
    end
    return false
end

local function Accepted(id)
    fromPartner[id] = true
    Record(SHARE.ACCEPTED, id)
end

function ns.ToggleShare()
    local st = ns.db.share
    st.on = not st.on
    ns.Print("Quest sharing " .. (st.on and "on" or "off") ..
        ": quests you pick up are " .. (st.on and "" or "not ") .. "shared with your partner, and theirs are " ..
        (st.on and "" or "not ") .. "accepted for you.")
end

-- Sharing in plain words, one line, for /duo sync.
function ns.ShareReport()
    local st = ns.db.share
    local line = "Quest sharing " .. (st.on and "on" or "off") .. "."
    if st.last then
        line = line .. " Last: " .. st.last.title .. " " .. SHARE_TEXT[st.last.cause] .. " (" ..
            ns.Ago(st.last.at):lower() .. ")."
    end
    local n = 0
    for _ in pairs(held) do n = n + 1 end
    if n > 0 then line = line .. " Waiting for combat to end: " .. n .. "." end
    return line
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_DETAIL", "QUEST_ACCEPT_CONFIRM", "PLAYER_REGEN_ENABLED" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, ...)
    if not (ns.db and ns.db.share) then return end
    if event == "QUEST_ACCEPTED" then
        -- Older clients pass the log index first, newer ones only the quest id.
        local a, b = ...
        local id = b or a
        if type(id) == "number" and id > 0 then Push(id) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        local ids = held
        held = {}
        for id in pairs(ids) do Push(id) end
    elseif not ns.db.share.on then
        return
    elseif event == "QUEST_DETAIL" then
        if not IsPartnerUnit("questnpc") then return end
        local id = GetQuestID and GetQuestID()
        if not id or id == 0 then return end
        Accepted(id)
        if QuestGetAutoAccept and QuestGetAutoAccept() then
            CloseQuest() -- the game has accepted it already
        else
            AcceptQuest()
        end
    elseif event == "QUEST_ACCEPT_CONFIRM" then
        -- An escort or event quest a party member started.
        local name, _, id = ...
        if not IsPartnerName(name) then return end
        if type(id) == "number" then Accepted(id) end
        ConfirmAcceptQuest()
        if StaticPopup_Hide then StaticPopup_Hide("QUEST_ACCEPT") end
    end
end)
