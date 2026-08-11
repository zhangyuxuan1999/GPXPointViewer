//
//  StressTest.swift
//  GPXPointViewer
//
//  压力测试数据生成：沿一条示意曲线（科布伦茨→特里尔方向）合成 N 个点，
//  多核并行填充预分配 SoA 数组（每线程写各自独立区间，无锁）。
//  生成后走与真实文件完全相同的投影/测速/着色/渲染流水线。
//

import Foundation

enum StressTest {

    static func generate(count n: Int) -> ParsedTrack {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ctrl: [(lat: Double, lon: Double)] = [
            (50.3506, 7.5886), (50.3000, 7.5600), (50.2400, 7.6000), (50.1800, 7.5500),
            (50.1300, 7.4700), (50.0600, 7.4500), (49.9900, 7.3500), (49.9500, 7.2200),
            (49.9000, 7.1000), (49.8300, 7.0000), (49.7800, 6.9000), (49.7557, 6.6514),
        ]
        let segs = ctrl.count - 1

        var lat = [Double](repeating: 0, count: n)
        var lon = [Double](repeating: 0, count: n)
        var ele = [Double](repeating: 0, count: n)
        var time = [Double](repeating: 0, count: n)

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, n / 4096 + 1))

        lat.withUnsafeMutableBufferPointer { pLat in
            lon.withUnsafeMutableBufferPointer { pLon in
                ele.withUnsafeMutableBufferPointer { pEle in
                    time.withUnsafeMutableBufferPointer { pTime in
                        let la = pLat.baseAddress!, lo = pLon.baseAddress!
                        let el = pEle.baseAddress!, ti = pTime.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                            let a = ci * n / chunks
                            let b = (ci + 1) * n / chunks
                            for i in a..<b {
                                let t = Double(i) / Double(max(1, n - 1))
                                let ft = t * Double(segs)
                                let seg = min(Int(ft), segs - 1)
                                let u = ft - Double(seg)
                                let s = (1.0 - cos(u * .pi)) * 0.5   // 平滑插值
                                let baseLat = ctrl[seg].lat + (ctrl[seg + 1].lat - ctrl[seg].lat) * s
                                let baseLon = ctrl[seg].lon + (ctrl[seg + 1].lon - ctrl[seg].lon) * s
                                // 小幅摆动，让点云有结构
                                let wiggle = 0.0035 * sin(t * 260.0 * .pi)
                                la[i] = baseLat + wiggle
                                lo[i] = baseLon + 0.006 * sin(t * 74.0 * .pi)
                                el[i] = 160.0 + 130.0 * sin(t * 16.0 * .pi)
                                ti[i] = 1_774_500_000.0 + Double(i) * 0.1
                            }
                        }
                    }
                }
            }
        }

        var out = ParsedTrack()
        out.lat = lat; out.lon = lon; out.ele = ele; out.time = time
        out.name = "压力测试 · \(n.formatted()) 点"
        out.chunkCount = chunks
        out.byteCount = 0
        out.parseSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        return out
    }
}
