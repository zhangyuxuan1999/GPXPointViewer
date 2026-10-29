import Foundation
import Metal

var passed = 0
func require(_ ok: @autoclosure () -> Bool, _ name: String) {
    guard ok() else { print("FAIL \(name)"); exit(1) }
    passed += 1; print("PASS \(name)")
}
guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { print("UNSUPPORTED no Metal device"); exit(77) }
let arguments=CommandLine.arguments
let shaderURL=URL(fileURLWithPath:arguments[1])
let originalShaderURL=URL(fileURLWithPath:arguments[2])
let source=try String(contentsOf:shaderURL,encoding:.utf8)
let inspectKernel="""
kernel void inspectPath(const device uint* order [[buffer(0)]],
                        const device PathDrawRun* runs [[buffer(1)]],
                        constant PathUniforms& path [[buffer(2)]],
                        device uint2* output [[buffer(3)]], uint iid [[thread_position_in_grid]]) {
    PathEdge e=pathEdge(iid,order,runs,path);
    output[iid]=e.valid ? uint2(e.i0,e.i1) : uint2(0xFFFFFFFFu);
}
"""
let library=try device.makeLibrary(source:source+inspectKernel,options:nil)
let compute=try device.makeComputePipelineState(function:library.makeFunction(name:"inspectPath")!)
print("DEVICE \(device.name)")
require(MemoryLayout<PathDrawRun>.size == 16 && MemoryLayout<PathDrawRun>.stride == 16 && MemoryLayout<PathUniforms>.stride == 16,"Swift/Metal draw descriptor ABI is 16 bytes")
let dummy=device.makeBuffer(length:4,options:.storageModeShared)!
func encodeInspection(_ group:PathGPUPlan, command:MTLCommandBuffer) -> MTLBuffer {
    let out=device.makeBuffer(length:max(8,group.plan.instanceCount*8),options:.storageModeShared)!
    guard group.plan.instanceCount > 0 else { return out }
    group.retain(untilCompleted:command)
    var uniform=group.uniforms()
    let encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(compute)
    encoder.setBuffer(group.order ?? dummy,offset:0,index:0);encoder.setBuffer(group.runs,offset:0,index:1)
    encoder.setBytes(&uniform,length:MemoryLayout<PathUniforms>.stride,index:2);encoder.setBuffer(out,offset:0,index:3)
    encoder.dispatchThreads(MTLSize(width:group.plan.instanceCount,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(64,group.plan.instanceCount),height:1,depth:1))
    encoder.endEncoding();return out
}
func decode(_ buffer:MTLBuffer,count:Int)->[String] {
    let words=buffer.contents().assumingMemoryBound(to:UInt32.self)
    return (0..<count).map { "\(words[2*$0])->\(words[2*$0+1])" }
}
func gpuEdges(_ group:PathGPUPlan)->[String] {
    let cmd=queue.makeCommandBuffer()!,out=encodeInspection(group,command:cmd)
    cmd.commit();cmd.waitUntilCompleted()
    require(cmd.status == .completed,"GPU endpoint inspection completes")
    return decode(out,count:group.plan.instanceCount)
}
func renderer(_ track:TrackData)->MetalPointRenderer {
    let r=MetalPointRenderer(library:library)!;r.setData(track:track);return r
}
func build(_ lat:[Double],_ lon:[Double],_ segments:[UInt32],time:[Double]?=nil,file:[UInt16]=[])->TrackData {
    var p=ParsedTrack();p.lat=lat;p.lon=lon;p.ele=Array(repeating:0,count:lat.count)
    p.time=time ?? lat.indices.map{Double($0)};p.segmentID=segments;p.fileID=file
    return TrackData.build(parsed:p,preferredMode:.single).0
}
let lat0=48.0,lon0=11.0
let dy=15.0/111320.0,dx=15.0/(111320.0*cos(lat0 * .pi/180))
let overlap=build([lat0-dy,lat0+dy,lat0-dy,lat0+dy],[lon0-dx,lon0-dx,lon0+dx,lon0+dx],[10,20,10,20],file:[0,1,0,1])
let r=renderer(overlap)
let sharedCache=TrackGPUBuffers(device:device,track:overlap)!
overlap.gpuBuffers=sharedCache; let sharedA=renderer(overlap)
overlap.gpuBuffers=sharedCache; let sharedB=renderer(overlap)
require(sharedA.testingPlan(kind:.line,start:0,length:4,stride:1)!.order === sharedCache.pathOrder &&
        sharedB.testingPlan(kind:.fog,start:0,length:4,stride:1)!.order === sharedCache.pathOrder,
        "two renderers adopt one immutable background-built path order without main-thread copies")

