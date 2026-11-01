//
//  Shaders.metal
//  GPXPointViewer
//
//  实例化点渲染：每个点是一个由 4 顶点三角带展开的屏幕对齐四边形，
//  片元着色器用 smoothstep 画抗锯齿圆 + 白色描边。
//  全部 N 个点一次 drawPrimitives(instanceCount: N) 画完 —— 单 draw call。
//
//  顶点属性是 SoA 裸缓冲（posX/posY/color 各一条），与 CPU 端数组
//  在统一内存里是同一块物理页，没有任何转换或拷贝。
//

#include <metal_stdlib>
using namespace metal;

struct PointUniforms {
    float2 scale;        // RTC 墨卡托 → NDC 缩放
    float2 offset;       // NDC 平移（含 RTC 中心）
    float2 ndcPerPixel;  // 每像素对应的 NDC 增量
    float  radiusPx;     // 点半径（物理像素）
    float  haloPx;       // 白描边宽度（物理像素）
    float  alpha;        // 全局不透明度
    uint   mode;         // 0 = 常规点，1 = 高亮环
    uint   stride;       // LOD：每 stride 取 1 个点（1 = 全量）
    uint   count;        // 总点数（越界钳制）
    uint   start;        // 时间筛选：可见区间起始下标
    uint   rangeLen;     // 时间筛选：可见区间长度
    uint   pixelMode;    // 城市章节回放：1 = 启用按区域揭示（见 buffer 9/10/11）
    int    flashFile;    // 文件高亮闪烁：目标文件下标（-1 = 无）
    float  flashStrength;// 闪烁强度 0…1（淡入/淡出）
    uint   useOrder;     // 空间剔除：1 = 实例经莫顿序置换表间接寻址
    uint   orderStart;   // 置换表区段起点
    uint   orderLen;     // 置换表区段长度
    uint   _pad2;
};

// 空间剔除下的下标解析：pi = 原始（时间序）下标，用于时间区间检查/文件 ID；
// di = 数据下标——时间序路径等于 pi，空间路径是置换表位置（位置/颜色缓冲
// 绑定的是按莫顿序物理重排的副本，顺序读，无随机 gather）。
// useOrder：0 时间序；1 置换表区段；2 去重（aux = 格首点表）；
// 3 时间序可见表（aux = 视口内点按时间排好的原始下标，读时间序缓冲）。
// 落在时间筛选区间外的点剔除（区段不含时间过滤）。返回 false = 本实例剔除
static inline bool resolvePointIndex(uint iid, constant PointUniforms& u,
                                     const device uint* order,
                                     const device uint* aux,
                                     thread uint& pi, thread uint& di)
{
    uint hi = min(u.start + u.rangeLen - 1, u.count - 1);
    if (u.useOrder == 0u) {
        pi = min(u.start + iid * u.stride, hi);
        di = pi;
        return true;
    }
    if (u.useOrder == 3u) {
        if (iid >= u.orderLen) { pi = hi; di = hi; return false; }
        pi = aux[u.orderStart + iid];
        di = pi;
        return pi >= u.start && pi <= hi;
    }
    if (u.useOrder == 2u) {
        // 去重 LOD：实例 = 格首点表子区间的一项 → 莫顿序位置 → 原始下标
        if (iid >= u.orderLen) { pi = hi; di = hi; return false; }
        di = aux[u.orderStart + iid];
        pi = order[di];
        return pi >= u.start && pi <= hi;
    }
    uint k = iid * u.stride;
    if (k >= u.orderLen) { pi = hi; di = hi; return false; }
    di = u.orderStart + k;
    pi = order[di];
    return pi >= u.start && pi <= hi;
}

struct VOut {
    float4 position [[position]];
    float2 pxOffset;     // 相对圆心的像素偏移（插值）
    float4 color;
    float  radiusPx;     // 本实例半径（文件闪烁时目标文件放大）
    float  glow;         // DeepSeek 2026-10-31：新揭示的点短暂提亮（0…1）
};

constant float2 quadCorners[4] = {
    float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
};

vertex VOut pointVertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        const device float*  posX   [[buffer(0)]],
                        const device float*  posY   [[buffer(1)]],
                        const device uchar4* colors [[buffer(2)]],
                        constant PointUniforms& u   [[buffer(3)]],
                        const device ushort* fileID [[buffer(4)]],
                        const device uint*   order  [[buffer(7)]],
                        const device uint*   aux    [[buffer(8)]],
                        const device ushort* revealArea [[buffer(9)]],
                        const device uint*   revealTime [[buffer(10)]],
                        const device uint*   revealCursor [[buffer(11)]])
{
    // LOD 抽稀 + 时间筛选区间（时间序）或 置换表区段（空间剔除）
    uint pi, di;
    if (!resolvePointIndex(iid, u, order, aux, pi, di)) {
        VOut cull;
        cull.position = float4(0.0, 0.0, -2.0, 1.0);   // 近平面之外 → 裁掉
        cull.pxOffset = float2(0.0);
        cull.color = float4(0.0);
        cull.radiusPx = 0.0;
        cull.glow = 0.0;
        return cull;
    }
    // DeepSeek 2026-10-31：城市章节回放的按区域揭示。每帧 CPU 只更新几十个
    // 区域的游标；点的“区域 + 相对时间”是载入时一次上传的静态缓冲。
    // 新揭示的点在 2.5s 内提亮，避免“同一条街第二次经过”看不出生长。
    float revealGlow = 0.0;
    if (u.pixelMode != 0u) {
        uint cur = revealCursor[revealArea[pi]];
        uint rt = revealTime[pi];
        if (rt > cur) {
            VOut cull;
            cull.position = float4(0.0, 0.0, -2.0, 1.0);
            cull.pxOffset = float2(0.0);
            cull.color = float4(0.0);
            cull.radiusPx = 0.0;
            cull.glow = 0.0;
            return cull;
        }
        revealGlow = clamp(1.0 - float(cur - rt) / 1.2, 0.0, 1.0);
    }

    float2 center = float2(posX[di], posY[di]) * u.scale + u.offset;

    // 文件闪烁：目标文件透明度拉满 + 放大，其余保色降透明（不全透明）
    float radius = u.radiusPx;
    float4 c = float4(colors[di]) / 255.0;
    float a = c.a * u.alpha;
    if (u.flashFile >= 0) {
        if (int(fileID[pi]) == u.flashFile) {
            radius = u.radiusPx * (1.0 + 0.55 * u.flashStrength);
            a = mix(a, 1.0, u.flashStrength);
        } else {
            a = a * mix(1.0, 0.10, u.flashStrength);
        }
    }

    // 小点用更紧的 AA 余量，省约三分之一的填充面积
    float margin = (radius <= 2.0) ? 1.0 : 1.5;
    float ext = (u.mode == 1) ? (radius + 6.0) : (radius + u.haloPx + margin);
    float2 corner = quadCorners[vid];

    VOut o;
    o.position = float4(center + corner * ext * u.ndcPerPixel, 0.0, 1.0);
    o.pxOffset = corner * ext;
    o.color = float4(c.rgb, a);
    o.radiusPx = radius;
    o.glow = revealGlow;
    return o;
}

