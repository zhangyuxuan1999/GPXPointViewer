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
    uint   pixelMode;    // 保留占位（与 Swift 端布局对齐）
    int    flashFile;    // 文件高亮闪烁：目标文件下标（-1 = 无）
    float  flashStrength;// 闪烁强度 0…1（淡入/淡出）
};

struct VOut {
    float4 position [[position]];
    float2 pxOffset;     // 相对圆心的像素偏移（插值）
    float4 color;
    float  radiusPx;     // 本实例半径（文件闪烁时目标文件放大）
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
                        const device ushort* fileID [[buffer(4)]])
{
    // LOD 抽稀 + 时间筛选区间：pi = start + iid·stride，双重钳制
    uint hi = min(u.start + u.rangeLen - 1, u.count - 1);
    uint pi = min(u.start + iid * u.stride, hi);

    float2 center = float2(posX[pi], posY[pi]) * u.scale + u.offset;

    // 文件闪烁：目标文件透明度拉满 + 放大，其余保色降透明（不全透明）
    float radius = u.radiusPx;
    float4 c = float4(colors[pi]) / 255.0;
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
    return float4(rgb, outer * in.color.a);
}

// ============================================================================
// 方向箭头轨迹线（GPU 实例化）
//
// 第 i 个实例 = 第 i 条线段，顶点着色器直接读 posX/posY[iid] 与 [iid+1]
// —— 与点渲染共用同一对 SoA 缓冲，零额外几何内存、零 CPU 预计算。
// 方向归一化、法线、箭头张角全部在 GPU 上对全部线段并行完成。
// 箭头语义：从时间早的点（iid）指向时间晚的点（iid+1）。
//
// 每条线段两次实例化提交：4 顶点三角带 = 箭杆，3 顶点三角形 = 箭头。
// ============================================================================

struct LineUniforms {
    float2 scale;        // RTC 墨卡托 → NDC
    float2 offset;
    float2 viewportPx;   // 物理像素
    float2 _pad;
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

vertex LineVOut segmentVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device float* posX [[buffer(0)]],
                              const device float* posY [[buffer(1)]],
                              constant LineUniforms& u [[buffer(2)]])
{
    LineVOut o;
    // LOD 抽稀 + 时间筛选区间：第 iid 段连接抽稀后的相邻两点
    uint hiIdx = min(u.start + u.rangeLen - 1, u.count - 1);
    uint i0 = min(u.start + iid * u.stride, hiIdx > 0 ? hiIdx - 1 : 0);
    uint i1 = min(i0 + u.stride, hiIdx);
    float2 a = lineMercToPixel(posX[i0], posY[i0], u);   // 时间早
    float2 b = lineMercToPixel(posX[i1], posY[i1], u);   // 时间晚
    float2 d = b - a;
    float len = length(d);
    if (len < 0.75) {
        // 亚像素线段：裁掉（z 超出 [0,w] 被剔除），远缩放时自动降密
        o.position = float4(0.0, 0.0, -2.0, 1.0);
        o.edgePx = 0.0;
        return o;
    }
    float2 dir = d / len;
    float2 nrm = float2(-dir.y, dir.x);
    float head = min(u.headLenPx, len * 0.5);

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

    // 文件闪烁（与平面路径同语义）
    float radius = u.radiusPx;
    float4 c = float4(colors[pi]) / 255.0;
    float a = c.a * u.alpha;
    if (u.flashFile >= 0 && !ring) {
        if (int(fileID[pi]) == u.flashFile) {
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