require(overlap.topology.order == [0,2,1,3],"fixture is globally interleaved with known normalized order")
for stride in [1,2,100] {
    for kind in [PathDrawKind.line,.fog] {
        let group=r.testingPlan(kind:kind,start:0,length:4,stride:stride)!
        require(gpuEdges(group)==["0->2","1->3"],"GPU keeps both true overlap edges stride \(stride) pass \(kind)")
    }
}
require(gpuEdges(r.testingPlan(kind:.line,start:1,length:3,stride:100)!)==["1->3"],"time filter line keeps only complete B edge")
require(gpuEdges(r.testingPlan(kind:.fog,start:1,length:3,stride:100)!)==["2->2","1->3"],"time filter fog keeps A singleton and B edge")
let five=build(Array(repeating:lat0,count:5),(0..<5).map{lon0+Double($0)*dx},[])
let fiveR=renderer(five)
require(gpuEdges(fiveR.testingPlan(kind:.line,start:0,length:5,stride:3)!)==["0->3","3->4"],"single identity stride3 retains tail edge")
let lone=build([lat0,lat0+dy],[lon0,lon0],[1,2])
let loneR=renderer(lone)
require(loneR.testingPlan(kind:.line,start:0,length:2,stride:99)!.plan.instanceCount==0,"line excludes singleton segments")
require(gpuEdges(loneR.testingPlan(kind:.fog,start:0,length:2,stride:99)!)==["0->0","1->1"],"fog keeps every singleton at large stride")
let soft=build([lat0-dy,lat0+dy,lat0-dy,lat0+dy],[lon0-dx,lon0-dx,lon0+dx,lon0+dx],[10,20,10,20],time:[0,1,700,701])
let softR=renderer(soft)
require(gpuEdges(softR.testingPlan(kind:.line,start:0,length:4,stride:100)!)==["0->2","1->3"],"line retains edges below its own soft time threshold")
require(gpuEdges(softR.testingPlan(kind:.fog,start:0,length:4,stride:100)!)==["0->0","2->2","1->1","3->3"],"fog soft time break cannot be skipped by LOD")
let farLon=lon0+200.0/(111320.0*cos(lat0 * .pi/180))
let distanceSoft=build([lat0-dy,lat0+dy,lat0-dy,lat0+dy,lat0-dy],[lon0-dx,lon0-dx,lon0+dx,lon0+dx,farLon],[10,20,10,20,10])
let distanceR=renderer(distanceSoft)
require(gpuEdges(distanceR.testingPlan(kind:.fog,start:0,length:5,stride:100)!)==["0->2","4->4","1->3"],"fog distance soft break remains split at arbitrary LOD")
require(gpuEdges(distanceR.testingPlan(kind:.line,start:0,length:5,stride:100)!)==["0->4","1->3"],"line uses its separate distance threshold rather than fog threshold")
let lineSoft=build([lat0,lat0],[lon0-dx,lon0+dx],[3,3],time:[0,1900])
let lineSoftR=renderer(lineSoft)
require(lineSoftR.testingPlan(kind:.line,start:0,length:2,stride:99)!.plan.instanceCount==0,"line honors its own soft time break")
require(gpuEdges(lineSoftR.testingPlan(kind:.line,start:0,length:2,stride:99,softBreaks:false)!)==["0->1"],"explicit preview disables soft break without merging hard segments")
require(gpuEdges(r.testingPlan(kind:.line,start:0,length:4,stride:100,softBreaks:false)!)==["0->2","1->3"],"preview soft-break override still cannot merge hard segments")
let cacheA=r.testingPlan(kind:.line,start:0,length:4,stride:2)!
let builds=r.pathPlanBuilds
let cacheB=r.testingPlan(kind:.line,start:0,length:4,stride:2)!
require(cacheA === cacheB && r.pathPlanBuilds==builds,"unchanged camera-independent cache key reuses immutable descriptor buffer")

