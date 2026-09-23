import AppKit
import MetalKit
import simd

struct IconVertex { var position:SIMD4<Float>; var normal:SIMD4<Float>; var uvKind:SIMD4<Float> }
private struct Uniforms {
    var mvp:simd_float4x4; var model:simd_float4x4; var inverseModel:simd_float4x4
    var time:SIMD4<Float>; var lightVP:simd_float4x4
    var light:SIMD4<Float>; var tint:SIMD4<Float>; var settings:SIMD4<Float>
    var light1:SIMD4<Float>; var light2:SIMD4<Float>; var light3:SIMD4<Float>
    var tint1:SIMD4<Float>; var tint2:SIMD4<Float>; var tint3:SIMD4<Float>
    var vp1:simd_float4x4; var vp2:simd_float4x4; var vp3:simd_float4x4
    var kinds:SIMD4<Float>
    var direction0:SIMD4<Float>; var direction1:SIMD4<Float>; var direction2:SIMD4<Float>; var direction3:SIMD4<Float>
}

final class RotationClock {
    private var angle:Double=0.42
    private var last=CACurrentMediaTime()
    var speed:Double=1 { willSet { advance() } }
    var paused=false { willSet { advance() } }
    func advance() { let now=CACurrentMediaTime(); if !paused {angle += (now-last)*0.30*speed};last=now }
    var current:Float {advance();return Float(angle.truncatingRemainder(dividingBy:Double.pi*2))}
}
struct RenderAsset {
    let source:CutoutImage
    let palette:[IconColor]
    let texture:MTLTexture
    let sideTexture:MTLTexture
    let vertices:MTLBuffer
    let vertexCount:Int
    let sideSegments:Int
    let method:String
    let rayStructure:MTLAccelerationStructure?
    static func make(_ input:CutoutImage,device:MTLDevice) throws -> RenderAsset {
        let contours=IconContour.loops(input)
        let cutout=IconContour.applying(contours,to:input)
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:cutout.size,height:cutout.size,mipmapped:false)
        desc.storageMode = .shared;desc.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:desc) else {throw IconRenderer.RendererError.unavailable}
        cutout.pixels.withUnsafeBytes {texture.replace(region:MTLRegionMake2D(0,0,cutout.size,cutout.size),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:cutout.size*4)}
        let (mesh,segments)=Self.mesh(cutout,contours:contours)
        guard let buffer=device.makeBuffer(bytes:mesh,length:MemoryLayout<IconVertex>.stride*mesh.count,options:.storageModeShared) else {throw IconRenderer.RendererError.unavailable}
        return RenderAsset(source:cutout,palette:IconPalette.colors(in:cutout),texture:texture,sideTexture:try sidePaint(cutout,device:device),vertices:buffer,vertexCount:mesh.count,sideSegments:segments,method:cutout.method,rayStructure:buildRayStructure(cutout,mesh:mesh,device:device))
    }
    func replacingTexture(_ cut:CutoutImage,device:MTLDevice) throws -> RenderAsset {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:cut.size,height:cut.size,mipmapped:false)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:d) else {throw IconRenderer.RendererError.unavailable}
        cut.pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,cut.size,cut.size),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:cut.size*4)}
        return RenderAsset(source:source,palette:palette,texture:t,sideTexture:try Self.sidePaint(cut,device:device),vertices:vertices,vertexCount:vertexCount,sideSegments:sideSegments,method:method,rayStructure:rayStructure)
    }
    static func buildRayStructure(_ cutout:CutoutImage,mesh:[IconVertex],device:MTLDevice)->MTLAccelerationStructure? {
        guard device.supportsRaytracingFromRender else{return nil}
        // The ordinary face is a square with shader-discarded transparent pixels.
        // Build rays from covered cells instead, so icon holes stay open to light.
        let grid=128,n=cutout.size
        var positions:[SIMD4<Float>]=[]
        positions.reserveCapacity(grid*grid*6)
        func triangle(_ a:SIMD4<Float>,_ b:SIMD4<Float>,_ c:SIMD4<Float>) {positions.append(a);positions.append(b);positions.append(c)}
        for y in 0..<grid {for x in 0..<grid {
            let px=min(n-1,(x*n+n/2)/grid),py=min(n-1,(y*n+n/2)/grid)
            guard cutout.pixels[(py*n+px)*4+3]>=128 else{continue}
            let x0=Float(x)*2/Float(grid)-1,x1=Float(x+1)*2/Float(grid)-1
            let y0=1-Float(y)*2/Float(grid),y1=1-Float(y+1)*2/Float(grid)
            for z in [Float(0.13),Float(-0.13)] {
                let a=SIMD4<Float>(x0,y0,z,1),b=SIMD4<Float>(x1,y0,z,1),c=SIMD4<Float>(x1,y1,z,1),d=SIMD4<Float>(x0,y1,z,1)
                triangle(a,b,c);triangle(a,c,d)
            }
        }}
        positions.append(contentsOf:mesh.dropFirst(12).map{$0.position})
        guard positions.count>=3,let queue=device.makeCommandQueue() else{return nil}
        let byteCount=positions.count*MemoryLayout<SIMD4<Float>>.stride
        guard let vertices=positions.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:byteCount,options:.storageModeShared)}) else{return nil}
        let geometry=MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer=vertices;geometry.vertexFormat = .float3;geometry.vertexStride=MemoryLayout<SIMD4<Float>>.stride;geometry.triangleCount=positions.count/3
        let descriptor=MTLPrimitiveAccelerationStructureDescriptor();descriptor.geometryDescriptors=[geometry]
        let sizes=device.accelerationStructureSizes(descriptor:descriptor)
        guard sizes.accelerationStructureSize < 128*1024*1024,
              let structure=device.makeAccelerationStructure(size:sizes.accelerationStructureSize),
              let scratch=device.makeBuffer(length:sizes.buildScratchBufferSize,options:.storageModePrivate),
              let command=queue.makeCommandBuffer(),let encoder=command.makeAccelerationStructureCommandEncoder() else{return nil}
        encoder.build(accelerationStructure:structure,descriptor:descriptor,scratchBuffer:scratch,scratchBufferOffset:0)
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        return command.status == .completed ? structure : nil
    }
    // Body paint is a separate low-frequency color field. Face detail never gets
    // stretched down the extrusion, and recoloring regenerates both paint fields.
    static func sidePaint(_ cut:CutoutImage,device:MTLDevice) throws -> MTLTexture {
        let n=cut.size,r=max(3,n/28)
        var values=(0..<n*n).map { i in SIMD4<Float>(Float(cut.pixels[i*4]),Float(cut.pixels[i*4+1]),Float(cut.pixels[i*4+2]),Float(cut.pixels[i*4+3]))/255 }
        for _ in 0..<3 {for horizontal in [true,false] {
            var next=[SIMD4<Float>](repeating:.zero,count:n*n)
            for line in 0..<n {
                func index(_ offset:Int)->Int {let x=max(0,min(n-1,offset));return horizontal ? line*n+x : x*n+line}
                var sum=SIMD4<Float>.zero
                for offset in -r...r {sum+=values[index(offset)]}
                for offset in 0..<n {
                    next[index(offset)]=sum/Float(2*r+1)
                    sum-=values[index(offset-r)];sum+=values[index(offset+r+1)]
                }
            }
            values=next
        }}
        var bytes=[UInt8](repeating:255,count:n*n*4)
        for i in values.indices {for c in 0..<3 {bytes[i*4+c]=UInt8(max(0,min(255,(values[i][c]/max(values[i].w,0.0001)*255).rounded())))}}
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:n,height:n,mipmapped:false)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:d) else{throw IconRenderer.RendererError.unavailable}
        bytes.withUnsafeBytes {texture.replace(region:MTLRegionMake2D(0,0,n,n),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:n*4)}
        return texture
    }
    static func mesh(_ cutout:CutoutImage,contours:[[SIMD2<Float>]]?=nil) -> ([IconVertex],Int) {
        var out:[IconVertex]=[]
        let depth:Float=0.13
        func v(_ uv:SIMD2<Float>,_ z:Float,_ normal:SIMD3<Float>,_ kind:Float,_ sampleUV:SIMD2<Float>?=nil) -> IconVertex {
            let s=sampleUV ?? uv
            return IconVertex(position:SIMD4(uv.x*2-1,1-uv.y*2,z,1),normal:SIMD4(normal,0),uvKind:SIMD4(s.x,s.y,kind,0))
        }
        let corners:[SIMD2<Float>]=[SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)]
        // Transparent front/back samples are discarded, including every interior hole.
        for z in [depth,-depth] {for i in [0,1,2,0,2,3] {out.append(v(corners[i],z,SIMD3(0,0,z>0 ? 1 : -1),0))}}
        let n=cutout.size
        func a(_ x:Int,_ y:Int) -> Float {Float(cutout.pixels[(max(0,min(n-1,y))*n+max(0,min(n-1,x)))*4+3])/255}
        func alpha(_ uv:SIMD2<Float>)->Float {
            let px=uv.x*Float(n)-0.5,py=uv.y*Float(n)-0.5
            let x=Int(floor(px)),y=Int(floor(py)),tx=px-Float(x),ty=py-Float(y)
            return (a(x,y)*(1-tx)+a(x+1,y)*tx)*(1-ty)+(a(x,y+1)*(1-tx)+a(x+1,y+1)*tx)*ty
        }
        let paths=contours ?? IconContour.loops(cutout)
        var count=0
        for path in paths {
            let size=path.count
            var normals:[SIMD3<Float>]=[]
            for i in path.indices {
                // Average over a short arc, independent of the original pixel grid.
                let span=min(16,max(1,size/8)),d=path[(i+span)%size]-path[(i+size-span)%size]
                let tangent=SIMD3(d.x,-d.y,0)
                normals.append(simd_length(tangent)>0.000001 ? simd_normalize(SIMD3(-tangent.y,tangent.x,0)) : SIMD3(1,0,0))
            }
            var orientation:Float=0
            for i in path.indices {
                let offset=SIMD2(normals[i].x,-normals[i].y)*2.5/Float(n)
                orientation += alpha(path[i]+offset)-alpha(path[i]-offset)
            }
            if orientation>0 {normals=normals.map{-$0}}
            // The face ends at the original contour. A rounded lip rolls outward
            // into the body, with continuous normals from face through side to back.
            let bevel:Float=min(0.022,12.0/Float(n))
            var rings:[(offset:Float,z:Float,side:Float,front:Float)]=[]
            for step in 0...6 {
                let t=Float(step)/6 * Float.pi/2
                rings.append((bevel*sin(t),depth-bevel+bevel*cos(t),sin(t),cos(t)))
            }
            for step in (0...6).reversed() {
                let t=Float(step)/6 * Float.pi/2
                rings.append((bevel*sin(t),-depth+bevel-bevel*cos(t),sin(t),-cos(t)))
            }
            func point(_ i:Int,_ ring:Int)->IconVertex {
                let normal=normals[i],r=rings[ring],uv=path[i]+SIMD2(normal.x,-normal.y)*r.offset*0.5
                let paint=path[i]+SIMD2(-normal.x,normal.y)*8/Float(n)
                return v(uv,r.z,SIMD3(normal.x*r.side,normal.y*r.side,r.front),1,paint)
            }
            for i in path.indices {
                let j=(i+1)%size
                for ring in 0..<rings.count-1 {
                    out += [point(i,ring),point(j,ring),point(j,ring+1),point(i,ring),point(j,ring+1),point(i,ring+1)]
                }
                count+=1
            }
        }
        return (out,count)
    }
}
private func rotation(_ angle:Float,axis:SIMD3<Float>) -> simd_float4x4 {simd_float4x4(simd_quatf(angle:angle,axis:axis))}
private func translation(_ z:Float) -> simd_float4x4 {var m=matrix_identity_float4x4;m.columns.3.z=z;return m}
private func perspective(_ aspect:Float) -> simd_float4x4 {
    let y:Float=1/tan(0.57/2),x=y/aspect,near:Float=0.1,far:Float=30
    return simd_float4x4(columns:(SIMD4(x,0,0,0),SIMD4(0,y,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,far*near/(near-far),0)))
}
final class IconRenderer:NSObject,MTKViewDelegate {
    let device:MTLDevice
    let clock:RotationClock
    private let queue:MTLCommandQueue
    private let pipeline:MTLRenderPipelineState
    private let rayPipeline:MTLRenderPipelineState?
    private let receiverPipeline:MTLRenderPipelineState
    private let shadowPipeline:MTLRenderPipelineState
    private let depthState:MTLDepthStencilState
    private var shadowMap:MTLTexture?
    private var extraShadowMaps:[MTLTexture?]=[nil,nil,nil]
    private let inFlight=DispatchSemaphore(value:2)
    private(set) var gpuMilliseconds:Double=0
    private(set) var gpuSamples=0
    private(set) var completedFrames=0
    private(set) var gpuErrors=0
    static let desktopPadding:CGFloat=2.6
    var transparentShadow=false
    var viewportPadding:Float=1
    var studio=false
    var lightPosition=SIMD3<Float>(-2,2.5,4)
    var lightColor=SIMD3<Float>(1,0.93,0.83)
    var lightPower:Float=1
    var sceneLights:[SceneLight]=[]
    var quality=1 {didSet {if oldValue != quality {shadowMap=nil;extraShadowMaps=[nil,nil,nil]}}}
    var lightingWork=1
    var shadowEnabled=true
    var targetFPS=30 {didSet {view?.preferredFramesPerSecond=targetFPS}}
    var shadowSize:Int {[512,1024,2048][max(0,min(2,quality))]}
    var shadowBytes:Int {([shadowMap]+extraShadowMaps).compactMap{$0}.reduce(0){$0+$1.width*$1.height*4}}
    private weak var view:MTKView?
    private(set) var asset:RenderAsset?
    private(set) var frames=0
    var material:MTLTexture?
    var fixedAngle:Float?
    var pitch:Float = -0.10
    var zoom:Float = 1
    var finish:Float = 1
    var depthScale:Float = 1
    var paused=false {didSet {view?.isPaused=paused;if paused {view?.draw()}}}
    init(view:MTKView,device:MTLDevice,clock:RotationClock) throws {
        self.device=device;self.clock=clock
        guard let queue=device.makeCommandQueue() else {throw RendererError.unavailable};self.queue=queue
        let library=try device.makeLibrary(source:Self.shader,options:nil),desc=MTLRenderPipelineDescriptor()
        desc.vertexFunction=library.makeFunction(name:"vertex_main");desc.fragmentFunction=library.makeFunction(name:"fragment_main")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.rasterSampleCount=device.supportsTextureSampleCount(4) ? 4 : 1
        desc.isAlphaToCoverageEnabled=desc.rasterSampleCount>1
        desc.isAlphaToOneEnabled=desc.rasterSampleCount>1
        if desc.rasterSampleCount==1 {
            let a=desc.colorAttachments[0]!
            a.isBlendingEnabled=true;a.sourceRGBBlendFactor = .sourceAlpha;a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one;a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        desc.depthAttachmentPixelFormat = .depth32Float
        pipeline=try device.makeRenderPipelineState(descriptor:desc)
        // The shadow receiver needs continuous alpha, not alpha-to-coverage.
        desc.isAlphaToCoverageEnabled=false;desc.isAlphaToOneEnabled=false
        let blend=desc.colorAttachments[0]!
        blend.isBlendingEnabled=true;blend.sourceRGBBlendFactor = .sourceAlpha;blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one;blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        receiverPipeline=try device.makeRenderPipelineState(descriptor:desc)
        if device.supportsRaytracingFromRender,
           let rayLibrary=try? device.makeLibrary(source:Self.shader+Self.rayShader,options:nil),
           let rayFunction=rayLibrary.makeFunction(name:"fragment_ray") {
            let rayDescriptor=desc.copy() as! MTLRenderPipelineDescriptor
            rayDescriptor.fragmentFunction=rayFunction
            rayPipeline=try? device.makeRenderPipelineState(descriptor:rayDescriptor)
        } else {rayPipeline=nil}
        let shadowDesc=MTLRenderPipelineDescriptor()
        shadowDesc.vertexFunction=library.makeFunction(name:"shadow_vertex")
        shadowDesc.fragmentFunction=library.makeFunction(name:"shadow_fragment")
        shadowDesc.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline=try device.makeRenderPipelineState(descriptor:shadowDesc)
        let dd=MTLDepthStencilDescriptor();dd.depthCompareFunction = .less;dd.isDepthWriteEnabled=true
        guard let ds=device.makeDepthStencilState(descriptor:dd) else {throw RendererError.unavailable};depthState=ds
        self.view=view
        super.init()
        view.device=device;view.colorPixelFormat = .bgra8Unorm;view.sampleCount=desc.rasterSampleCount
        view.depthStencilPixelFormat = .depth32Float;view.clearColor=MTLClearColorMake(0,0,0,0)
        view.layer?.isOpaque=false;view.layer?.backgroundColor=NSColor.clear.cgColor
        view.preferredFramesPerSecond=30;view.delegate=self
    }
    enum RendererError:Error {case unavailable}
    // Multi-light ray queries caused rare very slow frames on the local M5.
    // Keep hardware rays for one active lamp; multiple lamps retain individual shadow maps.
    var hardwareRayActive:Bool {rayPipeline != nil && asset?.rayStructure != nil && lightingWork>=2 && sceneLights.filter{$0.enabled}.count<=1}
    func setAsset(_ next:RenderAsset) {asset=next;view?.draw()}
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    private func lightMatrix(_ light:SceneLight)->simd_float4x4 {
        let position=light.position
        let z=light.kind == .flashlight || light.kind == .studio ? -light.direction : simd_normalize(position)
        let up=abs(z.y)>0.97 ? SIMD3<Float>(0,0,1) : SIMD3<Float>(0,1,0)
        let x=simd_normalize(simd_cross(up,z)),y=simd_cross(z,x)
        let v=simd_float4x4(rows:[SIMD4(x,-simd_dot(x,position)),SIMD4(y,-simd_dot(y,position)),SIMD4(z,-simd_dot(z,position)),SIMD4(0,0,0,1)])
        let ortho=simd_float4x4(diagonal:SIMD4<Float>(1/3.5,1/3.5,-1/15,1))
        return ortho*v
    }
    private func depthTexture(size:Int)->MTLTexture? {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:size,height:size,mipmapped:false)
        d.storageMode = .private;d.usage=[.renderTarget,.shaderRead]
        return device.makeTexture(descriptor:d)
    }
    func draw(in view:MTKView) {
        guard let asset,view.drawableSize.width>0,view.drawableSize.height>0,
              inFlight.wait(timeout:.now()) == .success else{return}
        guard let drawable=view.currentDrawable,let pass=view.currentRenderPassDescriptor,
              let command=queue.makeCommandBuffer() else {inFlight.signal();return}
        let angle=fixedAngle ?? clock.current
        let model=rotation(-0.06,axis:SIMD3(0,0,1))*rotation(pitch,axis:SIMD3(1,0,0))*rotation(angle,axis:SIMD3(0,1,0))
        let aspect=Float(view.drawableSize.width/view.drawableSize.height)
        let framing=simd_float4x4(diagonal:SIMD4<Float>(1/viewportPadding,1/viewportPadding,1,1))
        let camera=framing*perspective(aspect)*translation(-4.4/zoom)
        let shadows=(studio || transparentShadow) && shadowEnabled
        let fallback=SceneLight(kind:.studio,x:lightPosition.x,y:lightPosition.y,z:lightPosition.z,power:lightPower,hex:IconColor(lightColor).hex)
        let source=sceneLights.isEmpty ? [fallback] : Array((sceneLights.filter{$0.enabled}+sceneLights.filter{!$0.enabled}).prefix(4))
        var off=SceneLight(kind:.studio,x:0,y:0,z:4,power:0)
        off.enabled=false
        let lamps=(source+Array(repeating:off,count:max(0,4-source.count))).prefix(4).map { lamp -> SceneLight in
            var next=lamp;next.clamp();return next
        }
        func position(_ i:Int)->SIMD4<Float> {let l=lamps[i];return SIMD4(l.position,l.enabled ? l.power : 0)}
        func tint(_ i:Int)->SIMD4<Float> {SIMD4(IconColor(hex:lamps[i].hex)?.rgb ?? SIMD3<Float>(1,1,1),1)}
        let kind=SIMD4<Float>(Float(lamps[0].kind.rawValue),Float(lamps[1].kind.rawValue),Float(lamps[2].kind.rawValue),Float(lamps[3].kind.rawValue))
        let points=(0..<4).map {position($0)}
        let colors=(0..<4).map {tint($0)}
        let matrices=(0..<4).map {lightMatrix(lamps[$0])}
        let directions=(0..<4).map {SIMD4<Float>(lamps[$0].direction,0)}
        let shadowCount=max(1,min(4,lightingWork+1))
        var u=Uniforms(mvp:camera*model,model:model,inverseModel:simd_inverse(model),time:SIMD4(angle,Float(CACurrentMediaTime().truncatingRemainder(dividingBy:1000)),finish,depthScale),lightVP:matrices[0],light:points[0],tint:colors[0],settings:SIMD4(shadows ? 1:0,Float(quality),transparentShadow ? 1:0,Float(lightingWork)),light1:points[1],light2:points[2],light3:points[3],tint1:colors[1],tint2:colors[2],tint3:colors[3],vp1:matrices[1],vp2:matrices[2],vp3:matrices[3],kinds:kind,direction0:directions[0],direction1:directions[1],direction2:directions[2],direction3:directions[3])
        let sizes=(0..<4).map {shadows && $0<shadowCount && points[$0].w>0 ? shadowSize : 1}
        if shadowMap?.width != sizes[0] {shadowMap=depthTexture(size:sizes[0])}
        for i in 0..<3 where extraShadowMaps[i]?.width != sizes[i+1] {extraShadowMaps[i]=depthTexture(size:sizes[i+1])}
        guard let shadowMap,let map1=extraShadowMaps[0],let map2=extraShadowMaps[1],let map3=extraShadowMaps[2] else {inFlight.signal();return}
        let maps=[shadowMap,map1,map2,map3]
        if shadows {
            for i in 0..<shadowCount where points[i].w>0 {
                let sp=MTLRenderPassDescriptor();sp.depthAttachment.texture=maps[i];sp.depthAttachment.loadAction = .clear;sp.depthAttachment.storeAction = .store;sp.depthAttachment.clearDepth=1
                guard let se=command.makeRenderCommandEncoder(descriptor:sp) else {inFlight.signal();return}
                var su=u;su.time.y=Float(i)
                se.setRenderPipelineState(shadowPipeline);se.setDepthStencilState(depthState);se.setCullMode(.none)
                se.setDepthBias(0.002,slopeScale:1.5,clamp:0.01)
                se.setVertexBuffer(asset.vertices,offset:0,index:0);se.setVertexBytes(&su,length:MemoryLayout<Uniforms>.stride,index:1)
                se.setFragmentTexture(asset.texture,index:0)
                se.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:asset.vertexCount)
                se.endEncoding()
            }
        }
        guard let e=command.makeRenderCommandEncoder(descriptor:pass) else {inFlight.signal();return}
        e.setRenderPipelineState(pipeline);e.setDepthStencilState(depthState);e.setCullMode(.none)
        e.setFragmentTexture(asset.texture,index:0);e.setFragmentTexture(material ?? asset.texture,index:1);e.setFragmentTexture(asset.sideTexture,index:2)
        for (i,map) in maps.enumerated() {e.setFragmentTexture(map,index:3+i)}
        if studio || transparentShadow {
            if hardwareRayActive,let rayPipeline,let rayStructure=asset.rayStructure {
                e.setRenderPipelineState(rayPipeline)
                e.setFragmentAccelerationStructure(rayStructure,bufferIndex:2)
                e.useResource(rayStructure,usage:.read,stages:.fragment)
            } else {e.setRenderPipelineState(receiverPipeline)}
            let points:[SIMD2<Float>]=[SIMD2(-8,-8),SIMD2(8,-8),SIMD2(8,8),SIMD2(-8,-8),SIMD2(8,8),SIMD2(-8,8)]
            let ground=points.map{IconVertex(position:SIMD4($0.x,$0.y,-1.6,1),normal:SIMD4(0,0,1,0),uvKind:SIMD4(0,0,2,0))}
            var g=u;g.model=matrix_identity_float4x4;g.mvp=camera;g.time.w=1
            e.setVertexBytes(ground,length:ground.count*MemoryLayout<IconVertex>.stride,index:0)
            e.setVertexBytes(&g,length:MemoryLayout<Uniforms>.stride,index:1);e.setFragmentBytes(&g,length:MemoryLayout<Uniforms>.stride,index:1)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        }
        e.setRenderPipelineState(pipeline)
        e.setVertexBuffer(asset.vertices,offset:0,index:0);e.setVertexBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1);e.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1)
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:asset.vertexCount);e.endEncoding()
        let gate=inFlight
        command.addCompletedHandler { [weak self] cb in
            let ms=(cb.gpuEndTime-cb.gpuStartTime)*1000,ok=cb.status == .completed
            gate.signal()
            DispatchQueue.main.async {
                guard let self else{return};self.completedFrames+=1
                if !ok {self.gpuErrors+=1}
                if ok && ms>0 {self.gpuMilliseconds=self.gpuSamples==0 ? ms : self.gpuMilliseconds*0.8+ms*0.2;self.gpuSamples+=1}
            }
        }
        command.present(drawable);command.commit();frames+=1
    }
    static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position; float4 normal; float4 uvKind; };
    struct Uniforms {
        float4x4 mvp; float4x4 model; float4x4 inverseModel; float4 time; float4x4 lightVP;
        float4 light; float4 tint; float4 settings;
        float4 light1; float4 light2; float4 light3;
        float4 tint1; float4 tint2; float4 tint3;
        float4x4 vp1; float4x4 vp2; float4x4 vp3; float4 kinds;
        float4 direction0; float4 direction1; float4 direction2; float4 direction3;
    };
    float4 lamp(constant Uniforms &u,int i) {return i==0 ? u.light : (i==1 ? u.light1 : (i==2 ? u.light2 : u.light3));}
    float3 lamp_direction(constant Uniforms &u,int i) {return i==0 ? u.direction0.xyz : (i==1 ? u.direction1.xyz : (i==2 ? u.direction2.xyz : u.direction3.xyz));}
    float3 lamp_color(constant Uniforms &u,int i) {return i==0 ? u.tint.xyz : (i==1 ? u.tint1.xyz : (i==2 ? u.tint2.xyz : u.tint3.xyz));}
    float4x4 lamp_vp(constant Uniforms &u,int i) {return i==0 ? u.lightVP : (i==1 ? u.vp1 : (i==2 ? u.vp2 : u.vp3));}
    struct Out { float4 position [[position]]; float3 normal; float3 world; float2 uv; float kind; };
    vertex Out vertex_main(uint id [[vertex_id]],const device Vertex *v [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
        float4 p=v[id].position;p.z*=max(u.time.w,0.2);
        Out o;o.position=u.mvp*p;float3 n=v[id].normal.xyz;n.z/=max(u.time.w,0.2);o.normal=(u.model*float4(normalize(n),0)).xyz;
        o.world=(u.model*p).xyz;o.uv=v[id].uvKind.xy;o.kind=v[id].uvKind.z;return o;
    }
    vertex Out shadow_vertex(uint id [[vertex_id]],const device Vertex *v [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
        Out o;float4 p=v[id].position;p.z*=max(u.time.w,0.2);
        o.position=lamp_vp(u,int(u.time.y+0.5))*u.model*p;o.uv=v[id].uvKind.xy;o.kind=v[id].uvKind.z;return o;
    }
    fragment void shadow_fragment(Out in [[stage_in]],texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        if(in.kind<0.5 && tex.sample(s,in.uv).a<0.5) discard_fragment();
    }
    float visibility(float3 world,constant Uniforms &u,depth2d<float> map,float4x4 vp) {
        if(u.settings.x<0.5) return 1;
        float4 p=vp*float4(world,1);float3 q=p.xyz/p.w;
        float2 uv=float2(q.x*0.5+0.5,0.5-q.y*0.5);
        if(any(uv<0) || any(uv>1) || q.z<0 || q.z>1) return 1;
        constexpr sampler cmp(coord::normalized,address::clamp_to_edge,filter::linear,compare_func::less_equal);
        int work=clamp(int(u.settings.w+0.5),0,4);
        int samples=work==0 ? 4 : (work==1 ? 12 : (work==2 ? 24 : (work==3 ? 48 : 80)));
        float radius=(work==0 ? 1.0 : (work==1 ? 2.0 : (work==2 ? 3.0 : (work==3 ? 4.0 : 5.0))))/float(map.get_width());
        float sum=0;
        // A fixed low-discrepancy disk sequence turns additional GPU work into
        // visibly smoother, wider contact shadows without frame-to-frame noise.
        for(int i=0;i<samples;i++) {
            float r=sqrt((float(i)+0.5)/float(samples));
            float a=float(i)*2.39996323;
            sum+=map.sample_compare(cmp,uv+float2(cos(a),sin(a))*r*radius,q.z-0.0012);
        }
        return sum/float(samples);
    }
    float lamp_factor(float3 world,constant Uniforms &u,int i) {
        float4 l=lamp(u,i);if(l.w<=0.001) return 0;
        float distance=length(l.xyz-world);
        int kind=int(u.kinds[i]+0.5);
        float falloff=kind==0 || kind==2 || kind==6 ? 1.0 : (kind==1 ? 1.0/(1.0+0.025*distance*distance) : 1.0/(1.0+0.14*distance*distance));
        if(kind==1) {
            float3 direction=normalize(world-l.xyz);
            falloff*=smoothstep(0.85,0.96,dot(normalize(lamp_direction(u,i)),direction));
        } else if(kind==0) {
            float3 direction=normalize(world-l.xyz);
            falloff*=smoothstep(0.08,0.62,dot(normalize(lamp_direction(u,i)),direction));
        }
        if(kind>=3 && kind<=5) {
            float phase=u.time.y*(kind==5 ? 17.1 : 9.3)+float(i)*2.7;
            float amplitude=kind==4 ? 0.19 : kind==5 ? 0.25 : 0.07;
            falloff*=1.0+amplitude*(0.75*sin(phase)+0.25*sin(phase*2.13));
        }
        return falloff;
    }
    float4 shadow_vis(float3 world,constant Uniforms &u,depth2d<float> a,depth2d<float> b,depth2d<float> c,depth2d<float> d) {
        float4 result=1;
        if(u.light.w>0) result.x=visibility(world,u,a,u.lightVP);
        if(u.settings.w>=1 && u.light1.w>0) result.y=visibility(world,u,b,u.vp1);
        if(u.settings.w>=2 && u.light2.w>0) result.z=visibility(world,u,c,u.vp2);
        if(u.settings.w>=3 && u.light3.w>0) result.w=visibility(world,u,d,u.vp3);
        return result;
    }
    float4 shade_main(Out in,texture2d<float> tex,texture2d<float> paint,constant Uniforms &u,float4 vis) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        if(in.kind>1.5) {
            if(u.settings.z>0.5) {
                float opacity=0;
                for(int i=0;i<4;i++) opacity+=(1.0-vis[i])*0.35*clamp(lamp(u,i).w*lamp_factor(in.world,u,i),0.0,1.5);
                opacity=min(opacity,0.72);
                if(opacity<0.001) discard_fragment();
                return float4(0,0,0,opacity);
            }
            float distance=length(in.world.xy);
            float3 base=mix(float3(0.115,0.14,0.18),float3(0.025,0.035,0.06),smoothstep(0.0,4.5,distance));
            float3 lightSum=0;
            for(int i=0;i<4;i++) {
                float4 l=lamp(u,i);if(l.w<=0) continue;
                float diffuse=max(dot(float3(0,0,1),normalize(l.xyz-in.world)),0.0);
                lightSum+=lamp_color(u,i)*l.w*lamp_factor(in.world,u,i)*diffuse*vis[i];
            }
            return float4(base*(0.40+lightSum*0.60),1);
        }
        float4 pixel=tex.sample(s,in.uv);
        if(in.kind>=0.5) pixel=paint.sample(s,in.uv);
        float coverage=1.0;
        if(in.kind<0.5) {
            float width=max(fwidth(pixel.a)*0.7,0.025);
            coverage=smoothstep(0.5-width,0.5+width,pixel.a);
            if(coverage<0.01) discard_fragment();
        }
        float3 base=pixel.rgb/max(pixel.a,0.01);
        float3 n=normalize(in.normal),eye=normalize(float3(0,0,4.4)-in.world);
        float3 fill=normalize(float3(1.2,0.3,-0.6));
        float rough=u.time.z<0.5 ? 0.7 : (u.time.z<1.5 ? 0.26 : 0.16);
        float metallic=u.time.z>1.5 ? 0.8 : 0.0;
        float facing=max(dot(n,eye),0.0);
        float exponent=mix(9.0,150.0,1.0-rough);
        float fresnel=0.04+0.96*pow(1.0-facing,5.0);
        float3 reflection=reflect(-eye,n);
        // Broad studio cards provide readable reflections without noisy detail.
        float card=pow(max(dot(reflection,normalize(float3(-0.8,0.6,1.4))),0.0),24.0);
        float strip=pow(max(dot(reflection,normalize(float3(1.0,0.2,0.5))),0.0),60.0);
        float3 ambient=float3(0.17,0.19,0.24)+max(n.y,0.0)*float3(0.18,0.19,0.21);
        float3 direct=0,specular=0;
        for(int i=0;i<4;i++) {
            float4 l=lamp(u,i);if(l.w<=0) continue;
            float3 key=normalize(l.xyz-in.world);
            float ndl=max(dot(n,key),0.0);
            float halfSpec=pow(max(dot(n,normalize(key+eye)),0.0),exponent);
            float energy=l.w*lamp_factor(in.world,u,i)*vis[i];
            direct+=lamp_color(u,i)*energy*0.75*ndl;
            specular+=lamp_color(u,i)*energy*halfSpec*0.32;
        }
        float3 diffuse=base*(ambient+direct+0.20*max(dot(n,fill),0.0));
        float3 reflectionTint=mix(float3(1),base,metallic);
        float3 color=diffuse*(1.0-metallic*0.35)+reflectionTint*(specular+card*(0.18+0.55*metallic)+strip*0.3)*(0.3+fresnel*0.7);
        color+=base*0.12; // Keep dark original logos readable.
        color=color/(color+float3(0.65));
        color=pow(max(color,float3(0)),float3(1.0/1.25));
        return float4(clamp(color,0.0,1.0),coverage);
    }
    fragment float4 fragment_main(Out in [[stage_in]],texture2d<float> tex [[texture(0)]],texture2d<float> paint [[texture(2)]],depth2d<float> a [[texture(3)]],depth2d<float> b [[texture(4)]],depth2d<float> c [[texture(5)]],depth2d<float> d [[texture(6)]],constant Uniforms &u [[buffer(1)]]) {
        return shade_main(in,tex,paint,u,shadow_vis(in.world,u,a,b,c,d));
    }
    """
    static let rayShader="""
    using namespace raytracing;
    float ray_visibility(float3 world,constant Uniforms &u,acceleration_structure<> scene,int lightIndex) {
        int work=clamp(int(u.settings.w+0.5),2,4);
        int samples=work==2 ? 2 : (work==3 ? 4 : 8);
        float3 start=(u.inverseModel*float4(world,1)).xyz;
        start.z/=max(u.time.w,0.2);
        float visible=0;
        for(int i=0;i<samples;i++) {
            float a=float(i)*2.39996323;
            float r=sqrt((float(i)+0.5)/float(samples))*0.13;
            float3 areaLight=lamp(u,lightIndex).xyz+float3(cos(a)*r,sin(a)*r,0);
            float3 goal=(u.inverseModel*float4(areaLight,1)).xyz;
            goal.z/=max(u.time.w,0.2);
            float3 travel=goal-start;
            float distance=length(travel);
            ray query(start,travel/max(distance,0.0001));
            intersector<> queryIntersector;
            intersection_result<> hit=queryIntersector.intersect(query,scene);
            visible+=hit.type==intersection_type::triangle && hit.distance<distance-0.015 ? 0.0 : 1.0;
        }
        return visible/float(samples);
    }
    fragment float4 fragment_ray(Out in [[stage_in]],texture2d<float> tex [[texture(0)]],texture2d<float> paint [[texture(2)]],depth2d<float> a [[texture(3)]],depth2d<float> b [[texture(4)]],depth2d<float> c [[texture(5)]],depth2d<float> d [[texture(6)]],constant Uniforms &u [[buffer(1)]],acceleration_structure<> scene [[buffer(2)]]) {
        float4 vis=1;
        if(in.kind>1.5) {
            for(int i=0;i<4;i++) if(i<=int(u.settings.w+0.5) && lamp(u,i).w>0) vis[i]=ray_visibility(in.world,u,scene,i);
        } else vis=shadow_vis(in.world,u,a,b,c,d);
        return shade_main(in,tex,paint,u,vis);
    }
    """
}
