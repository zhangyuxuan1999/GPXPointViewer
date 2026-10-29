#!/usr/bin/env python3
"""从 xcodebuild -exportLocalizations 的 xcloc 里抽出权威键表 → keys.jsonl（每行 {table, key, comment, specifiers, chunk}）并切块给翻译 agent。
用法：extract_keys.py <export dir> <out dir> [chunk=70]"""
import sys, os, re, json, glob, xml.etree.ElementTree as ET
exp, out = sys.argv[1], sys.argv[2]; chunk = int(sys.argv[3]) if len(sys.argv) > 3 else 70
os.makedirs(out, exist_ok=True)
ns = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
rows = {}
for xliff in glob.glob(exp + "/*.xcloc/Localized Contents/*.xliff"):
    lang = os.path.basename(xliff).split(".")[0]
    root = ET.parse(xliff).getroot()
    for f in root.findall("x:file", ns):
        orig = f.get("original", "")
        if "InfoPlist" in orig: continue
        table = ("GPXQuickLook/" if "GPXQuickLook" in orig else "") + os.path.basename(orig).replace(".xcstrings", "")
        for tu in f.find("x:body", ns).findall("x:trans-unit", ns):
            key = tu.get("id"); src = tu.findtext("x:source", default="", namespaces=ns); note = tu.findtext("x:note", default="", namespaces=ns) or ""
            if "|==|" in key: continue   # 已有复数变体的键，导出会再附 "<key>|==|plural.one/other" 子条目：翻译块里按基键的 plural 给，这里不当独立键
            r = rows.setdefault((table, key), {"table": table, "key": key, "source": src, "comment": note, "langs": set()})
            r["langs"].add(lang)
def specs(k): return re.findall(r"%(?:\d+\$)?[#@]?(?:\.\d+)?(?:ll|l|h)?[dfsu@xXeEgGc%]|%#@\w+@", k)
items = sorted(rows.values(), key=lambda r: (r["table"], r["key"]))
with open(out + "/keys.jsonl", "w", encoding="utf-8") as f:
    for i, r in enumerate(items):
        r["specifiers"] = specs(r["key"]); r["langs"] = sorted(r["langs"]); r["chunk"] = i // chunk
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
nchunks = (len(items) + chunk - 1) // chunk
for c in range(nchunks):
    with open(f"{out}/chunk_{c:02d}.json", "w", encoding="utf-8") as f:
        json.dump([{"table": r["table"], "key": r["key"], "comment": r["comment"], "specifiers": r["specifiers"]} for r in items if r["chunk"] == c], f, ensure_ascii=False, indent=1)
tables = {}
for r in items: tables[r["table"]] = tables.get(r["table"], 0) + 1
print(json.dumps({"keys": len(items), "chunks": nchunks, "tables": tables, "withSpecifiers": sum(1 for r in items if r["specifiers"]), "nonChinese": sum(1 for r in items if not re.search(r"[一-鿿]", r["key"]))}, ensure_ascii=False))
