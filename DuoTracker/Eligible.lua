-- Duo Tracker: whether a character is able to do a quest at all.
-- A quest only counts as "to catch up on" when the character behind could take
-- it. The requirements are read from QuestieDB (the database Questie uses);
-- nothing about individual quests is kept in this addon.
local _, ns = ...

local CONTRACT = 4 -- the QuestieDB contract version this file was written against

local quest, classKeys, raceMaskById
do
    local lib = _G.LibQuestieDB
    if type(lib) == "table" and type(lib.RequireContract) == "function" and lib.RequireContract(CONTRACT)
        and type(lib.Quest) == "table" and type(lib.Enum) == "table" then
        quest, classKeys, raceMaskById = lib.Quest, lib.Enum.classKeys, lib.Enum.raceMaskById
    end
end

-- True when quest requirements can be read on this computer.
function ns.QuestDataReady()
    return quest ~= nil
end

-- Masks hold one bit per class or race; Forever's race bits go past 32, so this is plain arithmetic.
local function allows(mask, flag)
    return not mask or mask == 0 or not flag or (mask % (2 * flag)) >= flag
end

-- Why character `c` can't do quest `id`: "class", "race" or "profession".
-- Returns nil when it can, or when requirements can't be read.
function ns.QuestBlock(id, c)
    if not quest then return nil end
    if not allows(quest.Get(id, "requiredClasses"), c.class and classKeys and classKeys[c.class]) then
        return "class"
    end
    if not allows(quest.Get(id, "requiredRaces"), c.race and raceMaskById and raceMaskById[c.race]) then
        return "race"
    end
    local skill = quest.Get(id, "requiredSkill")
    local skillId = type(skill) == "table" and skill[1]
    if skillId and not (c.x and c.x.skills and c.x.skills[skillId]) then
        return "profession"
    end
    return nil
end
