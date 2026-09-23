import AppKit
import MetalKit

struct DesktopPlacement {
    static func clamped(_ p:NSPoint) -> NSPoint {
        NSPoint(x:max(0,min(1,p.x.isFinite ? p.x : 0.75)),y:max(0,min(1,p.y.isFinite ? p.y : 0.25)))
    }
    static func frame(in area:NSRect,side:CGFloat,position:NSPoint) -> NSRect {
        let p=clamped(position),s=max(1,min(side,min(area.width,area.height)))
        return NSRect(x:area.minX+p.x*max(0,area.width-s),y:area.minY+p.y*max(0,area.height-s),width:s,height:s)
    }
    static func shadowFrame(_ frame:NSRect)->NSRect {
        frame.insetBy(dx:-frame.width*(IconRenderer.desktopPadding-1)/2,dy:-frame.height*(IconRenderer.desktopPadding-1)/2)
    }
    static func normalized(origin:NSPoint,in area:NSRect,side:CGFloat) -> NSPoint {
        clamped(NSPoint(x:(origin.x-area.minX)/max(1,area.width-side),y:(origin.y-area.minY)/max(1,area.height-side)))
    }
}

final class DesktopCanvas:NSView {
    var renderView:MTKView!
    var modelView:LightModelOverlay?
    var worldSize=NSSize(width:1440,height:900) {didSet{updatePlacement()}}
    var position=NSPoint(x:0.75,y:0.25) {didSet{updatePlacement()}}
    var iconSide:CGFloat=300 {didSet{updatePlacement()}}
    var onMove:((NSPoint)->Void)?
    var dragging=false
    private var dragOffset=NSPoint.zero
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool {true}
    var desktopRect:NSRect {
        let room=NSRect(x:14,y:30,width:max(1,bounds.width-28),height:max(1,bounds.height-70))
        let ratio=min(room.width/max(1,worldSize.width),room.height/max(1,worldSize.height))
        let size=NSSize(width:worldSize.width*ratio,height:worldSize.height*ratio)
        return NSRect(x:room.midX-size.width/2,y:room.midY-size.height/2,width:size.width,height:size.height)
    }
    var miniatureSide:CGFloat {min(iconSide,min(worldSize.width,worldSize.height))*desktopRect.width/max(1,worldSize.width)}
    var iconFrame:NSRect {DesktopPlacement.frame(in:desktopRect,side:miniatureSide,position:position)}
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true;layer?.cornerRadius=18;layer?.masksToBounds=true
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("模拟桌面：拖动图标调整真实桌面位置")
    }
    required init?(coder:NSCoder) {fatalError()}
    func install(_ view:MTKView) {renderView=view;addSubview(view);updatePlacement()}
    func installModels(_ view:LightModelOverlay) {modelView=view;addSubview(view);updatePlacement()}
    override func hitTest(_ point:NSPoint) -> NSView? {super.hitTest(point)==nil ? nil : self}
    override func layout() {super.layout();updatePlacement()}
    private func updatePlacement() {let f=DesktopPlacement.shadowFrame(iconFrame);renderView?.frame=f;modelView?.frame=f;needsDisplay=true;window?.invalidateCursorRects(for:self)}
    override func resetCursorRects() {addCursorRect(iconFrame,cursor:.openHand)}
    override func mouseDown(with event:NSEvent) {
        let p=convert(event.locationInWindow,from:nil)
        guard desktopRect.contains(p) else {return}
        window?.makeFirstResponder(self)
        dragging=true
        dragOffset=iconFrame.contains(p) ? NSPoint(x:p.x-iconFrame.minX,y:p.y-iconFrame.minY) : NSPoint(x:miniatureSide/2,y:miniatureSide/2)
        NSCursor.closedHand.set();move(to:p)
    }
    override func mouseDragged(with event:NSEvent) {guard dragging else{return};move(to:convert(event.locationInWindow,from:nil))}
    override func mouseUp(with event:NSEvent) {guard dragging else{return};move(to:convert(event.locationInWindow,from:nil));dragging=false;NSCursor.openHand.set();needsDisplay=true}
    private func move(to point:NSPoint) {
        position=DesktopPlacement.normalized(origin:NSPoint(x:point.x-dragOffset.x,y:point.y-dragOffset.y),in:desktopRect,side:miniatureSide)
        onMove?(position)
    }
    override func keyDown(with event:NSEvent) {
        var p=position
        switch event.keyCode {case 123:p.x-=0.015;case 124:p.x+=0.015;case 125:p.y-=0.015;case 126:p.y+=0.015;default:super.keyDown(with:event);return}
        position=DesktopPlacement.clamped(p);onMove?(position)
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(srgbRed:0.035,green:0.045,blue:0.062,alpha:1).setFill();bounds.fill()
        let r=desktopRect
        let outer=NSBezierPath(roundedRect:r.insetBy(dx:-1,dy:-1),xRadius:10,yRadius:10)
        NSGradient(colors:[NSColor(srgbRed:0.16,green:0.16,blue:0.27,alpha:1),NSColor(srgbRed:0.07,green:0.07,blue:0.12,alpha:1)])!.draw(in:outer,angle:-65)
        NSGraphicsContext.saveGraphicsState();outer.addClip()
        let wave=NSBezierPath();wave.move(to:NSPoint(x:r.minX-30,y:r.minY+r.height*0.15))
        wave.curve(to:NSPoint(x:r.maxX+30,y:r.maxY*0.7),controlPoint1:NSPoint(x:r.midX,y:r.maxY*1.3),controlPoint2:NSPoint(x:r.midX,y:r.minY-r.height*0.5))
        wave.line(to:NSPoint(x:r.maxX+30,y:r.minY-20));wave.line(to:NSPoint(x:r.minX-30,y:r.minY-20));wave.close()
        NSGradient(starting:NSColor(srgbRed:0.30,green:0.24,blue:0.47,alpha:0.65),ending:NSColor(srgbRed:0.10,green:0.10,blue:0.21,alpha:0.3))!.draw(in:wave,angle:80)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.14).setStroke();outer.lineWidth=1;outer.stroke()
        let top=r.maxY+8
        for i in 0..<3 {NSColor.white.withAlphaComponent(0.25).setFill();NSBezierPath(ovalIn:NSRect(x:r.minX+4+CGFloat(i)*10,y:top,width:4,height:4)).fill()}
        let attr:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.white.withAlphaComponent(0.5)]
        "模拟桌面 · 拖动即同步".draw(at:NSPoint(x:r.minX+42,y:top-4),withAttributes:attr)
        let dock=NSBezierPath(roundedRect:NSRect(x:r.midX-54,y:8,width:108,height:14),xRadius:6,yRadius:6)
        NSColor.white.withAlphaComponent(0.06).setFill();dock.fill()
        for i in 0..<6 {NSColor.white.withAlphaComponent(0.13).setFill();NSBezierPath(roundedRect:NSRect(x:r.midX-43+CGFloat(i)*16,y:11,width:9,height:9),xRadius:2,yRadius:2).fill()}
        let outline=NSBezierPath(roundedRect:iconFrame.insetBy(dx:1,dy:1),xRadius:8,yRadius:8)
        NSColor(srgbRed:0.74,green:0.69,blue:1.0,alpha:dragging ? 0.8 : 0.3).setStroke()
        outline.lineWidth=1;outline.setLineDash([4,4],count:2,phase:0);outline.stroke()
    }
}
