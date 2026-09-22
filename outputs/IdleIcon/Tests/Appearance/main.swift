import AppKit
import MetalKit
import simd

let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let legacy=CommandLine.arguments.contains("--legacy")
let gpu=MTLCreateSystemDefaultDevice()!
var checks:[String]=[]
func check(_ ok:Bool,_ message:String) {precondition(ok,message);checks.append(message);print("PASS: \(message)")}
func save(_ cut:CutoutImage,_ name:String) throws {
    let data=NSBitmapImageRep(cgImage:cut.cgImage()!).representation(using:.png,properties:[:])!
    try data.write(to:out.appendingPathComponent(name+".png"))
}
struct CaptureUniforms {var mvp:simd_float4x4;var model:simd_float4x4;var time:SIMD4<Float>;var lightVP:simd_float4x4;var light:SIMD4<Float>;var tint:SIMD4<Float>;var settings:SIMD4<Float>}
func capture(_ cut:CutoutImage,angle:Float,name:String,finish:Float=1,thickness:Float=1,studio:Bool=false,lightX:Float = -2,shadows:Bool=true,quality:Int=1,transparent:Bool=false,lightY:Float=2.5,lightZ:Float=4) throws {
    let asset=try RenderAsset.make(cut,device:gpu),size=640
    let descriptor=MTLRenderPipelineDescriptor();let library=try gpu.makeLibrary(source:IconRenderer.shader,options:nil)
    descriptor.vertexFunction=library.makeFunction(name:"vertex_main");descriptor.fragmentFunction=library.makeFunction(name:"fragment_main")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm;descriptor.depthAttachmentPixelFormat = .depth32Float
    descriptor.rasterSampleCount=4;descriptor.isAlphaToCoverageEnabled = !legacy;descriptor.isAlphaToOneEnabled = !legacy
    let pipeline=try gpu.makeRenderPipelineState(descriptor:descriptor)
    descriptor.isAlphaToCoverageEnabled=false;descriptor.isAlphaToOneEnabled=false
    let blend=descriptor.colorAttachments[0]!
    blend.isBlendingEnabled=true;blend.sourceRGBBlendFactor = .sourceAlpha;blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
    blend.sourceAlphaBlendFactor = .one;blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    let receiver=try gpu.makeRenderPipelineState(descriptor:descriptor)
    let output=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:size,height:size,mipmapped:false)
    output.storageMode = .shared;output.usage = [.renderTarget,.shaderRead]
    let resolved=gpu.makeTexture(descriptor:output)!
    output.textureType = .type2DMultisample;output.sampleCount=4;output.storageMode = .private
    let msaa=gpu.makeTexture(descriptor:output)!
    output.pixelFormat = .depth32Float
    let depth=gpu.makeTexture(descriptor:output)!
    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=msaa;pass.colorAttachments[0].resolveTexture=resolved
    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .multisampleResolve
    pass.colorAttachments[0].clearColor=transparent ? MTLClearColorMake(0,0,0,0) : MTLClearColorMake(0.08,0.08,0.11,1)
    pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth=1
    let queue=gpu.makeCommandQueue()!,command=queue.makeCommandBuffer()!
    let dd=MTLDepthStencilDescriptor();dd.depthCompareFunction = .less;dd.isDepthWriteEnabled=true
    func rot(_ x:Float,_ axis:SIMD3<Float>)->simd_float4x4 {simd_float4x4(simd_quatf(angle:x,axis:axis))}
    let model=rot(-0.06,SIMD3(0,0,1))*rot(-0.10,SIMD3(1,0,0))*rot(angle,SIMD3(0,1,0))
    let y:Float=1/tan(0.57/2),near:Float=0.1,far:Float=30
    var projection=simd_float4x4(columns:(SIMD4(y,0,0,0),SIMD4(0,y,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,far*near/(near-far),0)))
    if transparent {projection=simd_float4x4(diagonal:SIMD4<Float>(1/Float(IconRenderer.desktopPadding),1/Float(IconRenderer.desktopPadding),1,1))*projection}
    var translation=matrix_identity_float4x4;translation.columns.3.z = -4.4
    let light=SIMD3<Float>(lightX,lightY,lightZ),z=simd_normalize(light),x=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),z)),yy=simd_cross(z,x)
    let lightView=simd_float4x4(rows:[SIMD4(x,-simd_dot(x,light)),SIMD4(yy,-simd_dot(yy,light)),SIMD4(z,-simd_dot(z,light)),SIMD4(0,0,0,1)])
    let lightVP=simd_float4x4(diagonal:SIMD4<Float>(1/3.5,1/3.5,-1/15,1))*lightView
    var u=CaptureUniforms(mvp:projection*translation*model,model:model,time:SIMD4(angle,0,finish,thickness),lightVP:lightVP,light:SIMD4(light,1),tint:SIMD4(1,0.93,0.83,1),settings:SIMD4((studio || transparent) && shadows ? 1:0,Float(quality),transparent ? 1:0,0))
    let sd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:[512,1024,2048][quality],height:[512,1024,2048][quality],mipmapped:false);sd.storageMode = .private;sd.usage=[.renderTarget,.shaderRead]
    let shadow=gpu.makeTexture(descriptor:sd)!,sp=MTLRenderPassDescriptor();sp.depthAttachment.texture=shadow;sp.depthAttachment.loadAction = .clear;sp.depthAttachment.storeAction = .store;sp.depthAttachment.clearDepth=1
    let se=command.makeRenderCommandEncoder(descriptor:sp)!
    if (studio || transparent) && shadows {
        let pd=MTLRenderPipelineDescriptor();pd.vertexFunction=library.makeFunction(name:"shadow_vertex");pd.fragmentFunction=library.makeFunction(name:"shadow_fragment");pd.depthAttachmentPixelFormat = .depth32Float
        se.setRenderPipelineState(try gpu.makeRenderPipelineState(descriptor:pd));se.setDepthStencilState(gpu.makeDepthStencilState(descriptor:dd));se.setCullMode(.none);se.setDepthBias(0.002,slopeScale:1.5,clamp:0.01)
        se.setVertexBuffer(asset.vertices,offset:0,index:0);se.setVertexBytes(&u,length:MemoryLayout<CaptureUniforms>.stride,index:1);se.setFragmentTexture(asset.texture,index:0);se.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:asset.vertexCount)
    }
    se.endEncoding()
    let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
    encoder.setFragmentTexture(shadow,index:3)
    if studio || transparent {
        let points:[SIMD2<Float>]=[SIMD2(-8,-8),SIMD2(8,-8),SIMD2(8,8),SIMD2(-8,-8),SIMD2(8,8),SIMD2(-8,8)]
        let ground=points.map{IconVertex(position:SIMD4($0.x,$0.y,-1.6,1),normal:SIMD4(0,0,1,0),uvKind:SIMD4(0,0,2,0))}
        var g=u;g.model=matrix_identity_float4x4;g.mvp=projection*translation;g.time.w=1
        encoder.setRenderPipelineState(receiver);encoder.setDepthStencilState(gpu.makeDepthStencilState(descriptor:dd));encoder.setCullMode(.none)
        encoder.setVertexBytes(ground,length:ground.count*MemoryLayout<IconVertex>.stride,index:0);encoder.setVertexBytes(&g,length:MemoryLayout<CaptureUniforms>.stride,index:1);encoder.setFragmentBytes(&g,length:MemoryLayout<CaptureUniforms>.stride,index:1)
        encoder.setFragmentTexture(asset.texture,index:0);encoder.setFragmentTexture(asset.texture,index:1);encoder.setFragmentTexture(asset.sideTexture,index:2)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
    }
    encoder.setRenderPipelineState(pipeline);encoder.setDepthStencilState(gpu.makeDepthStencilState(descriptor:dd));encoder.setCullMode(.none)
    encoder.setVertexBuffer(asset.vertices,offset:0,index:0);encoder.setVertexBytes(&u,length:MemoryLayout<CaptureUniforms>.stride,index:1)
    encoder.setFragmentBytes(&u,length:MemoryLayout<CaptureUniforms>.stride,index:1);encoder.setFragmentTexture(asset.texture,index:0);encoder.setFragmentTexture(asset.texture,index:1);encoder.setFragmentTexture(asset.sideTexture,index:2)
    encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:asset.vertexCount);encoder.endEncoding();command.commit();command.waitUntilCompleted()
    check(command.status == .completed,"GPU capture completed: \(name)")
    var bytes=[UInt8](repeating:0,count:size*size*4);resolved.getBytes(&bytes,bytesPerRow:size*4,from:MTLRegionMake2D(0,0,size,size),mipmapLevel:0)
    for i in stride(from:0,to:bytes.count,by:4) {bytes.swapAt(i,i+2)}
    try save(CutoutImage(size:size,pixels:bytes,method:"GPU",retainedFraction:1),name)
}
if !legacy {
    let inspection=InspectorCanvas(frame:NSRect(x:0,y:0,width:400,height:400),device:gpu)
    var orbit=SIMD2<Float>.zero;inspection.orbit={orbit=SIMD2($0,$1)}
    func mouse(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
    inspection.mouseDown(with:mouse(.leftMouseDown,NSPoint(x:100,y:100)))
    inspection.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:140,y:120)))
    inspection.mouseUp(with:mouse(.leftMouseUp,NSPoint(x:140,y:120)))
    check(abs(orbit.x-0.48)<0.001 && abs(orbit.y+0.24)<0.001,"Inspector drag uses position changes, including synthetic events with zero delta")
    var moved=SIMD2<Float>.zero;inspection.moveLight={moved=SIMD2($0,$1)};inspection.draggingLight=true
    inspection.mouseDown(with:mouse(.leftMouseDown,NSPoint(x:100,y:100)))
    inspection.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:140,y:120)))
    inspection.mouseUp(with:mouse(.leftMouseUp,NSPoint(x:140,y:120)))
    check(abs(moved.x-0.8)<0.001 && abs(moved.y-0.4)<0.001 && abs(orbit.x-0.48)<0.001,"Light drag moves light without changing camera")
    let n=64
    let colors:[SIMD3<UInt8>]=[SIMD3(240,20,25),SIMD3(20,210,40),SIMD3(25,70,245),SIMD3(240,240,240)]
    var bytes=[UInt8](repeating:0,count:n*n*4)
    for y in 4..<n-4 {for x in 4..<n-4 {let i=y*n+x,c=colors[(x<n/2 ? 0 : 1)+(y<n/2 ? 0 : 2)];for j in 0..<3 {bytes[i*4+j]=c[j]};bytes[i*4+3]=255}}
    let cut=CutoutImage(size:n,pixels:bytes,method:"fixture",retainedFraction:1),palette=IconPalette.colors(in:cut)
    check(palette.count==4,"Extracts red, green, blue, white from opaque content")
    let red=palette.min{simd_distance($0.rgb,SIMD3(240,20,25)/255)<simd_distance($1.rgb,SIMD3(240,20,25)/255)}!
    let changed=IconPalette.recolor(cut,palette:palette,replacements:[red.hex:"#B8A5FF"])
    check((0..<n*n).allSatisfy{cut.pixels[$0*4+3]==changed.pixels[$0*4+3]},"Recolor preserves every alpha and therefore the silhouette")
    let redIndex=(10*n+10)*4,greenIndex=(10*n+50)*4
    check(changed.pixels[redIndex+2]>200 && changed.pixels[redIndex+1]>100,"Selected red region takes the target purple")
    check((0..<4).allSatisfy{abs(Int(cut.pixels[greenIndex+$0])-Int(changed.pixels[greenIndex+$0]))<=1},"Unselected green region remains unchanged")
    check(IconPalette.recolor(cut,palette:palette,replacements:[:]).pixels==cut.pixels,"Restore is byte-exact original texture")
    let drifted=IconPalette.recolor(cut,palette:palette,replacements:["#EF1518":"#B8A5FF"])
    check(drifted.pixels==changed.pixels,"Saved source colors tolerate tiny extraction differences")
    for i in 0..<100 {
        let c=SIMD3<Float>(Float((i*71)%101)/100,Float((i*43)%101)/100,Float((i*97)%101)/100)
        check(simd_distance(c,IconPalette.rgb(IconPalette.lab(c)))<0.0001,"Color-space round trip \(i)")
    }
    var ramp=[UInt8](repeating:255,count:256*256*4)
    for y in 0..<256 {for x in 0..<256 {for c in 0..<3 {ramp[(y*256+x)*4+c]=UInt8(60+x/2)}}}
    let gradient=CutoutImage(size:256,pixels:ramp,method:"gradient",retainedFraction:1),shades=IconPalette.colors(in:gradient)
    let single=IconPalette.recolor(gradient,palette:shades,replacements:Dictionary(uniqueKeysWithValues:shades.map{($0.hex,"#65D6AA")}))
    let jumps=(1..<256).map{abs(Int(single.pixels[(128*256+$0)*4])-Int(single.pixels[(128*256+$0-1)*4]))}
    var baseline=SIMD3<Float>.zero,weight:Float=0
    for shade in shades {let w=Float(max(0.001,shade.share));baseline+=IconPalette.lab(shade.rgb)*w;weight+=w};baseline/=weight
    let targetLab=IconPalette.lab(IconColor(hex:"#65D6AA")!.rgb)
    var maximumError=0
    for x in 0..<256 {
        let delta=IconPalette.lab(SIMD3<Float>(repeating:Float(60+x/2)/255))-baseline
        let expected=IconPalette.rgb(targetLab+SIMD3(max(-0.22,min(0.22,delta.x)),delta.y*0.55,delta.z*0.55))
        for c in 0..<3 {maximumError=max(maximumError,abs(Int(single.pixels[(128*256+x)*4+c])-Int((expected[c]*255).rounded())))}
    }
    check(maximumError<=1,"All same-target shades match one continuous lightness transform across cluster boundaries")
    try save(single,"same-target-gradient")
    try save(cut,"palette-original");try save(changed,"palette-recolored")
    #if !LEGACY
    let ringSize=192
    var ringBytes=[UInt8](repeating:0,count:ringSize*ringSize*4)
    for y in 0..<ringSize {for x in 0..<ringSize {
        let r=hypot(Double(x)-95.5,Double(y)-95.5)
        if r>31 && r<77 {for c in 0..<4 {ringBytes[(y*ringSize+x)*4+c]=255}}
    }}
    let ring=CutoutImage(size:ringSize,pixels:ringBytes,method:"ring",retainedFraction:1)
    let paths=IconContour.loops(ring),clean=IconContour.applying(paths,to:ring)
    check(paths.count==2,"Reconstructed contour preserves one exterior and one hole")
    let before=(0..<ringSize*ringSize).map{ringBytes[$0*4+3]>127}
    let after=(0..<ringSize*ringSize).map{clean.pixels[$0*4+3]>127}
    let intersection=zip(before,after).filter{$0 && $1}.count,union=zip(before,after).filter{$0 || $1}.count
    check(Double(intersection)/Double(union)>0.985,"Contour smoothing preserves more than 98.5 percent silhouette overlap")
    check(clean.pixels[(96*ringSize+96)*4+3]==0,"Smoothed face leaves center hole transparent")
    let asset=try RenderAsset.make(ring,device:gpu)
    let painted=try asset.replacingTexture(IconPalette.recolor(asset.source,palette:asset.palette,replacements:[asset.palette[0].hex:"#70B5FF"]),device:gpu)
    check(asset.vertices === painted.vertices,"Color replacement reuses exact same 3D geometry")
    let (mesh,_)=RenderAsset.mesh(ring)
    check(mesh.contains{abs($0.normal.z)>0.1 && abs($0.normal.z)<0.9},"Actual bevel vertices connect front to body")
    check(mesh.allSatisfy{abs(simd_length(SIMD3($0.normal.x,$0.normal.y,$0.normal.z))-1)<0.001},"All bevel normals are finite and normalized")
    var stripes=[UInt8](repeating:255,count:64*64*4)
    for y in 0..<64 {for x in 0..<64 {for c in 0..<3 {stripes[(y*64+x)*4+c]=y%2==0 ? 40 : 220}}}
    let paint=try RenderAsset.sidePaint(CutoutImage(size:64,pixels:stripes,method:"striped",retainedFraction:1),device:gpu)
    var paintedBytes=[UInt8](repeating:0,count:64*64*4);paint.getBytes(&paintedBytes,bytesPerRow:256,from:MTLRegionMake2D(0,0,64,64),mipmapLevel:0)
    let samples=(15..<49).map{Int(paintedBytes[($0*64+32)*4])}
    check(samples.max()!-samples.min()!<8,"Side paint rejects alternating source stripes without padding resources")
    try capture(ring,angle:0.1,name:"desktop-ring-left",transparent:true)
    try capture(ring,angle:0.1,name:"desktop-ring-right",lightX:2,transparent:true)
    try capture(ring,angle:0.1,name:"desktop-ring-clear",shadows:false,transparent:true)
    try capture(ring,angle:0.85,name:"desktop-extreme",thickness:2.5,lightX:4,transparent:true,lightY:4,lightZ:3)
    try capture(ring,angle:0.1,name:"studio-ring-left",studio:true)
    try capture(ring,angle:0.1,name:"studio-ring-right",studio:true,lightX:2)
    try capture(ring,angle:0.1,name:"studio-ring-no-shadow",studio:true,shadows:false)
    try capture(ring,angle:0.1,name:"studio-ring-fine",studio:true,quality:2)
    try capture(ring,angle:0.1,name:"studio-ring-light",studio:true,quality:0)
    try capture(ring,angle:0.85,name:"ring-smoothed")
    try capture(ring,angle:1.35,name:"ring-near-side",finish:2,thickness:2.5)
    #endif
}
var measurements:[[String:Any]]=[]
for (name,id) in [("chatgpt","com.openai.codex"),("chrome","com.google.Chrome"),("wechat","com.tencent.xinWeChat"),("safari","com.apple.Safari")] {
    guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:id),let source=IconCutout.sourceImage(NSWorkspace.shared.icon(forFile:url.path)) else{continue}
    let cut=IconCutout.prepare(source),palette=IconPalette.colors(in:cut)
    try save(cut,name+"-cutout")
    try capture(cut,angle:0.85,name:name+"-side")
    try capture(cut,angle:1.35,name:name+"-near-side",finish:2)
    if name=="chatgpt" {
        try capture(cut,angle:0.65,name:"studio-icon",studio:true)
        try capture(cut,angle:0,name:"chatgpt-front")
        try capture(cut,angle:0.85,name:"chatgpt-matte",finish:0,thickness:0.4)
        try capture(cut,angle:0.85,name:"chatgpt-metal",finish:2,thickness:2)
    }
    if name=="chatgpt",!legacy {
        var flat=cut.pixels
        for i in 0..<cut.size*cut.size {for c in 0..<3 {flat[i*4+c]=UInt8(Float(flat[i*4+3])*0.7)}}
        try capture(CutoutImage(size:cut.size,pixels:flat,method:"uniform",retainedFraction:1),angle:0.85,name:"uniform-side")
    }
    if !legacy,let first=palette.first {
        let colored=IconPalette.recolor(cut,palette:palette,replacements:[first.hex:"#65D6AA"])
        try capture(colored,angle:0.85,name:name+"-colored")
    }
    measurements.append(["app":id,"dimension":cut.size,"palette":palette.map{$0.hex},"method":cut.method])
}
try JSONSerialization.data(withJSONObject:["checks":checks,"samples":measurements],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("appearance-tests.json"))
