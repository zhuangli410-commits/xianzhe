import AppKit
import MetalKit
import simd

struct IconVertex { var position:SIMD4<Float>; var normal:SIMD4<Float>; var uvKind:SIMD4<Float> }
private struct Uniforms { var mvp:simd_float4x4; var model:simd_float4x4; var time:SIMD4<Float>; var lightVP:simd_float4x4; var light:SIMD4<Float>; var tint:SIMD4<Float>; var settings:SIMD4<Float> }

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
    static func make(_ input:CutoutImage,device:MTLDevice) throws -> RenderAsset {
        let contours=IconContour.loops(input)
        let cutout=IconContour.applying(contours,to:input)
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:cutout.size,height:cutout.size,mipmapped:false)
        desc.storageMode = .shared;desc.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:desc) else {throw IconRenderer.RendererError.unavailable}
        cutout.pixels.withUnsafeBytes {texture.replace(region:MTLRegionMake2D(0,0,cutout.size,cutout.size),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:cutout.size*4)}
        let (mesh,segments)=Self.mesh(cutout,contours:contours)
        guard let buffer=device.makeBuffer(bytes:mesh,length:MemoryLayout<IconVertex>.stride*mesh.count,options:.storageModeShared) else {throw IconRenderer.RendererError.unavailable}
        return RenderAsset(source:cutout,palette:IconPalette.colors(in:cutout),texture:texture,sideTexture:try sidePaint(cutout,device:device),vertices:buffer,vertexCount:mesh.count,sideSegments:segments,method:cutout.method)
    }
    func replacingTexture(_ cut:CutoutImage,device:MTLDevice) throws -> RenderAsset {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:cut.size,height:cut.size,mipmapped:false)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:d) else {throw IconRenderer.RendererError.unavailable}
        cut.pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,cut.size,cut.size),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:cut.size*4)}
        return RenderAsset(source:source,palette:palette,texture:t,sideTexture:try Self.sidePaint(cut,device:device),vertices:vertices,vertexCount:vertexCount,sideSegments:sideSegments,method:method)
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
    private let receiverPipeline:MTLRenderPipelineState
    private let shadowPipeline:MTLRenderPipelineState
    private let depthState:MTLDepthStencilState
    private var shadowMap:MTLTexture?
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
    var quality=1 {didSet {if oldValue != quality {shadowMap=nil}}}
    var shadowEnabled=true
    var targetFPS=30 {didSet {view?.preferredFramesPerSecond=targetFPS}}
    var shadowSize:Int {[512,1024,2048][max(0,min(2,quality))]}
    var shadowBytes:Int {shadowMap.map{$0.width*$0.height*4} ?? 0}
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
    func setAsset(_ next:RenderAsset) {asset=next;view?.draw()}
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    private func lightMatrix()->simd_float4x4 {
        let z=simd_normalize(lightPosition),x=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),z)),y=simd_cross(z,x)
        let v=simd_float4x4(rows:[SIMD4(x,-simd_dot(x,lightPosition)),SIMD4(y,-simd_dot(y,lightPosition)),SIMD4(z,-simd_dot(z,lightPosition)),SIMD4(0,0,0,1)])
        let ortho=simd_float4x4(diagonal:SIMD4<Float>(1/3.5,1/3.5,-1/15,1))
        return ortho*v
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
        if shadowMap==nil || shadowMap?.width != (shadows ? shadowSize : 1) {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:shadows ? shadowSize : 1,height:shadows ? shadowSize : 1,mipmapped:false)
            d.storageMode = .private;d.usage=[.renderTarget,.shaderRead];shadowMap=device.makeTexture(descriptor:d)
        }
        guard let shadowMap else{inFlight.signal();return}
        var u=Uniforms(mvp:camera*model,model:model,time:SIMD4(angle,0,finish,depthScale),lightVP:lightMatrix(),light:SIMD4(lightPosition,lightPower),tint:SIMD4(lightColor,1),settings:SIMD4(shadows ? 1:0,Float(quality),transparentShadow ? 1:0,0))
        let sp=MTLRenderPassDescriptor();sp.depthAttachment.texture=shadowMap;sp.depthAttachment.loadAction = .clear;sp.depthAttachment.storeAction = .store;sp.depthAttachment.clearDepth=1
        guard let se=command.makeRenderCommandEncoder(descriptor:sp) else {inFlight.signal();return}
        if shadows {
            se.setRenderPipelineState(shadowPipeline);se.setDepthStencilState(depthState);se.setCullMode(.none)
            se.setDepthBias(0.002,slopeScale:1.5,clamp:0.01)
            se.setVertexBuffer(asset.vertices,offset:0,index:0);se.setVertexBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1)
            se.setFragmentTexture(asset.texture,index:0)
            se.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:asset.vertexCount)
        }
        se.endEncoding()
        guard let e=command.makeRenderCommandEncoder(descriptor:pass) else {inFlight.signal();return}
        e.setRenderPipelineState(pipeline);e.setDepthStencilState(depthState);e.setCullMode(.none)
        e.setFragmentTexture(asset.texture,index:0);e.setFragmentTexture(material ?? asset.texture,index:1);e.setFragmentTexture(asset.sideTexture,index:2);e.setFragmentTexture(shadowMap,index:3)
        if studio || transparentShadow {
            e.setRenderPipelineState(receiverPipeline)
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
    struct Uniforms { float4x4 mvp; float4x4 model; float4 time; float4x4 lightVP; float4 light; float4 tint; float4 settings; };
    struct Out { float4 position [[position]]; float3 normal; float3 world; float2 uv; float kind; };
    vertex Out vertex_main(uint id [[vertex_id]],const device Vertex *v [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
        float4 p=v[id].position;p.z*=max(u.time.w,0.2);
        Out o;o.position=u.mvp*p;float3 n=v[id].normal.xyz;n.z/=max(u.time.w,0.2);o.normal=(u.model*float4(normalize(n),0)).xyz;
        o.world=(u.model*p).xyz;o.uv=v[id].uvKind.xy;o.kind=v[id].uvKind.z;return o;
    }
    vertex Out shadow_vertex(uint id [[vertex_id]],const device Vertex *v [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
        Out o;float4 p=v[id].position;p.z*=max(u.time.w,0.2);
        o.position=u.lightVP*u.model*p;o.uv=v[id].uvKind.xy;o.kind=v[id].uvKind.z;return o;
    }
    fragment void shadow_fragment(Out in [[stage_in]],texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        if(in.kind<0.5 && tex.sample(s,in.uv).a<0.5) discard_fragment();
    }
    float visibility(float3 world,constant Uniforms &u,depth2d<float> map) {
        if(u.settings.x<0.5) return 1;
        float4 p=u.lightVP*float4(world,1);float3 q=p.xyz/p.w;
        float2 uv=float2(q.x*0.5+0.5,0.5-q.y*0.5);
        if(any(uv<0) || any(uv>1) || q.z<0 || q.z>1) return 1;
        constexpr sampler cmp(coord::normalized,address::clamp_to_edge,filter::linear,compare_func::less_equal);
        int radius=u.settings.y<0.5 ? 1 : (u.settings.y<1.5 ? 2:3);
        float sum=0;float step=1.4/float(map.get_width());
        for(int y=-radius;y<=radius;y++) for(int x=-radius;x<=radius;x++)
            sum+=map.sample_compare(cmp,uv+float2(x,y)*step,q.z-0.0012);
        return sum/float((radius*2+1)*(radius*2+1));
    }
    fragment float4 fragment_main(Out in [[stage_in]],texture2d<float> tex [[texture(0)]],texture2d<float> noise [[texture(1)]],texture2d<float> paint [[texture(2)]],depth2d<float> shadow [[texture(3)]],constant Uniforms &u [[buffer(1)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float vis=visibility(in.world,u,shadow);
        if(in.kind>1.5) {
            if(u.settings.z>0.5) {
                float opacity=(1.0-vis)*0.42*clamp(u.light.w,0.0,1.5);
                if(opacity<0.001) discard_fragment();
                return float4(0,0,0,opacity);
            }
            float distance=length(in.world.xy);
            float3 base=mix(float3(0.115,0.14,0.18),float3(0.025,0.035,0.06),smoothstep(0.0,4.5,distance));
            float diffuse=max(dot(float3(0,0,1),normalize(u.light.xyz-in.world)),0.0);
            return float4(base*(0.50+u.light.w*diffuse*vis)*mix(float3(1),u.tint.xyz,0.35),1);
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
        float3 key=normalize(u.light.xyz-in.world),fill=normalize(float3(1.2,0.3,-0.6));
        float rough=u.time.z<0.5 ? 0.7 : (u.time.z<1.5 ? 0.26 : 0.16);
        float metallic=u.time.z>1.5 ? 0.8 : 0.0;
        float facing=max(dot(n,eye),0.0),ndl=max(dot(n,key),0.0);
        float3 halfVector=normalize(key+eye);
        float exponent=mix(9.0,150.0,1.0-rough);
        float spec=pow(max(dot(n,halfVector),0.0),exponent);
        float fresnel=0.04+0.96*pow(1.0-facing,5.0);
        float3 reflection=reflect(-eye,n);
        // Broad studio cards provide readable reflections without noisy detail.
        float card=pow(max(dot(reflection,normalize(float3(-0.8,0.6,1.4))),0.0),24.0);
        float strip=pow(max(dot(reflection,normalize(float3(1.0,0.2,0.5))),0.0),60.0);
        float3 ambient=float3(0.17,0.19,0.24)+max(n.y,0.0)*float3(0.18,0.19,0.21);
        float3 diffuse=base*(ambient+u.tint.xyz*u.light.w*0.75*ndl*vis+0.20*max(dot(n,fill),0.0));
        float3 reflectionTint=mix(float3(1),base,metallic);
        float3 color=diffuse*(1.0-metallic*0.35)+reflectionTint*(spec*0.32*vis*u.light.w+card*(0.18+0.55*metallic)+strip*0.3)*(0.3+fresnel*0.7);
        color+=base*0.12; // Keep dark original logos readable.
        color=color/(color+float3(0.65));
        color=pow(max(color,float3(0)),float3(1.0/1.25));
        return float4(clamp(color,0.0,1.0),coverage);
    }
    """
}
