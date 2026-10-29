// RegionStats 只用到 TrackData 的这几个成员；离线探针用桩替代 app 里的真实类型
import Foundation
final class TrackData {
    let lat: [Double], lon: [Double], time: [Double]
    let count: Int, timedCount: Int
    init(lat: [Double], lon: [Double], time: [Double], timedCount: Int) {
        self.lat = lat; self.lon = lon; self.time = time; self.count = lat.count; self.timedCount = timedCount
    }
}
// FogArchive 只用到 FogStats 这个结构（真实定义在 TrackData.swift）
struct FogStats {
    var cells: Int; var km2: Double; var level: Int; var percent: Double; var nextLevelKm2: Double
}