fragment float4 pointFragment(VOut in [[stage_in]],
                              constant PointUniforms& u [[buffer(0)]])
{
    float d = length(in.pxOffset);

    if (u.mode == 1) {
        // 悬停/选中高亮：一个描边圆环
        float ri = in.radiusPx + 1.5;
        float ro = in.radiusPx + 4.5;
        float band = smoothstep(ri - 0.8, ri + 0.8, d) * (1.0 - smoothstep(ro - 0.8, ro + 0.8, d));
        return float4(float3(0.04, 0.52, 1.0), band);
    }

    float coreR = in.radiusPx;
    float haloR = in.radiusPx + u.haloPx;
    float outer = 1.0 - smoothstep(haloR - 0.8, haloR + 0.8, d);   // 整体覆盖
    float core  = 1.0 - smoothstep(coreR - 0.8, coreR + 0.8, d);   // 彩色芯
    float3 rgb  = mix(float3(1.0), in.color.rgb, core);            // 芯外一圈白描边
    rgb = mix(rgb, float3(1.0), in.glow * 0.45);                   // 新揭示的点提亮
    return float4(rgb, outer * in.color.a);
}

// ============================================================================
// 方向箭头轨迹线（GPU 实例化）
//
// 每个实例经紧凑 draw-run 找到同段内两个规范化时间下标。
// 与点渲染共用位置 SoA；只上传 run 描述符，不展开每条边的坐标。
// 方向归一化、法线、箭头张角全部在 GPU 上对全部线段并行完成。
// 箭头语义：从本段内规范化时间早的点指向晚的点。
//
// 每条线段两次实例化提交：4 顶点三角带 = 箭杆，3 顶点三角形 = 箭头。
// ============================================================================

// Compact normalized segment topology. One descriptor per soft-broken run;
// iid locates a run, then samples its path ranks. Never joins two runs.
struct PathDrawRun { uint begin; uint end; uint firstInstance; uint instanceCount; };
struct PathUniforms { uint runCount; uint stride; uint identityOrder; uint fileMask; };
struct PathEdge { uint i0; uint i1; uint localInstance; bool valid; };
static inline PathEdge pathEdge(uint iid, const device uint* order,
                                const device PathDrawRun* runs,
                                constant PathUniforms& p) {
    PathEdge e = { 0u, 0u, 0u, false };
    uint lo = 0u, hi = p.runCount;
    while (p.runCount > 1u && lo < hi) {
        uint mid = lo + (hi - lo) / 2u;
        PathDrawRun r = runs[mid];
        if (iid >= r.firstInstance + r.instanceCount) lo = mid + 1u;
        else hi = mid;
    }
    if (lo >= p.runCount) return e;
    PathDrawRun r = runs[lo];
    if (iid < r.firstInstance || r.end <= r.begin) return e;
    uint j = iid - r.firstInstance;
    uint a = r.begin + min(j * p.stride, r.end - r.begin - 1u);
    uint b = a + min(p.stride, r.end - 1u - a); // saturates without uint multiplication overflow
    e.i0 = p.identityOrder != 0u ? a : order[a];
    e.i1 = p.identityOrder != 0u ? b : order[b];
    e.localInstance = j; e.valid = true;
    return e;
}
static inline bool pathFileHidden(uint i, uint mask, const device ushort* ids) {
    if (mask == 0xFFFFFFFFu) return false; // dummy file buffer is only two bytes
    uint file = uint(ids[i]);
    return file < 32u && ((mask >> file) & 1u) == 0u;
}

struct LineUniforms {
    float2 scale;        // RTC 墨卡托 → NDC
    float2 offset;
    float2 viewportPx;   // 物理像素
    uint   useBreaks;    // 1 = 按断点前缀和剔除跨段直连（buffer 3）
    uint   arrowEvery;   // 箭头密度：每 N 段一个箭头（箭杆照常）
    float4 color;        // 线颜色（a = 线透明度）
    float  widthPx;      // 箭杆宽（像素）
    float  headLenPx;    // 箭头长（0 = 不画箭头，箭杆通到底）
    float  headWidthPx;  // 箭头底宽
    uint   isHead;       // 0 = 箭杆，1 = 箭头
    uint   stride;       // LOD：与点云一致的抽稀间隔
    uint   count;        // 总点数
    uint   start;        // 时间筛选：可见区间起始下标
    uint   rangeLen;     // 时间筛选：可见区间长度
};

struct LineVOut {
    float4 position [[position]];
    float  edgePx;       // 距线中轴的像素距离（箭杆抗锯齿用）
};

static inline float2 lineMercToPixel(float x, float y, constant LineUniforms& u) {
    float2 ndc = float2(x, y) * u.scale + u.offset;
    return float2((ndc.x + 1.0) * 0.5 * u.viewportPx.x,
                  (1.0 - ndc.y) * 0.5 * u.viewportPx.y);
}

static inline float4 linePixelToClip(float2 p, constant LineUniforms& u) {
    return float4(p.x / u.viewportPx.x * 2.0 - 1.0,
                  1.0 - p.y / u.viewportPx.y * 2.0, 0.0, 1.0);
}

static inline LineVOut culledLine() {
    LineVOut o; o.position=float4(0.0,0.0,-2.0,1.0);o.edgePx=0.0;return o;
}
static inline LineVOut lineGeometry(uint vid, uint localInstance, uint i0, uint i1,
                                    const device float* posX, const device float* posY,
                                    constant LineUniforms& u, bool cullAABB) {
    LineVOut o;
    float2 a = lineMercToPixel(posX[i0], posY[i0], u);   // 时间早
    float2 b = lineMercToPixel(posX[i1], posY[i1], u);   // 时间晚
    float2 d = b - a;
    float len = length(d);
    // 跨段/跨天的超长直连不画（世界墨卡托单位，由 CPU 按纬度换算自 10 km）；
    // 亚像素线段裁掉（远缩放自动降密）；箭头按密度隔段画
    // 这一段有没有箭头：按密度隔段画；没箭头的段箭杆通到底（否则看起来像虚线）
    bool hasHead = u.headLenPx > 0.0 && (u.arrowEvery <= 1 || (localInstance % u.arrowEvery) == 0);
    bool skipHead = u.isHead == 1 && !hasHead;
    // 跨段/跨天直连不画：两点之间（含 LOD 抽稀跨过的点）有任何断点（>30 min 或 >10 km 的步）
    // Runs already enforce both hard and requested soft breaks. Cull the edge
    // AABB, not its endpoints: a crossing edge can have both endpoints outside.
    bool outside = false;
    if (cullAABB) {
        float pad = max(u.widthPx, u.headWidthPx) * 0.5 + u.headLenPx + 1.0;
        float2 low = min(a,b), high = max(a,b);
        outside = high.x < -pad || high.y < -pad ||
                  low.x > u.viewportPx.x + pad || low.y > u.viewportPx.y + pad;
    }
    if (len < 0.75 || skipHead || outside) {
        o.position = float4(0.0, 0.0, -2.0, 1.0);
        o.edgePx = 0.0;
        return o;
    }
    float2 dir = d / len;
    float2 nrm = float2(-dir.y, dir.x);
    float head = hasHead ? min(u.headLenPx, len * 0.5) : 0.0;

    if (u.isHead == 1) {
        float halfW = u.headWidthPx * 0.5;
        float2 base = b - dir * head;
        float2 p = (vid == 0) ? b
                 : (vid == 1) ? (base + nrm * halfW)
                              : (base - nrm * halfW);
        o.position = linePixelToClip(p, u);
        o.edgePx = 0.0;
    } else {
        float su = (vid < 2) ? 0.0 : 1.0;              // 沿线段
        float sv = (vid % 2 == 0) ? -1.0 : 1.0;        // 横向
        float halfW = u.widthPx * 0.5 + 0.7;           // 抗锯齿余量
        float2 end = b - dir * head;                   // 箭杆止于箭头底
        float2 p = a + (end - a) * su + nrm * halfW * sv;
        o.position = linePixelToClip(p, u);
        o.edgePx = sv * halfW;
    }
    return o;
}

