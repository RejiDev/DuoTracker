"""Offline check of the quest comparison against real saved data.

Replays the addon's "quests to catch up on" rule over a DuoTracker saved-variables
file, reading quest requirements from the installed QuestieDB, and prints for each
pair how many quests are listed and how many are left out and why.

    python tools/quest_audit.py [path to WTF/.../SavedVariables/DuoTracker.lua]

With no argument it uses the newest DuoTracker.lua under the saved addons path.
"""
import base64
import glob
import os
import re
import sys

WOW = r"C:\Program Files (x86)\World of Warcraft\_forever_"
RACES, CLASSES, SKILL = 6, 7, 18  # field numbers, from QuestieDB src/meta/questMeta.lua


def cbor(b, i=0):
    head = b[i]
    major, info = head >> 5, head & 31
    i += 1
    if info < 24:
        n = info
    elif info < 28:
        size = 1 << (info - 24)
        n = int.from_bytes(b[i:i + size], "big")
        i += size
    else:
        raise ValueError("unsupported CBOR length")
    if major == 0:
        return n, i
    if major == 1:
        return -1 - n, i
    if major in (2, 3):
        return b[i:i + n], i + n
    if major == 4:
        out = []
        for _ in range(n):
            v, i = cbor(b, i)
            out.append(v)
        return out, i
    if major == 5:
        out = {}
        for _ in range(n):
            k, i = cbor(b, i)
            v, i = cbor(b, i)
            out[k if not isinstance(k, bytes) else k.decode()] = v
        return out, i
    return None, i  # floats and simple values are not needed here


def load_quests(toc):
    """quest id -> (race mask, class mask, required skill id)"""
    rows, skills = {}, {}
    pattern = re.compile(r"^## X-Quest-(\d+)-(S|18): (\S+)")
    with open(toc, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = pattern.match(line)
            if not m:
                continue
            value, _ = cbor(base64.b64decode(m.group(3)))
            if m.group(2) == "S":
                if isinstance(value, list):  # a dense row is stored as an array
                    value = {n + 1: v for n, v in enumerate(value)}
                rows[int(m.group(1))] = value
            else:
                skills[int(m.group(1))] = value
    out = {}
    for qid, row in rows.items():
        skill = skills.get(qid)
        while isinstance(skill, list) and skill and isinstance(skill[0], list):
            skill = skill[0]
        out[qid] = (row.get(RACES) or 0, row.get(CLASSES) or 0, skill[0] if skill else None)
    return out


def load_enum(path, table):
    text = open(path, encoding="utf-8").read()
    body = text[text.index(table):]
    return {k: int(v) for k, v in re.findall(r"(\w+)\s*=\s*(\d+)", body[:body.index("}")])}


def lua_table(text):
    """Parses the saved-variables table literal into dicts."""
    pos = text.index("{")
    token = re.compile(r'\s*(?:(\{)|(\})|\["((?:[^"\\]|\\.)*)"\]\s*=|\[(-?\d+)\]\s*=|"((?:[^"\\]|\\.)*)"|(-?[\d.]+)|(true|false|nil)|,)')

    def parse(i):
        out, n = {}, 0
        key = None
        while True:
            m = token.match(text, i)
            i = m.end()
            if m.group(2):
                return out, i
            if m.group(3) is not None:
                key = m.group(3)
                continue
            if m.group(4) is not None:
                key = int(m.group(4))
                continue
            if m.group(1):
                value, i = parse(i)
            elif m.group(5) is not None:
                value = m.group(5)
            elif m.group(6) is not None:
                value = float(m.group(6)) if "." in m.group(6) else int(m.group(6))
            elif m.group(7):
                value = {"true": True, "false": False, "nil": None}[m.group(7)]
            else:
                continue  # a comma
            if key is None:
                n += 1
                key = n
            out[key] = value
            key = None

    return parse(pos + 1)[0]


def norm(name):
    return re.sub(r"\s+", "", name or "").lower()


def main():
    if len(sys.argv) > 1:
        saved = sys.argv[1]
    else:
        files = glob.glob(os.path.join(WOW, "WTF", "Account", "*", "SavedVariables", "DuoTracker.lua"))
        saved = max(files, key=os.path.getmtime)
    qdb = os.path.join(WOW, "Interface", "AddOns", "QuestieDB")
    quests = load_quests(os.path.join(qdb, "QuestieDB_Forever.toc"))
    class_mask = load_enum(os.path.join(qdb, "src", "corrections", "enum", "expansions.lua"), "classKeys")
    skill_ids = load_enum(os.path.join(qdb, "src", "corrections", "enum", "professions.lua"), "professionKeys")
    skill_ids = {k.replace("_", "").lower(): v for k, v in skill_ids.items()}
    db = lua_table(open(saved, encoding="utf-8").read())
    chars, ignored = db["chars"], db.get("ignored", {})

    def verdict(qid, need):
        if qid not in quests:
            return "unknown to Questie"
        _races, classes, skill = quests[qid]
        mask = class_mask.get(need.get("class", ""), 0)
        if classes and mask and (classes % (2 * mask)) < mask:
            return "other class"
        if skill:
            profs = (need.get("x") or {}).get("profs") or {}
            have = {skill_ids.get(norm(p[1])) for p in profs.values()}
            if skill not in have:
                return "profession"
        return None

    print(f"{saved}\n{len(quests)} quests in QuestieDB\n")
    total_old = total_new = 0
    for pair in db["pairs"].values():
        a, b = chars.get(norm(pair[1])), chars.get(norm(pair[2]))
        if not (a and b and a.get("done") and b.get("done")):
            continue
        for need, have in ((a, b), (b, a)):
            old, kept, cut = 0, [], {}
            for qid in have["done"]:
                if qid in need["done"]:
                    continue
                old += 1
                why = verdict(qid, need)
                if why:
                    cut.setdefault(why, []).append(qid)
                else:
                    kept.append(qid)
            total_old += old
            total_new += len(kept)
            by_hand = sum(1 for q in kept if q in ignored)
            print(f"{need['name']} ({need.get('class')}) vs {have['name']}: {old} before -> {len(kept)} now"
                  f" ({by_hand} of those already ignored by hand)")
            for why, ids in sorted(cut.items()):
                print(f"    left out, {why}: {sorted(ids)}")
            print(f"    still listed: {sorted(kept)}")
    print(f"\nAll pairs: {total_old} before -> {total_new} now")


if __name__ == "__main__":
    main()
