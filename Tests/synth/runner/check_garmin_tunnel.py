#!/usr/bin/env python3
"""真实数据回归：Muenchen_Roma_Garmin 隧道检测（2026-10-26 诊断 Tests/reports/20261026_1500_tunnel_diagnosis.md §1.3 / §3）。

用法（仓库根目录）：python3 -I Tests/synth/runner/check_garmin_tunnel.py <synthrunner 路径> [gpx 路径]
gpx 默认 data/compare/Muenchen_Roma_Garmin.gpx。只用标准库。

检查 synthrunner 输出的 merged_list（App 里看到的候选，经 shiftFrozenChains + 并群）：
- 候选 50 处（改前 44 + staleClock 微型入口 V1 新增 6 处）；
- 新增 6 处的原 A：8782 9807 9919 20907 21464 21646
  （诊断报告写作 8783…21647，那是「1 s 大跳」那一步的终点下标；候选 A 是它的前一点）；
- A 侧冻结假点链前移 12 处：(原 A, n)，前移后 iA = 原 A − n，frozenA = n；
- 23756（12 步真实直路）、21676（恒转弯率外推，不是锁死型）不前移；
- Inntal 2759–3012 区间内没有候选（83 m 量化抖动步不能被 V1 收进来）。
每条打印 ok/FAIL，末行 FAILS: none 或失败项列表；有失败时退出码 1。
"""
import json
import os
import subprocess
import sys

BASE44 = [128, 193, 214, 244, 293, 5882, 5958, 7178, 8420, 9050, 9323, 9468, 9625, 9732, 10021, 12013,
          20270, 20885, 20893, 20937, 21024, 21042, 21073, 21146, 21214, 21242, 21331, 21385, 21430, 21448,
          21497, 21528, 21676, 21730, 22719, 22979, 23046, 23281, 23461, 23756, 27117, 31246, 31290, 32750]
NEW6 = [8782, 9807, 9919, 20907, 21464, 21646]
FROZEN12 = {9050: 4, 9323: 4, 9468: 3, 9732: 4, 10021: 5, 20885: 5,
            21242: 3, 21385: 3, 21448: 3, 21730: 3, 31246: 5, 31290: 5}
UNMOVED = [23756, 21676]
INNTAL = (2759, 3012)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    runner = sys.argv[1]
    gpx = sys.argv[2] if len(sys.argv) > 2 else 'data/compare/Muenchen_Roma_Garmin.gpx'
    env = dict(os.environ, SYNTH_LIST_CAP='100000')
    out = subprocess.run([runner, gpx], capture_output=True, text=True, env=env)
    if out.returncode != 0:
        print('FAIL runner exit %d: %s' % (out.returncode, out.stderr.strip().splitlines()[-1:] if out.stderr else ''))
        print('FAILS: runner')
        return 1
    d = json.loads(out.stdout.strip().splitlines()[-1])
    cands = d['merged_list']
    # 原 A = 前移后 iA + frozenA
    orig = {}
    for c in cands:
        n = c.get('frozenA', 0)
        orig[c['iA'] + n] = (c['iA'], n, c['iB'])
    fails = []

    def check(name, cond, detail):
        print('%s  %s  %s' % ('ok  ' if cond else 'FAIL', name, detail))
        if not cond:
            fails.append(name)

    check('candidates==50', len(cands) == 50, 'merged=%d (gaps=%d stale=%d)' % (len(cands), d['gaps'], d['stale']))
    added = sorted(set(orig) - set(BASE44))
    check('new6', added == NEW6, 'added(origA)=%s expect=%s' % (added, NEW6))
    missing = sorted(set(BASE44) - set(orig))
    check('base44 kept', not missing, 'missing=%s' % missing)
    # 原 44 处的 B 也不能变（并群 21331→21337 照旧）
    changedB = [a for a in BASE44 if a in orig and orig[a][2] != a + (6 if a == 21331 else 2)]
    check('base44 iB unchanged', not changedB, 'changed=%s' % changedB)
    for a, n in sorted(FROZEN12.items()):
        got = orig.get(a)
        cond = got is not None and got[1] == n and got[0] == a - n
        check('frozen %d' % a, cond, 'expect iA=%d n=%d, got %s' % (a - n, n, None if got is None else 'iA=%d n=%d' % (got[0], got[1])))
    shifted44 = sorted(a for a in BASE44 if a in orig and orig[a][1] > 0)
    check('frozen hits in base44 ==12', shifted44 == sorted(FROZEN12), 'hits=%s' % shifted44)
    for a in UNMOVED:
        got = orig.get(a)
        check('unmoved %d' % a, got is not None and got[1] == 0, 'got %s' % (None if got is None else 'iA=%d n=%d' % (got[0], got[1])))
    inn = [c['iA'] for c in cands if c['iB'] >= INNTAL[0] and c['iA'] <= INNTAL[1]]
    check('inntal %d-%d empty' % INNTAL, not inn, 'cands=%s' % inn)
    new_hits = ['%d:n=%d' % (a, orig[a][1]) for a in NEW6 if a in orig and orig[a][1] > 0]
    print('info  V1 新增 6 处中前移的：%s' % (', '.join(new_hits) if new_hits else 'none'))
    print('FAILS: %s' % (', '.join(fails) if fails else 'none'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
