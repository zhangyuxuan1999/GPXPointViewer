import Foundation
import Cocoa

func storedPointCount(_ shape: GPXTrackShape) -> Int {
    Mirror(reflecting: shape).children.first(where: { $0.label == "scaledPts" }).map { ($0.value as! [CGPoint]).count } ?? -1
}
if CommandLine.arguments.contains("--memory") {
    let n = 1_000_000
    let lat = (0..<n).map { Double($0) / Double(n) * 0.1 }
    let lon = [Double](repeating: 0, count: n)
    let shape = GPXTrackShape(lat: lat, lon: lon)
    print("{\"input\":\(n),\"retained\":\(storedPointCount(shape)),\"edges\":\(shape.connectedEdgeCount)}")
    exit(0)
}
var passed = 0, failed: [String] = []
func check(_ predicate: @autoclosure () -> Bool, _ message: String) {
    if predicate() { passed += 1 } else { failed.append(message); print("FAIL: \(message)") }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func bitmap(_ shape: GPXTrackShape, name: String) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    NSColor.white.setFill(); NSBezierPath(rect: CGRect(x:0,y:0,width:320,height:120)).fill()
    shape.draw(in: CGRect(x:20,y:20,width:280,height:80), lineWidth: 2, dotRadius: 5)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name+".png"))
    return rep
}
func isInk(_ rep: NSBitmapImageRep, x: Int, y: Int = 60) -> Bool {
    let c = rep.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
    return min(c.redComponent, c.greenComponent, c.blueComponent) < 0.85
}
let singles = GPXTrackShape(lat:[0,0,0], lon:[0,1,2], segmentID:[1,2,3])
let singlePixels = bitmap(singles,name:"three-isolated")
check(isInk(singlePixels,x:20),"first isolated point visible")
check(isInk(singlePixels,x:160),"middle isolated point visible")
check(isInk(singlePixels,x:299),"last isolated point visible")
check(!isInk(singlePixels,x:90) && !isInk(singlePixels,x:230),"no bridge between isolated sources")
check(singles.connectedEdgeCount == 0,"isolated geometry has no edge")
let one = bitmap(GPXTrackShape(lat:[0],lon:[0],segmentID:[9]),name:"one-point")
check((152...164).contains { x in (52...68).contains { y in isInk(one,x:x,y:y) } },"one point visible")
let pair = bitmap(GPXTrackShape(lat:[0,0],lon:[0,2],segmentID:[9,9]),name:"two-connected")
check(isInk(pair,x:160),"two same-source points connect")
let splitPair = bitmap(GPXTrackShape(lat:[0,0],lon:[0,2],segmentID:[9,10]),name:"two-separated")
check(!isInk(splitPair,x:160),"two separate points never connect")
let overlap = GPXTrackShape(lat:[0,0.2,0,0.2],lon:[0,0,2,2],segmentID:[1,2,1,2])
check(overlap.connectedEdgeCount == 2,"interleaved sources keep two true edges")
_ = bitmap(overlap,name:"interleaved")
let count = 10_000
let longLat = (0..<(count*2)).map { Double($0%2000)*0.00001 }
let longLon = (0..<(count*2)).map { Double($0/2000)*0.00001 }
let twoSources = (0..<(count*2)).map { UInt32($0/2) }
let manyPairs = GPXTrackShape(lat:longLat,lon:longLon,segmentID:twoSources)
check(storedPointCount(manyPairs) <= 6000,"10000 two-point segments obey global6000 budget")
let waypoints = GPXTrackShape(lat:Array(longLat.prefix(count)),lon:Array(longLon.prefix(count)),segmentID:(0..<count).map(UInt32.init))
check(storedPointCount(waypoints) <= 6000,"10000 isolated sources obey global6000 budget")
check(waypoints.connectedEdgeCount == 0,"budgeted waypoints create no edge")
let softLat = [Double](repeating:0,count:104)
let softLon = [0.0,0.01,0.02,1.02] + (0..<100).map { $0%2 == 0 ? -100.0 : 100.0 }
let softIDs: [UInt32] = [1,1,1,1] + (2..<102).map(UInt32.init)
let softShape = GPXTrackShape(lat:softLat,lon:softLon,segmentID:softIDs)
check(softShape.connectedEdgeCount == 2,"cross-source distances cannot inflate soft-break median")
#if PREVIEW_PLAN
let pairsPlan = GPXPreviewSampling.plan(lat:longLat,lon:longLon,segmentID:twoSources)
check(pairsPlan.indices.count <= GPXPreviewSampling.pointBudget,"sampling plan global bound")
var groups: [UInt32:[Int]] = [:]
for i in pairsPlan.indices { groups[twoSources[i],default:[]].append(i) }
check(groups.values.allSatisfy { $0.count == 2 && $0[1] == $0[0]+1 && $0[0]%2 == 0 },"every retained two-point source preserves true endpoints")
let implicitCount=100_000
let implicit = GPXPreviewSampling.plan(lat:(0..<implicitCount).map { Double($0)*0.00001 },lon:[Double](repeating:0,count:implicitCount),segmentID:[])
check(implicit.indices.count == 6000 && implicit.indices.first == 0 && implicit.indices.last == implicitCount-1,"implicit arithmetic sampling retains true endpoints within budget")
let softPlan=GPXPreviewSampling.plan(lat:softLat,lon:softLon,segmentID:softIDs)
check(softPlan.medianStep < 0.02,"median uses only original same-source adjacency")
let excursionCount=20_000
var excursionLon=(0..<excursionCount).map { Double($0)*0.000001 }
excursionLon[10_001] += 2
let excursion=GPXPreviewSampling.plan(lat:[Double](repeating:0,count:excursionCount),lon:excursionLon,segmentID:[])
check(excursion.breakBefore.dropFirst().contains(true),"LOD propagates a skipped original soft break")
var unevenIDs:[UInt32]=[]
var expectedBounds:[UInt32:(first:Int,last:Int)]=[:]
for id in 0..<5000 {
    let first=unevenIDs.count
    unevenIDs.append(contentsOf:repeatElement(UInt32(id),count:id%7+1))
    expectedBounds[UInt32(id)]=(first,unevenIDs.count-1)
}
let uneven=GPXPreviewSampling.plan(lat:unevenIDs.indices.map { Double($0)*0.000001 },lon:[Double](repeating:0,count:unevenIDs.count),segmentID:unevenIDs)
let unevenGroups=Dictionary(grouping:uneven.indices,by:{unevenIDs[$0]})
check(uneven.indices.count<=6000,"uneven many-source global budget")
check(unevenGroups.allSatisfy { id,indices in indices.first == expectedBounds[id]!.first && indices.last == expectedBounds[id]!.last },"every retained uneven source keeps its true first and last")
let interleavedN=30000
let interleavedIDs=(0..<interleavedN).map { UInt32($0%7) }
let interleavedPlan=GPXPreviewSampling.plan(lat:(0..<interleavedN).map { Double($0)*0.000001 },lon:[Double](repeating:0,count:interleavedN),segmentID:interleavedIDs)
let interleavedGroups=Dictionary(grouping:interleavedPlan.indices,by:{interleavedIDs[$0]})
check(interleavedPlan.indices.count==6000 && interleavedGroups.count==7,"large interleaved paths share the global budget")
check(interleavedGroups.allSatisfy { id,indices in indices.first == Int(id) && indices.last == interleavedN-1-((interleavedN-1-Int(id))%7) },"interleaved true endpoints survive sampling")
check(interleavedPlan.indices.indices.dropFirst().allSatisfy { k in interleavedIDs[interleavedPlan.indices[k]] == interleavedIDs[interleavedPlan.indices[k-1]] || interleavedPlan.breakBefore[k] },"interleaved source transitions always break")
let endShape=GPXTrackShape(lat:[0,0,0,0],lon:[0,1,1.5,2],segmentID:[1,2,2,1])
let endPixels=bitmap(endShape,name:"original-end-marker")
let endColor=endPixels.colorAt(x:299,y:60)!.usingColorSpace(.deviceRGB)!
check(endColor.redComponent > endColor.greenComponent,"end marker follows original final point after grouping")
#endif
let report:[String:Any]=["passed":passed,"failed":failed,"pairInput":count*2,"pairRetained":storedPointCount(manyPairs),"waypointInput":count,"waypointRetained":storedPointCount(waypoints),"context":"headless NSBitmapImageRep + NSGraphicsContext; no NSApplication/window"]
print(String(data:try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
exit(failed.isEmpty ? 0:1)
