"""Offline tests for Duo Tracker. Run every test with:

    python tools/test.py

Two copies of the addon run in Lua 5.1 (the version WoW uses) with a small fake of
the WoW API, joined by a fake Battle.net link, on a simulated clock. Each test logs
both players in, lets them play, and checks what each one sees of the other.

Needs `pip install lupa`. Older versions of the addon are read from git, so mixed
versions (one player updated, the other not) are tested against the real old code.
"""
import os
import re
import subprocess
import sys

from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "DuoTracker")
# Versions players may still be running, by the commit that released them.
OLD_VERSIONS = {"1.6.1": "48961e0", "1.7.0": "0e9e8a9", "1.8.0": "3097c76"}

FAKE_WOW = r"""
local clock = 1800000000
local timers = {}
local frames = {}
errors = {}
printed = {}

function time() return math.floor(clock) end
function GetTime() return clock end

local function run(f, ...)
    local ok, err = pcall(f, ...)
    if not ok then errors[#errors + 1] = tostring(err) end
end

function advance(seconds)
    local stop = clock + seconds
    while true do
        local best
        for _, t in ipairs(timers) do
            if not t.cancelled and t.at <= stop and (not best or t.at < best.at) then best = t end
        end
        if not best then break end
        clock = best.at
        if best.every then best.at = best.at + best.every else best.cancelled = true end
        run(best.f, best)
    end
    clock = stop
end

C_Timer = {
    After = function(s, f) timers[#timers + 1] = { at = clock + s, f = f } end,
    NewTicker = function(s, f)
        local t = { at = clock + s, every = s, f = f }
        t.Cancel = function() t.cancelled = true end
        timers[#timers + 1] = t
        return t
    end,
}

-- Every widget is one stub: any method works and returns another stub.
local stubMeta = {}
local function stub() return setmetatable({}, stubMeta) end
stubMeta.__index = function(self, key)
    -- Game methods start with a capital letter; anything else is a field the addon sets itself.
    if type(key) ~= "string" or not key:match("^%u") then return nil end
    if key == "RegisterEvent" then
        return function(f, e) f._events = f._events or {}; f._events[e] = true end
    elseif key == "UnregisterEvent" then
        return function(f, e) if f._events then f._events[e] = nil end end
    elseif key == "SetScript" then
        return function(f, name, fn) f["_" .. name] = fn end
    elseif key == "GetScript" then
        return function(f, name) return f["_" .. name] end
    elseif key == "IsShown" then
        return function(f) return f._shown == true end
    elseif key == "Show" then
        return function(f) f._shown = true end
    elseif key == "Hide" then
        return function(f) f._shown = false end
    elseif key == "GetHeight" or key == "GetWidth" or key == "GetStringWidth" then
        return function() return 10 end
    elseif key == "GetText" then
        return function(f) return f._text or "" end
    elseif key == "SetText" then
        return function(f, t) f._text = t end
    end
    return function() return stub() end
end
function CreateFrame()
    local f = stub()
    frames[#frames + 1] = f
    return f
end
function fire(event, ...)
    for _, f in ipairs(frames) do
        if f._events and f._events[event] and f._OnEvent then run(f._OnEvent, f, event, ...) end
    end
end
UIParent, Minimap, GameTooltip = stub(), stub(), stub()
UISpecialFrames = {}
RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
LOCALIZED_CLASS_NAMES_MALE = {}
NUM_BAG_SLOTS = 4
BNET_CLIENT_WOW = "WoW"
SlashCmdList = {}
function print(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    printed[#printed + 1] = table.concat(t, " ")
end
function hooksecurefunc() end
function IsInGroup() return link.party end
function GetMoney() return player.gold end
function UnitName(unit)
    if unit == "player" then return player.first, player.last end
    if unit == "party1" and link.party then return link.partyFirst, link.partyLast end
    if unit == "questnpc" and quests.giver then return quests.giver[1], quests.giver[2] end
end
function UnitClass(unit) return player.class, player.class end
function UnitRace(unit) return "Orc", "Orc", 2 end
function UnitLevel(unit) return player.level end
function UnitXP(unit) return player.xp end
function UnitXPMax(unit) return player.xpmax end
function GetProfessions() return nil end
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, text, channel)
        if not link.party then return 1 end
        link.partyOut[#link.partyOut + 1] = { prefix, text }
        return 0
    end,
}
C_QuestLog = {
    GetAllCompletedQuestIDs = function() return player.quests end,
    GetTitleForQuestID = function(id) return "Quest " .. id end,
    RequestLoadQuestByID = function() end,
}
C_Container = { GetContainerNumSlots = function() return 0 end }

-- The quest log, and sharing over the party link.
quests = { log = {}, selected = 0, unshareable = {}, combat = false, offered = 0, giver = nil, accepted = {} }
C_QuestLog.GetLogIndexForQuestID = function(id)
    for i, q in ipairs(quests.log) do if q == id then return i end end
end
C_QuestLog.GetSelectedQuest = function() return quests.selected end
C_QuestLog.SetSelectedQuest = function(id) quests.selected = id end
C_QuestLog.IsPushableQuest = function(id) return not quests.unshareable[id] end
function QuestLogPushQuest()
    if link.party then link.pushes[#link.pushes + 1] = quests.selected end
end
function InCombatLockdown() return quests.combat end
function GetQuestID() return quests.offered end
function QuestGetAutoAccept() return false end
function ConfirmAcceptQuest() pickUp(quests.confirm) end
function confirm(id, name)
    quests.confirm = id
    fire("QUEST_ACCEPT_CONFIRM", name, "Quest " .. id, id)
end
function pickUp(id)
    quests.log[#quests.log + 1] = id
    fire("QUEST_ACCEPTED", id)
end
function AcceptQuest()
    quests.accepted[#quests.accepted + 1] = quests.offered
    pickUp(quests.offered)
end
function offer(id, first, last)
    quests.offered, quests.giver = id, { first, last }
    fire("QUEST_DETAIL")
end
C_Item = { GetItemInfo = function() return nil end }

-- The Battle.net link: what the other player looks like from here, and the wire.
link = { online = false, party = false, outbox = {}, partyOut = {}, pushes = {} }
function BNGetNumFriends() return 1 end
C_BattleNet = {
    GetFriendAccountInfo = function(i) return { battleTag = link.tag } end,
    GetFriendNumGameAccounts = function(i) return link.online and 1 or 0 end,
    GetFriendGameAccountInfo = function(i, j)
        return { isOnline = link.online, gameAccountID = link.id, clientProgram = "WoW",
            characterName = link.character }
    end,
}
function BNSendGameData(id, prefix, text)
    if id == link.id and link.online then link.outbox[#link.outbox + 1] = { prefix, text } end
end
"""