vertex LineVOut segmentVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device float* posX [[buffer(0)]],
                              const device float* posY [[buffer(1)]],
                              constant LineUniforms& u [[buffer(2)]],
                              const device uint* brk [[buffer(3)]],
                              const device ushort* fileID [[buffer(4)]],
                              const device uint* pathOrder [[buffer(5)]],
                              const device PathDrawRun* pathRuns [[buffer(6)]],
                              constant PathUniforms& path [[buffer(7)]])
{
    PathEdge edge=pathEdge(iid,pathOrder,pathRuns,path);
    if (!edge.valid || edge.i0>=u.count || edge.i1>=u.count ||
        pathFileHidden(edge.i0,path.fileMask,fileID) || pathFileHidden(edge.i1,path.fileMask,fileID))
        return culledLine();
    return lineGeometry(vid,edge.localInstance,edge.i0,edge.i1,posX,posY,u,true);
}

// Ordinary identity single-run path stays independent of descriptor lookup.
// CPU supplies this run's clipped begin/end; ceil((L-1)/stride) keeps its tail.
vertex LineVOut segmentIdentityVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device float* posX [[buffer(0)]],
                                      const device float* posY [[buffer(1)]],
                                      constant LineUniforms& u [[buffer(2)]],
                                      const device ushort* fileID [[buffer(4)]],
                                      constant uint& fileMask [[buffer(8)]]) {
    uint hi=min(u.start+u.rangeLen-1u,u.count-1u);
    uint i0=u.start+iid*u.stride;
    if (i0>=hi) return culledLine();
    uint i1=i0+min(u.stride,hi-i0);
    if (pathFileHidden(i0,fileMask,fileID) || pathFileHidden(i1,fileMask,fileID)) return culledLine();
    // Native clip-space clipping is sufficient for this linear fast path.
    return lineGeometry(vid,iid,i0,i1,posX,posY,u,false);
}

fragment float4 segmentFragment(LineVOut in [[stage_in]],
                                constant LineUniforms& u [[buffer(0)]])
{
    float a = u.color.a;
    if (u.isHead == 0) {
        float halfW = u.widthPx * 0.5;
        a *= 1.0 - smoothstep(halfW - 0.7, halfW + 0.7, abs(in.edgePx));
    }
    return float4(u.color.rgb, a);
}

// ============================================================================
// 自绘地球（完全脱离 MapKit 的球体渲染路径）
//
// - 球体：UV 球网格 + 等距圆柱地表纹理，视图空间 N·L 光照 + 边缘大气辉光；
// - 点云：每点预存球面单位向量（TrackData 载入时 vForce 批算好），
//   顶点着色器抬升 pointLift 贴在球面上，透视投影后按像素半径展开
//   屏幕对齐四边形 —— 与平面路径同样是单 draw call 实例化；
// - 深度：球体写深度，点云 lessEqual 只测不写 —— 背面点被球身自然遮住，
//   无需任何 CPU 端剔除；
// - 交互约定（用户指定）：拖拽只旋转、滚轮只缩放，两者绝不混动。
// ============================================================================

struct GlobeUniforms {
    float4x4 mvp;          // proj · view · model
    float4x4 modelView;    // view · model（视图空间光照用；纯旋转+平移）
    float4   moonPosModel; // xyz = 月球位置（地固模型系，球半径=1），w = 月球半径
    float4   sunDirModel;  // xyz = 太阳方向（模型系单位向量，月相光照用）
    float2   ndcPerPixel;  // 每像素 NDC 增量（点广告牌展开）
    float2   projDiag;     // 透视矩阵对角 (xs, ys)：视空间位移 → 裁剪空间偏移
    float    radiusPx;     // 点半径（物理像素）
    float    haloPx;       // 白描边宽度
    float    alpha;        // 点全局透明度
    float    pointLift;    // 点沿法线的基础抬升（海拔抬升另加，见 lift 缓冲）
    uint     stride;       // LOD 抽稀间隔
    uint     count;        // 总点数
    uint     start;        // 时间筛选区间起始
    uint     rangeLen;     // 时间筛选区间长度
    uint     flags;        // bit0 = 高亮环，bit1 = 浅色外观（跟随系统日间模式）
    float    mapDim;       // 底图不透明度（与平面地图的压暗语义一致，只作用于球面）
    int      flashFile;    // 文件高亮闪烁：目标文件下标（-1 = 无）
    float    flashStrength;// 闪烁强度 0…1
    uint     fileMask;     // 迷雾模式文件显隐位掩码（仅 fogStyle 下生效）
    uint     pad0;
    uint     pad1;
    uint     pad2;
};

// 视图空间固定灯位（略偏右上，随相机走 —— 可见半球恒亮）
constant float3 kGlobeLight = float3(0.2993, 0.3492, 0.8880);

struct GlobeSphereVOut {
    float4 position [[position]];
    float3 normalView;
    float2 uv;
};

vertex GlobeSphereVOut globeSphereVertex(uint vid [[vertex_id]],
                                         const device packed_float3* pos [[buffer(0)]],
                                         const device float2* uv  [[buffer(1)]],
                                         constant GlobeUniforms& u [[buffer(2)]])
{
    float3 p = float3(pos[vid]);
    GlobeSphereVOut o;
    o.position = u.mvp * float4(p, 1.0);
    o.normalView = (u.modelView * float4(p, 0.0)).xyz;   // 单位球：法线 = 位置
    o.uv = uv[vid];
    return o;
}

fragment float4 globeSphereFragment(GlobeSphereVOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant GlobeUniforms& u [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear, mip_filter::linear,
                          s_address::repeat, t_address::clamp_to_edge);
    float3 base = tex.sample(smp, in.uv).rgb;
    float3 N = normalize(in.normalView);
    float diff = max(dot(N, kGlobeLight), 0.0);
    bool light = (u.flags & 2u) != 0u;
    // 日间外观：底色亮、环境光高、大气圈更浅更收敛
    float shade = light ? (0.52 + 0.48 * diff) : (0.32 + 0.68 * diff);
    float rim = pow(1.0 - saturate(N.z), 3.0);           // 边缘大气辉光
    float3 rimC = light ? float3(0.45, 0.62, 0.88) : float3(0.16, 0.32, 0.55);
    float rimK = light ? 0.24 : 0.35;
    float3 col = (base * shade + rimC * (rim * rimK)) * u.mapDim;
    return float4(col, 1.0);
}

struct GlobePointVOut {
    float4 position [[position]];
    float2 pxOffset;
    float4 color;
    float  radiusPx;
    float  haloPx;
    float  ringMode;     // 1 = 悬停/选中高亮环
};

