import SwiftUI
import Foundation

typealias Overlay = TrackStore.FillOverlay
typealias Line = Overlay.BatchLine
let productionSwiftUIFont = Font(Overlay.engineLabelFont)

func line(_ status: Int, _ points: [CGPoint], selected: Bool = false, included: Bool = false) -> Line {
    Line(pts: points, status: status, selected: selected, included: included)
}
func pair(_ points: [CGPoint]) -> [Line] { [line(4, points), line(5, points)] }
func actualSize(_ text: String) -> CGSize {
    let glyphs = (text as NSString).size(withAttributes: [.font: Overlay.engineLabelFont])
    return CGSize(width: ceil(glyphs.width + 8), height: ceil(glyphs.height + 2))
}
func rect(_ label: Overlay.EngineLabel) -> CGRect {
    let size = actualSize(label.text)
    return CGRect(x: label.at.x - size.width / 2, y: label.at.y - size.height / 2,
                  width: size.width, height: size.height)
}
var failures: [String] = []
var records: [[String: Any]] = []
func check(_ name: String, _ lines: [Line], count: Int, minimum: CGFloat = 90,
           centers: [CGPoint]? = nil) {
    let labels = Overlay.engineLabels(lines, minScreenLength: minimum)
    let expectedTexts = lines.filter { ($0.status == 4 || $0.status == 5) && $0.pts.count >= 2 }
                            .map { $0.status == 4 ? "OSRM" : "Valhalla" }
    var errors: [String] = []
    if labels.count != count { errors.append("count \(labels.count), expected \(count)") }
    if count == expectedTexts.count && labels.map(\.text) != expectedTexts { errors.append("text/order changed") }
    for (index, label) in labels.enumerated() {
        if !label.at.x.isFinite || !label.at.y.isFinite { errors.append("nonfinite center \(index)") }
        if Overlay.engineLabelSize(label.text) != actualSize(label.text) { errors.append("frame/font mismatch \(index)") }
        for other in labels.indices where other < index {
            if rect(label).intersects(rect(labels[other])) { errors.append("rect collision \(other)/\(index)") }
        }
    }
    if let centers, labels.map(\.at) != centers { errors.append("noncolliding baseline position changed") }
    failures += errors.map { name + ": " + $0 }
    records.append(["name": name, "passed": errors.isEmpty, "errors": errors,
                    "count": labels.count, "labels": labels.map { l in
        ["text": l.text, "x": l.at.x, "y": l.at.y, "width": rect(l).width, "height": rect(l).height] as [String: Any]
    }])
}
let vertical = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 200)]
let horizontal = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)]
check("coincident-vertical", pair(vertical), count: 2)
check("coincident-vertical-reversed", pair(Array(vertical.reversed())), count: 2)
check("coincident-horizontal", pair(horizontal), count: 2, centers: [CGPoint(x: 100, y: -11), CGPoint(x: 100, y: 11)])
check("coincident-horizontal-reversed", pair(Array(horizontal.reversed())), count: 2)
check("diagonal-rising", pair([.zero, CGPoint(x: 200, y: 200)]), count: 2)
check("diagonal-falling", pair([CGPoint(x: 0, y: 200), CGPoint(x: 200, y: 0)]), count: 2)
check("opposite-line-directions", [line(4, vertical), line(5, Array(vertical.reversed()))], count: 2)
check("parallel-close-vertical", [line(4, vertical), line(5, vertical.map { CGPoint(x: $0.x + 30, y: $0.y) })], count: 2)
check("parallel-swapped-vertical", [line(4, vertical.map { CGPoint(x: $0.x + 30, y: $0.y) }), line(5, vertical)], count: 2,
      centers: [CGPoint(x: 41, y: 100), CGPoint(x: -11, y: 100)])
check("parallel-horizontal", [line(4, horizontal), line(5, horizontal.map { CGPoint(x: $0.x, y: $0.y + 20) })], count: 2,
      centers: [CGPoint(x: 100, y: -11), CGPoint(x: 100, y: 31)])
check("crossing-diagonals", [line(4, [.zero, CGPoint(x: 200, y: 200)]),
                            line(5, [CGPoint(x: 0, y: 200), CGPoint(x: 200, y: 0)])], count: 2)
check("curved-close-routes", [line(4, [.zero, CGPoint(x: 20, y: 100), CGPoint(x: 40, y: 200)]),
                              line(5, [.zero, CGPoint(x: 30, y: 100), CGPoint(x: 40, y: 200)])], count: 2)
check("zero-segment-before-midpoint", pair([.zero, .zero, CGPoint(x: 0, y: 200)]), count: 2)
check("eight-coincident-labels", (0..<8).map { line($0.isMultiple(of: 2) ? 4 : 5, vertical) }, count: 8)
check("noncolliding-original-offsets", [line(4, vertical), line(5, vertical.map { CGPoint(x: 200, y: $0.y) })], count: 2,
      centers: [CGPoint(x: 11, y: 100), CGPoint(x: 189, y: 100)])
check("below-90pt-hidden", pair([.zero, CGPoint(x: 89.999, y: 0)]), count: 0)
check("exact-90pt-visible", pair([.zero, CGPoint(x: 90, y: 0)]), count: 2)
check("other-statuses-hidden", (0...5).map { line($0, vertical) }, count: 2)
check("one-point-hidden", pair([.zero]), count: 0)
check("zero-length-hidden", pair([.zero, .zero]), count: 0)
check("custom-threshold-hidden", pair([.zero, CGPoint(x: 100, y: 0)]), count: 0, minimum: 120)
check("custom-threshold-visible", pair([.zero, CGPoint(x: 130, y: 0)]), count: 2, minimum: 120)
check("bent-arclength-midpoint", pair([.zero, CGPoint(x: 90, y: 0), CGPoint(x: 90, y: 90)]), count: 2,
      centers: [CGPoint(x: 90, y: -11), CGPoint(x: 90, y: 11)])
check("selection-flags-preserved", [line(4, vertical, selected: true, included: false),
                                   line(5, vertical, selected: false, included: true)], count: 2)
let report: [String: Any] = ["fontName": Overlay.engineLabelFont.fontName, "fontSize": Overlay.engineLabelFont.pointSize,
                           "cases": records.count, "passed": records.filter { $0["passed"] as? Bool == true }.count,
                           "failures": failures, "results": records]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
exit(failures.isEmpty ? 0 : 1)