class Player:
    """One copy of the addon, on one account, with its own saved variables."""

    def __init__(self, name, version, battle_tag, account_id):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.version, self.tag, self.account_id = version, battle_tag, account_id
        self.lua.execute(FAKE_WOW)
        self.g = self.lua.globals()
        self.g.player = self.lua.table_from({"first": "", "last": "", "class": "WARRIOR", "level": 1,
                                             "xp": 0, "xpmax": 400, "gold": 0,
                                             "quests": self.lua.table()})
        files = self.files()
        toc = files["DuoTracker.toc"]
        meta = dict(re.findall(r"(?m)^## ([^:]+):\s*(.*?)\s*$", toc))
        self.g.GetAddOnMetadata = lambda addon, key: meta.get(key)
        self.lua.execute("C_AddOns = { GetAddOnMetadata = GetAddOnMetadata }")
        self.ns = self.lua.table()
        load = self.lua.eval("function(src, name) return assert(loadstring(src, '@' .. name)) end")
        for line in toc.splitlines():
            line = line.strip()
            if line.endswith(".lua"):
                load(files[line], line)("DuoTracker", self.ns)
        self.name = name

    def files(self):
        if self.version == "current":
            return {f: open(os.path.join(ADDON, f), encoding="utf-8").read()
                    for f in os.listdir(ADDON) if f.endswith((".lua", ".toc"))}
        commit = OLD_VERSIONS[self.version]
        names = subprocess.run(["git", "-C", ROOT, "ls-tree", "--name-only", commit, "DuoTracker/"],
                               capture_output=True, text=True, check=True).stdout.split()
        out = {}
        for path in names:
            if path.endswith((".lua", ".toc")):
                out[os.path.basename(path)] = subprocess.run(
                    ["git", "-C", ROOT, "show", commit + ":" + path],
                    capture_output=True, text=True, check=True, encoding="utf-8").stdout
        return out

    def play(self, character, cls, level, xp, xpmax):
        first, last = character.split(" ", 1)
        p = self.g.player
        p.first, p.last = first, last
        p["class"], p.level, p.xp, p.xpmax = cls, level, xp, xpmax

    def login(self):
        self.lua.eval("fire")("PLAYER_LOGIN")

    def db(self):
        return self.g.DuoTrackerDB

    def char(self, key):
        chars = self.db().chars
        return chars[key] if chars else None

    def errors(self):
        return list(self.g.errors.values())


def connect(a, b, a_char, b_char, transport="bn"):
    """Puts both players online and visible to each other, over Battle.net or in a party."""
    for me, other, other_char in ((a, b, b_char), (b, a, a_char)):
        link = me.g.link
        if transport == "bn":
            link.online = True
            link.id = other.account_id
            link.tag = other.tag
            link.character = other_char.split(" ")[0]
        else:
            link.party = True
            link.partyFirst, link.partyLast = other_char.split(" ", 1)
        me.sender = a_char if me is a else b_char