let size=256
func texture(_ kind:PathDrawKind)->MTLTexture {
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:kind == .line ? .bgra8Unorm:.r16Float,width:size,height:size,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
    return device.makeTexture(descriptor:descriptor)!
}
let mercPerMeter=1.0/(40075016.7*cos(lat0 * .pi/180))
let scale=SIMD2<Float>(Float(2/(50*mercPerMeter)),Float(-2/(60*mercPerMeter)))
func value(_ tex:MTLTexture,_ x:Int,_ y:Int)->Float {
    let xx=max(0,min(size-1,x)),yy=max(0,min(size-1,y))
    if tex.pixelFormat == .r16Float {
        var word:UInt16=0;tex.getBytes(&word,bytesPerRow:2,from:MTLRegionMake2D(xx,yy,1,1),mipmapLevel:0)
        return Float(Float16(bitPattern:word))
    }
    var pixel:[UInt8]=[0,0,0,0]
    tex.getBytes(&pixel,bytesPerRow:4,from:MTLRegionMake2D(xx,yy,1,1),mipmapLevel:0)
    return Float(pixel[0])/255
}
func pixel(_ track:TrackData,_ index:Int,_ sc:SIMD2<Float>)->(Int,Int) {
    (Int((track.rtcX[index]*sc.x+1)*Float(size)/2),Int((1-track.rtcY[index]*sc.y)*Float(size)/2))
}
var lastRenderGPUms: Double?
func render(_ rr:MetalPointRenderer,_ track:TrackData,_ kind:PathDrawKind,_ sc:SIMD2<Float>,start:Int=0,length:Int?=nil,stride:Int=1,mask:UInt32=0xFFFFFFFF)->MTLTexture {
    let t=texture(kind)
    let cmd=rr.testingRenderPaths(texture:t,kind:kind,start:start,length:length ?? track.count,stride:stride,scale:sc,fileMask:mask,centerMercY:Float(track.center.y))!
    cmd.waitUntilCompleted();require(cmd.status == .completed,"offscreen \(kind) command completes")
    lastRenderGPUms = cmd.gpuStartTime > 0 ? (cmd.gpuEndTime-cmd.gpuStartTime)*1000:nil
    return t
}
let rowA=pixel(overlap,0,scale).1,rowB=pixel(overlap,1,scale).1
for kind in [PathDrawKind.line,.fog] {
    let image=render(r,overlap,kind,scale,stride:100)
    require(value(image,128,rowA)>0.6 && value(image,128,rowB)>0.6,"offscreen \(kind) preserves both overlap corridors at stride100")
    require(value(image,128,128)<0.05,"offscreen \(kind) has no cross-segment bridge")
    let masked=render(r,overlap,kind,scale,stride:100,mask:1)
    require(value(masked,128,rowA)>0.6 && value(masked,128,rowB)<0.05,"offscreen \(kind) hides one file without erasing other segment")
}
let filtered=render(r,overlap,.fog,scale,start:1,length:3,stride:100)
let aEnd=pixel(overlap,2,scale),aStart=pixel(overlap,0,scale)
require(value(filtered,aEnd.0,aEnd.1)>0.6 && value(filtered,aStart.0,aStart.1)<0.05,"filtered fog singleton is visible without resurrecting excluded A0")
let broken=render(softR,soft,.fog,scale,stride:100)
require(value(broken,128,rowA)<0.05 && value(broken,128,rowB)<0.05,"soft-broken fog does not restore corridors between singleton endpoints")
let crossing=build([lat0,lat0],[lon0-2*dx,lon0+2*dx],[5,5])
let crossingR=renderer(crossing),narrow=SIMD2<Float>(Float(2/(10*mercPerMeter)),Float(-2/(20*mercPerMeter)))
require(abs(crossing.rtcX[0]*narrow.x)>1.6 && abs(crossing.rtcX[1]*narrow.x)>1.6,"crossing fixture has both endpoints outside old culling window")
for kind in [PathDrawKind.line,.fog] {
    let image=render(crossingR,crossing,kind,narrow,stride:100)
    require(value(image,128,128)>0.6,"offscreen \(kind) keeps edge passing through viewport with both ends outside")
}

for kind in [PathDrawKind.line,.fog] {
    let visible=render(crossingR,crossing,kind,narrow,stride:100,mask:1)
    let hidden=render(crossingR,crossing,kind,narrow,stride:100,mask:0)
    require(value(visible,128,128)>0.6 && value(hidden,128,128)<0.05,"implicit file0 visibility never indexes dummy fileID buffer for \(kind)")
}
// Descriptor buffers are also immutable while an older GPU command is gated.
let oldGroup=r.testingPlan(kind:.line,start:0,length:4,stride:1)!
let oldBytes=Data(bytes:oldGroup.runs!.contents(),count:oldGroup.runs!.length)
let gate=device.makeSharedEvent()!,oldCommand=queue.makeCommandBuffer()!
oldCommand.encodeWaitForEvent(gate,value:1)
let oldOutput=encodeInspection(oldGroup,command:oldCommand);oldCommand.commit()
let newGroup=r.testingPlan(kind:.line,start:1,length:3,stride:100)!
let newCommand=queue.makeCommandBuffer()!,newOutput=encodeInspection(newGroup,command:newCommand);newCommand.commit()
require(oldGroup !== newGroup && oldGroup.runs! !== newGroup.runs! && oldBytes==Data(bytes:oldGroup.runs!.contents(),count:oldGroup.runs!.length),"cache replacement leaves old in-flight descriptor references and bytes untouched")
gate.signaledValue=1;oldCommand.waitUntilCompleted();newCommand.waitUntilCompleted()
require(decode(oldOutput,count:2)==["0->2","1->3"] && decode(newOutput,count:1)==["1->3"],"controlled GPU delay reads old and new path plans consistently")

