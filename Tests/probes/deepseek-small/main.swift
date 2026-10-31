//
//  main.swift
//  Tests/probes/deepseek-small
//
//  本轮有界修复的离线定向探针：
//  - N25 Valhalla 错误码映射（从 RoadNetwork.swift 抽取的生产表达式）
//  - N28 RailPath 空/不完整路径防御 guard（从 RoadNetwork.swift 抽取的生产语句）
//
//  期望值来自 Valhalla 官方源码/API 合同与 DeepSeek/issues.md，不来自产品实现本身：
//  https://raw.githubusercontent.com/valhalla/valhalla/master/src/exceptions.cc
//  https://valhalla.github.io/valhalla/api/route/api-reference/#internal-error-codes-and-conditions
//  170 OSRM_NO_ROUTE、171 OSRM_NO_SEGMENT、172 OSRM_BREAKAGE_EXCEEDED；442 按官方异常实现归 NoRoute。
//  172 不得猜成 NoRoute/NoSegment，保留带错误码/错误文本的 fallback。
//
//  本文件不联网、不启动 app；run.py 从当前产品源码抽取函数后与它一起编译。
//

import Darwin
import Foundation

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
    }
}

func expectStatus(_ name: String, ec: Int, err: String, expected: String) {
    let got = valhallaStatus(ec, err)
    check(name, got == expected,
          "expected \(expected.debugDescription), got \(got.debugDescription)")
}

// MARK: - N25 Valhalla 错误码

expectStatus("N25 442 -> NoRoute", ec: 442, err: "OSRM_NO_ROUTE", expected: "NoRoute")
expectStatus("N25 170 -> NoRoute", ec: 170, err: "OSRM_NO_ROUTE", expected: "NoRoute")
expectStatus("N25 171 -> NoSegment", ec: 171, err: "OSRM_NO_SEGMENT", expected: "NoSegment")
expectStatus("N25 172 -> fallback with code and text", ec: 172,
             err: "OSRM_BREAKAGE_EXCEEDED", expected: "Valhalla 172 OSRM_BREAKAGE_EXCEEDED")
expectStatus("N25 unknown 0 -> fallback", ec: 0, err: "unknown", expected: "Valhalla 0 unknown")
expectStatus("N25 negative code -> fallback", ec: -7, err: "bad", expected: "Valhalla -7 bad")

let longError = String(repeating: "ABCDEFGHIJ", count: 10)   // 100 ASCII characters
expectStatus("N25 long error keeps only 60 characters", ec: 12345, err: longError,
             expected: "Valhalla 12345 " + String(longError.prefix(60)))
check("N25 long error is not longer than 60 chars", valhallaStatus(12345, longError).count ==
      "Valhalla 12345 ".count + 60,
      "got length \(valhallaStatus(12345, longError).count)")
check("N25 172 is not mapped to NoRoute", valhallaStatus(172, longError) != "NoRoute")
check("N25 172 is not mapped to NoSegment", valhallaStatus(172, longError) != "NoSegment")
check("N25 171 is not mapped to NoRoute", valhallaStatus(171, longError) != "NoRoute")

// MARK: - N28 RailPath guard

func expectNoRailPath(_ name: String, ids: [Int], coord: [Int: Int]) {
    do {
        let path = try railPathExcerpt(ids: ids, coord: coord)
        check(name, false, "did not throw; path=\(path)")
    } catch RouteError.noRailPath {
        check(name, true)
    } catch {
        check(name, false, "unexpected error \(error)")
    }
}

expectNoRailPath("N28 empty ids", ids: [], coord: [:])
expectNoRailPath("N28 single id", ids: [7], coord: [7: 1])
expectNoRailPath("N28 missing middle coordinate", ids: [1, 2, 3], coord: [1: 10, 3: 30])
expectNoRailPath("N28 missing first coordinate", ids: [1, 2, 3], coord: [2: 20, 3: 30])
expectNoRailPath("N28 missing last coordinate", ids: [1, 2, 3], coord: [1: 10, 2: 20])
expectNoRailPath("N28 empty ids but non-empty coord", ids: [], coord: [1: 10])

do {
    let got = try railPathExcerpt(ids: [1, 2, 3], coord: [1: 10, 2: 20, 3: 30])
    check("N28 normal chain unchanged", got == [10, 20, 30], "got \(got)")
} catch {
    check("N28 normal chain unchanged", false, "unexpected error \(error)")
}

do {
    let got = try railPathExcerpt(ids: [3, 1, 2], coord: [1: 10, 2: 20, 3: 30])
    check("N28 normal chain preserves ids order", got == [30, 10, 20], "got \(got)")
} catch {
    check("N28 normal chain preserves ids order", false, "unexpected error \(error)")
}

print("RESULT passed=\(passed) failed=\(failed)")
exit(failed == 0 ? 0 : 1)