vertex GlobePointVOut globePointVertex(uint vid [[vertex_id]],
                                       uint iid [[instance_id]],
                                       const device float*  ux [[buffer(0)]],
                                       const device float*  uy [[buffer(1)]],
                                       const device float*  uz [[buffer(2)]],
                                       const device uchar4* colors [[buffer(3)]],
                                       const device float*  lift [[buffer(4)]],
                                       constant GlobeUniforms& u [[buffer(5)]],
                                       const device ushort* fileID [[buffer(6)]])
{
    // 与平面路径同款下标钳制：LOD 抽稀 + 时间筛选区间
    uint hi = min(u.start + u.rangeLen - 1, u.count - 1);
    uint pi = min(u.start + iid * u.stride, hi);

    bool ring = (u.flags & 1u) != 0u;
    float3 unit = float3(ux[pi], uy[pi], uz[pi]);
    // 基础抬升 + 海拔抬升：地面轨迹略离球面，飞行轨迹拱出立体弧线
    float4 clip = u.mvp * float4(unit * (1.0 + u.pointLift + lift[pi]), 1.0);

    // 迷雾风格（flags bit2）：点云统一为白亮轨迹（配合暗化球面，
    // 与平面迷雾的"暗雾 + 亮走廊"观感在过渡时连续）
    bool fogStyle = (u.flags & 4u) != 0u;
    // 迷雾模式的文件显隐（与平面掩码语义一致；掩码全 1 时不读 fileID，
    // 避免占位缓冲越界；≥32 号文件恒可见）
    if (fogStyle && u.fileMask != 0xFFFFFFFFu) {
        uint fid = (u.flags & 8u) != 0u ? 0u:uint(fileID[pi]);
        if (fid < 32u && ((u.fileMask >> fid) & 1u) == 0u) {
            clip = float4(0.0, 0.0, -2.0, 1.0);   // 裁掉
        }
    }
    // 文件闪烁（与平面路径同语义）
    float radius = u.radiusPx;
    float4 c = float4(colors[pi]) / 255.0;
    if (fogStyle) { c = float4(0.97, 0.97, 0.94, 0.92); }
    float a = c.a * u.alpha;
    if (u.flashFile >= 0 && !ring) {
        if (((u.flags & 8u) != 0u ? 0:int(fileID[pi])) == u.flashFile) {
            radius = u.radiusPx * (1.0 + 0.55 * u.flashStrength);
            a = mix(a, 1.0, u.flashStrength);
        } else {
            a = a * mix(1.0, 0.10, u.flashStrength);
        }
    }

    // 裁剪空间加像素偏移：×clip.w 抵消透视除法，屏上恒为像素尺寸
    float margin = (radius <= 2.0) ? 1.0 : 1.5;
    float ext = ring ? (radius + 6.0)
                     : (radius + u.haloPx + margin);
    float2 corner = quadCorners[vid];
    clip.xy += corner * ext * u.ndcPerPixel * clip.w;

    // 与球面同一盏灯：点带一点明暗，视觉上贴合球体
    float3 nv = normalize((u.modelView * float4(unit, 0.0)).xyz);
    float shade = 0.55 + 0.45 * max(dot(nv, kGlobeLight), 0.0);

    GlobePointVOut o;
    o.position = clip;
    o.pxOffset = corner * ext;
    o.color = float4(c.rgb * shade, a);
    o.radiusPx = radius;
    o.haloPx = u.haloPx;
    o.ringMode = ring ? 1.0 : 0.0;
    return o;
}

fragment float4 globePointFragment(GlobePointVOut in [[stage_in]])
{
    float d = length(in.pxOffset);

    if (in.ringMode > 0.5) {
        // 悬停/选中高亮：描边圆环（与平面模式同款）
        float ri = in.radiusPx + 1.5;
        float ro = in.radiusPx + 4.5;
        float band = smoothstep(ri - 0.8, ri + 0.8, d) * (1.0 - smoothstep(ro - 0.8, ro + 0.8, d));
        return float4(float3(0.04, 0.52, 1.0), band);
    }

    float coreR = in.radiusPx;
    float haloR = in.radiusPx + in.haloPx;
    float outer = 1.0 - smoothstep(haloR - 0.8, haloR + 0.8, d);
    float core  = 1.0 - smoothstep(coreR - 0.8, coreR + 0.8, d);
    float3 rgb  = mix(float3(1.0), in.color.rgb, core);
    return float4(rgb, outer * in.color.a);
}

// ============================================================================
// 太空布景：星空（无穷远方向，随地球一起旋转）、月球（真实位置 + 真实月相）、
// 月球轨道细线。星星画在最远深度且不写深度，被球体自然遮挡。
// ============================================================================

struct StarData {          // 与 Swift 端 StarData 逐字段对齐（32 B）
    float4 a;              // xyz = 方向（模型系单位向量），w = 大小(px)
    float4 b;              // rgb = 色温，a = 亮度
};

struct StarVOut {
    float4 position [[position]];
    float2 local;
    float3 color;
    float  bright;
    float  sizePx;
};

vertex StarVOut starVertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           const device StarData* stars [[buffer(0)]],
                           constant GlobeUniforms& u [[buffer(1)]])
{
    StarData s = stars[iid];
    // 方向向量按 w=0 变换：星星在无穷远，只随旋转走，不随平移走
    float3 dv = (u.modelView * float4(s.a.xyz, 0.0)).xyz;
    StarVOut o;
    if (dv.z > -0.001) {                       // 相机背后的半天球
        o.position = float4(0.0, 0.0, -2.0, 1.0);
        o.local = float2(0.0); o.color = float3(0.0); o.bright = 0.0; o.sizePx = 1.0;
        return o;
    }
    float inv = 1.0 / (-dv.z);
    float2 ndc = float2(dv.x * u.projDiag.x * inv, dv.y * u.projDiag.y * inv);
    float ext = s.a.w * 2.0 + 1.5;    // 光晕余量
    float2 corner = quadCorners[vid];
    o.position = float4(ndc + corner * ext * u.ndcPerPixel, 0.99997, 1.0);   // 贴住远平面
    o.local = corner * ext;
    o.color = s.b.rgb;
    o.bright = s.b.a;
    o.sizePx = s.a.w;
    return o;
}

fragment float4 starFragment(StarVOut in [[stage_in]])
{
    float d = length(in.local);
    float core = 1.0 - smoothstep(in.sizePx * 0.5, in.sizePx, d);       // 实心星核
    float glow = 0.22 * exp(-d * d / max(in.sizePx * in.sizePx * 2.0, 0.1));
    float a = in.bright * min(1.0, core + glow);
    return float4(in.color, a);
}

struct MoonVOut {
    float4 position [[position]];
    float2 local;              // 广告牌局部坐标 [-1, 1]
    float3 sunView;            // 视图空间太阳方向（月相）
    float  fade;               // 近景淡出（sunDirModel.w）
};

vertex MoonVOut moonVertex(uint vid [[vertex_id]],
                           constant GlobeUniforms& u [[buffer(0)]])
{
    float4 clip = u.mvp * float4(u.moonPosModel.xyz, 1.0);
    float r = u.moonPosModel.w;
    float2 corner = quadCorners[vid];
    // 视空间位移 d 的裁剪空间像 = 投影对角 × d（与 z 无关），广告牌恒面向相机
    clip.x += corner.x * r * u.projDiag.x;
    clip.y += corner.y * r * u.projDiag.y;
    MoonVOut o;
    o.position = clip;
    o.local = corner;
    o.sunView = normalize((u.modelView * float4(u.sunDirModel.xyz, 0.0)).xyz);
    o.fade = u.sunDirModel.w;
    return o;
}

