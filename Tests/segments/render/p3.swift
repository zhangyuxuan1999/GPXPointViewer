import Foundation
import Metal
func runP3Regression() throws -> Int {

var passes = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { print("FAIL \(name)"); exit(1) }
    passes += 1; print("PASS \(name)")
}
func bytes(_ b: MTLBuffer) -> [UInt8] { Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: UInt8.self), count: b.length)) }
func permuted(_ rgba: [UInt8], _ order: [UInt32]) -> [UInt8] { order.flatMap { Array(rgba[(Int($0)*4)..<(Int($0)*4+4)]) } }
guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { print("UNSUPPORTED no Metal device"); exit(77) }
print("DEVICE \(dev.name)")
let shader = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 position [[position]]; };
vertex V pointVertex(uint i [[vertex_id]]) { V o; o.position=float4(0,0,0,1); return o; }
fragment float4 pointFragment() { return float4(1); }
vertex V segmentVertex(uint i [[vertex_id]]) { V o; o.position=float4(0,0,0,1); return o; }
fragment float4 segmentFragment() { return float4(1); }
"""
let lib = try dev.makeLibrary(source: shader, options: nil)
guard let a = MetalPointRenderer(library: lib), let b = MetalPointRenderer(library: lib) else { print("UNSUPPORTED renderer init"); exit(77) }
let order: [UInt32] = [2, 0, 3, 1]
let old: [UInt8] = [1,2,3,255, 10,20,30,255, 40,50,60,255, 70,80,90,255]
let one = old.map { $0 &+ 1 }, two = old.map { $0 &+ 2 }
let shared = PointColorBuffers.build(device: dev, colors: old, order: order, version: 0)!
a.testingAdopt(shared, count: 4, order: order); b.testingAdopt(shared, count: 4, order: order)
a.updateColors(one)
let first = a.testingColors!
check(first !== shared && first.temporal !== shared.temporal && first.spatial! !== shared.spatial!, "publish new temporal+spatial references")
check(bytes(shared.temporal) == old && bytes(shared.spatial!) == permuted(old,order), "old temporal/spatial bytes immutable")
check(bytes(first.temporal) == one && bytes(first.spatial!) == permuted(one,order), "new RGBA and known Morton permutation exact")
check(b.testingColors === shared && bytes(b.testingColors!.temporal) == old, "second renderer sharing initial group unaffected")
var allocations = 0
a.updateColors(two, allocate: { size in allocations += 1; return allocations == 2 ? nil : dev.makeBuffer(length:size,options:.storageModeShared) })
check(allocations == 2 && a.testingColors === first && a.testingColors!.version == first.version, "second allocation failure keeps entire old group+version")
a.updateColors([1,2,3])
check(a.testingColors === first, "invalid RGBA length leaves references+version unchanged")
let temporalOnly = PointColorBuffers.build(device: dev, colors: old, order: [], version: 10)!
a.testingAdopt(temporalOnly,count:4,order:[]); a.updateColors(one)
check(a.testingColors!.spatial == nil && bytes(a.testingColors!.temporal) == one, "no spatial copy updates temporal only")

var parsed = ParsedTrack()
parsed.lat = [48, 48.002, 48.001, 48.003]; parsed.lon = [11,11.003,11.001,11.002]
parsed.ele = [0,1,2,3]; parsed.time = [1,2,3,4]
let track = TrackData.build(parsed: parsed, preferredMode: .single).0
let cache = TrackGPUBuffers(device: dev,track: track)!
let cacheT = bytes(cache.color), cacheS = bytes(cache.scolor!)
track.gpuBuffers = cache; a.setData(track:track)
track.gpuBuffers = cache; b.setData(track:track)
check(a.testingColors!.temporal === cache.color && b.testingColors!.temporal === cache.color, "two real setData paths adopt same TrackGPUBuffers")
a.updateColors(two)
check(bytes(cache.color) == cacheT && bytes(cache.scolor!) == cacheS && bytes(b.testingColors!.temporal) == cacheT, "TrackGPUBuffers and other renderer stay unchanged after recolor")

// The GPU is submitted before CPU recoloring, but cannot read until event=1.
// No sleep or rapid-toggle visual observation can satisfy this gate.
let gate = dev.makeSharedEvent()!
let outOldT=dev.makeBuffer(length:old.count,options:.storageModeShared)!
let outOldS=dev.makeBuffer(length:old.count,options:.storageModeShared)!
a.testingAdopt(PointColorBuffers.build(device:dev,colors:old,order:order,version:20)!,count:4,order:order)
weak var delayedOldGroup = a.testingColors
let oldCommand = queue.makeCommandBuffer()!
oldCommand.encodeWaitForEvent(gate,value:1)
do {
    let snapshot = a.testingColors!
    snapshot.retain(untilCompleted:oldCommand)
    let copy=oldCommand.makeBlitCommandEncoder()!
    copy.copy(from:snapshot.temporal,sourceOffset:0,to:outOldT,destinationOffset:0,size:old.count)
    copy.copy(from:snapshot.spatial!,sourceOffset:0,to:outOldS,destinationOffset:0,size:old.count)
    copy.endEncoding()
}
oldCommand.commit()
a.updateColors(one); a.updateColors(two)
check(gate.signaledValue == 0 && oldCommand.status != .completed, "old GPU read held behind unsignaled gate across two CPU color publications")
check(delayedOldGroup != nil && delayedOldGroup!.version == 20, "old immutable group retained while its GPU command is pending")
let fresh = a.testingColors!
let outNewT=dev.makeBuffer(length:old.count,options:.storageModeShared)!
let outNewS=dev.makeBuffer(length:old.count,options:.storageModeShared)!
let newCommand=queue.makeCommandBuffer()!
fresh.retain(untilCompleted:newCommand)
let copy=newCommand.makeBlitCommandEncoder()!
copy.copy(from:fresh.temporal,sourceOffset:0,to:outNewT,destinationOffset:0,size:old.count)
copy.copy(from:fresh.spatial!,sourceOffset:0,to:outNewS,destinationOffset:0,size:old.count)
copy.endEncoding(); newCommand.commit()
gate.signaledValue=1
oldCommand.waitUntilCompleted(); newCommand.waitUntilCompleted()
check(oldCommand.status == .completed && newCommand.status == .completed, "both gated command buffers completed without GPU error")
check(bytes(outOldT) == old && bytes(outOldS) == permuted(old,order), "controlled old GPU frame reads original complete color pair")
check(bytes(outNewT) == two && bytes(outNewS) == permuted(two,order), "new GPU frame reads newest complete pair")

// Negative control: exactly the pre-fix in-place memcpy/gather behavior.
let legacy = PointColorBuffers.build(device:dev,colors:old,order:order,version:0)!
let legacyGate=dev.makeSharedEvent()!, legacyOut=dev.makeBuffer(length:old.count,options:.storageModeShared)!
let legacyCommand=queue.makeCommandBuffer()!
legacyCommand.encodeWaitForEvent(legacyGate,value:1)
let legacyCopy=legacyCommand.makeBlitCommandEncoder()!
legacyCopy.copy(from:legacy.temporal,sourceOffset:0,to:legacyOut,destinationOffset:0,size:old.count)
legacyCopy.endEncoding(); legacyCommand.commit()
two.withUnsafeBytes { _ = memcpy(legacy.temporal.contents(), $0.baseAddress!, $0.count) }
legacyGate.signaledValue=1; legacyCommand.waitUntilCompleted()
check(bytes(legacyOut) != old && bytes(legacyOut) == two, "negative control reproduces old frame observing CPU-overwritten bytes")

let n=1_000_000
let bigColors = (0..<(n*4)).map { UInt8(truncatingIfNeeded:$0) }
let bigOrder = (0..<n).reversed().map { UInt32($0) }
let baselineAllocated=dev.currentAllocatedSize
let start=DispatchTime.now().uptimeNanoseconds
let big=PointColorBuffers.build(device:dev,colors:bigColors,order:bigOrder,version:1)!
let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
check(big.temporal.length == n*4 && big.spatial!.length == n*4, "million-point pair allocation sizes exact")
a.testingAdopt(big,count:n,order:bigOrder)
let firstUpdateStart=DispatchTime.now().uptimeNanoseconds
a.updateColors(bigColors)
let firstUpdateMs=Double(DispatchTime.now().uptimeNanoseconds-firstUpdateStart)/1e6
let retainedIntermediate=a.testingColors!
let secondUpdateStart=DispatchTime.now().uptimeNanoseconds
a.updateColors(bigColors)
let secondUpdateMs=Double(DispatchTime.now().uptimeNanoseconds-secondUpdateStart)/1e6
check(a.testingColors !== retainedIntermediate && retainedIntermediate.temporal !== big.temporal,
      "million-point consecutive renderer updates publish distinct versions")
let metrics = try! JSONSerialization.data(withJSONObject: ["points":n,"pair_build_ms":elapsed,
    "first_update_ms":firstUpdateMs,"second_update_ms":secondUpdateMs,
    "gpu_allocated_before":baselineAllocated,"gpu_allocated_peak_sampled":dev.currentAllocatedSize,
    "retained_large_pair_versions":3])
print("METRICS " + String(data:metrics,encoding:.utf8)!)
print("SUMMARY \(passes)/\(passes) PASS")
return passes
}
