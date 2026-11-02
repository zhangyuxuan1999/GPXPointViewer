import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let path = "/Users/zyx/Documents/GPXPointViewer/data/backUpData-all 6.gpx"
let data = try! Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
let parsed = try! GPXParser.parse(data: data)
let (track, _) = TrackData.build(parsed: parsed, preferredMode: .single)
let plan = PlaybackPlan.buildCities(events: PlaybackPlan.events(track: track), duration: 45.0667)!
let cp = plan.cityPlan!
func lon(_ x: Double) -> Double { x*360-180 }
func lat(_ y: Double) -> Double { atan(sinh(.pi*(1-2*y)))*180 / .pi }
var failures = 0
for (i, ch) in cp.chapters.enumerated() {
    let kind = ch.city >= 0 ? "city\(ch.city)" : (ch.trip ? "trip" : (ch.finale ? "fin" : "trans"))
    for frac in [0.02, 0.1, 0.4, 0.7, 0.95] {
        let p = ch.p0 + (ch.p1 - ch.p0) * frac
        guard let cur = plan.cursors(at: p) else { continue }
        var active: [Int] = []
        for a in 0..<cur.count where cur[a] > 0 { active.append(a) }
        // 过渡必须没有活动点
        if ch.city < 0 && !ch.trip && !ch.finale {
            if !active.isEmpty { print("FAIL \(i) \(kind) frac=\(frac) transition draws \(active.count) areas"); failures += 1 }
            continue
        }
        var x0 = 1.0, x1 = 0.0, y0 = 1.0, y1 = 0.0
        var has = false
        for a in active {
            let bx: (Double,Double,Double,Double)
            if a < cp.cities.count {
                let c = cp.cities[a]; bx = (c.x0,c.y0,c.x1,c.y1)
            } else {
                let t = cp.transit[a - cp.cities.count]; bx = (t.x0,t.y0,t.x1,t.y1)
            }
            x0=min(x0,bx.0); y0=min(y0,bx.1); x1=max(x1,bx.2); y1=max(y1,bx.3); has = true
        }
        let cam = cp.camera(at: p, aspect: 9.0/16.0)
        let halfW = cam.span/2, halfH = cam.span*(9.0/16.0)/2
        if has {
            let inside = x0 >= cam.cx-halfW-1e-6 && x1 <= cam.cx+halfW+1e-6 && y0 >= cam.cy-halfH-1e-6 && y1 <= cam.cy+halfH+1e-6
            if !inside {
                print(String(format: "FAIL %d %@ frac=%.2f active bbox outside camera (n=%d) x=%.4f..%.4f cam=%.4f±%.4f y=%.4f..%.4f cam=%.4f±%.4f", i, kind, frac, active.count, x0,x1,cam.cx,halfW,y0,y1,cam.cy,halfH))
                failures += 1
            }
        }
        // 城市开头强制空
        if ch.city >= 0, frac <= 0.02, p < ch.p0 + 0.2 {
            if !active.isEmpty { print("FAIL \(i) city\(ch.city) start has \(active.count) active areas"); failures += 1 }
        }
        // 长途：活动区域中心必须在同一区域（欧洲章不能混中国）
        if ch.trip {
            var lons: [Double] = []
            for a in active where a >= cp.cities.count {
                let t = cp.transit[a - cp.cities.count]; lons.append(lon((t.x0+t.x1)/2))
            }
            if let mn = lons.min(), let mx = lons.max(), mx - mn > 60 {
                print("FAIL \(i) trip spans lon \(mn)..\(mx)"); failures += 1
            }
        }
    }
}
print(failures == 0 ? "CHECK PASS" : "CHECK FAIL \(failures)")
exit(failures == 0 ? 0 : 1)