fragment float4 moonFragment(MoonVOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]])
{
    float rr = dot(in.local, in.local);
    float edge = (1.0 - smoothstep(0.94, 1.0, sqrt(rr))) * in.fade;
    if (edge <= 0.001) { discard_fragment(); }
    // 真实月面纹理（正面圆盘正交投影：月球潮汐锁定，永远以正面示人）
    constexpr sampler smp(mag_filter::linear, min_filter::linear, mip_filter::linear,
                          s_address::clamp_to_edge, t_address::clamp_to_edge);
    float2 uv = float2(in.local.x * 0.5 + 0.5, 0.5 - in.local.y * 0.5);
    float3 albedo = tex.sample(smp, uv).rgb * float3(1.0, 0.99, 0.955);   // 微暖色
    // 球体冒充：由圆面坐标重建法线 → 真实太阳方向打光 = 正确月相
    float nz = sqrt(max(1.0 - rr, 0.0));
    float3 N = normalize(float3(in.local.x, in.local.y, nz));
    float diff = max(dot(N, in.sunView), 0.0);
    float limb = 0.55 + 0.45 * nz;                       // 边缘减光
    float3 col = albedo * (0.045 + 0.955 * diff) * limb;
    return float4(col, edge);
}

vertex float4 orbitVertex(uint vid [[vertex_id]],
                          const device packed_float3* pts [[buffer(0)]],
                          constant GlobeUniforms& u [[buffer(1)]])
{
    return u.mvp * float4(float3(pts[vid]), 1.0);
}

fragment float4 orbitFragment(constant GlobeUniforms& u [[buffer(0)]])
{
    bool light = (u.flags & 2u) != 0u;
    float4 c = light ? float4(0.38, 0.46, 0.60, 0.45) : float4(0.55, 0.66, 0.85, 0.38);
    c.a *= u.sunDirModel.w;      // 近景淡出
    return c;
}

// ============================================================================
// 像素地球模式：点阵大陆/海洋 + 数据柱（计数 → 高度/色温）+ 流星。
// 地形点与数据柱共用 32B 实例结构；全部实例化、深度测试对球身自然遮挡。
// ============================================================================

struct PixelDot {          // 与 Swift 端 PixelDotData 逐字段对齐（32 B）
    float4 a;              // xyz = 单位向量；w = 地形: 0 海洋/1 陆地；数据柱: 柱高
    float4 b;              // 数据柱颜色 rgba（地形点忽略）
};

struct PixelDotVOut {
    float4 position [[position]];
    float2 local;
    float4 color;
    float  sizePx;
};

// 地形点阵：颜色按 海洋/陆地 × 深浅外观 从常量表取
vertex PixelDotVOut pixelDotVertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device PixelDot* dots [[buffer(0)]],
                                   constant GlobeUniforms& u [[buffer(1)]])
{
    PixelDot d = dots[iid];
    float4 clip = u.mvp * float4(d.a.xyz * 1.0015, 1.0);
    float sizePx = u.radiusPx;                     // 由 CPU 按格距投影算好
    float ext = sizePx + 1.0;
    float2 corner = quadCorners[vid];
    clip.xy += corner * ext * u.ndcPerPixel * clip.w;

    bool light = (u.flags & 2u) != 0u;
    bool land = d.a.w > 0.5;
    float3 col = light ? (land ? float3(0.33, 0.38, 0.45) : float3(0.58, 0.64, 0.71))
                       : (land ? float3(0.64, 0.68, 0.74) : float3(0.22, 0.25, 0.30));
    float alpha = land ? 0.68 : 0.30;

    PixelDotVOut o;
    o.position = clip;
    o.local = corner * ext;
    o.color = float4(col, alpha * u.mapDim);       // 底图透明度同样作用于点阵
    o.sizePx = sizePx;
    return o;
}

// 数据柱顶帽：同一结构，位置抬到柱顶，颜色取实例色
vertex PixelDotVOut pixelCapVertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device PixelDot* cells [[buffer(0)]],
                                   constant GlobeUniforms& u [[buffer(1)]])
{
    PixelDot d = cells[iid];
    float4 clip = u.mvp * float4(d.a.xyz * (1.002 + d.a.w), 1.0);
    float sizePx = u.radiusPx * 1.25;
    float ext = sizePx + 1.0;
    float2 corner = quadCorners[vid];
    clip.xy += corner * ext * u.ndcPerPixel * clip.w;
    PixelDotVOut o;
    o.position = clip;
    o.local = corner * ext;
    o.color = float4(d.b.rgb * 1.15, 1.0);
    o.sizePx = sizePx;
    return o;
}

fragment float4 pixelDotFragment(PixelDotVOut in [[stage_in]])
{
    float dd = length(in.local);
    float a = (1.0 - smoothstep(in.sizePx - 0.7, in.sizePx + 0.7, dd)) * in.color.a;
    return float4(in.color.rgb, a);
}

// 数据柱身：底/顶两端各自投影，屏幕空间展开定宽条带（近似圆柱），
// 每端携带自己的深度 → 与球身/其他柱正确遮挡
struct ColumnVOut {
    float4 position [[position]];
    float4 color;
    float  edge;       // 横向 [-1,1]（圆柱明暗）
};

vertex ColumnVOut columnVertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               const device PixelDot* cells [[buffer(0)]],
                               constant GlobeUniforms& u [[buffer(1)]])
{
    PixelDot d = cells[iid];
    float4 c0 = u.mvp * float4(d.a.xyz * 1.001, 1.0);              // 底
    float4 c1 = u.mvp * float4(d.a.xyz * (1.002 + d.a.w), 1.0);    // 顶
    float2 n0 = c0.xy / c0.w;
    float2 n1 = c1.xy / c1.w;
    float2 axis = n1 - n0;
    float lenN = length(axis);
    float2 dir = lenN > 1e-6 ? axis / lenN : float2(0.0, 1.0);
    float2 nrm = float2(-dir.y, dir.x);
    float halfW = u.haloPx * 0.5 + 0.45;                           // 柱宽（px）由 CPU 给
    float side = (vid % 2 == 0) ? -1.0 : 1.0;
    bool top = vid >= 2;
    float4 base = top ? c1 : c0;
    float2 ndc = (top ? n1 : n0) + nrm * side * halfW * u.ndcPerPixel;
    ColumnVOut o;
    o.position = float4(ndc * base.w, base.z, base.w);
    o.color = float4(d.b.rgb, 0.92);
    o.edge = side;
    return o;
}

fragment float4 columnFragment(ColumnVOut in [[stage_in]])
{
    // 柱面圆润明暗 + 边缘轻微 AA
    float shade = 0.72 + 0.28 * sqrt(max(0.0, 1.0 - in.edge * in.edge));
    float a = in.color.a * (1.0 - smoothstep(0.85, 1.0, abs(in.edge)));
    return float4(in.color.rgb * shade, a);
}

// 纯色球体（像素模式的底球：占深度 + 剪影 + 大气边）
fragment float4 pixelSphereFragment(GlobeSphereVOut in [[stage_in]],
                                    constant GlobeUniforms& u [[buffer(0)]])
{
    float3 N = normalize(in.normalView);
    bool light = (u.flags & 2u) != 0u;
    float diff = max(dot(N, kGlobeLight), 0.0);
    float3 base = light ? float3(0.885, 0.90, 0.92) : float3(0.045, 0.055, 0.075);
    float shade = light ? (0.94 + 0.06 * diff) : (0.80 + 0.20 * diff);
    float rim = pow(1.0 - saturate(N.z), 3.0);
    float3 rimC = light ? float3(0.45, 0.62, 0.88) : float3(0.20, 0.34, 0.55);
    float3 col = base * shade * u.mapDim + rimC * (rim * (light ? 0.20 : 0.30));
    return float4(col, 1.0);
}

