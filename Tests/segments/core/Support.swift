// Only GPU publication is stubbed: no product app or GPU submission is started.
import Foundation
import SwiftUI
struct TrackGPUBuffers {}
enum MetalPointRenderer { static func buildBuffers(track: TrackData) -> TrackGPUBuffers? { nil } }
// Exact bit-key value semantics from GapFillExport; routing/edit machinery is not linked.
enum GapFillExport {
    struct PointKey: Hashable {
        let t: UInt64, la: UInt64, lo: UInt64
        let segment: UInt32
        init(_ time: Double, _ lat: Double, _ lon: Double, segment: UInt32 = 0) {
            t = time.bitPattern; la = lat.bitPattern; lo = lon.bitPattern
            self.segment = segment
        }
    }
}
