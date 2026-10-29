#!/usr/bin/env python3
"""把翻译块（translations/chunk_XX.json：[{table,key,en,de,zh-Hant,plural?:{lang:{one,other}},noTranslate?}]）组装成 xcstrings，
校验占位符多重集一致（lld 不变、%% 不变；允许位置参数 %1$@ 形式），列出缺失。
用法：assemble.py <keys.jsonl> <translations dir> <repo root>"""
import sys, os, json, re, glob
keys_path, tdir, root = sys.argv[1], sys.argv[2], sys.argv[3]
def specs(k): return sorted(re.sub(r"^%\d+\$", "%", s) for s in re.findall(r"%(?:\d+\$)?[#@]?(?:\.\d+)?(?:ll|l|h)?[dfsu@xXeEgGc%]|%#@\w+@", k))
keys = [json.loads(l) for l in open(keys_path, encoding="utf-8")]
trans = {}
for f in sorted(glob.glob(tdir + "/chunk_*.json")):
    for t in json.load(open(f, encoding="utf-8")): trans[(t["table"], t["key"])] = t
problems, missing = [], []
catalogs = {}
for r in keys:
    table, key = r["table"], r["key"]
    cat = catalogs.setdefault(table, {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"})
    entry = {"localizations": {}}
    if r.get("comment"): entry["comment"] = r["comment"]
    t = trans.get((table, key))
    if t is None: missing.append(f"{table}:{key}"); cat["strings"][key] = entry; continue
    if t.get("noTranslate"):
        entry["shouldTranslate"] = False; cat["strings"][key] = entry; continue
    src = specs(r.get("source") or key)
    for lang in ("en", "de", "zh-Hant"):
        pl = (t.get("plural") or {}).get(lang)
        if pl:
            for form, v in pl.items():
                if specs(v) != src: problems.append(f"{table}:{key} [{lang}/{form}] specifiers {specs(v)} != {src}")
            entry["localizations"][lang] = {"variations": {"plural": {form: {"stringUnit": {"state": "translated", "value": v}} for form, v in pl.items()}}}
        else:
            v = t.get(lang)
            if not v: missing.append(f"{table}:{key} [{lang}]"); continue
            if specs(v) != src: problems.append(f"{table}:{key} [{lang}] specifiers {specs(v)} != {src}")
            entry["localizations"][lang] = {"stringUnit": {"state": "translated", "value": v}}
    cat["strings"][key] = entry
for table, cat in catalogs.items():
    path = os.path.join(root, table + ".xcstrings") if "/" in table else os.path.join(root, "GPXPointViewer", table + ".xcstrings")
    json.dump(cat, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2, sort_keys=True)
    print("wrote", path, len(cat["strings"]), "keys")
print("missing", len(missing)); [print("  MISSING", m) for m in missing[:40]]
print("specifier problems", len(problems)); [print("  BAD", p) for p in problems[:40]]
sys.exit(1 if problems else 0)
