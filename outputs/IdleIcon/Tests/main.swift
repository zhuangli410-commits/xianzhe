import AppKit
import MetalKit

let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
var checks:[String]=[]
// Absolute origins include an external screen to the left of the main screen.
for area in [NSRect(x:0,y:24,width:1440,height:850),NSRect(x:-1920,y:40,width:1920,height:1040),NSRect(x:0,y:0,width:800,height:1200)] {
    for side:CGFloat in [120,300,600] { for p in [NSPoint(x:0,y:0),NSPoint(x:1,y:1),NSPoint(x:0.42,y:0.76)] {
        let f=DesktopPlacement.frame(in:area,side:side,position:p)
        assert(area.contains(f))
        let expanded=DesktopPlacement.shadowFrame(f)
        assert(abs(expanded.midX-f.midX)<0.001 && abs(expanded.midY-f.midY)<0.001)
        assert(abs(expanded.width/IconRenderer.desktopPadding-f.width)<0.001)
        let back=DesktopPlacement.normalized(origin:f.origin,in:area,side:f.width)
        assert(abs(back.x-p.x)<0.0001 && abs(back.y-p.y)<0.0001)
        let factor:CGFloat=0.32
        let mini=NSRect(x:12,y:36,width:area.width*factor,height:area.height*factor)
        let mf=DesktopPlacement.frame(in:mini,side:side*factor,position:p)
        assert(abs((f.minX-area.minX)*factor-(mf.minX-mini.minX))<0.001)
        assert(abs((f.minY-area.minY)*factor-(mf.minY-mini.minY))<0.001)
    }}
}
checks.append("Position round-trip, preview/desktop mapping and edge containment: 27 cases passed")
// Exercise the actual AppKit event handlers with synthetic local events; this is
// a handler test, not a claim that OS-level pointer automation succeeded.
let canvas=DesktopCanvas(frame:NSRect(x:0,y:0,width:570,height:360))
canvas.worldSize=NSSize(width:2048,height:1043);canvas.iconSide=300
canvas.position=NSPoint(x:0.5,y:0.5)
var delivered:NSPoint?
canvas.onMove={delivered=$0}
let first=NSPoint(x:canvas.iconFrame.midX,y:canvas.iconFrame.midY)
let destination=NSPoint(x:first.x-90,y:first.y+50)
func event(_ type:NSEvent.EventType,_ p:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:p,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
canvas.mouseDown(with:event(.leftMouseDown,first))
canvas.mouseDragged(with:event(.leftMouseDragged,destination))
canvas.mouseUp(with:event(.leftMouseUp,destination))
assert(delivered != nil && delivered!.x<0.5 && delivered!.y>0.5 && !canvas.dragging)
assert(abs(canvas.iconFrame.midX-destination.x)<0.001 && abs(canvas.iconFrame.midY-destination.y)<0.001)
checks.append("Simulated AppKit drag: grab offset, continuous callback and mouse-up verified")
let n=64
var bytes=[UInt8](repeating:0,count:n*n*4)
for y in 0..<n {for x in 0..<n {let r=hypot(Double(x)-31.5,Double(y)-31.5);if r>10 && r<25 {let i=(y*n+x)*4;bytes[i]=80;bytes[i+1]=210;bytes[i+2]=130;bytes[i+3]=255}}}
let donut=CutoutImage(size:n,pixels:bytes,method:"test",retainedFraction:1)
let (mesh,sides)=RenderAsset.mesh(donut)
assert(sides>150 && mesh.count==12+sides*6*13)
let walls=mesh.dropFirst(12)
assert(walls.contains{hypot($0.position.x,$0.position.y)<0.4}) // inner wall exists
assert(walls.contains{hypot($0.position.x,$0.position.y)>0.7}) // outer wall exists
assert(walls.allSatisfy{$0.position.x.isFinite && $0.normal.x.isFinite})
checks.append("Donut silhouette has both interior and exterior sidewalls; no square backing geometry")
let clock=RotationClock();let a=clock.current;usleep(30000);let b=clock.current;assert(b>a)
clock.speed=0;let c=clock.current;usleep(30000);assert(abs(clock.current-c)<0.000001)
clock.speed=2;let d=clock.current;assert(abs(d-c)<0.01)
clock.paused=true;let e=clock.current;usleep(30000);assert(abs(clock.current-e)<0.000001)
checks.append("Rotation: advancing, zero-speed freeze, no speed-change jump, pause")
var samples:[[String:Any]]=[]
for (index,id) in ["com.openai.codex","com.apple.calculator","com.apple.finder","com.apple.systempreferences","com.apple.Safari"].enumerated() {
    guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:id),let cg=IconCutout.sourceImage(NSWorkspace.shared.icon(forFile:url.path)) else {continue}
    let start=Date()
    let cut=IconCutout.prepare(cg)
    guard let image=cut.cgImage() else {fatalError("Missing cutout image")}
    try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("cutout-\(index).png"))
    let (_,count)=RenderAsset.mesh(cut);assert(count>20)
    if index==0 {assert(cut.retainedFraction<0.65);let center=(cut.size/2*cut.size+cut.size/2)*4+3;assert(cut.pixels[center]<64)}
    samples.append(["app":id,"method":cut.method,"retainedFraction":cut.retainedFraction,"sideSegments":count,"seconds":Date().timeIntervalSince(start)])
}
checks.append("Real application icon extraction completed; inspect generated PNGs for semantic quality")
let report:[String:Any]=["checks":checks,"samples":samples]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("test-results.json"))
for check in checks {print(check)}
