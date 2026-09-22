import AppKit
import MetalKit
final class InspectorCanvas:MTKView {
    var orbit:((Float,Float)->Void)?
    var draggingLight=false
    var moveLight:((Float,Float)->Void)?
    var magnify:((Float)->Void)?
    private var anchor:NSPoint?
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func mouseDown(with event:NSEvent) {anchor=convert(event.locationInWindow,from:nil)}
    override func mouseDragged(with event:NSEvent) {
        let point=convert(event.locationInWindow,from:nil)
        if let old=anchor {
            if draggingLight || event.modifierFlags.contains(.shift) {moveLight?(Float(point.x-old.x)*0.02,Float(point.y-old.y)*0.02)}
            else {orbit?(Float(point.x-old.x)*0.012,Float(old.y-point.y)*0.012)}
        }
        anchor=point
    }
    override func mouseUp(with event:NSEvent) {anchor=nil}
    override func scrollWheel(with event:NSEvent) {magnify?(Float(event.scrollingDeltaY)*0.008)}
}

final class LightPositionPad:NSView {
    var position=SIMD2<Float>(-2,2.5) {didSet{needsDisplay=true}}
    var onMove:((SIMD2<Float>)->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel("灯光位置图：拖动光点调整左右和上下")
    }
    required init?(coder:NSCoder) {fatalError()}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    private var area:NSRect {bounds.insetBy(dx:18,dy:18)}
    private func move(_ event:NSEvent) {
        let p=convert(event.locationInWindow,from:nil),a=area
        onMove?(SIMD2(max(-4,min(4,Float((p.x-a.minX)/a.width*8-4))),max(-4,min(4,Float((p.y-a.minY)/a.height*8-4)))))
    }
    override func mouseDown(with event:NSEvent) {move(event)}
    override func mouseDragged(with event:NSEvent) {move(event)}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(srgbRed:0.08,green:0.10,blue:0.15,alpha:1).setFill();NSBezierPath(roundedRect:bounds,xRadius:12,yRadius:12).fill()
        let a=area,path=NSBezierPath();path.move(to:NSPoint(x:a.midX,y:a.minY));path.line(to:NSPoint(x:a.midX,y:a.maxY));path.move(to:NSPoint(x:a.minX,y:a.midY));path.line(to:NSPoint(x:a.maxX,y:a.midY));NSColor.white.withAlphaComponent(0.16).setStroke();path.stroke()
        let point=NSPoint(x:a.minX+CGFloat(position.x+4)/8*a.width,y:a.minY+CGFloat(position.y+4)/8*a.height)
        NSColor.systemYellow.withAlphaComponent(0.15).setFill();NSBezierPath(ovalIn:NSRect(x:point.x-18,y:point.y-18,width:36,height:36)).fill()
        NSColor.systemYellow.setFill();NSBezierPath(ovalIn:NSRect(x:point.x-7,y:point.y-7,width:14,height:14)).fill()
    }
}
