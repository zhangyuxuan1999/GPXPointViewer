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
    let name: String        // 已本地化的显示名（主 Localizable 表）；标签文字与宽度测量共用同一值
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
        GlobeCity(name: String(localized: "北京", comment: "City label: Beijing (39.90,116.41)"), lat: 39.90, lon: 116.41),
        GlobeCity(name: String(localized: "上海", comment: "City label: Shanghai (31.23,121.47)"), lat: 31.23, lon: 121.47),
        GlobeCity(name: String(localized: "天津", comment: "City label: Tianjin (39.13,117.20)"), lat: 39.13, lon: 117.20),
        GlobeCity(name: String(localized: "重庆", comment: "City label: Chongqing (29.56,106.55)"), lat: 29.56, lon: 106.55),
        GlobeCity(name: String(localized: "石家庄", comment: "City label: Shijiazhuang (38.04,114.51)"), lat: 38.04, lon: 114.51),
        GlobeCity(name: String(localized: "太原", comment: "City label: Taiyuan (37.87,112.55)"), lat: 37.87, lon: 112.55),
        GlobeCity(name: String(localized: "呼和浩特", comment: "City label: Hohhot (40.84,111.75)"), lat: 40.84, lon: 111.75),
        GlobeCity(name: String(localized: "沈阳", comment: "City label: Shenyang (41.80,123.43)"), lat: 41.80, lon: 123.43),
        GlobeCity(name: String(localized: "长春", comment: "City label: Changchun (43.82,125.32)"), lat: 43.82, lon: 125.32),
        GlobeCity(name: String(localized: "哈尔滨", comment: "City label: Harbin (45.80,126.53)"), lat: 45.80, lon: 126.53),
        GlobeCity(name: String(localized: "南京", comment: "City label: Nanjing (32.06,118.80)"), lat: 32.06, lon: 118.80),
        GlobeCity(name: String(localized: "杭州", comment: "City label: Hangzhou (30.27,120.16)"), lat: 30.27, lon: 120.16),
        GlobeCity(name: String(localized: "合肥", comment: "City label: Hefei (31.82,117.23)"), lat: 31.82, lon: 117.23),
        GlobeCity(name: String(localized: "福州", comment: "City label: Fuzhou (26.07,119.30)"), lat: 26.07, lon: 119.30),
        GlobeCity(name: String(localized: "南昌", comment: "City label: Nanchang (28.68,115.86)"), lat: 28.68, lon: 115.86),
        GlobeCity(name: String(localized: "济南", comment: "City label: Jinan (36.65,117.12)"), lat: 36.65, lon: 117.12),
        GlobeCity(name: String(localized: "郑州", comment: "City label: Zhengzhou (34.75,113.63)"), lat: 34.75, lon: 113.63),
        GlobeCity(name: String(localized: "武汉", comment: "City label: Wuhan (30.59,114.31)"), lat: 30.59, lon: 114.31),
        GlobeCity(name: String(localized: "长沙", comment: "City label: Changsha (28.23,112.94)"), lat: 28.23, lon: 112.94),
        GlobeCity(name: String(localized: "广州", comment: "City label: Guangzhou (23.13,113.26)"), lat: 23.13, lon: 113.26),
        GlobeCity(name: String(localized: "南宁", comment: "City label: Nanning (22.82,108.37)"), lat: 22.82, lon: 108.37),
        GlobeCity(name: String(localized: "海口", comment: "City label: Haikou (20.04,110.34)"), lat: 20.04, lon: 110.34),
        GlobeCity(name: String(localized: "成都", comment: "City label: Chengdu (30.57,104.07)"), lat: 30.57, lon: 104.07),
        GlobeCity(name: String(localized: "贵阳", comment: "City label: Guiyang (26.65,106.63)"), lat: 26.65, lon: 106.63),
        GlobeCity(name: String(localized: "昆明", comment: "City label: Kunming (24.88,102.83)"), lat: 24.88, lon: 102.83),
        GlobeCity(name: String(localized: "拉萨", comment: "City label: Lhasa (29.65,91.14)"), lat: 29.65, lon: 91.14),
        GlobeCity(name: String(localized: "西安", comment: "City label: Xi'an (34.34,108.94)"), lat: 34.34, lon: 108.94),
        GlobeCity(name: String(localized: "兰州", comment: "City label: Lanzhou (36.06,103.83)"), lat: 36.06, lon: 103.83),
        GlobeCity(name: String(localized: "西宁", comment: "City label: Xining (36.62,101.78)"), lat: 36.62, lon: 101.78),
        GlobeCity(name: String(localized: "银川", comment: "City label: Yinchuan (38.49,106.23)"), lat: 38.49, lon: 106.23),
        GlobeCity(name: String(localized: "乌鲁木齐", comment: "City label: Urumqi (43.83,87.62)"), lat: 43.83, lon: 87.62),
        GlobeCity(name: String(localized: "台北", comment: "City label: Taipei (25.03,121.57)"), lat: 25.03, lon: 121.57),
        GlobeCity(name: String(localized: "香港", comment: "City label: Hong Kong (22.32,114.17)"), lat: 22.32, lon: 114.17),
        GlobeCity(name: String(localized: "澳门", comment: "City label: Macau (22.20,113.55)"), lat: 22.20, lon: 113.55),
        GlobeCity(name: String(localized: "深圳", comment: "City label: Shenzhen (22.54,114.06)"), lat: 22.54, lon: 114.06),
        GlobeCity(name: String(localized: "大连", comment: "City label: Dalian (38.91,121.61)"), lat: 38.91, lon: 121.61),
        GlobeCity(name: String(localized: "青岛", comment: "City label: Qingdao (36.07,120.38)"), lat: 36.07, lon: 120.38),
        GlobeCity(name: String(localized: "厦门", comment: "City label: Xiamen (24.48,118.09)"), lat: 24.48, lon: 118.09),
        GlobeCity(name: String(localized: "宁波", comment: "City label: Ningbo (29.87,121.54)"), lat: 29.87, lon: 121.54),
        GlobeCity(name: String(localized: "苏州", comment: "City label: Suzhou (31.30,120.58)"), lat: 31.30, lon: 120.58),
        GlobeCity(name: String(localized: "无锡", comment: "City label: Wuxi (31.49,120.31)"), lat: 31.49, lon: 120.31),
        GlobeCity(name: String(localized: "洛阳", comment: "City label: Luoyang (34.62,112.45)"), lat: 34.62, lon: 112.45),
        GlobeCity(name: String(localized: "桂林", comment: "City label: Guilin (25.28,110.29)"), lat: 25.28, lon: 110.29),
        GlobeCity(name: String(localized: "三亚", comment: "City label: Sanya (18.25,109.51)"), lat: 18.25, lon: 109.51),
        GlobeCity(name: String(localized: "敦煌", comment: "City label: Dunhuang (40.14,94.66)"), lat: 40.14, lon: 94.66),
        GlobeCity(name: String(localized: "哈密", comment: "City label: Hami (42.83,93.51)"), lat: 42.83, lon: 93.51),
        // 亚洲
        GlobeCity(name: String(localized: "东京", comment: "City label: Tokyo (35.68,139.69)"), lat: 35.68, lon: 139.69),
        GlobeCity(name: String(localized: "大阪", comment: "City label: Osaka (34.69,135.50)"), lat: 34.69, lon: 135.50),
        GlobeCity(name: String(localized: "京都", comment: "City label: Kyoto (35.01,135.77)"), lat: 35.01, lon: 135.77),
        GlobeCity(name: String(localized: "札幌", comment: "City label: Sapporo (43.06,141.35)"), lat: 43.06, lon: 141.35),
        GlobeCity(name: String(localized: "首尔", comment: "City label: Seoul (37.57,126.98)"), lat: 37.57, lon: 126.98),
        GlobeCity(name: String(localized: "釜山", comment: "City label: Busan (35.18,129.08)"), lat: 35.18, lon: 129.08),
        GlobeCity(name: String(localized: "乌兰巴托", comment: "City label: Ulaanbaatar (47.89,106.91)"), lat: 47.89, lon: 106.91),
        GlobeCity(name: String(localized: "河内", comment: "City label: Hanoi (21.03,105.85)"), lat: 21.03, lon: 105.85),
        GlobeCity(name: String(localized: "曼谷", comment: "City label: Bangkok (13.76,100.50)"), lat: 13.76, lon: 100.50),
        GlobeCity(name: String(localized: "新加坡", comment: "City label: Singapore (1.35,103.82)"), lat: 1.35, lon: 103.82),
        GlobeCity(name: String(localized: "吉隆坡", comment: "City label: Kuala Lumpur (3.14,101.69)"), lat: 3.14, lon: 101.69),
        GlobeCity(name: String(localized: "雅加达", comment: "City label: Jakarta (-6.21,106.85)"), lat: -6.21, lon: 106.85),
        GlobeCity(name: String(localized: "马尼拉", comment: "City label: Manila (14.60,120.98)"), lat: 14.60, lon: 120.98),
        GlobeCity(name: String(localized: "新德里", comment: "City label: New Delhi (28.61,77.21)"), lat: 28.61, lon: 77.21),
        GlobeCity(name: String(localized: "孟买", comment: "City label: Mumbai (19.08,72.88)"), lat: 19.08, lon: 72.88),
        GlobeCity(name: String(localized: "加德满都", comment: "City label: Kathmandu (27.72,85.32)"), lat: 27.72, lon: 85.32),
        GlobeCity(name: String(localized: "德黑兰", comment: "City label: Tehran (35.69,51.39)"), lat: 35.69, lon: 51.39),
        GlobeCity(name: String(localized: "迪拜", comment: "City label: Dubai (25.20,55.27)"), lat: 25.20, lon: 55.27),
        GlobeCity(name: String(localized: "利雅得", comment: "City label: Riyadh (24.71,46.68)"), lat: 24.71, lon: 46.68),
        GlobeCity(name: String(localized: "伊斯坦布尔", comment: "City label: Istanbul (41.01,28.98)"), lat: 41.01, lon: 28.98),
        // 欧洲
        GlobeCity(name: String(localized: "莫斯科", comment: "City label: Moscow (55.76,37.62)"), lat: 55.76, lon: 37.62),
        GlobeCity(name: String(localized: "圣彼得堡", comment: "City label: Saint Petersburg (59.93,30.34)"), lat: 59.93, lon: 30.34),
        GlobeCity(name: String(localized: "华沙", comment: "City label: Warsaw (52.23,21.01)"), lat: 52.23, lon: 21.01),
        GlobeCity(name: String(localized: "柏林", comment: "City label: Berlin (52.52,13.41)"), lat: 52.52, lon: 13.41),
        GlobeCity(name: String(localized: "慕尼黑", comment: "City label: Munich (48.14,11.58)"), lat: 48.14, lon: 11.58),
        GlobeCity(name: String(localized: "法兰克福", comment: "City label: Frankfurt am Main (50.11,8.68)"), lat: 50.11, lon: 8.68),
        GlobeCity(name: String(localized: "达姆施塔特", comment: "City label: Darmstadt (49.87,8.65)"), lat: 49.87, lon: 8.65),
        GlobeCity(name: String(localized: "斯图加特", comment: "City label: Stuttgart (48.78,9.18)"), lat: 48.78, lon: 9.18),
        GlobeCity(name: String(localized: "汉堡", comment: "City label: Hamburg (53.55,9.99)"), lat: 53.55, lon: 9.99),
        GlobeCity(name: String(localized: "科隆", comment: "City label: Cologne (50.94,6.96)"), lat: 50.94, lon: 6.96),
        GlobeCity(name: String(localized: "巴黎", comment: "City label: Paris (48.86,2.35)"), lat: 48.86, lon: 2.35),
        GlobeCity(name: String(localized: "伦敦", comment: "City label: London (51.51,-0.13)"), lat: 51.51, lon: -0.13),
        GlobeCity(name: String(localized: "阿姆斯特丹", comment: "City label: Amsterdam (52.37,4.90)"), lat: 52.37, lon: 4.90),
        GlobeCity(name: String(localized: "布鲁塞尔", comment: "City label: Brussels (50.85,4.35)"), lat: 50.85, lon: 4.35),
        GlobeCity(name: String(localized: "卢森堡", comment: "City label: Luxembourg (49.61,6.13)"), lat: 49.61, lon: 6.13),
        GlobeCity(name: String(localized: "苏黎世", comment: "City label: Zurich (47.38,8.54)"), lat: 47.38, lon: 8.54),
        GlobeCity(name: String(localized: "日内瓦", comment: "City label: Geneva (46.20,6.14)"), lat: 46.20, lon: 6.14),
        GlobeCity(name: String(localized: "米兰", comment: "City label: Milan (45.46,9.19)"), lat: 45.46, lon: 9.19),
        GlobeCity(name: String(localized: "罗马", comment: "City label: Rome (41.90,12.50)"), lat: 41.90, lon: 12.50),
        GlobeCity(name: String(localized: "威尼斯", comment: "City label: Venice (45.44,12.32)"), lat: 45.44, lon: 12.32),
        GlobeCity(name: String(localized: "维也纳", comment: "City label: Vienna (48.21,16.37)"), lat: 48.21, lon: 16.37),
        GlobeCity(name: String(localized: "布拉格", comment: "City label: Prague (50.08,14.44)"), lat: 50.08, lon: 14.44),
        GlobeCity(name: String(localized: "布达佩斯", comment: "City label: Budapest (47.50,19.04)"), lat: 47.50, lon: 19.04),
        GlobeCity(name: String(localized: "哥本哈根", comment: "City label: Copenhagen (55.68,12.57)"), lat: 55.68, lon: 12.57),
        GlobeCity(name: String(localized: "斯德哥尔摩", comment: "City label: Stockholm (59.33,18.07)"), lat: 59.33, lon: 18.07),
        GlobeCity(name: String(localized: "奥斯陆", comment: "City label: Oslo (59.91,10.75)"), lat: 59.91, lon: 10.75),
        GlobeCity(name: String(localized: "赫尔辛基", comment: "City label: Helsinki (60.17,24.94)"), lat: 60.17, lon: 24.94),
        GlobeCity(name: String(localized: "里斯本", comment: "City label: Lisbon (38.72,-9.14)"), lat: 38.72, lon: -9.14),
        GlobeCity(name: String(localized: "马德里", comment: "City label: Madrid (40.42,-3.70)"), lat: 40.42, lon: -3.70),
        GlobeCity(name: String(localized: "巴塞罗那", comment: "City label: Barcelona (41.39,2.17)"), lat: 41.39, lon: 2.17),
        GlobeCity(name: String(localized: "雅典", comment: "City label: Athens (37.98,23.73)"), lat: 37.98, lon: 23.73),
        // 非洲 / 大洋洲
        GlobeCity(name: String(localized: "开罗", comment: "City label: Cairo (30.04,31.24)"), lat: 30.04, lon: 31.24),
        GlobeCity(name: String(localized: "内罗毕", comment: "City label: Nairobi (-1.29,36.82)"), lat: -1.29, lon: 36.82),
        GlobeCity(name: String(localized: "约翰内斯堡", comment: "City label: Johannesburg (-26.20,28.05)"), lat: -26.20, lon: 28.05),
        GlobeCity(name: String(localized: "开普敦", comment: "City label: Cape Town (-33.92,18.42)"), lat: -33.92, lon: 18.42),
        GlobeCity(name: String(localized: "卡萨布兰卡", comment: "City label: Casablanca (33.57,-7.59)"), lat: 33.57, lon: -7.59),
        GlobeCity(name: String(localized: "悉尼", comment: "City label: Sydney (-33.87,151.21)"), lat: -33.87, lon: 151.21),
        GlobeCity(name: String(localized: "墨尔本", comment: "City label: Melbourne (-37.81,144.96)"), lat: -37.81, lon: 144.96),
        GlobeCity(name: String(localized: "布里斯班", comment: "City label: Brisbane (-27.47,153.03)"), lat: -27.47, lon: 153.03),
        GlobeCity(name: String(localized: "珀斯", comment: "City label: Perth (-31.95,115.86)"), lat: -31.95, lon: 115.86),
        GlobeCity(name: String(localized: "奥克兰", comment: "City label: Auckland, New Zealand (-36.85,174.76)"), lat: -36.85, lon: 174.76),
        // 美洲
        GlobeCity(name: String(localized: "纽约", comment: "City label: New York City (40.71,-74.01)"), lat: 40.71, lon: -74.01),
        GlobeCity(name: String(localized: "波士顿", comment: "City label: Boston (42.36,-71.06)"), lat: 42.36, lon: -71.06),
        GlobeCity(name: String(localized: "华盛顿", comment: "City label: Washington, D.C. (38.91,-77.04)"), lat: 38.91, lon: -77.04),
        GlobeCity(name: String(localized: "芝加哥", comment: "City label: Chicago (41.88,-87.63)"), lat: 41.88, lon: -87.63),
        GlobeCity(name: String(localized: "西雅图", comment: "City label: Seattle (47.61,-122.33)"), lat: 47.61, lon: -122.33),
        GlobeCity(name: String(localized: "旧金山", comment: "City label: San Francisco (37.77,-122.42)"), lat: 37.77, lon: -122.42),
        GlobeCity(name: String(localized: "洛杉矶", comment: "City label: Los Angeles (34.05,-118.24)"), lat: 34.05, lon: -118.24),
        GlobeCity(name: String(localized: "拉斯维加斯", comment: "City label: Las Vegas (36.17,-115.14)"), lat: 36.17, lon: -115.14),
        GlobeCity(name: String(localized: "休斯顿", comment: "City label: Houston (29.76,-95.37)"), lat: 29.76, lon: -95.37),
        GlobeCity(name: String(localized: "迈阿密", comment: "City label: Miami (25.76,-80.19)"), lat: 25.76, lon: -80.19),
        GlobeCity(name: String(localized: "多伦多", comment: "City label: Toronto (43.65,-79.38)"), lat: 43.65, lon: -79.38),
        GlobeCity(name: String(localized: "温哥华", comment: "City label: Vancouver (49.28,-123.12)"), lat: 49.28, lon: -123.12),
        GlobeCity(name: String(localized: "蒙特利尔", comment: "City label: Montreal (45.50,-73.57)"), lat: 45.50, lon: -73.57),
        GlobeCity(name: String(localized: "墨西哥城", comment: "City label: Mexico City (19.43,-99.13)"), lat: 19.43, lon: -99.13),
        GlobeCity(name: String(localized: "圣保罗", comment: "City label: São Paulo (-23.55,-46.63)"), lat: -23.55, lon: -46.63),
        GlobeCity(name: String(localized: "里约热内卢", comment: "City label: Rio de Janeiro (-22.91,-43.17)"), lat: -22.91, lon: -43.17),
        GlobeCity(name: String(localized: "布宜诺斯艾利斯", comment: "City label: Buenos Aires (-34.60,-58.38)"), lat: -34.60, lon: -58.38),
        GlobeCity(name: String(localized: "利马", comment: "City label: Lima (-12.05,-77.04)"), lat: -12.05, lon: -77.04),
        GlobeCity(name: String(localized: "圣地亚哥", comment: "City label: Santiago de Chile (-33.45,-70.67)"), lat: -33.45, lon: -70.67),
        GlobeCity(name: String(localized: "波哥大", comment: "City label: Bogotá (4.71,-74.07)"), lat: 4.71, lon: -74.07),
    ]
}
