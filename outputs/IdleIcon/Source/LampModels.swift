import AppKit
import simd

// Small lamps are built from shaded 3D surfaces. No emoji or image is used as a model.
typealias V3 = SIMD3<Float>

private struct LampFace {
    let vertices:[V3]
    let normal:V3
    let color:NSColor
    var depth:Float {vertices.reduce(0) {$0+simd_dot($1,V3(0.62,0.30,1))}/Float(vertices.count)}
}

private struct LampMesh {
    var faces:[LampFace]=[]
    mutating func orient(fromXTo direction:V3) {
        guard simd_length(direction)>0.001 else{return}
        let q=simd_quatf(from:V3(1,0,0),to:simd_normalize(direction))
        faces=faces.map {LampFace(vertices:$0.vertices.map{q.act($0)},normal:q.act($0.normal),color:$0.color)}
    }
    mutating func face(_ vertices:[V3],_ color:NSColor,_ normal:V3?=nil) {
        guard vertices.count>=3 else{return}
        let raw=normal ?? simd_cross(vertices[1]-vertices[0],vertices[2]-vertices[0])
        faces.append(LampFace(vertices:vertices,normal:simd_length(raw)>0.0001 ? simd_normalize(raw) : V3(0,0,1),color:color))
    }
    mutating func box(_ lo:V3,_ hi:V3,_ color:NSColor) {
        let a=V3(lo.x,lo.y,lo.z),b=V3(hi.x,lo.y,lo.z),c=V3(hi.x,hi.y,lo.z),d=V3(lo.x,hi.y,lo.z)
        let e=V3(lo.x,lo.y,hi.z),f=V3(hi.x,lo.y,hi.z),g=V3(hi.x,hi.y,hi.z),h=V3(lo.x,hi.y,hi.z)
        face([a,d,c,b],color,V3(0,0,-1));face([e,f,g,h],color,V3(0,0,1))
        face([a,e,h,d],color,V3(-1,0,0));face([b,c,g,f],color,V3(1,0,0))
        face([a,b,f,e],color,V3(0,-1,0));face([d,h,g,c],color,V3(0,1,0))
    }
    mutating func tube(_ start:V3,_ end:V3,_ radius:Float,_ color:NSColor,segments:Int=18) {
        let axis=simd_normalize(end-start)
        let reference=abs(axis.y)<0.9 ? V3(0,1,0) : V3(1,0,0)
        let u=simd_normalize(simd_cross(axis,reference)),v=simd_cross(axis,u)
        for i in 0..<segments {
            let a=Float(i)*2*Float.pi/Float(segments),b=Float(i+1)*2*Float.pi/Float(segments)
            let ra=u*cos(a)*radius+v*sin(a)*radius,rb=u*cos(b)*radius+v*sin(b)*radius
            face([start+ra,start+rb,end+rb,end+ra],color,simd_normalize(ra+rb))
            face([start,start+rb,start+ra],color,-axis)
            face([end,end+ra,end+rb],color,axis)
        }
    }
    mutating func lathe(_ rings:[(Float,Float)],center:V3,_ color:NSColor,segments:Int=18) {
        for j in 0..<(rings.count-1) {
            let (ya,ra)=rings[j],(yb,rb)=rings[j+1]
            for i in 0..<segments {
                let a=Float(i)*2*Float.pi/Float(segments),b=Float(i+1)*2*Float.pi/Float(segments)
                let p=V3(center.x+ra*cos(a),center.y+ya,center.z+ra*sin(a))
                let q=V3(center.x+ra*cos(b),center.y+ya,center.z+ra*sin(b))
                let r=V3(center.x+rb*cos(b),center.y+yb,center.z+rb*sin(b))
                let s=V3(center.x+rb*cos(a),center.y+yb,center.z+rb*sin(a))
                let n=simd_normalize(V3(cos((a+b)/2),max(-0.45,min(0.45,(ra-rb)*2)),sin((a+b)/2)))
                face([p,q,r,s],color,n)
            }
        }
        if let first=rings.first {face((0..<segments).map {i in let a=Float(i)*2*Float.pi/Float(segments);return V3(center.x+first.1*cos(a),center.y+first.0,center.z+first.1*sin(a))},color,V3(0,-1,0))}
        if let last=rings.last {face((0..<segments).map {i in let a=Float(i)*2*Float.pi/Float(segments);return V3(center.x+last.1*cos(a),center.y+last.0,center.z+last.1*sin(a))},color,V3(0,1,0))}
    }
    mutating func sphere(_ c:V3,_ r:Float,_ color:NSColor,segments:Int=18) {
        for j in 0..<8 {
            let a = -Float.pi/2+Float(j)*Float.pi/8,b = -Float.pi/2+Float(j+1)*Float.pi/8
            for i in 0..<segments {
                let t=Float(i)*2*Float.pi/Float(segments),u=Float(i+1)*2*Float.pi/Float(segments)
                let points=[V3(cos(a)*cos(t),sin(a),cos(a)*sin(t)),V3(cos(a)*cos(u),sin(a),cos(a)*sin(u)),V3(cos(b)*cos(u),sin(b),cos(b)*sin(u)),V3(cos(b)*cos(t),sin(b),cos(b)*sin(t))]
                face(points.map {c+$0*r},color,simd_normalize(points.reduce(V3.zero,+)))
            }
        }
    }
    func draw(at center:NSPoint,size:CGFloat) {
        let scale=size/2.75
        func project(_ v:V3)->NSPoint {
            NSPoint(x:center.x+CGFloat(v.x-v.z)*scale*0.70,y:center.y+CGFloat(v.y)*scale*0.84+CGFloat(v.x+v.z)*scale*0.22)
        }
        for f in faces.sorted(by:{$0.depth<$1.depth}) {
            let n=f.normal
            let light=max(0,simd_dot(n,simd_normalize(V3(-0.45,0.8,0.75))))
            let reflected=max(0,simd_dot(n,simd_normalize(V3(0.55,0.3,1.0))))
            let k=CGFloat(min(1.22,0.48+light*0.55+pow(reflected,8)*0.20))
            let c=f.color.usingColorSpace(.sRGB) ?? f.color
            NSColor(srgbRed:min(1,c.redComponent*k),green:min(1,c.greenComponent*k),blue:min(1,c.blueComponent*k),alpha:c.alphaComponent).setFill()
            let path=NSBezierPath();path.move(to:project(f.vertices[0]));for v in f.vertices.dropFirst(){path.line(to:project(v))};path.close();path.fill()
        }
    }
}