// 流星：屏幕空间条带，头亮尾淡（暖色），背景层绘制、被球身覆盖
struct MeteorUniforms {    // 与 Swift 端 MeteorUniforms 对齐（32 B）
    float2 p0;             // 头部 NDC
    float2 dir;            // 单位方向（NDC 系，含纵横比修正）
    float  lenNdc;
    float  phase;          // 0..1 生命进度
    float  widthNdcY;
    float  pad;
};

struct MeteorVOut {
    float4 position [[position]];
    float  along;          // 0 = 头，1 = 尾
    float  side;
    float  phase;
};

vertex MeteorVOut meteorVertex(uint vid [[vertex_id]],
                               constant MeteorUniforms& m [[buffer(0)]])
{
    float along = (vid < 2) ? 0.0 : 1.0;
    float side = (vid % 2 == 0) ? -1.0 : 1.0;
    float2 nrm = float2(-m.dir.y, m.dir.x);
    float2 p = m.p0 - m.dir * m.lenNdc * along + nrm * side * m.widthNdcY;
    MeteorVOut o;
    o.position = float4(p, 0.99996, 1.0);
    o.along = along;
    o.side = side;
    o.phase = m.phase;
    return o;
}

fragment float4 meteorFragment(MeteorVOut in [[stage_in]])
{
    float tail = pow(1.0 - in.along, 2.2);                          // 头亮尾淡
    float across = 1.0 - smoothstep(0.4, 1.0, abs(in.side));
    float a = tail * across;                                        // 进出都在画面外，无需包络
    float3 col = mix(float3(1.0, 0.98, 0.92), float3(1.0, 0.62, 0.30), in.along * 1.15);
    return float4(col, a * 0.9);
}

// ============================================================================
// 平面热力图（两趟）：
// 1) heatAccum*：全部可见点以高斯核加性混合累积到半分辨率 r16f 密度纹理；
// 2) heatColor*：全屏三角形采样密度，1-exp(-v·gain) 压缩后过蓝→红色标。
// LOD 抽稀的密度损失由 gain×stride 归一化补偿。
// ============================================================================

struct HeatUniforms {
    float gain;        // 密度→热度增益（已含 stride 归一化）
    float opacity;     // 图层整体透明度
    float pad1;
    float pad2;
};

vertex VOut heatAccumVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            const device float* posX [[buffer(0)]],
                            const device float* posY [[buffer(1)]],
                            constant PointUniforms& u [[buffer(3)]],
                            const device uint* order [[buffer(7)]],
                            const device uint* aux [[buffer(8)]])
{
    uint pi, di;
    if (!resolvePointIndex(iid, u, order, aux, pi, di)) {
        VOut cull;
        cull.position = float4(0.0, 0.0, -2.0, 1.0);
        cull.pxOffset = float2(0.0);
        cull.color = float4(0.0);
        cull.radiusPx = 0.0;
        return cull;
    }
    float2 center = float2(posX[di], posY[di]) * u.scale + u.offset;
    float2 corner = quadCorners[vid];
    VOut o;
    o.position = float4(center + corner * u.radiusPx * u.ndcPerPixel, 0.0, 1.0);
    o.pxOffset = corner * u.radiusPx;
    o.color = float4(1.0);
    o.radiusPx = u.radiusPx;
    return o;
}

fragment float4 heatAccumFragment(VOut in [[stage_in]])
{
    float d = length(in.pxOffset) / max(in.radiusPx, 0.001);
    float w = exp(-d * d * 3.0) * step(d, 1.0);   // 高斯核，核外为零
    return float4(w, 0.0, 0.0, 0.0);
}

struct HeatQuadVOut {
    float4 position [[position]];
    float2 uv;
};

vertex HeatQuadVOut heatQuadVertex(uint vid [[vertex_id]])
{
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    HeatQuadVOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = float2((pos[vid].x + 1.0) * 0.5, (1.0 - pos[vid].y) * 0.5);
    return o;
}

fragment float4 heatColorFragment(HeatQuadVOut in [[stage_in]],
                                  texture2d<float> density [[texture(0)]],
                                  constant HeatUniforms& hu [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear);
    float v = density.sample(smp, in.uv).r;
    float t = 1.0 - exp(-v * hu.gain);            // 软压缩到 0..1
    if (t < 0.02) { discard_fragment(); }
    float3 c;
    if (t < 0.25)      c = mix(float3(0.10, 0.25, 0.85), float3(0.05, 0.75, 0.90), t / 0.25);
    else if (t < 0.50) c = mix(float3(0.05, 0.75, 0.90), float3(0.15, 0.85, 0.25), (t - 0.25) / 0.25);
    else if (t < 0.75) c = mix(float3(0.15, 0.85, 0.25), float3(0.98, 0.85, 0.15), (t - 0.50) / 0.25);
    else               c = mix(float3(0.98, 0.85, 0.15), float3(0.95, 0.15, 0.10), (t - 0.75) / 0.25);
    float a = min(1.0, t * 1.6) * hu.opacity;
    return float4(c, a);
}

// ============================================================================
// 迷雾模式（世界迷雾同款观感）：两趟——
// 1) fogSeg*：沿轨迹相邻点的"线段"撒胶囊形清除区（走廊连续，不会断珠），
//    清除半径按真实米制（随纬度校正），缩小时钳制最小像素宽度；
//    相邻点距离过大（轨迹间瞬移）自动剪断，只清端点；
// 2) fogColor*：全屏合成——未探索处画深色雾，走过区域挖透并叠加
//    白色冲刷 + 边缘亮晕（与手机版世界迷雾的明暗对比一致）。
// ============================================================================

struct FogUniforms {
    float4 color;    // rgb = 雾色，a = 雾整体不透明度
    float4 params;   // x = RTC 中心的墨卡托 y，y = 清除半径（米），
                     // z = 最小半径（累积纹理像素），w = 清除区白冲刷强度
    uint4  flags;    // x = 文件可见位掩码（重叠模式勾选显隐），yzw 备用
};

struct FogSegVOut {
    float4 position [[position]];
    float2 local;      // 胶囊局部坐标（像素）：x 沿线段，y 横向
    float  segLen;     // 线段长（像素）
    float  radius;     // 清除半径（像素）
};

