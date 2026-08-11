//
//  PixelGlobe.swift
//  GPXPointViewer
//
//  像素地球模式的数据侧：等积点阵网格、陆地/海洋地形点（内置 land_mask.png
//  采样）、轨迹点聚合成数据柱（计数取十位数 → 对数高度 + 蓝→红色温），
//  以及"有数据的大城市"标签选取。
//
//  性能设计：
//  - 网格 221 行 / ~6.4 万点，进程内缓存（gridRows/gridOffsets），实例缓冲 ~2 MB；
//  - 聚合是单趟扫描（行偏移 + 直接下标，无字典）；大数据量时分块并行计数
//    （每线程部分数组 + vDSP 归约），-O 下毫秒级；
//  - 只在 数据换代 / 时间筛选变化 / 切入像素模式 时重建，逐帧零 CPU。
//

import Foundation
import Accelerate
import CoreGraphics
import ImageIO
import simd

/// 与 Shaders.metal 中 PixelDot 逐字段对齐（32 B）
struct PixelDotData {
    var a: SIMD4<Float>   // xyz = 球面单位向量；w = 地形点: 0 海洋 / 1 陆地；数据柱: 柱高
    var b: SIMD4<Float>   // 数据柱颜色 rgba（地形点忽略）
}

/// 大城市（像素模式地名标签用）
struct GlobeCity {
    let name: String
    let lat: Double
    let lon: Double
}

enum PixelGlobe {
    static let cellDeg = 0.8            // 点阵/聚合格距（度），赤道约 89 km

    // MARK: 网格

    /// 纬度行表：每行 (下边缘纬度, 列数)；列数 ∝ cos(lat) → 近似等积
    static func rows() -> [(lat: Double, cols: Int)] {
        var r: [(Double, Int)] = []
        var lat = -88.0
        while lat <= 88.0 {
            r.append((lat, max(8, Int(360.0 / cellDeg * cos(lat * .pi / 180)))))
            lat += cellDeg
        }
        return r
    }

    static func rowOffsets(_ rows: [(lat: Double, cols: Int)]) -> [Int] {
        var offs = [Int](repeating: 0, count: rows.count + 1)
        for i in 0..<rows.count { offs[i + 1] = offs[i] + rows[i].cols }
        return offs
    }

    /// 网格只与 cellDeg 有关，进程内不变——缓存起来，免去每次聚合重建 221 行 cos 表
    static let gridRows = rows()
    static let gridOffsets = rowOffsets(gridRows)

    @inline(__always)
    static func unitOf(latDeg: Double, lonDeg: Double) -> SIMD3<Float> {
        let la = latDeg * Double.pi / 180
        let lo = lonDeg * Double.pi / 180
        return SIMD3(Float(cos(la) * sin(lo)), Float(sin(la)), Float(cos(la) * cos(lo)))
    }

    // MARK: 地形点阵（一次性）

    /// 全球点阵：每格采样内置陆地掩码 → 海洋(0)/陆地(1)
    static func terrainDots() -> [PixelDotData] {
        guard let mask = loadMask() else { return [] }
        let rs = gridRows
        var dots = [PixelDotData]()
        dots.reserveCapacity(65_000)
        for (lat0, cols) in rs {
            let lat = lat0 + cellDeg / 2
            for c in 0..<cols {
                let lon = -180.0 + (Double(c) + 0.5) * 360.0 / Double(cols)
                let mx = min(mask.w - 1, max(0, Int((lon + 180) / 360 * Double(mask.w))))
                let my = min(mask.h - 1, max(0, Int((90 - lat) / 180 * Double(mask.h))))
                let land: Float = mask.data[my * mask.w + mx] > 128 ? 1 : 0
                let u = unitOf(latDeg: lat, lonDeg: lon)
                dots.append(PixelDotData(a: SIMD4(u.x, u.y, u.z, land), b: .zero))
            }
        }
        return dots
    }

