import AppKit
import simd

enum LampKind:Int,Codable,CaseIterable {
    case studio,flashlight,sun,lighter,candle,match,moon
    var title:String {switch self {case .studio:return "摄影灯";case .flashlight:return "手电筒";case .sun:return "太阳";case .lighter:return "打火机";case .candle:return "蜡烛";case .match:return "火柴";case .moon:return "月亮"}}
    var defaultColor:String {switch self {case .studio:return "#FFECD4";case .flashlight:return "#E5F3FF";case .sun:return "#FFE4A0";case .lighter:return "#FFAD65";case .candle:return "#FFC47A";case .match:return "#FF9955";case .moon:return "#B8CAFF"}}
    var relativeStrength:Float {switch self {case .studio:return 1;case .flashlight:return 1.12;case .sun:return 1.32;case .lighter:return 0.44;case .candle:return 0.34;case .match:return 0.22;case .moon:return 0.19}}
}

struct SceneLight:Codable,Equatable {
    var id:UUID=UUID()
    var kind:LampKind
    var x:Float
    var y:Float
    var z:Float
    var power:Float
    var hex:String
    var enabled:Bool=true
    var yaw:Float
    var pitch:Float
    var elapsed:Float=0
    var position:SIMD3<Float> {SIMD3(x,y,z)}
    var direction:SIMD3<Float> {SIMD3(sin(yaw)*cos(pitch),cos(yaw)*cos(pitch),sin(pitch))}
    var burnFraction:Float {kind == .candle ? min(1,elapsed/600) : kind == .match ? min(1,elapsed/45) : 0}
    init(kind:LampKind,x:Float,y:Float,z:Float,power:Float=1,hex:String?=nil) {
        self.kind=kind;self.x=x;self.y=y;self.z=z;self.power=power;self.hex=hex ?? kind.defaultColor
        let d=simd_normalize(SIMD3<Float>(-x,-y,-z))
        yaw=atan2(d.x,d.y);pitch=asin(d.z)
    }
    enum CodingKeys:String,CodingKey {case id,kind,x,y,z,power,hex,enabled,yaw,pitch,elapsed}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let kind=try c.decode(LampKind.self,forKey:.kind)
        self.init(kind:kind,x:try c.decode(Float.self,forKey:.x),y:try c.decode(Float.self,forKey:.y),z:try c.decode(Float.self,forKey:.z),power:try c.decode(Float.self,forKey:.power),hex:try c.decode(String.self,forKey:.hex))
        id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID()
        enabled=try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? true
        yaw=try c.decodeIfPresent(Float.self,forKey:.yaw) ?? yaw
        pitch=try c.decodeIfPresent(Float.self,forKey:.pitch) ?? pitch
        elapsed=try c.decodeIfPresent(Float.self,forKey:.elapsed) ?? 0
        clamp()
    }
    func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(kind,forKey:.kind)
        try c.encode(x,forKey:.x);try c.encode(y,forKey:.y);try c.encode(z,forKey:.z)
        try c.encode(power,forKey:.power);try c.encode(hex,forKey:.hex);try c.encode(enabled,forKey:.enabled)
        try c.encode(yaw,forKey:.yaw);try c.encode(pitch,forKey:.pitch);try c.encode(elapsed,forKey:.elapsed)
    }
    mutating func clamp() {
        x=max(-4,min(4,x.isFinite ? x : -2));y=max(-4,min(4,y.isFinite ? y : 2))
        z=max(0.5,min(8,z.isFinite ? z : 4));power=max(0.1,min(3,power.isFinite ? power : 1))
        if IconColor(hex:hex)==nil {hex=kind.defaultColor}
        yaw=max(-Float.pi,min(Float.pi,yaw.isFinite ? yaw : 0))
        pitch=max(-1.4,min(1.4,pitch.isFinite ? pitch : -0.5))
        elapsed=max(0,elapsed.isFinite ? elapsed : 0)
    }
    mutating func turn(horizontal:Float,vertical:Float) {
        yaw=atan2(sin(yaw+horizontal),cos(yaw+horizontal))
        pitch=max(-1.4,min(1.4,pitch+vertical))
    }
    func resolved() -> SceneLight {
        var l=self
        if kind == .sun {
            let phase=elapsed.truncatingRemainder(dividingBy:240)/240
            let day=phase<0.5,progress=day ? phase*2 : (phase-0.5)*2
            l.kind=day ? .sun : .moon
            l.x=max(-4,min(4,x-4+8*progress));l.y=y;l.z=max(0.6,1.2+(z-1.2)*sin(Float.pi*progress))
            l.hex=l.kind.defaultColor
            let d=simd_normalize(SIMD3<Float>(-l.x,-l.y,-l.z))
            l.yaw=atan2(d.x,d.y);l.pitch=asin(d.z)
            l.power=power*l.kind.relativeStrength*max(0.18,sin(Float.pi*progress))
        } else {
            l.power=power*kind.relativeStrength
            if kind == .candle {l.z=max(0.55,z-0.8*burnFraction);l.power*=max(0,1-burnFraction)}
            if kind == .match {l.power*=max(0,1-burnFraction)}
        }
        if l.power<0.015 {l.enabled=false}
        return l
    }
}