enum LightGlyph {
    private static let graphite=NSColor(srgbRed:0.20,green:0.25,blue:0.31,alpha:1)
    private static let metal=NSColor(srgbRed:0.70,green:0.77,blue:0.82,alpha:1)
    private static let wax=NSColor(srgbRed:0.94,green:0.84,blue:0.65,alpha:1)
    private static func rgb(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat)->NSColor {NSColor(srgbRed:r,green:g,blue:b,alpha:1)}
    static func draw(kind:LampKind,at p:NSPoint,size:CGFloat,color:NSColor,selected:Bool=false,direction:V3=V3(1,0,0),burnFraction:Float=0) {
        NSGraphicsContext.saveGraphicsState()
        let halo=NSBezierPath(ovalIn:NSRect(x:p.x-size*0.72,y:p.y-size*0.72,width:size*1.44,height:size*1.44))
        NSGradient(starting:color.withAlphaComponent(selected ? 0.25 : 0.14),ending:color.withAlphaComponent(0))?.draw(in:halo,relativeCenterPosition:.zero)
        var mesh=LampMesh()
        switch kind {
        case .studio:
            mesh.tube(V3(0,-1.15,0),V3(0,-0.35,0),0.07,metal)
            mesh.box(V3(-0.62,-0.38,-0.27),V3(0.62,0.48,0.27),graphite)
            mesh.box(V3(-0.52,-0.27,0.28),V3(0.52,0.36,0.33),color)
            mesh.box(V3(-0.54,0.48,-0.06),V3(0.54,0.52,0.18),metal)
        case .flashlight:
            mesh.tube(V3(-1.18,-0.12,0),V3(0.40,-0.12,0),0.27,graphite)
            mesh.tube(V3(-0.95,-0.12,0),V3(-0.83,-0.12,0),0.30,metal)
            mesh.tube(V3(-0.30,-0.12,0),V3(-0.20,-0.12,0),0.30,metal)
            mesh.tube(V3(0.30,-0.12,0),V3(0.92,-0.12,0),0.43,metal)
            mesh.tube(V3(0.86,-0.12,0),V3(1.00,-0.12,0),0.46,graphite)
            mesh.tube(V3(1.002,-0.12,0),V3(1.012,-0.12,0),0.36,color)
            mesh.box(V3(-0.26,0.15,-0.16),V3(0.11,0.32,0.16),metal)
            mesh.box(V3(-0.18,0.32,-0.10),V3(0.04,0.37,0.10),rgb(0.10,0.16,0.20))
            mesh.orient(fromXTo:direction)
        case .sun:
            for i in 0..<12 {
                let a=Float(i)*Float.pi/6
                let base=V3(cos(a)*0.74,sin(a)*0.74,0)
                let tip=V3(cos(a)*1.20,sin(a)*1.20,0)
                mesh.tube(base,tip,0.075,color,segments:8)
            }
            mesh.sphere(V3.zero,0.78,color)
        case .moon:
            mesh.sphere(V3.zero,0.80,rgb(0.72,0.79,0.93))
            mesh.sphere(V3(-0.24,0.26,0.68),0.13,rgb(0.52,0.61,0.77))
            mesh.sphere(V3(0.30,-0.14,0.71),0.10,rgb(0.55,0.65,0.81))
        case .lighter:
            mesh.box(V3(-0.47,-1.02,-0.26),V3(0.47,0.23,0.26),rgb(0.66,0.18,0.15))
            mesh.box(V3(-0.45,0.17,-0.27),V3(0.45,0.48,0.27),metal)
            mesh.tube(V3(-0.21,0.52,-0.03),V3(0.21,0.52,-0.03),0.15,graphite,segments:12)
            mesh.box(V3(0.25,0.43,-0.20),V3(0.42,0.63,0.20),metal)
            flame(on:&mesh,at:V3(0,0.66,0),color:color,height:0.77)
        case .candle:
            let top:Float=0.39-min(0.85,burnFraction)*1.2
            mesh.lathe([(-1.03,0.47),(-0.99,0.50),(top-0.11,0.50),(top,0.44)],center:.zero,wax)
            mesh.lathe([(top,0.44),(top+0.03,0.35)],center:.zero,rgb(1,0.93,0.76))
            mesh.tube(V3(0,top,0),V3(0,top+0.22,0),0.035,graphite,segments:8)
            if burnFraction<1 {flame(on:&mesh,at:V3(0,top+0.22,0),color:color,height:0.79)}
        case .match:
            mesh.box(V3(-0.09,-1.13,-0.09),V3(0.09,0.41,0.09),rgb(0.69,0.40,0.20))
            mesh.sphere(V3(0,0.47,0),0.20,rgb(0.70,0.16,0.11))
            if burnFraction<1 {flame(on:&mesh,at:V3(0,0.62,0),color:color,height:0.72*(1-burnFraction))}
        }
        mesh.draw(at:p,size:size)
        if kind == .flashlight {drawLens(at:p,size:size,color:color,direction:direction)}
        if kind == .lighter || ((kind == .candle || kind == .match) && burnFraction<1) {drawFlameGlow(at:p,size:size,kind:kind,color:color,burnFraction:burnFraction)}
        if selected {NSColor.white.withAlphaComponent(0.72).setStroke();halo.lineWidth=1.25;halo.stroke()}
        NSGraphicsContext.restoreGraphicsState()
    }
    private static func flame(on mesh:inout LampMesh,at p:V3,color:NSColor,height:Float) {
        mesh.lathe([(0,0.07),(height*0.16,0.18),(height*0.40,0.25),(height*0.73,0.14),(height,0.005)],center:p,color,segments:16)
        let core=rgb(1,0.94,0.58)
        mesh.lathe([(height*0.05,0.035),(height*0.25,0.10),(height*0.56,0.07),(height*0.76,0.002)],center:V3(p.x,p.y,p.z+0.18),core,segments:12)
    }
    private static func drawLens(at p:NSPoint,size:CGFloat,color:NSColor,direction:V3) {
        let s=size/2.75
        let q=simd_quatf(from:V3(1,0,0),to:simd_normalize(direction))
        func projected(_ y:CGFloat,_ z:CGFloat)->NSPoint {
            let v=q.act(V3(1.015,Float(y),Float(z)))
            return NSPoint(x:p.x+CGFloat(v.x-v.z)*s*0.70,y:p.y+CGFloat(v.y)*s*0.84+CGFloat(v.x+v.z)*s*0.22)
        }
        func disc(_ radius:CGFloat)->NSBezierPath {
            let path=NSBezierPath()
            for i in 0...48 {
                let a=CGFloat(i)*2*CGFloat.pi/48
                let q=projected(-0.12+cos(a)*radius,sin(a)*radius)
                if i==0 {path.move(to:q)} else {path.line(to:q)}
            }
            path.close();return path
        }
        let rim=disc(0.36);NSColor(srgbRed:0.12,green:0.20,blue:0.26,alpha:1).setFill();rim.fill()
        let glass=disc(0.30)
        NSGradient(starting:color.withAlphaComponent(0.98),ending:rgb(0.48,0.68,0.76))?.draw(in:glass,angle:130)
        NSColor.white.withAlphaComponent(0.48).setStroke();glass.lineWidth=max(0.5,size/80);glass.stroke()
        let g=projected(0.02,0.16)
        let glint=NSBezierPath(ovalIn:NSRect(x:g.x-s*0.06,y:g.y-s*0.04,width:s*0.15,height:s*0.10))
        NSColor.white.withAlphaComponent(0.78).setFill();glint.fill()
    }
    private static func drawFlameGlow(at p:NSPoint,size:CGFloat,kind:LampKind,color:NSColor,burnFraction:Float) {
        let s=size/2.75
        let y:CGFloat=kind == .lighter ? 1.04 : kind == .candle ? 1.00-CGFloat(min(0.85,burnFraction))*1.2 : 0.98
        let center=NSPoint(x:p.x,y:p.y+y*s)
        let radius=s*0.55
        let glow=NSBezierPath(ovalIn:NSRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
        NSGradient(starting:color.withAlphaComponent(0.24),ending:color.withAlphaComponent(0))?.draw(in:glow,relativeCenterPosition:.zero)
        let core=NSBezierPath(ovalIn:NSRect(x:center.x-s*0.065,y:center.y-s*0.07,width:s*0.13,height:s*0.26))
        rgb(1,0.95,0.67).withAlphaComponent(0.78).setFill();core.fill()
    }
}