// Pure draw-plan scaling plus real Metal endpoint dispatch: no million-entry edge table.
let originalLibrary=try device.makeLibrary(source:String(contentsOf:originalShaderURL,encoding:.utf8),options:nil)
let images=URL(fileURLWithPath:arguments.count>3 ? arguments[3]:"/private/tmp/segment-render-images")
try FileManager.default.createDirectory(at:images,withIntermediateDirectories:true)
for kind in [PathDrawKind.line,.fog] {
    let before=legacyImage(device:device,library:originalLibrary,track:overlap,kind:kind,scale:scale,size:size)
    let after=render(r,overlap,kind,scale)
    require(value(before,128,128)>0.6 && value(after,128,128)<0.05,"actual old shader negative control draws cross-segment bridge for \(kind)")
    try saveMask(before,to:images.appendingPathComponent("before-\(kind).png"))
    try saveMask(after,to:images.appendingPathComponent("after-\(kind).png"))
}
let tailBefore=legacyImage(device:device,library:originalLibrary,track:five,kind:.line,scale:scale,size:size,stride:3)
let tailAfter=render(fiveR,five,.line,scale,stride:3)
require(value(tailBefore,230,128)<0.05 && value(tailAfter,230,128)>0.6,"actual identity fast shader keeps visible 3->4 tail that old LOD draw count omits")
let crossingBefore=legacyImage(device:device,library:originalLibrary,track:crossing,kind:.fog,scale:narrow,size:size)
require(value(crossingBefore,128,128)<0.05,"actual old fog shader negative control drops both-outside crossing edge")
let crossingAfter=render(crossingR,crossing,.fog,narrow)
try saveMask(crossingBefore,to:images.appendingPathComponent("crossing-before.png"))
try saveMask(crossingAfter,to:images.appendingPathComponent("crossing-after.png"))
let globe=globePointsImage(device:device,library:library,size:size,mask:UInt32.max)
let globeMask=globePointsImage(device:device,library:library,size:size,mask:1)
require(value(globe,77,179)>0.3 && value(globe,77,77)>0.3 && value(globe,128,128)<0.05,"actual globe fog-style shader remains point-only with no invented connecting edge")
require(value(globeMask,77,179)>0.3 && value(globeMask,77,77)<0.05,"actual globe shader preserves existing file visibility mask")
let implicitGlobe=globePointsImage(device:device,library:library,size:size,mask:1,implicitFile:true)
let hiddenGlobe=globePointsImage(device:device,library:library,size:size,mask:0,implicitFile:true)
require(value(implicitGlobe,77,77)>0.3 && value(hiddenGlobe,77,77)<0.05,"globe implicit file0 uses safe uniform flag with two-byte fileID placeholder")
try saveMask(globe,to:images.appendingPathComponent("globe-points.png"))
let cameraPlan=r.testingPlan(kind:.line,start:0,length:4,stride:100)!,cameraBuilds=r.pathPlanBuilds
_ = render(r,overlap,.line,scale*0.9,stride:100)
require(r.testingPlan(kind:.line,start:0,length:4,stride:100) === cameraPlan && r.pathPlanBuilds == cameraBuilds,"camera scale change reuses cached plan without CPU point scan")