final class AimDragButton:NSButton {
    var onTurn:((Float,Float)->Void)?
    private var last:NSPoint?
    override func mouseDown(with event:NSEvent) {last=event.locationInWindow;state = .on}
    override func mouseDragged(with event:NSEvent) {
        guard let old=last else{return}
        let next=event.locationInWindow
        onTurn?(Float(next.x-old.x)*0.015,Float(next.y-old.y)*0.012)
        last=next
    }
    override func mouseUp(with event:NSEvent) {last=nil;state = .off}
}

final class LightRigPad:NSView {
    var lights:[SceneLight]=[] {didSet {needsDisplay=true}}
    var selected=0 {didSet {needsDisplay=true}}
    var onSelect:((Int)->Void)?
    var onMove:((Int,SIMD3<Float>)->Void)?
    private var dragIndex:Int?
    private var last:NSPoint?
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true);setAccessibilityRole(.group)
        setAccessibilityLabel("三维布光台：点选灯具，拖动改变地面位置；按住 Option 拖动改变高度")
    }
    required init?(coder:NSCoder) {fatalError()}
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool {true}
    private var unit:CGFloat {max(12,min(bounds.width/13,bounds.height/11))}
    private var origin:NSPoint {NSPoint(x:bounds.midX,y:bounds.height*0.32)}
    func project(_ p:SIMD3<Float>) -> NSPoint {
        let s=unit,o=origin,x=CGFloat(p.x),y=CGFloat(p.y),z=CGFloat(p.z)
        return NSPoint(x:o.x+(x-y)*s*0.76,y:o.y+(x+y)*s*0.30+z*s*0.72)
    }
    override func mouseDown(with event:NSEvent) {
        let p=convert(event.locationInWindow,from:nil)
        let nearest=lights.indices.min {a,b in
            let pa=project(lights[a].position),pb=project(lights[b].position)
            return hypot(pa.x-p.x,pa.y-p.y)<hypot(pb.x-p.x,pb.y-p.y)
        }
        guard let i=nearest else{return}
        let q=project(lights[i].position)
        guard hypot(q.x-p.x,q.y-p.y)<32 else{return}
        dragIndex=i;last=p;onSelect?(i)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let i=dragIndex,lights.indices.contains(i),let old=last else{return}
        let p=convert(event.locationInWindow,from:nil),s=unit
        var l=lights[i]
        if event.modifierFlags.contains(.option) {l.z+=Float((p.y-old.y)/(s*0.72))}
        else {
            let a=(p.x-old.x)/(s*0.76),b=(p.y-old.y)/(s*0.30)
            l.x+=Float((a+b)/2);l.y+=Float((b-a)/2)
        }
        l.clamp();last=p;onMove?(i,l.position)
    }
    override func mouseUp(with event:NSEvent) {dragIndex=nil;last=nil}
    override func draw(_ dirtyRect:NSRect) {
        let mint=NSColor(srgbRed:0.74,green:0.69,blue:1.0,alpha:1)
        NSColor(srgbRed:0.055,green:0.075,blue:0.11,alpha:1).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:14,yRadius:14).fill()
        let o=origin,s=unit
        let grid=NSBezierPath()
        for t in -4...4 {
            let a=project(SIMD3<Float>(Float(t),-4,0)),b=project(SIMD3<Float>(Float(t),4,0))
            let c=project(SIMD3<Float>(-4,Float(t),0)),d=project(SIMD3<Float>(4,Float(t),0))
            grid.move(to:a);grid.line(to:b);grid.move(to:c);grid.line(to:d)
        }
        grid.lineWidth=0.8;NSColor.white.withAlphaComponent(0.12).setStroke();grid.stroke()
        let icon=project(SIMD3<Float>(0,0,1.2))
        let base=NSBezierPath(ovalIn:NSRect(x:o.x-16,y:o.y-7,width:32,height:14))
        mint.withAlphaComponent(0.18).setFill();base.fill()
        let block=NSBezierPath(roundedRect:NSRect(x:icon.x-15,y:icon.y-16,width:30,height:32),xRadius:8,yRadius:8)
        mint.withAlphaComponent(0.7).setFill();block.fill()
        for (i,l) in lights.enumerated() {
            let top=project(l.position),ground=project(SIMD3<Float>(l.x,l.y,0))
            let stem=NSBezierPath();stem.move(to:ground);stem.line(to:top);stem.lineWidth=1
            (i==selected ? mint : NSColor.white.withAlphaComponent(0.35)).setStroke();stem.stroke()
            let color=IconColor(hex:l.hex)?.nsColor ?? .systemYellow
            LightGlyph.draw(kind:l.kind,at:top,size:34,color:l.enabled ? color : .gray,selected:i==selected,direction:l.direction,burnFraction:l.burnFraction)
            if l.kind == .studio || l.kind == .flashlight {
                let toward=project(l.position+l.direction*1.4)
                let arrow=NSBezierPath();arrow.move(to:top);arrow.line(to:toward);arrow.lineWidth=i==selected ? 2.2 : 1.2
                color.withAlphaComponent(i==selected ? 0.9 : 0.55).setStroke();arrow.stroke()
                let dot=NSBezierPath(ovalIn:NSRect(x:toward.x-3,y:toward.y-3,width:6,height:6));color.setFill();dot.fill()
            }
            let tag="\(i+1) \(l.kind.title)"
            let attr:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:11,weight:i==selected ? .semibold : .regular),.foregroundColor:NSColor.white.withAlphaComponent(i==selected ? 0.95 : 0.65)]
            tag.draw(at:NSPoint(x:top.x+23,y:top.y-7),withAttributes:attr)
        }
        let hint="拖动灯具：平移  ·  Option + 拖动：高度  ·  按住调向按钮拖动：朝向"
        hint.draw(at:NSPoint(x:15,y:12),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.white.withAlphaComponent(0.55)])
        _=s
    }
}