vertex FogSegVOut fogSegVertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               const device float* posX [[buffer(0)]],
                               const device float* posY [[buffer(1)]],
                               constant PointUniforms& u [[buffer(3)]],
                               constant FogUniforms& f [[buffer(4)]],
                               const device uint* brk [[buffer(5)]],
                               const device ushort* fileID [[buffer(6)]],
                               const device uint* pathOrder [[buffer(7)]],
                               const device PathDrawRun* pathRuns [[buffer(8)]],
                               constant PathUniforms& path [[buffer(9)]])
{
    PathEdge edge = pathEdge(iid, pathOrder, pathRuns, path);
    if (!edge.valid || edge.i0 >= u.count || edge.i1 >= u.count) {
        FogSegVOut cull;
        cull.position = float4(0.0,0.0,-2.0,1.0); cull.local = float2(0.0);
        cull.segLen = 0.0; cull.radius = 1.0; return cull;
    }
    uint i0 = edge.i0, i1 = edge.i1;
    float2 aN = float2(posX[i0], posY[i0]) * u.scale + u.offset;
    float2 bN = float2(posX[i1], posY[i1]) * u.scale + u.offset;

    FogSegVOut o;
    // 文件显隐（重叠模式勾选）：掩码全 1 时跳过 fileID 读取——单文件/压测/
    // 删点重建等路径绑定的是 2 字节占位缓冲，读了就是越界。
    // i0 端隐藏 → 整段剔除；仅 i1 端隐藏 → 按断点处理（只清 i0 端点）。
    // ≥32 号文件超出掩码位宽，恒可见（UI 侧同样只给前 32 个勾选框）
    bool hideSeg = false;
    bool cutSeg = false;
    if (f.flags.x != 0xFFFFFFFFu) {
        uint f0 = uint(fileID[i0]);
        uint f1 = uint(fileID[i1]);
        hideSeg = (f0 < 32u) && (((f.flags.x >> f0) & 1u) == 0u);
        cutSeg  = (f1 < 32u) && (((f.flags.x >> f1) & 1u) == 0u);
    }
    if (hideSeg) {
        o.position = float4(0.0, 0.0, -2.0, 1.0);
        o.local = float2(0.0);
        o.segLen = 0.0;
        o.radius = 1.0;
        return o;
    }

    // 米 → 墨卡托（i0 纬度）：cos(lat) = 1/cosh(π(1−2y))
    float mercY = posY[i0] + f.params.x;
    float cosLat = 1.0 / cosh(3.14159265f * (1.0f - 2.0f * mercY));
    float rMerc = f.params.y / (40075016.7f * max(cosLat, 0.05f));
    float rPx = clamp(rMerc * u.scale.x / u.ndcPerPixel.x, f.params.z, 4096.0f);

    // CPU fog-runs already split hard boundaries and every original soft gap.
    // LOD is confined to one run; a singleton run clears its own endpoint.
    if (cutSeg) { bN = aN; }
    float2 pad = abs(u.ndcPerPixel) * rPx;
    if (any(max(aN,bN) < -1.0f - pad) || any(min(aN,bN) > 1.0f + pad)) {
        o.position = float4(0.0,0.0,-2.0,1.0); o.local = float2(0.0);
        o.segLen = 0.0; o.radius = 1.0; return o;
    }

    // 像素空间展开胶囊四边形（中心原点，y 方向翻转与否不影响等距展开）
    float2 A = aN / u.ndcPerPixel;
    float2 B = bN / u.ndcPerPixel;
    float2 d = B - A;
    float L = length(d);
    float2 dir = (L > 1e-4f) ? d / L : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float su = (vid < 2) ? 0.0f : 1.0f;
    float sv = (vid % 2 == 0) ? -1.0f : 1.0f;
    float ax = su * (L + 2.0f * rPx) - rPx;       // 沿轴 [-r, L+r]
    float2 P = A + dir * ax + nrm * (sv * rPx);

    o.position = float4(P * u.ndcPerPixel, 0.0, 1.0);
    o.local = float2(ax, sv * rPx);
    o.segLen = L;
    o.radius = rPx;
    return o;
}

fragment float4 fogSegFragment(FogSegVOut in [[stage_in]])
{
    // 胶囊 SDF：到线段的距离 → 高斯衰减
    float dx = clamp(in.local.x, 0.0, in.segLen);
    float d = length(float2(in.local.x - dx, in.local.y)) / max(in.radius, 0.001);
    float w = exp(-d * d * 3.0) * step(d, 1.0);
    return float4(w, 0.0, 0.0, 0.0);
}

struct HeatQuadVOut2 { float4 position [[position]]; float2 uv; };

fragment float4 fogColorFragment(HeatQuadVOut in [[stage_in]],
                                 texture2d<float> mask [[texture(0)]],
                                 constant FogUniforms& f [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear);
    float v = mask.sample(smp, in.uv).r;
    float explored = smoothstep(0.16, 0.50, v);
    // 未探索：深色雾；已探索：白色冲刷把走廊提亮（世界迷雾同款对比）
    float fogA = f.color.a * (1.0 - explored);
    float rim = smoothstep(0.05, 0.20, v) * (1.0 - smoothstep(0.45, 1.05, v));
    float whiteA = min(1.0, f.params.w * explored + rim * 0.38);
    // 两层预合成为单输出：先雾后白
    float outA = fogA + whiteA * (1.0 - fogA);
    float3 rgb = (f.color.rgb * fogA + float3(1.0) * whiteA * (1.0 - fogA))
               / max(outA, 0.003);
    return float4(rgb, outA);
}

// ============================================================================
// 迷雾存档（.fwdb）方格实例：每实例 [x, y, halfSize, coverage]
// （墨卡托，相对批中心），写覆盖率进遮罩纹理，合成 pass 复用 fogColor*。
// 聚合级别的部分覆盖块以 coverage < 1 呈现半清除。
// ============================================================================

struct FwdbCellVOut {
    float4 position [[position]];
    float2 localPx;                    // 距块中心的偏移（遮罩像素）
    float2 halfPx [[flat]];            // 块真实半宽/半高（遮罩像素）
    float  feather [[flat]];           // 羽边半宽（像素）：0.5 = 精确格，随格宽扩散 = 平滑
    float  coverage [[flat]];
};

// 方格向外扩 0.5px 画，片元里按"1px 盒滤波"算解析式覆盖率：
// 近看（块几十像素）边缘只有半像素羽化，仍是锐利的格子；
// 远看（块 ≈1px）自然融成平滑细线——对齐手机版世界迷雾的观感，
// 而且扩边后亚像素块也必然覆盖到像素中心，不会漏画成虚线
vertex FwdbCellVOut fwdbCellVertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device float4* cells [[buffer(0)]],
                                   constant PointUniforms& u [[buffer(3)]])
{
    float4 c = cells[iid];
    float2 corner = quadCorners[vid];
    // 块半宽换算到遮罩像素（scale.y 为负取绝对值）
    float2 halfPx = abs(c.z * u.scale / u.ndcPerPixel);
    // 平滑模式（mode==1）：每格换成径向高斯溅斑（σ≈0.95×半宽），相邻格的场
    // 相加后阈值取等值线——阶梯边融成圆滑连续的轮廓（类金属球，即手机版
    // 世界迷雾的扩散观感）；精确模式恒 0.5px 盒滤波，近看是锐利的原始格
    float fe = (u.mode == 1u) ? max(0.5, 0.95 * min(halfPx.x, halfPx.y)) : 0.5;
    float2 quadPx = halfPx + ((u.mode == 1u) ? 3.0 * fe : fe);
    float2 center = c.xy * u.scale + u.offset;
    // corner 直接在像素空间外扩，再换回 NDC（y 轴方向由 ndcPerPixel 恒正、
    // NDC 上下对称，方向翻转对对称四边形无影响）
    float2 pos = center + corner * quadPx * u.ndcPerPixel;
    FwdbCellVOut o;
    o.position = float4(pos, 0.0, 1.0);
    o.localPx = corner * quadPx;
    o.halfPx = halfPx;
    o.feather = fe;
    o.coverage = c.w;
    return o;
}

fragment float4 fwdbCellFragment(FwdbCellVOut in [[stage_in]])
{
    // feather>0.5 = 平滑模式：径向高斯溅斑；否则精确模式：1px 盒滤波抗锯齿
    float v;
    if (in.feather > 0.5001) {
        float r2 = dot(in.localPx, in.localPx) / (in.feather * in.feather);
        v = exp(-0.5 * r2);
    } else {
        float2 w = clamp(in.halfPx - abs(in.localPx) + 0.5, 0.0, 1.0);
        v = w.x * w.y;
    }
    // 亚像素块饱和增益：块 <1.1px 时线心峰值被抬回 ≥1，
    // 级别切换前后合成端的 rim/explored 项都在饱和区 → 无亮度跳变、
    // 细线沿线亮度均匀（大块 boost=1，近看观感不变）
    float boost = clamp(0.55 / max(min(in.halfPx.x, in.halfPx.y), 0.18), 1.0, 3.0);
    return float4(in.coverage * boost * v, 0.0, 0.0, 0.0);
}