let clock=DispatchTime.now().uptimeNanoseconds
let million=TrackTopology(segmentID:[],count:1_000_000)
let millionPlan=million.makeDrawRuns(kind:.line,globalTimeRange:0..<1_000_000,stride:4096)
let millionMs=Double(DispatchTime.now().uptimeNanoseconds-clock)/1e6
let millionGPU=PathGPUPlan(device:device,plan:millionPlan,order:nil,identity:true)!
let millionEdges=gpuEdges(millionGPU)
require(millionPlan.runs.count==1 && millionEdges.first=="0->4096" && millionEdges.last!.hasSuffix("->999999"),"million-point identity plan uses one descriptor and retains final tail")
let labels=(0..<10000).map{UInt32($0)}+(0..<10000).map{UInt32($0)}
let manyClock=DispatchTime.now().uptimeNanoseconds
let many=TrackTopology(segmentID:labels,count:labels.count)
let manyPlan=many.makeDrawRuns(kind:.line,globalTimeRange:0..<labels.count,stride:100)
let manyMs=Double(DispatchTime.now().uptimeNanoseconds-manyClock)/1e6
let manyOrder=many.order.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}
let manyGPU=PathGPUPlan(device:device,plan:manyPlan,order:manyOrder,identity:false)!
let manyEdges=gpuEdges(manyGPU)
require(manyEdges == (0..<10000).map{"\($0)->\($0+10000)"},"10000 interleaved two-point segments map all real edges in one GPU dispatch")
let manyTrack=build(Array(repeating:lat0,count:20000),Array(repeating:lon0-dx,count:10000)+Array(repeating:lon0+dx,count:10000),labels,time:Array(repeating:0,count:10000)+Array(repeating:2,count:10000))
let manyRenderer=renderer(manyTrack)
let renderStart=DispatchTime.now().uptimeNanoseconds
_ = render(manyRenderer,manyTrack,.line,scale,stride:100)
let manyRenderWallMs=Double(DispatchTime.now().uptimeNanoseconds-renderStart)/1e6
require(manyRenderer.lastLineDrawCalls==1 && manyRenderer.topologyDrawStats["linePrimitives"]==10000,"10000 short segments use one actual production instanced line draw")
let manyRenderGPUMs=lastRenderGPUms
let singleCount=1_000_000
let singleLat=Array(repeating:lat0,count:singleCount)
let singleLon=(0..<singleCount).map {lon0-dx+2*dx*Double($0)/Double(singleCount-1)}
let singleTime=(0..<singleCount).map {Double($0)*0.01}
let singleTrack=build(singleLat,singleLon,[],time:singleTime)
let singleRenderer=renderer(singleTrack)
_ = render(singleRenderer,singleTrack,.line,scale)
let singleNewGPUms=lastRenderGPUms
require(singleRenderer.lastLineDrawCalls==1 && singleRenderer.topologyDrawStats["lineRuns"]==1 && singleRenderer.topologyDrawStats["linePrimitives"]==singleCount-1,"million-point single segment uses one identity descriptor and one actual line draw")
var singleOldGPUms:Double?
_ = legacyImage(device:device,library:originalLibrary,track:singleTrack,kind:.line,scale:scale,size:size,recordGPUTime:{singleOldGPUms=$0})
var warmNew:[Double]=[],warmOld:[Double]=[]
for round in 0..<7 {
    func measureNew() {
        _ = render(singleRenderer,singleTrack,.line,scale)
        if round>0, let ms=lastRenderGPUms { warmNew.append(ms) }
    }
    func measureOld() {
        _ = legacyImage(device:device,library:originalLibrary,track:singleTrack,kind:.line,scale:scale,size:size,recordGPUTime:{if round>0,let ms=$0 {warmOld.append(ms)}})
    }
    if round%2==0 {measureNew();measureOld()} else {measureOld();measureNew()}
}
func median(_ values:[Double])->Double? {let v=values.sorted();return v.isEmpty ? nil:(v[v.count/2]+v[(v.count-1)/2])/2}
let pathAllocatedBytes=device.currentAllocatedSize
let p3Checks=try runP3Regression()
require(p3Checks==17,"P3 real GPU immutable-color regression remains 17/17")
print("METRICS " + String(data:try JSONSerialization.data(withJSONObject:["million_identity_plan_ms":millionMs,"million_run_count":millionPlan.runs.count,"short_segments":10000,"short_segment_topology_plan_ms":manyMs,"short_segment_run_bytes":manyGPU.runs!.length,"short_segment_order_bytes":manyOrder.length,"device_allocated_bytes":device.currentAllocatedSize,"short_segments_render_wall_ms":manyRenderWallMs,"short_segments_line_draw_calls":manyRenderer.lastLineDrawCalls,"short_segments_render_gpu_ms":manyRenderGPUMs as Any? ?? NSNull(),"single_million_new_gpu_ms":singleNewGPUms as Any? ?? NSNull(),"single_million_old_gpu_ms":singleOldGPUms as Any? ?? NSNull(),"path_allocated_before_color_stress":pathAllocatedBytes,"single_warm_new_gpu_ms":warmNew,"single_warm_old_gpu_ms":warmOld,"single_warm_new_median_ms":median(warmNew) as Any? ?? NSNull(),"single_warm_old_median_ms":median(warmOld) as Any? ?? NSNull()]),encoding:.utf8)!)
print("SEGMENT_SUMMARY \(passed)/\(passed) PASS")