final class LightModelOverlay:NSView {
    var lights:[SceneLight]=[] {didSet {needsDisplay=true}}
    var visible=true {didSet {needsDisplay=true}}
    override func hitTest(_ point:NSPoint) -> NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        guard visible else{return}
        let scale=min(bounds.width,bounds.height)/10
        for light in lights where light.enabled && light.kind != .studio {
            let p=NSPoint(x:bounds.midX+CGFloat(light.x)*scale*0.6,y:bounds.midY+CGFloat(light.y)*scale*0.52+CGFloat(light.z-4)*scale*0.22)
            let color=IconColor(hex:light.hex)?.nsColor ?? .systemYellow
            let radius:CGFloat=light.kind == .sun ? scale*1.12 : light.kind == .flashlight ? scale*0.72 : scale*0.50
            let glow=NSBezierPath(ovalIn:NSRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2))
            NSGradient(starting:color.withAlphaComponent(0.20),ending:color.withAlphaComponent(0))?.draw(in:glow,relativeCenterPosition:.zero)
            if light.kind == .flashlight {
                let d=light.direction
                let toward=NSPoint(x:CGFloat(d.x)*scale*2.3*0.6,y:(CGFloat(d.y)*0.52+CGFloat(d.z)*0.22)*scale*2.3)
                let length=max(1,hypot(toward.x,toward.y)),perp=NSPoint(x:-toward.y/length,y:toward.x/length)
                let end=NSPoint(x:p.x+toward.x,y:p.y+toward.y)
                let width=scale*0.42
                let beam=NSBezierPath();beam.move(to:p)
                beam.line(to:NSPoint(x:end.x+perp.x*width,y:end.y+perp.y*width))
                beam.line(to:NSPoint(x:end.x-perp.x*width,y:end.y-perp.y*width));beam.close()
                color.withAlphaComponent(0.085).setFill();beam.fill()
            }
            LightGlyph.draw(kind:light.kind,at:p,size:max(40,min(88,scale*0.74)),color:color,direction:light.direction,burnFraction:light.burnFraction)
        }
    }
}
