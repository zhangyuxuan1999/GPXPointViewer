//
//  Heat3D.swift
//  GPXPointViewer
//
//  3D 热力柱的场景构建：把（时间筛选后的）轨迹点按世界迷雾格网聚合成
//  边长 k 格的方块（面积 k² = 1/4/9/…/36 格），点数 → 对数归一的高度与
//  热度。每块预计算四个网格节点角高（相邻 ≤4 块的平均，缺块记 0——
//  平滑样式的顶面据此双线性衔接、边缘自然收落），棱角样式忽略角高。
//  局部坐标系：墨卡托相对方块外接框中心，最长边缩放到 2（渲染 y 轴向上）。
//

import Foundation
import simd

/// 空间分块（实例按块连续存放）：CPU 逐帧视锥剔除 + 按投影尺寸分级绘制
struct Heat3DChunk {
    var start: Int32          // 实例起始下标
    var count: Int32
    var minX: Float, minZ: Float, maxX: Float, maxZ: Float   // 局部 AABB（含半宽）
    var maxH: Float
}

struct Heat3DScene {
    /// 每实例 12 floats：[cx, cz, half, hOwn, h00, h10, h11, h01, heat, 0, 0, 0]
    /// （cz = 局部化墨卡托 Y；角序与着色器 (-1,-1)(1,-1)(1,1)(-1,1) 对应）
    let instances: [Float]
    let count: Int
    let chunks: [Heat3DChunk]
    let blockHalf: Float      // 渲染单元半宽（平滑模式为细分子格，所有实例相同）
    let baseHalf: Float       // 聚合块半宽（与平滑细分无关；缩放下限用它，
                              // 否则切换 平滑/棱角 时细分粒度变了会把相机钳跳）
    let centerX: Double
    let centerY: Double
    let scale: Double                 // 墨卡托 → 局部（外接框最长边 = 2）
    let groundRect: SIMD4<Float>      // 局部 (x0, z0, x1, z1)，含边距
    let mercRect: (x0: Double, y0: Double, x1: Double, y1: Double)  // 地面截图范围
    let maxCount: Int
    let blockCells: Int
    // 初始取景：最密集块的位置与推荐距离（数据跨大洲时全景下柱体是亚像素，
    // 直接落到最"高耸"的城市尺度）
    let focusX: Float
    let focusZ: Float
    let focusDist: Float
}

enum Heat3D {
    static let grid = 1 << 22