def run(a, b, seconds, step=0.25):
    """Advances both clocks together, delivering messages as they are sent."""
    t = 0.0
    while t < seconds:
        for me, other in ((a, b), (b, a)):
            me.lua.eval("advance")(step)
            fire = other.lua.eval("fire")
            for box, deliver in (("outbox", lambda m: fire("BN_CHAT_MSG_ADDON", m[1], m[2], "WHISPER", me.account_id)),
                                 ("partyOut", lambda m: fire("CHAT_MSG_ADDON", m[1], m[2], "PARTY", me.sender + "-Forever"))):
                out = me.g.link[box]
                msgs = [out[i] for i in range(1, len(out) + 1)]
                me.lua.execute("link.%s = {}" % box)
                for m in msgs:
                    deliver(m)
            pushes = me.g.link.pushes
            ids = [pushes[i] for i in range(1, len(pushes) + 1)]
            me.lua.execute("link.pushes = {}")
            first, last = me.sender.split(" ", 1)
            for qid in ids:
                other.lua.eval("offer")(qid, first, last)
        t += step


FAILURES = []


def check(label, ok, detail=""):
    print(("  ok    " if ok else "  FAIL  ") + label + ("" if ok else "  (" + detail + ")"))
    if not ok:
        FAILURES.append(label)


def start(version_a, version_b, transport="bn", reji_db=None):
    reji = Player("Reji", version_a, "Reji#1111", 101)
    mark = Player("Mark", version_b, "Mark#2222", 202)
    if reji_db:
        reji.g.DuoTrackerDB = reji.lua.table_from(reji_db)
    reji.play("Reji Planty", "WARRIOR", 20, 9352, 23200)
    mark.play("Marjorie Dawes", "ROGUE", 18, 13961, 19400)
    reji.login()
    mark.login()
    connect(reji, mark, "Reji Planty", "Marjorie Dawes", transport)
    run(reji, mark, 30)
    return reji, mark


def xp_of(p, key):
    c = p.char(key)
    return None if c is None else (c.level, c.xp)


def sync_pair(version_a, version_b, transport="bn", break_mark_refresh=False):
    """Reji on `version_a` and Mark on `version_b` play a pair together."""
    print("Reji on %s, Mark on %s, over %s%s" % (version_a, version_b, transport,
                                                ", Mark's window refresh broken" if break_mark_refresh else ""))
    reji, mark = start(version_a, version_b, transport)
    if break_mark_refresh:
        mark.ns.UpdateBadge = mark.lua.eval("function() error('refresh broke') end")

    check("Reji sees Mark's character after logging in", xp_of(reji, "marjoriedawes") == (18, 13961),
          "got %r" % (xp_of(reji, "marjoriedawes"),))
    check("Mark sees Reji's character after logging in", xp_of(mark, "rejiplanty") == (20, 9352),
          "got %r" % (xp_of(mark, "rejiplanty"),))

    # Mark kills things for a while; Reji should see each change within half a minute.
    for xp in (14500, 15200, 16100):
        mark.g.player.xp = xp
        run(reji, mark, 30)
        check("Reji sees Mark's XP reach %d within 30 s" % xp, xp_of(reji, "marjoriedawes") == (18, xp),
              "got %r" % (xp_of(reji, "marjoriedawes"),))

    mark.g.player.level, mark.g.player.xp, mark.g.player.xpmax = 19, 200, 21300
    mark.lua.eval("fire")("PLAYER_LEVEL_UP", 19)
    run(reji, mark, 30)
    check("Reji sees Mark's level-up within 30 s", xp_of(reji, "marjoriedawes") == (19, 200),
          "got %r" % (xp_of(reji, "marjoriedawes"),))

    reji.g.player.xp = 12000
    run(reji, mark, 30)
    check("Mark sees Reji's XP change within 30 s", xp_of(mark, "rejiplanty") == (20, 12000),
          "got %r" % (xp_of(mark, "rejiplanty"),))

    if break_mark_refresh:
        err = mark.db().sync.refreshError
        check("Mark's addon recorded the refresh error", err is not None and "refresh broke" in str(err.err))
    else:
        for p in (reji, mark):
            errs = p.errors()
            check("%s's addon raised no Lua errors" % p.name, not errs, "; ".join(errs[:3]))
    for p in (reji, mark):
        if p.version == "current":
            p.ns.ToggleUI()
            for tab in ("overview", "gear", "profs", "gold", "notes"):
                p.ns.ShowTab(tab)
            err = p.db().sync.refreshError
            if not break_mark_refresh or p is reji:
                check("%s's window draws every tab" % p.name, err is None, str(err and err.err))
            st = p.db().sync
            check("%s's addon recorded the last message in" % p.name, st.lastIn is not None)
            drops = [k for k in st.drops] if st.drops else []
            check("%s's addon dropped nothing" % p.name, not drops, "dropped %s" % drops)