// ============================================================================
// 3D 热力柱：自绘透视场景。方块按世界迷雾格网聚合（边长 k 格），
// 点数 → 高度（对数归一）+ 颜色（绿→黄→红）。两种样式共用一套实例：
//   棱角 = 平顶方柱（顶面用块自身高度）；
//   平滑 = 顶面四角取相邻块平均高度的双线性面片，块间自然衔接成地形。
// 每实例 30 顶点（顶面 2 三角 + 四面墙各 2），无索引实例化单 draw call。
// ============================================================================

struct Heat3DUniforms {
    float4x4 mvp;
    float4   light;    // xyz = 方向光（单位向量），w = 环境光
    float4   params;   // x = 平滑(0/1)，y = 地面亮度，z = 块透明度，w 备用
};

struct H3DVOut {
    float4 position [[position]];
    float3 color;
    float  shade;
};

constant float2 h3dCorner[4] = { float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,1) };

static inline float3 h3dHeatColor(float t) {
    float3 g = float3(0.13, 0.52, 0.29);
    float3 y = float3(0.95, 0.83, 0.20);
    float3 r = float3(0.90, 0.16, 0.09);
    return (t < 0.5) ? mix(g, y, t * 2.0) : mix(y, r, t * 2.0 - 1.0);
}

vertex H3DVOut heat3DBlockVertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device float4* blocks [[buffer(0)]],   // 3×float4/实例
                                 constant Heat3DUniforms& u [[buffer(1)]])
{
    float4 a = blocks[iid * 3 + 0];       // cx, cz, half, hOwn
    float4 hc = blocks[iid * 3 + 1];      // 角高 h00, h10, h11, h01（网格节点共享均值）
    float4 c2 = blocks[iid * 3 + 2];      // heat, …
    bool smoothMode = u.params.x > 0.5;

    // 顶点布局：0–11 顶面（中心扇 4 三角），12–35 四面墙（各 6）
    // —— 顶点级 LOD/剔除（百万块场景的性能关键）——
    float4 cc = u.mvp * float4(a.x, 0.0, a.y, 1.0);
    float pxHalf = a.z * u.params.z / max(cc.w, 1e-7);
    // 阈值一律相对 w（场景尺度从大洲到街区跨 4 个数量级，绝对值必错）
    if (cc.w <= 0.0
        || abs(cc.x) > cc.w * 1.6
        || cc.y > cc.w * 1.6 || cc.y < -cc.w * 2.6
        || (vid >= 12 && pxHalf < 0.6)) {
        H3DVOut o;
        o.position = float4(0.0, 0.0, -2.0, 1.0);
        o.color = float3(0.0);
        o.shade = 0.0;
        return o;
    }

    float3 pos;
    float3 nrm;
    float dim = 1.0;                      // 墙脚渐暗（伪 AO）

    if (vid < 12) {
        // 顶面：中心扇。平滑 = 角高双线性 + 每顶点法线（Gouraud，光滑曲面感）；
        // 棱角 = 平顶 + 恒定法线
        uint t = vid / 3;                 // 三角 0..3
        uint v = vid % 3;                 // 0 = 中心，1 = 角 t，2 = 角 t+1
        float hC = smoothMode ? (hc[0] + hc[1] + hc[2] + hc[3]) * 0.25 : a.w;
        uint ci = (v == 1) ? t : (t + 1) & 3;
        float2 c = h3dCorner[ci];
        float h = smoothMode ? hc[ci] : a.w;
        if (v == 0) {
            pos = float3(a.x, hC, a.y);
        } else {
            pos = float3(a.x + c.x * a.z, h, a.y + c.y * a.z);
        }
        if (smoothMode) {
            // 每顶点坡度法线（相邻角高差 → 光照连续过渡）
            float dx, dz;
            if (v == 0) {
                dx = (hc[1] + hc[2] - hc[0] - hc[3]) * 0.5;
                dz = (hc[2] + hc[3] - hc[0] - hc[1]) * 0.5;
            } else if (ci == 0) { dx = hc[1] - hc[0]; dz = hc[3] - hc[0]; }
            else if (ci == 1)   { dx = hc[1] - hc[0]; dz = hc[2] - hc[1]; }
            else if (ci == 2)   { dx = hc[2] - hc[3]; dz = hc[2] - hc[1]; }
            else                { dx = hc[2] - hc[3]; dz = hc[3] - hc[0]; }
            nrm = normalize(float3(-dx, 2.0 * a.z, -dz));
        } else {
            nrm = float3(0.0, 1.0, 0.0);
        }
    } else {
        uint w = (vid - 12) / 6;
        uint v = (vid - 12) % 6;
        float2 cA = h3dCorner[w];
        float2 cB = h3dCorner[(w + 1) & 3];
        float hA = smoothMode ? hc[w] : a.w;
        float hB = smoothMode ? hc[(w + 1) & 3] : a.w;
        // 0: A顶, 1: A底, 2: B顶, 3: B顶, 4: A底, 5: B底
        bool isB = (v == 2 || v == 3 || v == 5);
        bool isTop = (v == 0 || v == 2 || v == 3);
        float2 c = isB ? cB : cA;
        float h = isTop ? (isB ? hB : hA) : 0.0;
        pos = float3(a.x + c.x * a.z, h, a.y + c.y * a.z);
        float2 d = cB - cA;
        nrm = normalize(float3(d.y, 0.0, -d.x));
        dim = isTop ? 1.0 : 0.62;         // 墙脚压暗，柱体立体感
    }

    H3DVOut o;
    o.position = u.mvp * float4(pos, 1.0);
    o.color = h3dHeatColor(c2.x);
    o.shade = (u.light.w + (1.0 - u.light.w) * abs(dot(nrm, u.light.xyz))) * dim;
    return o;
}

fragment float4 heat3DBlockFragment(H3DVOut in [[stage_in]],
                                    constant Heat3DUniforms& u [[buffer(1)]])
{
    return float4(in.color * in.shade, 1.0);
}

// 地面：数据范围的底图截图贴在 y=0 平面（未就绪时纯色）
struct H3DGroundVOut {
    float4 position [[position]];
    float2 uv;
};

vertex H3DGroundVOut heat3DGroundVertex(uint vid [[vertex_id]],
                                        constant Heat3DUniforms& u [[buffer(1)]],
                                        constant float4& rect [[buffer(2)]])
{
    float2 p = float2((vid & 1) ? rect.z : rect.x,
                      (vid & 2) ? rect.w : rect.y);
    H3DGroundVOut o;
    o.position = u.mvp * float4(p.x, u.params.w, p.y, 1.0);
    o.uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    return o;
}

fragment float4 heat3DGroundFragment(H3DGroundVOut in [[stage_in]],
                                     constant Heat3DUniforms& u [[buffer(1)]],
                                     texture2d<float> tex [[texture(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear,
                          address::clamp_to_edge);
    float4 c = tex.sample(smp, in.uv);
    return float4(c.rgb * u.params.y, 1.0);
}
