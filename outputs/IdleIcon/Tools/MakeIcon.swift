import AppKit
let destination=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let image=NSImage(size:NSSize(width:1024,height:1024))
    image.lockFocus()
    let bg=NSBezierPath(roundedRect:NSRect(x:44,y:44,width:936,height:936),xRadius:214,yRadius:214)
    NSColor(srgbRed:0.065,green:0.055,blue:0.115,alpha:1).setFill(); bg.fill()
    let shine=NSGradient(starting:NSColor(srgbRed:0.22,green:0.18,blue:0.36,alpha:1),ending:NSColor(srgbRed:0.045,green:0.055,blue:0.11,alpha:1))!
    shine.draw(in:bg,angle:-55)
    let ring=NSBezierPath(ovalIn:NSRect(x:155,y:300,width:714,height:340)); ring.lineWidth=22
    NSColor(srgbRed:0.70,green:0.65,blue:1,alpha:0.55).setStroke(); ring.stroke()
    let shadow=NSShadow(); shadow.shadowColor=NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius=35; shadow.shadowOffset=NSSize(width:12,height:-20)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    let body=NSBezierPath(roundedRect:NSRect(x:338,y:267,width:358,height:490),xRadius:105,yRadius:105)
    NSColor(srgbRed:0.38,green:0.30,blue:0.65,alpha:1).setFill(); body.fill()
    NSGraphicsContext.restoreGraphicsState()
    let front=NSBezierPath(roundedRect:NSRect(x:305,y:298,width:358,height:490),xRadius:105,yRadius:105)
    let face=NSGradient(starting:NSColor(srgbRed:0.95,green:0.92,blue:1,alpha:1),ending:NSColor(srgbRed:0.67,green:0.61,blue:0.98,alpha:1))!
    face.draw(in:front,angle:-75)
    let dot=NSBezierPath(ovalIn:NSRect(x:440,y:500,width:90,height:90)); NSColor(srgbRed:0.18,green:0.12,blue:0.30,alpha:1).setFill(); dot.fill()
    let lamp=NSBezierPath(ovalIn:NSRect(x:758,y:648,width:103,height:103))
    NSColor(srgbRed:1,green:0.85,blue:0.61,alpha:0.20).setFill();lamp.fill()
    let core=NSBezierPath(ovalIn:NSRect(x:790,y:680,width:39,height:39))
    NSColor(srgbRed:1,green:0.92,blue:0.76,alpha:1).setFill();core.fill()
    image.unlockFocus()
    guard let data=image.tiffRepresentation, let input=NSBitmapImageRep(data:data), let cg=input.cgImage,
        let ctx=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("icon") }
    ctx.interpolationQuality = .high; ctx.draw(cg,in:CGRect(x:0,y:0,width:size,height:size))
    let rep=NSBitmapImageRep(cgImage:ctx.makeImage()!)
    let png=rep.representation(using:.png,properties:[:])!
    if size <= 512 { try png.write(to:destination.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try png.write(to:destination.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
