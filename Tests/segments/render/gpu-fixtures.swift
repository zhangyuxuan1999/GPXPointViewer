import Foundation
import Metal
import ImageIO
import CoreGraphics
import simd

func legacyImage(device:MTLDevice,library:MTLLibrary,track:TrackData,kind:PathDrawKind,scale:SIMD2<Float>,size:Int,stride:Int=1,recordGPUTime:((Double?)->Void)? = nil)->MTLTexture {
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:kind == .line ? .bgra8Unorm:.r16Float,width:size,height:size,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
    let target=device.makeTexture(descriptor:descriptor)!
    let pipeline=MTLRenderPipelineDescriptor()
    pipeline.vertexFunction=library.makeFunction(name:kind == .line ? "segmentVertex":"fogSegVertex")
    pipeline.fragmentFunction=library.makeFunction(name:kind == .line ? "segmentFragment":"fogSegFragment")
    pipeline.colorAttachments[0].pixelFormat=target.pixelFormat
    if kind == .fog {
        pipeline.colorAttachments[0].isBlendingEnabled=true
        pipeline.colorAttachments[0].sourceRGBBlendFactor = .one
        pipeline.colorAttachments[0].destinationRGBBlendFactor = .one
    }
    let state=try! device.makeRenderPipelineState(descriptor:pipeline)
    let command=device.makeCommandQueue()!.makeCommandBuffer()!
    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
    let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
    func upload<T>(_ array:[T])->MTLBuffer { array.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!} }
    encoder.setRenderPipelineState(state)
    encoder.setVertexBuffer(upload(track.rtcX),offset:0,index:0);encoder.setVertexBuffer(upload(track.rtcY),offset:0,index:1)
    let zero=upload(Array(repeating:UInt32(0),count:track.count))
    if kind == .line {
        var u=LineUniforms(scale:scale,offset:.zero,viewportPx:SIMD2(Float(size),Float(size)),useBreaks:0,arrowEvery:1,color:SIMD4(1,1,1,1),widthPx:3,headLenPx:0,headWidthPx:0,isHead:0,stride:UInt32(stride),count:UInt32(track.count),start:0,rangeLen:UInt32(track.count))
        encoder.setVertexBytes(&u,length:MemoryLayout<LineUniforms>.stride,index:2)
        encoder.setVertexBuffer(zero,offset:0,index:3)
        encoder.setFragmentBytes(&u,length:MemoryLayout<LineUniforms>.stride,index:0)
        encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4,instanceCount:max(0,(track.count+stride-1)/stride-1))
    } else {
        var u=PointUniforms(scale:scale,offset:.zero,ndcPerPixel:SIMD2(2/Float(size),2/Float(size)),radiusPx:0,haloPx:0,alpha:1,mode:0,stride:1,count:UInt32(track.count),start:0,rangeLen:UInt32(track.count),pixelMode:0)
        var f=FogUniforms(color:SIMD4(0,0,0,1),params:SIMD4(Float(track.center.y),5,1,0),flags:SIMD4(UInt32.max,0,0,0))
        encoder.setVertexBytes(&u,length:MemoryLayout<PointUniforms>.stride,index:3)
        encoder.setVertexBytes(&f,length:MemoryLayout<FogUniforms>.stride,index:4)
        encoder.setVertexBuffer(zero,offset:0,index:5);encoder.setVertexBuffer(zero,offset:0,index:6);encoder.setVertexBuffer(zero,offset:0,index:7)
        encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4,instanceCount:track.count)
    }
    encoder.endEncoding();command.commit();command.waitUntilCompleted()
    precondition(command.status == .completed)
    recordGPUTime?(command.gpuStartTime > 0 ? (command.gpuEndTime-command.gpuStartTime)*1000:nil)
    return target
}

func saveMask(_ texture:MTLTexture,to url:URL) throws {
    let w=texture.width,h=texture.height
    var pixels=[UInt8](repeating:0,count:w*h)
    if texture.pixelFormat == .r16Float {
        var words=[UInt16](repeating:0,count:w*h)
        texture.getBytes(&words,bytesPerRow:w*2,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
        pixels=words.map { UInt8(min(255,max(0,Float(Float16(bitPattern:$0))*255))) }
    } else {
        var bytes=[UInt8](repeating:0,count:w*h*4)
        texture.getBytes(&bytes,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
        pixels=(0..<(w*h)).map { bytes[$0*4] }
    }
    let provider=CGDataProvider(data:Data(pixels) as CFData)!
    let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,
        space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
        decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain:"PNG",code:1) }
}

func globePointsImage(device:MTLDevice,library:MTLLibrary,size:Int,mask:UInt32,implicitFile:Bool=false)->MTLTexture {
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:size,height:size,mipmapped:false)
    d.storageMode = .shared;d.usage=[.renderTarget,.shaderRead]
    let target=device.makeTexture(descriptor:d)!
    let p=MTLRenderPipelineDescriptor()
    p.vertexFunction=library.makeFunction(name:"globePointVertex");p.fragmentFunction=library.makeFunction(name:"globePointFragment")
    p.colorAttachments[0].pixelFormat = .bgra8Unorm
    let state=try! device.makeRenderPipelineState(descriptor:p)
    let command=device.makeCommandQueue()!.makeCommandBuffer()!,pass=MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
    let e=command.makeRenderCommandEncoder(descriptor:pass)!
    func upload<T>(_ a:[T])->MTLBuffer {a.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}}
    e.setRenderPipelineState(state)
    e.setVertexBuffer(upload([Float(-0.4),-0.4,0.4,0.4]),offset:0,index:0)
    e.setVertexBuffer(upload([Float(-0.4),0.4,-0.4,0.4]),offset:0,index:1)
    e.setVertexBuffer(upload(Array(repeating:Float(sqrt(0.68)),count:4)),offset:0,index:2)
    e.setVertexBuffer(upload(Array(repeating:UInt8(255),count:16)),offset:0,index:3)
    e.setVertexBuffer(upload(Array(repeating:Float(0),count:4)),offset:0,index:4)
    e.setVertexBuffer(upload(implicitFile ? [UInt16(0)]:[UInt16(0),1,0,1]),offset:0,index:6)
    var u=GlobeUniforms(mvp:matrix_identity_float4x4,modelView:matrix_identity_float4x4,moonPosModel:.zero,sunDirModel:.zero,
        ndcPerPixel:SIMD2(2/Float(size),2/Float(size)),projDiag:SIMD2(1,1),radiusPx:4,haloPx:0,alpha:1,pointLift:0,stride:1,count:4,start:0,rangeLen:4,flags:implicitFile ? 12:4,mapDim:1,flashFile:-1,flashStrength:0,fileMask:mask)
    e.setVertexBytes(&u,length:MemoryLayout<GlobeUniforms>.stride,index:5)
    e.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4,instanceCount:4)
    e.endEncoding();command.commit();command.waitUntilCompleted();precondition(command.status == .completed)
    return target
}
