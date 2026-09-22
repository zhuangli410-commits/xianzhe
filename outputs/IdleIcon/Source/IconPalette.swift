import AppKit
import simd

struct IconColor:Equatable {
    let rgb:SIMD3<Float>
    var share:Double=0
    var hex:String {String(format:"#%02X%02X%02X",Int((rgb.x*255).rounded()),Int((rgb.y*255).rounded()),Int((rgb.z*255).rounded()))}
    var nsColor:NSColor {NSColor(srgbRed:CGFloat(rgb.x),green:CGFloat(rgb.y),blue:CGFloat(rgb.z),alpha:1)}
    init(_ rgb:SIMD3<Float>,share:Double=0) {self.rgb=simd_clamp(rgb,SIMD3(repeating:0),SIMD3(repeating:1));self.share=share}
    init?(hex:String) {
        let text=hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count==6,let value=UInt32(text,radix:16) else{return nil}
        self.init(SIMD3(Float((value>>16)&255),Float((value>>8)&255),Float(value&255))/255)
    }
    init(_ color:NSColor) {
        let c=color.usingColorSpace(.sRGB) ?? .white
        self.init(SIMD3(Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent)))
    }
}
enum IconPalette {
    // OKLab distances distinguish hue and lightness without grouping white with yellow.
    static func lab(_ c:SIMD3<Float>)->SIMD3<Float> {
        func linear(_ x:Float)->Float {x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4)}
        let r=linear(c.x),g=linear(c.y),b=linear(c.z)
        let l=cbrt(0.41222147*r+0.53633254*g+0.05144599*b)
        let m=cbrt(0.21190350*r+0.68069955*g+0.10739696*b)
        let s=cbrt(0.08830246*r+0.28171884*g+0.62997870*b)
        return SIMD3(0.21045426*l+0.79361779*m-0.00407205*s,1.97799850*l-2.42859221*m+0.45059371*s,0.02590404*l+0.78277177*m-0.80867577*s)
    }
    static func rgb(_ c:SIMD3<Float>)->SIMD3<Float> {
        let l=pow(c.x+0.39633778*c.y+0.21580376*c.z,3)
        let m=pow(c.x-0.10556135*c.y-0.06385417*c.z,3)
        let s=pow(c.x-0.08948418*c.y-1.29148555*c.z,3)
        let linear=SIMD3(4.07674166*l-3.30771159*m+0.23096993*s,-1.26843800*l+2.60975740*m-0.34131940*s,-0.00419609*l-0.70341861*m+1.70761470*s)
        func gamma(_ x:Float)->Float {x<=0.0031308 ? 12.92*x : 1.055*pow(x,1/2.4)-0.055}
        return simd_clamp(SIMD3(gamma(linear.x),gamma(linear.y),gamma(linear.z)),SIMD3(repeating:0),SIMD3(repeating:1))
    }
    static func colors(in cut:CutoutImage)->[IconColor] {
        var histogram:[Int:(SIMD3<Float>,Int)]=[:]
        for i in stride(from:0,to:cut.size*cut.size,by:3) where cut.pixels[i*4+3]>230 {
            let alpha=Float(cut.pixels[i*4+3])
            let c=SIMD3(Float(cut.pixels[i*4]),Float(cut.pixels[i*4+1]),Float(cut.pixels[i*4+2]))/alpha
            let key=Int(c.x*15)<<8 | Int(c.y*15)<<4 | Int(c.z*15)
            let old=histogram[key] ?? (.zero,0);histogram[key]=(old.0+c,old.1+1)
        }
        let bins=histogram.sorted{$0.key<$1.key}.map{(rgb:$0.value.0/Float($0.value.1),count:$0.value.1)}
        guard let first=bins.max(by:{$0.count<$1.count}) else{return []}
        let labs=bins.map{lab($0.rgb)}
        var centers=[lab(first.rgb)]
        while centers.count<5 {
            let distances=labs.map{c in centers.map{simd_distance_squared(c,$0)}.min()!}
            guard let index=bins.indices.max(by:{distances[$0]*sqrt(Float(bins[$0].count)) < distances[$1]*sqrt(Float(bins[$1].count))}),distances[index]>0.0064 else{break}
            centers.append(labs[index])
        }
        var assignment=[Int](repeating:0,count:bins.count)
        for _ in 0..<10 {
            var sums=[SIMD3<Float>](repeating:.zero,count:centers.count),weights=[Int](repeating:0,count:centers.count)
            for i in bins.indices {
                let k=centers.indices.min(by:{simd_distance_squared(labs[i],centers[$0]) < simd_distance_squared(labs[i],centers[$1])})!
                assignment[i]=k;sums[k]+=labs[i]*Float(bins[i].count);weights[k]+=bins[i].count
            }
            for k in centers.indices where weights[k]>0 {centers[k]=sums[k]/Float(weights[k])}
        }
        var sums=[SIMD3<Float>](repeating:.zero,count:centers.count),weights=[Int](repeating:0,count:centers.count)
        for i in bins.indices {sums[assignment[i]]+=bins[i].rgb*Float(bins[i].count);weights[assignment[i]]+=bins[i].count}
        let total=max(1,weights.reduce(0,+))
        return centers.indices.filter{Double(weights[$0])/Double(total)>=0.025}.map{IconColor(sums[$0]/Float(weights[$0]),share:Double(weights[$0])/Double(total))}.sorted{$0.share>$1.share}
    }
    static func recolor(_ cut:CutoutImage,palette:[IconColor],replacements:[String:String])->CutoutImage {
        guard !palette.isEmpty,!replacements.isEmpty else{return cut}
        let centers=palette.map{lab($0.rgb)}
        var targets=[SIMD3<Float>?](repeating:nil,count:palette.count)
        for (hex,newHex) in replacements.sorted(by:{$0.key<$1.key}) {
            guard let source=IconColor(hex:hex),let target=IconColor(hex:newHex) else{continue}
            let sourceLab=lab(source.rgb)
            guard let i=centers.indices.min(by:{simd_distance_squared(sourceLab,centers[$0])<simd_distance_squared(sourceLab,centers[$1])}),simd_distance(sourceLab,centers[i])<0.06 else{continue}
            targets[i]=lab(target.rgb)
        }
        // Several original shades mapped to the same target share one lightness
        // baseline. Per-cluster baselines otherwise create artificial color bands.
        var baselines=centers
        for i in targets.indices where targets[i] != nil {
            let group=targets.indices.filter{j in targets[j] != nil && simd_distance(targets[j]!,targets[i]!)<0.00001}
            var sum=SIMD3<Float>.zero,weight:Float=0
            for j in group {let w=Float(max(0.001,palette[j].share));sum+=centers[j]*w;weight+=w}
            baselines[i]=sum/weight
        }
        var bytes=cut.pixels
        // Quantized lookup avoids running color-space conversion for every repeated pixel.
        var table:[UInt32:SIMD3<Float>]=[:]
        for i in 0..<cut.size*cut.size where bytes[i*4+3]>0 {
            let a=Float(bytes[i*4+3]),c=simd_clamp(SIMD3(Float(bytes[i*4]),Float(bytes[i*4+1]),Float(bytes[i*4+2]))/a,SIMD3(repeating:0),SIMD3(repeating:1))
            let key=UInt32((c.x*255).rounded())<<16 | UInt32((c.y*255).rounded())<<8 | UInt32((c.z*255).rounded())
            let result:SIMD3<Float>
            if let cached=table[key] {result=cached} else {
                let value=lab(c),nearest=centers.indices.min(by:{simd_distance_squared(value,centers[$0]) < simd_distance_squared(value,centers[$1])})!
                if let target=targets[nearest] {
                    // Carry the source's small lighting variations into the target hue.
                    let delta=value-baselines[nearest]
                    result=rgb(target+SIMD3(max(-0.22,min(0.22,delta.x)),delta.y*0.55,delta.z*0.55))
                } else {result=c}
                table[key]=result
            }
            for j in 0..<3 {bytes[i*4+j]=UInt8(max(0,min(a,(result[j]*a).rounded())))}
        }
        return CutoutImage(size:cut.size,pixels:bytes,method:cut.method,retainedFraction:cut.retainedFraction)
    }
}
