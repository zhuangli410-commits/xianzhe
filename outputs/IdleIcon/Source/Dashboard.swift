import AppKit

final class MemoryHistory:NSView {
    var samples:[Double]=[]
    var total:Double=1
    func append(_ bytes:UInt64,total:UInt64) {self.total=Double(total);samples.append(Double(bytes));if samples.count>100 {samples.removeFirst()};needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        guard samples.count>1 else{return}
        let room=bounds.insetBy(dx:1,dy:5),scale=max(total*0.12,(samples.max() ?? 0)*1.2)
        let line=NSBezierPath()
        for (i,value) in samples.enumerated() {
            let p=NSPoint(x:room.minX+CGFloat(i)*room.width/99,y:room.minY+CGFloat(value/max(1,scale))*room.height)
            if i==0 {line.move(to:p)} else {line.line(to:p)}
        }
        NSColor(srgbRed:0.73,green:0.68,blue:1,alpha:0.8).setStroke();line.lineWidth=1.6;line.stroke()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let base=NSBezierPath();base.move(to:NSPoint(x:room.minX,y:room.minY));base.line(to:NSPoint(x:room.maxX,y:room.minY));base.stroke()
    }
}