    static func build(track: TrackData, range: (start: Int, len: Int),
                      blockCells k: Int, smooth: Bool) -> Heat3DScene? {
        guard range.len > 0, k >= 1 else { return nil }
        let perMerc = Double(grid) / Double(k)          // 每墨卡托单位的块数
        let maxCoord = Double(grid / k - 1)

        // 1) 逐点块键（bx<<22|by；块坐标 < 2^22/k，22 位装得下）
        var keys = [UInt64](unsafeUninitializedCapacity: range.len) { buf, cnt in
            track.mercX.withUnsafeBufferPointer { mx in
                track.mercY.withUnsafeBufferPointer { my in
                    for i in 0..<range.len {
                        let bx = UInt64(min(maxCoord, max(0, mx[range.start + i] * perMerc)))
                        let by = UInt64(min(maxCoord, max(0, my[range.start + i] * perMerc)))
                        buf[i] = bx << 22 | by
                    }
                }
            }
            cnt = range.len
        }
        keys.sort()

        // 2) 游程 → 块列表与计数
        var bKeys = [UInt64]()
        var bCounts = [Int32]()
        bKeys.reserveCapacity(min(keys.count, 1 << 20))
        bCounts.reserveCapacity(min(keys.count, 1 << 20))
        var i = 0
        while i < keys.count {
            let key = keys[i]
            var j = i + 1
            while j < keys.count, keys[j] == key { j += 1 }
            bKeys.append(key)
            bCounts.append(Int32(j - i))
            i = j
        }
        guard !bKeys.isEmpty else { return nil }
        let maxC = Int(bCounts.max() ?? 1)
        let logMax = log(1.0 + Double(maxC))

        // 3) 高度（对数归一）+ 邻接查询字典 + 外接框
        var height = [UInt64: Float](minimumCapacity: bKeys.count * 2)
        var minBX = UInt64.max, maxBX = UInt64.min
        var minBY = UInt64.max, maxBY = UInt64.min
        for idx in 0..<bKeys.count {
            let key = bKeys[idx]
            let h = Float(log(1.0 + Double(bCounts[idx])) / logMax)
            height[key] = h
            let bx = key >> 22, by = key & 0x3F_FFFF
            minBX = min(minBX, bx); maxBX = max(maxBX, bx)
            minBY = min(minBY, by); maxBY = max(maxBY, by)
        }

        let blockMerc = 1.0 / perMerc
        // （最大柱高在缩放确定后按块宽推导，见下）
        let mercX0 = Double(minBX) * blockMerc
        let mercX1 = Double(maxBX + 1) * blockMerc
        let mercY0 = Double(minBY) * blockMerc
        let mercY1 = Double(maxBY + 1) * blockMerc
        let cx = (mercX0 + mercX1) / 2, cy = (mercY0 + mercY1) / 2
        let span = max(mercX1 - mercX0, mercY1 - mercY0, blockMerc * 4)
        let S = 2.0 / span
        // 柱高与块宽成真实比例（最高 = 36×半宽 = 18 倍块宽），小场景钳 0.5：
        // 城市尺度下常去地块"高楼耸立"，拉远后柱体随比例自然变细矮
        let maxHeight = Float(min(0.5, blockMerc / 2 * S * 36.0))

        @inline(__always) func h(_ bx: Int64, _ by: Int64) -> Float {
            guard bx >= 0, by >= 0 else { return 0 }
            return height[UInt64(bx) << 22 | UInt64(by)] ?? 0
        }
        // 平滑模式的高度场：3×3 加权模糊（4-2-1 核，缺块计 0）。
        // 相邻块计数噪声造成的尖刺被抹平，孤立轨迹线柔化收落——
        // 角高/顶面全用平滑场；棱角模式的平顶仍用精确高度
        var heightS = [UInt64: Float](minimumCapacity: bKeys.count * 2)
        for key in bKeys {
            let bx = Int64(key >> 22), by = Int64(key & 0x3F_FFFF)
            var acc = h(bx, by) * 4
            acc += (h(bx - 1, by) + h(bx + 1, by) + h(bx, by - 1) + h(bx, by + 1)) * 2
            acc += h(bx - 1, by - 1) + h(bx + 1, by - 1)
                 + h(bx - 1, by + 1) + h(bx + 1, by + 1)
            heightS[key] = acc / 16
        }
        @inline(__always) func hs1(_ bx: Int64, _ by: Int64) -> Float {
            guard bx >= 0, by >= 0 else { return 0 }
            return heightS[UInt64(bx) << 22 | UInt64(by)] ?? 0
        }
        // 第二遍模糊：街区网格间的空块沟槽融进连续地形（只影响平滑模式的角高）
        var heightS2 = [UInt64: Float](minimumCapacity: bKeys.count * 2)
        for key in bKeys {
            let bx = Int64(key >> 22), by = Int64(key & 0x3F_FFFF)
            var acc = hs1(bx, by) * 4
            acc += (hs1(bx - 1, by) + hs1(bx + 1, by) + hs1(bx, by - 1) + hs1(bx, by + 1)) * 2
            acc += hs1(bx - 1, by - 1) + hs1(bx + 1, by - 1)
                 + hs1(bx - 1, by + 1) + hs1(bx + 1, by + 1)
            heightS2[key] = acc / 16
        }
        @inline(__always) func hs(_ bx: Int64, _ by: Int64) -> Float {
            guard bx >= 0, by >= 0 else { return 0 }
            return heightS2[UInt64(bx) << 22 | UInt64(by)] ?? 0
        }
        // 网格节点 (gx, gy) 的角高 = 共享该节点的 4 块（平滑场）平均（缺块计 0 → 边缘收落）
        @inline(__always) func corner(_ gx: Int64, _ gy: Int64) -> Float {
            (hs(gx - 1, gy - 1) + hs(gx, gy - 1) + hs(gx - 1, gy) + hs(gx, gy)) * 0.25
        }

        // 4) 空间分块（~44×44 网格）：块内实例连续，渲染端按 chunk 剔除/分级
        let spanBlocksX = Double(maxBX - minBX) + 1
        let spanBlocksY = Double(maxBY - minBY) + 1
        let chunkDim = max(1.0, ceil(max(spanBlocksX, spanBlocksY) / 44.0))
        var order = Array(0..<bKeys.count)
        @inline(__always) func chunkKey(_ key: UInt64) -> UInt64 {
            let bx = (key >> 22) &- minBX, by = (key & 0x3F_FFFF) &- minBY
            return (UInt64(Double(bx) / chunkDim) << 32) | UInt64(Double(by) / chunkDim)
        }
        order.sort { chunkKey(bKeys[$0]) < chunkKey(bKeys[$1]) }

        // 5) 实例数据（局部坐标；高度 × maxHeight）+ chunk 表。
        //    平滑模式自适应细分：块数少（大块/近景）时每块切成 sub×sub 子格，
        //    高度取模糊场角点的 Catmull-Rom 双三次曲面采样——块面不再是
        //    折面拼接，而是真正的连续曲面（棱角模式恒 sub=1 保持精确方柱）
        let sub = smooth
            ? max(1, min(4, Int((1_600_000.0 / Double(bKeys.count)).squareRoot())))
            : 1
        var out = [Float]()
        out.reserveCapacity(bKeys.count * 12 * sub * sub)
        let half = Float(blockMerc / 2 * S)
        let halfSub = half / Float(sub)
        var chunks = [Heat3DChunk]()
        var curChunk = UInt64.max
        var emitIdx = 0

        @inline(__always) func pushInstance(_ lx: Float, _ lz: Float, _ hf: Float,
                                            _ hOwn: Float,
                                            _ c00: Float, _ c10: Float,
                                            _ c11: Float, _ c01: Float,
                                            _ heat: Float, _ ck: UInt64) {
            out.append(lx); out.append(lz); out.append(hf); out.append(hOwn)
            out.append(c00); out.append(c10); out.append(c11); out.append(c01)
            out.append(heat); out.append(0); out.append(0); out.append(0)
            if ck != curChunk {
                curChunk = ck
                chunks.append(Heat3DChunk(start: Int32(emitIdx), count: 0,
                                          minX: lx, minZ: lz, maxX: lx, maxZ: lz,
                                          maxH: hOwn))
            }
            var c = chunks[chunks.count - 1]
            c.count += 1
            c.minX = min(c.minX, lx - hf); c.maxX = max(c.maxX, lx + hf)
            c.minZ = min(c.minZ, lz - hf); c.maxZ = max(c.maxZ, lz + hf)
            c.maxH = max(c.maxH, max(hOwn, max(max(c00, c10), max(c11, c01))))
            chunks[chunks.count - 1] = c
            emitIdx += 1
        }

        // 三次均匀 B 样条（近似而非插值）：凸包性质保证无过冲——
        // Catmull-Rom 在尖峰旁会振铃出沟槽
        @inline(__always) func cr(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float,
                                  _ t: Float) -> Float {
            let t2 = t * t
            let t3 = t2 * t
            let b0 = (1 - t) * (1 - t) * (1 - t)
            let b1 = 3 * t3 - 6 * t2 + 4
            let b2 = -3 * t3 + 3 * t2 + 3 * t + 1
            return (b0 * p0 + b1 * p1 + b2 * p2 + t3 * p3) / 6
        }

        var grid = [Float](repeating: 0, count: 16)
        var samples = [Float](repeating: 0, count: (sub + 1) * (sub + 1))
        for idx in order {
            let key = bKeys[idx]
            let bx = Int64(key >> 22), by = Int64(key & 0x3F_FFFF)
            let bcx = (Double(bx) + 0.5) * blockMerc
            let bcy = (Double(by) + 0.5) * blockMerc
            let heat = Float(log(1.0 + Double(bCounts[idx])) / logMax)
            let ck = chunkKey(key)
            if sub == 1 {
                let lx = Float((bcx - cx) * S)
                let lz = Float((bcy - cy) * S)
                pushInstance(lx, lz, half, height[key]! * maxHeight,
                             corner(bx, by) * maxHeight,
                             corner(bx + 1, by) * maxHeight,
                             corner(bx + 1, by + 1) * maxHeight,
                             corner(bx, by + 1) * maxHeight,
                             heat, ck)
            } else {
                // 4×4 角点邻域 → 双三次曲面，采样 (sub+1)² 子角点
                for r in 0..<4 {
                    for c in 0..<4 {
                        grid[r * 4 + c] = corner(bx + Int64(c) - 1, by + Int64(r) - 1)
                    }
                }
                for sj in 0...sub {
                    let v = Float(sj) / Float(sub)
                    let r0 = cr(grid[0], grid[1], grid[2], grid[3], 0)
                    _ = r0
                    var col = [Float](repeating: 0, count: 4)
                    for r in 0..<4 {
                        col[r] = cr(grid[r * 4], grid[r * 4 + 1],
                                    grid[r * 4 + 2], grid[r * 4 + 3],
                                    Float(0))
                    }
                    for si in 0...sub {
                        let u = Float(si) / Float(sub)
                        for r in 0..<4 {
                            col[r] = cr(grid[r * 4], grid[r * 4 + 1],
                                        grid[r * 4 + 2], grid[r * 4 + 3], u)
                        }
                        samples[sj * (sub + 1) + si] =
                            max(0, cr(col[0], col[1], col[2], col[3], v))
                    }
                }
                let baseX = Double(bx) * blockMerc
                let baseY = Double(by) * blockMerc
                let stepMerc = blockMerc / Double(sub)
                for sj in 0..<sub {
                    for si in 0..<sub {
                        let scx = baseX + (Double(si) + 0.5) * stepMerc
                        let scy = baseY + (Double(sj) + 0.5) * stepMerc
                        let h00 = samples[sj * (sub + 1) + si] * maxHeight
                        let h10 = samples[sj * (sub + 1) + si + 1] * maxHeight
                        let h01 = samples[(sj + 1) * (sub + 1) + si] * maxHeight
                        let h11 = samples[(sj + 1) * (sub + 1) + si + 1] * maxHeight
                        pushInstance(Float((scx - cx) * S), Float((scy - cy) * S),
                                     halfSub,
                                     (h00 + h10 + h11 + h01) * 0.25,
                                     h00, h10, h11, h01, heat, ck)
                    }
                }
            }
        }

        // 初始取景：最大计数块为焦点；距离 ≈ 屏幕看到 ~220 块宽
        var focusIdx = 0
        var bestC: Int32 = 0
        for idx in 0..<bKeys.count where bCounts[idx] > bestC {
            bestC = bCounts[idx]; focusIdx = idx
        }
        let fKey = bKeys[focusIdx]
        let fx = Float(((Double(fKey >> 22) + 0.5) * blockMerc - cx) * S)
        let fz = Float(((Double(fKey & 0x3F_FFFF) + 0.5) * blockMerc - cy) * S)
        // 距离 ≈ 屏幕看到 ~220 块宽（数据跨大洲时块极小，距离随之贴近）
        let fDist = min(3.2, max(half * 8, half * 316))

        // 地面范围：块外接框 + 18% 边距
        let padX = (mercX1 - mercX0) * 0.18 + blockMerc
        let padY = (mercY1 - mercY0) * 0.18 + blockMerc
        let gx0 = mercX0 - padX, gx1 = mercX1 + padX
        let gy0 = mercY0 - padY, gy1 = mercY1 + padY
        return Heat3DScene(
            instances: out, count: emitIdx,
            chunks: chunks, blockHalf: halfSub, baseHalf: half,
            centerX: cx, centerY: cy, scale: S,
            groundRect: SIMD4(Float((gx0 - cx) * S), Float((gy0 - cy) * S),
                              Float((gx1 - cx) * S), Float((gy1 - cy) * S)),
            mercRect: (gx0, gy0, gx1, gy1),
            maxCount: maxC, blockCells: k,
            focusX: fx, focusZ: fz, focusDist: fDist)
    }
}