def wrong_partner():
    """Reji's saved BattleTag is someone else's: every message from Mark is turned away."""
    print("Reji's saved partner BattleTag is wrong")
    reji, mark = start("current", "current", reji_db={"schema": 2, "partnerTag": "Someone#9999"})
    d = reji.db().sync.drops["unknown_sender"]
    check("Reji's addon records Mark's messages as from an unknown sender", d is not None and d.n > 0)
    check("the record names who sent them", d is not None and "Mark#2222" in str(d.detail),
          "got %r" % (None if d is None else d.detail,))
    report = " / ".join(reji.ns.SyncReport().values())
    check("/duo sync explains it", "isn't your partner" in report and "Mark#2222" in report, report)


def lst(t):
    return [t[i] for i in range(1, len(t) + 1)] if t else []


def quest_sharing():
    """In a party, a quest one picks up is shared and the other accepts it; nothing is shared back."""
    print("Quest sharing in a party")
    reji, mark = start("current", "current", transport="party")
    reji.lua.eval("pickUp")(101)
    run(reji, mark, 2)
    check("Mark accepted the quest Reji picked up", lst(mark.g.quests.accepted) == [101],
          "got %r" % lst(mark.g.quests.accepted))
    check("Reji's record says it was shared", reji.db().share.last.cause == "shared", str(reji.db().share.last.cause))
    check("Mark's record says it came from Reji and wasn't shared back",
          mark.db().share.last.cause == "accepted" and mark.db().share.counts["shared"] is None
          and lst(reji.g.quests.accepted) == [])
    check("/duo sync shows it", "Quest sharing on" in " / ".join(reji.ns.SyncReport().values()))

    reji.g.quests.combat = True
    reji.lua.eval("pickUp")(102)
    run(reji, mark, 2)
    check("in combat the quest waits", 102 not in lst(mark.g.quests.accepted) and reji.db().share.last.cause == "combat")
    reji.g.quests.combat = False
    reji.lua.eval("fire")("PLAYER_REGEN_ENABLED")
    run(reji, mark, 2)
    check("it is shared once combat ends", 102 in lst(mark.g.quests.accepted), "got %r" % lst(mark.g.quests.accepted))

    reji.lua.execute("quests.unshareable[103] = true")
    reji.lua.eval("pickUp")(103)
    run(reji, mark, 2)
    check("a quest the game can't share is recorded, not sent",
          reji.db().share.last.cause == "not_shareable" and 103 not in lst(mark.g.quests.accepted))

    mark.lua.eval("offer")(104, "Random", "Stranger")
    check("a quest shared by someone not paired isn't accepted", 104 not in lst(mark.g.quests.accepted))

    mark.lua.eval("confirm")(106, "Reji Planty")
    run(reji, mark, 2)
    check("an escort quest Reji starts is confirmed for Mark, not shared back",
          106 in lst(mark.g.quests.log) and mark.db().share.last.cause == "accepted")
    mark.lua.eval("confirm")(107, "Random Stranger")
    check("an escort quest a stranger starts isn't confirmed", 107 not in lst(mark.g.quests.log))

    mark.ns.ToggleShare()
    reji.lua.eval("pickUp")(105)
    run(reji, mark, 2)
    check("with sharing off on Mark's side, Mark doesn't accept", 105 not in lst(mark.g.quests.accepted))
    mark.ns.ToggleShare()
    for p in (reji, mark):
        errs = p.errors()
        check("%s's addon raised no Lua errors" % p.name, not errs, "; ".join(errs[:3]))


def quest_sharing_bn_only():
    """Synced over Battle.net but not grouped: nothing to share with."""
    print("Quest sharing while not in a party")
    reji, mark = start("current", "current")
    reji.lua.eval("pickUp")(201)
    run(reji, mark, 2)
    check("not shared when the partner isn't in the party", reji.db().share.last.cause == "no_partner"
          and lst(mark.g.quests.accepted) == [])


def main():
    sync_pair("current", "current")
    for old in OLD_VERSIONS:
        sync_pair("current", old)
        sync_pair(old, "current")
    sync_pair("current", "current", transport="party")
    sync_pair("current", "current", break_mark_refresh=True)
    wrong_partner()
    quest_sharing()
    quest_sharing_bn_only()
    print()
    if FAILURES:
        print("%d check(s) failed." % len(FAILURES))
        sys.exit(1)
    print("All checks passed.")


if __name__ == "__main__":
    main()