    /// 裸位打包掩码：<W:UInt16LE><H:UInt16LE> + 每行 ceil(W/8) 字节（MSB 在前），
    /// 行序自上而下（lat 90 → -90）。零解码依赖，无图像框架的方向/色彩空间歧义。
    private static func loadMask() -> (data: [UInt8], w: Int, h: Int)? {
        guard let url = Bundle.main.url(forResource: "land_mask", withExtension: "bin"),
              let raw = try? Data(contentsOf: url), raw.count > 4 else { return nil }
        let w = Int(raw[raw.startIndex]) | (Int(raw[raw.startIndex + 1]) << 8)
        let h = Int(raw[raw.startIndex + 2]) | (Int(raw[raw.startIndex + 3]) << 8)
        let rowBytes = (w + 7) / 8
        guard w > 0, h > 0, raw.count >= 4 + rowBytes * h else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        raw.withUnsafeBytes { buf in
            let p = buf.baseAddress!.advanced(by: 4).assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                let row = p + y * rowBytes
                for x in 0..<w where (row[x >> 3] & (0x80 >> UInt8(x & 7))) != 0 {
                    out[y * w + x] = 255
                }
            }
        }
        return (out, w, h)
    }

    // MARK: 数据聚合（单趟扫描，无字典）

    /// range 内的点按格计数 → 数据柱。
    /// 计数取十位数（示意图精度），高度 = 0.014 + 0.032·(log10−1)（封顶 0.15R），
    /// 颜色 蓝(少) → 红(多)。返回 (柱实例, 平行的计数数组——标签热度用)。
    static func aggregate(track: TrackData,
                          range: (start: Int, len: Int)) -> (cells: [PixelDotData], counts: [Int32]) {
        let rs = gridRows
        let offs = gridOffsets
        let total = offs[rs.count]
        var counts = [Int32](repeating: 0, count: total)
        let a = max(0, min(range.start, track.count))
        let b = max(a, min(range.start + range.len, track.count))
        let n = b - a
        track.lat.withUnsafeBufferPointer { lap in
            track.lon.withUnsafeBufferPointer { lop in
                let la = lap.baseAddress!, lo = lop.baseAddress!
                let inv = 1.0 / cellDeg
                // 计数核：把 [s,e) 的点累进 dst（各线程写各自的部分计数，互不重叠）
                func countInto(_ dst: UnsafeMutablePointer<Int32>, _ s: Int, _ e: Int) {
                    for i in s..<e {
                        let y = la[i]
                        guard y > -88.0, y < 88.8 else { continue }
                        let row = min(rs.count - 1, Int((y + 88.0) * inv))
                        let cols = rs[row].cols
                        var x = lo[i]
                        if x < -180 { x += 360 }; if x >= 180 { x -= 360 }
                        let col = min(cols - 1, max(0, Int((x + 180.0) / 360.0 * Double(cols))))
                        dst[offs[row] + col] &+= 1
                    }
                }
                let cores = ProcessInfo.processInfo.activeProcessorCount
                if n > 200_000, cores > 1 {
                    // 并行分块计数 → 每线程部分数组（~256 KB/份）→ vDSP 整数向量求和归约
                    let parts = min(cores, max(2, n / 100_000))
                    var partial = [Int32](repeating: 0, count: parts * total)
                    partial.withUnsafeMutableBufferPointer { pb in
                        let pbase = pb.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: parts) { pi in
                            countInto(pbase + pi * total,
                                      a + n * pi / parts, a + n * (pi + 1) / parts)
                        }
                        counts.withUnsafeMutableBufferPointer { cb in
                            let c = cb.baseAddress!
                            for pi in 0..<parts {
                                vDSP_vaddi(c, 1, pbase + pi * total, 1, c, 1, vDSP_Length(total))
                            }
                        }
                    }
                } else {
                    counts.withUnsafeMutableBufferPointer { cb in
                        countInto(cb.baseAddress!, a, b)
                    }
                }
            }
        }
        var cells = [PixelDotData]()
        var cellCounts = [Int32]()
        cells.reserveCapacity(4096)
        for (ri, rc) in rs.enumerated() {
            let lat = rc.lat + cellDeg / 2
            let base = offs[ri]
            for c in 0..<rc.cols where counts[base + c] > 0 {
                let n = Int(counts[base + c])
                let n10 = max(10, n / 10 * 10)                 // 精确到十位数
                let lg = log10(Double(n10))
                let h = Float(min(0.15, 0.014 + 0.032 * (lg - 1)))
                let t = Float(max(0, min(1, (lg - 1) / 3.5)))
                let color = SIMD3<Float>(0.30, 0.55, 1.00) * (1 - t)
                          + SIMD3<Float>(1.00, 0.32, 0.25) * t
                let lon = -180.0 + (Double(c) + 0.5) * 360.0 / Double(rc.cols)
                let u = unitOf(latDeg: lat, lonDeg: lon)
                cells.append(PixelDotData(a: SIMD4(u.x, u.y, u.z, h),
                                          b: SIMD4(color.x, color.y, color.z, 1)))
                cellCounts.append(Int32(n))
            }
        }
        return (cells, cellCounts)
    }

    // MARK: 地名标签（只标有数据的省会/大城市）

    /// 城市热度 = 1.3° 内数据柱计数和；≥ 40 才入选；按热度取前 limit 个，
    /// 相邻 1° 内只保留热度更高者
    static func labels(cells: [PixelDotData], counts: [Int32],
                       limit: Int = 14) -> [(city: GlobeCity, unit: SIMD3<Double>)] {
        guard !cells.isEmpty else { return [] }
        let cosR = cos(1.3 * Double.pi / 180)
        var scored: [(GlobeCity, SIMD3<Double>, Int)] = []
        for city in cities {
            let cu = unitOf(latDeg: city.lat, lonDeg: city.lon)
            let cud = SIMD3<Double>(Double(cu.x), Double(cu.y), Double(cu.z))
            var s = 0
            for (i, cell) in cells.enumerated() {
                let d = Double(cu.x * cell.a.x + cu.y * cell.a.y + cu.z * cell.a.z)
                if d > cosR { s += Int(counts[i]) }
            }
            if s >= 40 { scored.append((city, cud, s)) }
        }
        scored.sort { $0.2 > $1.2 }
        let cosSep = cos(1.0 * Double.pi / 180)
        var picked: [(city: GlobeCity, unit: SIMD3<Double>)] = []
        for (city, u, _) in scored {
            guard picked.count < limit else { break }
            if picked.allSatisfy({ simd_dot($0.unit, u) < cosSep }) {
                picked.append((city, u))
            }
        }
        return picked
    }

    /// 省会 + 重要大城市（中文名，全球覆盖）
    static let cities: [GlobeCity] = [
        // 中国：直辖市/省会/首府 + 重要城市
        GlobeCity(name: "北京", lat: 39.90, lon: 116.41), GlobeCity(name: "上海", lat: 31.23, lon: 121.47),
        GlobeCity(name: "天津", lat: 39.13, lon: 117.20), GlobeCity(name: "重庆", lat: 29.56, lon: 106.55),
        GlobeCity(name: "石家庄", lat: 38.04, lon: 114.51), GlobeCity(name: "太原", lat: 37.87, lon: 112.55),
        GlobeCity(name: "呼和浩特", lat: 40.84, lon: 111.75), GlobeCity(name: "沈阳", lat: 41.80, lon: 123.43),
        GlobeCity(name: "长春", lat: 43.82, lon: 125.32), GlobeCity(name: "哈尔滨", lat: 45.80, lon: 126.53),
        GlobeCity(name: "南京", lat: 32.06, lon: 118.80), GlobeCity(name: "杭州", lat: 30.27, lon: 120.16),
        GlobeCity(name: "合肥", lat: 31.82, lon: 117.23), GlobeCity(name: "福州", lat: 26.07, lon: 119.30),
        GlobeCity(name: "南昌", lat: 28.68, lon: 115.86), GlobeCity(name: "济南", lat: 36.65, lon: 117.12),
        GlobeCity(name: "郑州", lat: 34.75, lon: 113.63), GlobeCity(name: "武汉", lat: 30.59, lon: 114.31),
        GlobeCity(name: "长沙", lat: 28.23, lon: 112.94), GlobeCity(name: "广州", lat: 23.13, lon: 113.26),
        GlobeCity(name: "南宁", lat: 22.82, lon: 108.37), GlobeCity(name: "海口", lat: 20.04, lon: 110.34),
        GlobeCity(name: "成都", lat: 30.57, lon: 104.07), GlobeCity(name: "贵阳", lat: 26.65, lon: 106.63),
        GlobeCity(name: "昆明", lat: 24.88, lon: 102.83), GlobeCity(name: "拉萨", lat: 29.65, lon: 91.14),
        GlobeCity(name: "西安", lat: 34.34, lon: 108.94), GlobeCity(name: "兰州", lat: 36.06, lon: 103.83),
        GlobeCity(name: "西宁", lat: 36.62, lon: 101.78), GlobeCity(name: "银川", lat: 38.49, lon: 106.23),
        GlobeCity(name: "乌鲁木齐", lat: 43.83, lon: 87.62), GlobeCity(name: "台北", lat: 25.03, lon: 121.57),
        GlobeCity(name: "香港", lat: 22.32, lon: 114.17), GlobeCity(name: "澳门", lat: 22.20, lon: 113.55),
        GlobeCity(name: "深圳", lat: 22.54, lon: 114.06), GlobeCity(name: "大连", lat: 38.91, lon: 121.61),
        GlobeCity(name: "青岛", lat: 36.07, lon: 120.38), GlobeCity(name: "厦门", lat: 24.48, lon: 118.09),
        GlobeCity(name: "宁波", lat: 29.87, lon: 121.54), GlobeCity(name: "苏州", lat: 31.30, lon: 120.58),
        GlobeCity(name: "无锡", lat: 31.49, lon: 120.31), GlobeCity(name: "洛阳", lat: 34.62, lon: 112.45),
        GlobeCity(name: "桂林", lat: 25.28, lon: 110.29), GlobeCity(name: "三亚", lat: 18.25, lon: 109.51),
        GlobeCity(name: "敦煌", lat: 40.14, lon: 94.66), GlobeCity(name: "哈密", lat: 42.83, lon: 93.51),
        // 亚洲
        GlobeCity(name: "东京", lat: 35.68, lon: 139.69), GlobeCity(name: "大阪", lat: 34.69, lon: 135.50),
        GlobeCity(name: "京都", lat: 35.01, lon: 135.77), GlobeCity(name: "札幌", lat: 43.06, lon: 141.35),
        GlobeCity(name: "首尔", lat: 37.57, lon: 126.98), GlobeCity(name: "釜山", lat: 35.18, lon: 129.08),
        GlobeCity(name: "乌兰巴托", lat: 47.89, lon: 106.91), GlobeCity(name: "河内", lat: 21.03, lon: 105.85),
        GlobeCity(name: "曼谷", lat: 13.76, lon: 100.50), GlobeCity(name: "新加坡", lat: 1.35, lon: 103.82),
        GlobeCity(name: "吉隆坡", lat: 3.14, lon: 101.69), GlobeCity(name: "雅加达", lat: -6.21, lon: 106.85),
        GlobeCity(name: "马尼拉", lat: 14.60, lon: 120.98), GlobeCity(name: "新德里", lat: 28.61, lon: 77.21),
        GlobeCity(name: "孟买", lat: 19.08, lon: 72.88), GlobeCity(name: "加德满都", lat: 27.72, lon: 85.32),
        GlobeCity(name: "德黑兰", lat: 35.69, lon: 51.39), GlobeCity(name: "迪拜", lat: 25.20, lon: 55.27),
        GlobeCity(name: "利雅得", lat: 24.71, lon: 46.68), GlobeCity(name: "伊斯坦布尔", lat: 41.01, lon: 28.98),
        // 欧洲
        GlobeCity(name: "莫斯科", lat: 55.76, lon: 37.62), GlobeCity(name: "圣彼得堡", lat: 59.93, lon: 30.34),
        GlobeCity(name: "华沙", lat: 52.23, lon: 21.01), GlobeCity(name: "柏林", lat: 52.52, lon: 13.41),
        GlobeCity(name: "慕尼黑", lat: 48.14, lon: 11.58), GlobeCity(name: "法兰克福", lat: 50.11, lon: 8.68),
        GlobeCity(name: "达姆施塔特", lat: 49.87, lon: 8.65), GlobeCity(name: "斯图加特", lat: 48.78, lon: 9.18),
        GlobeCity(name: "汉堡", lat: 53.55, lon: 9.99), GlobeCity(name: "科隆", lat: 50.94, lon: 6.96),
        GlobeCity(name: "巴黎", lat: 48.86, lon: 2.35), GlobeCity(name: "伦敦", lat: 51.51, lon: -0.13),
        GlobeCity(name: "阿姆斯特丹", lat: 52.37, lon: 4.90), GlobeCity(name: "布鲁塞尔", lat: 50.85, lon: 4.35),
        GlobeCity(name: "卢森堡", lat: 49.61, lon: 6.13), GlobeCity(name: "苏黎世", lat: 47.38, lon: 8.54),
        GlobeCity(name: "日内瓦", lat: 46.20, lon: 6.14), GlobeCity(name: "米兰", lat: 45.46, lon: 9.19),
        GlobeCity(name: "罗马", lat: 41.90, lon: 12.50), GlobeCity(name: "威尼斯", lat: 45.44, lon: 12.32),
        GlobeCity(name: "维也纳", lat: 48.21, lon: 16.37), GlobeCity(name: "布拉格", lat: 50.08, lon: 14.44),
        GlobeCity(name: "布达佩斯", lat: 47.50, lon: 19.04), GlobeCity(name: "哥本哈根", lat: 55.68, lon: 12.57),
        GlobeCity(name: "斯德哥尔摩", lat: 59.33, lon: 18.07), GlobeCity(name: "奥斯陆", lat: 59.91, lon: 10.75),
        GlobeCity(name: "赫尔辛基", lat: 60.17, lon: 24.94), GlobeCity(name: "里斯本", lat: 38.72, lon: -9.14),
        GlobeCity(name: "马德里", lat: 40.42, lon: -3.70), GlobeCity(name: "巴塞罗那", lat: 41.39, lon: 2.17),
        GlobeCity(name: "雅典", lat: 37.98, lon: 23.73),
        // 非洲 / 大洋洲
        GlobeCity(name: "开罗", lat: 30.04, lon: 31.24), GlobeCity(name: "内罗毕", lat: -1.29, lon: 36.82),
        GlobeCity(name: "约翰内斯堡", lat: -26.20, lon: 28.05), GlobeCity(name: "开普敦", lat: -33.92, lon: 18.42),
        GlobeCity(name: "卡萨布兰卡", lat: 33.57, lon: -7.59),
        GlobeCity(name: "悉尼", lat: -33.87, lon: 151.21), GlobeCity(name: "墨尔本", lat: -37.81, lon: 144.96),
        GlobeCity(name: "布里斯班", lat: -27.47, lon: 153.03), GlobeCity(name: "珀斯", lat: -31.95, lon: 115.86),
        GlobeCity(name: "奥克兰", lat: -36.85, lon: 174.76),
        // 美洲
        GlobeCity(name: "纽约", lat: 40.71, lon: -74.01), GlobeCity(name: "波士顿", lat: 42.36, lon: -71.06),
        GlobeCity(name: "华盛顿", lat: 38.91, lon: -77.04), GlobeCity(name: "芝加哥", lat: 41.88, lon: -87.63),
        GlobeCity(name: "西雅图", lat: 47.61, lon: -122.33), GlobeCity(name: "旧金山", lat: 37.77, lon: -122.42),
        GlobeCity(name: "洛杉矶", lat: 34.05, lon: -118.24), GlobeCity(name: "拉斯维加斯", lat: 36.17, lon: -115.14),
        GlobeCity(name: "休斯顿", lat: 29.76, lon: -95.37), GlobeCity(name: "迈阿密", lat: 25.76, lon: -80.19),
        GlobeCity(name: "多伦多", lat: 43.65, lon: -79.38), GlobeCity(name: "温哥华", lat: 49.28, lon: -123.12),
        GlobeCity(name: "蒙特利尔", lat: 45.50, lon: -73.57), GlobeCity(name: "墨西哥城", lat: 19.43, lon: -99.13),
        GlobeCity(name: "圣保罗", lat: -23.55, lon: -46.63), GlobeCity(name: "里约热内卢", lat: -22.91, lon: -43.17),
        GlobeCity(name: "布宜诺斯艾利斯", lat: -34.60, lon: -58.38), GlobeCity(name: "利马", lat: -12.05, lon: -77.04),
        GlobeCity(name: "圣地亚哥", lat: -33.45, lon: -70.67), GlobeCity(name: "波哥大", lat: 4.71, lon: -74.07),
    ]
}
