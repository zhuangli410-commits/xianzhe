import AppKit
import Vision
import CoreImage
import simd

struct CutoutImage {
    let size: Int
    let pixels: [UInt8] // premultiplied RGBA, row zero is the top of the image
    let method: String
    let retainedFraction: Double
    func cgImage() -> CGImage? {
        guard let provider=CGDataProvider(data:Data(pixels) as CFData) else { return nil }
        return CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}

enum IconCutout {
    static let dimension=768
    static func sourceImage(_ image:NSImage) -> CGImage? {
        var rect=CGRect(x:0,y:0,width:1024,height:1024)
        return image.cgImage(forProposedRect:&rect,context:nil,hints:nil)
    }
    static func raster(_ image:CGImage, size:Int) -> [UInt8] {
        guard let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        let s=min(CGFloat(size)/CGFloat(image.width),CGFloat(size)/CGFloat(image.height))
        let w=CGFloat(image.width)*s, h=CGFloat(image.height)*s
        context.interpolationQuality = .high
        context.draw(image,in:CGRect(x:(CGFloat(size)-w)/2,y:(CGFloat(size)-h)/2,width:w,height:h))
        return Array(UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:size*size*4))
    }
    static func prepare(_ image:CGImage, mode:Int=0) -> CutoutImage {
        let n=dimension, source=raster(image,size:dimension)
        guard source.count == n*n*4 else { return CutoutImage(size:1,pixels:[80,170,130,255],method:"图标读取失败",retainedFraction:1) }
        let original=(0..<n*n).map{Float(source[$0*4+3])/255}
        let originalCount=original.filter{$0>0.5}.count
        var mask=original, method="透明轮廓"
        if mode != 2 {
            // Vision sometimes finds the whole macOS tile, or only a tiny detail.
            // Accept it only if it removes a useful amount without discarding almost everything.
            if mode == 0, let semantic=foregroundMask(image,size:n) {
                let count=semantic.enumerated().filter{$0.element*original[$0.offset]>0.5}.count
                let ratio=Double(count)/Double(max(1,originalCount))
                if ratio>0.20 && ratio<0.84 {
                    mask=zip(original,semantic).map{min($0,$1)}; method="智能抠图"
                }
            }
            if method == "透明轮廓", let removed=removePlate(source,n:n) {
                mask=removed; method="去除底色"
            }
        }
        mask=smoothMask(mask,original:original,n:n)
        let remaining=mask.filter{$0>0.5}.count
        guard remaining>64 else { return normalized(source,mask:original,n:n,method:"保留原始轮廓",fraction:1) }
        return normalized(source,mask:mask,n:n,method:method,fraction:Double(remaining)/Double(max(1,originalCount)))
    }
    // A narrow separable Gaussian suppresses pixel stair-steps without closing holes.
    // Never invent opacity outside the source icon's own alpha coverage.
    static func smoothMask(_ mask:[Float],original:[Float],n:Int)->[Float] {
        let kernel:[Float]=[1,4,6,4,1]
        var horizontal=[Float](repeating:0,count:n*n),out=horizontal
        for y in 0..<n {for x in 0..<n {
            var value:Float=0
            for j in -2...2 {value += mask[y*n+max(0,min(n-1,x+j))]*kernel[j+2]}
            horizontal[y*n+x]=value/16
        }}
        for y in 0..<n {for x in 0..<n {
            var value:Float=0
            for j in -2...2 {value += horizontal[max(0,min(n-1,y+j))*n+x]*kernel[j+2]}
            out[y*n+x]=min(original[y*n+x],value/16)
        }}
        return out
    }
    private static func foregroundMask(_ image:CGImage,size:Int) -> [Float]? {
        do {
            let request=VNGenerateForegroundInstanceMaskRequest()
            let handler=VNImageRequestHandler(cgImage:image)
            try handler.perform([request])
            guard let result=request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer=try result.generateScaledMaskForImage(forInstances:result.allInstances,from:handler)
            let ci=CIImage(cvPixelBuffer:buffer)
            guard let cg=CIContext(options:[.cacheIntermediates:false]).createCGImage(ci,from:ci.extent) else { return nil }
            let bytes=raster(cg,size:size)
            guard bytes.count==size*size*4 else { return nil }
            return (0..<size*size).map{Float(bytes[$0*4])/255}
        } catch { return nil }
    }
    private static func removePlate(_ pixels:[UInt8],n:Int) -> [Float]? {
        let original=(0..<n*n).map{Float(pixels[$0*4+3])/255}
        var minX=n,maxX=0,minY=n,maxY=0
        for y in 0..<n { for x in 0..<n where original[y*n+x]>0.9 { minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y) } }
        guard maxX>minX+30,maxY>minY+30 else { return nil }
        let w=maxX-minX+1,h=maxY-minY+1
        func color(_ x:Int,_ y:Int) -> SIMD3<Float> {
            let i=(y*n+x)*4,a=max(1,Float(pixels[i+3]))
            return SIMD3(Float(pixels[i])/a,Float(pixels[i+1])/a,Float(pixels[i+2])/a)
        }
        let lx=minX+w/12,rx=maxX-w/12
        var pairs:[(SIMD3<Float>,SIMD3<Float>)]=[]
        for y in (minY+h/5)...(maxY-h/5) { pairs.append((color(lx,y),color(rx,y))) }
        // A two-color logo such as Finder is itself a symbol, not a uniform removable plate.
        let meanDifference=pairs.reduce(Float(0)){$0+simd_length($1.0-$1.1)}/Float(pairs.count)
        guard meanDifference<0.40 else { return nil }
        var mask=[Float](repeating:0,count:n*n)
        for y in minY...maxY {
            let sy=max(minY+h/5,min(maxY-h/5,y))
            let left=color(lx,sy),right=color(rx,sy)
            for x in minX...maxX {
                let mix=Float(x-lx)/Float(rx-lx)
                let background=left+(right-left)*max(0,min(1,mix))
                let distance=simd_length(color(x,y)-background)
                // Ignore the original plate's bevel, which differs from its flat background.
                let edge=min(min(x-minX,maxX-x),min(y-minY,maxY-y))
                let a=max(0,min(1,(distance-0.20)/0.10))
                mask[y*n+x]=edge>w/24 ? min(original[y*n+x],a) : 0
            }
        }
        // Remove specks; preserve separate meaningful pieces of a logo.
        var visited=[Bool](repeating:false,count:n*n),components:[[Int]]=[]
        for i in 0..<n*n where !visited[i] && mask[i]>0.5 {
            var stack=[i],component:[Int]=[];visited[i]=true
            while let j=stack.popLast() {
                component.append(j);let x=j%n,y=j/n
                for (xx,yy) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where xx>=0 && xx<n && yy>=0 && yy<n {
                    let k=yy*n+xx
                    if !visited[k] && mask[k]>0.5 {visited[k]=true;stack.append(k)}
                }
            }
            components.append(component)
        }
        let largest=components.map{$0.count}.max() ?? 0
        for c in components {
            let cx=Double(c.reduce(0){$0+$1%n})/Double(c.count),cy=Double(c.reduce(0){$0+$1/n})/Double(c.count)
            let cornerX=cx<Double(minX)+Double(w)*0.20 || cx>Double(maxX)-Double(w)*0.20
            let cornerY=cy<Double(minY)+Double(h)*0.20 || cy>Double(maxY)-Double(h)*0.20
            // Uniform macOS plates can leave detached bevel scraps in their corners.
            // Keep small central logo details; this applies only to plate removal.
            let bevelFragment=cornerX && cornerY && c.count<largest/12
            if c.count<max(25,largest/100) || bevelFragment {for i in c {mask[i]=0}}
        }
        // A predominantly solid object (calculator / compass face) keeps its interior
        // painted details. Sparse logos (knots / gears) keep their real negative space.
        let foreground=(0..<n*n).filter{mask[$0]>0.5}
        let fx=foreground.map{$0%n},fy=foreground.map{$0/n}
        let boxArea=max(1,((fx.max() ?? 0)-(fx.min() ?? 0)+1)*((fy.max() ?? 0)-(fy.min() ?? 0)+1))
        let solidObject=Double(foreground.count)/Double(boxArea)>0.62
        // Fill small surface details, but preserve larger interior holes in sparse logos.
        visited=[Bool](repeating:false,count:n*n)
        for i in 0..<n*n where !visited[i] && mask[i]<=0.5 {
            var stack=[i],hole:[Int]=[];visited[i]=true;var exterior=false
            while let j=stack.popLast() {
                hole.append(j);let x=j%n,y=j/n
                if x==0 || y==0 || x==n-1 || y==n-1 { exterior=true }
                for (xx,yy) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where xx>=0 && xx<n && yy>=0 && yy<n {
                    let k=yy*n+xx
                    if !visited[k] && mask[k]<=0.5 {visited[k]=true;stack.append(k)}
                }
            }
            if !exterior && (solidObject || hole.count<max(12,largest/250)) {for j in hole {mask[j]=original[j]}}
        }
        let originalCount=original.filter{$0>0.5}.count, remaining=mask.filter{$0>0.5}.count
        let ratio=Double(remaining)/Double(max(1,originalCount))
        return ratio>0.08 && ratio<0.86 ? mask : nil
    }
    private static func normalized(_ source:[UInt8],mask:[Float],n:Int,method:String,fraction:Double) -> CutoutImage {
        var cut=[UInt8](repeating:0,count:source.count)
        var minX=n,maxX=0,minY=n,maxY=0
        for y in 0..<n {for x in 0..<n {
            let i=y*n+x,a=max(0,min(1,mask[i]))
            if a>0.5 {minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)}
            var colorIndex=i
            if a>0 && a<0.98 {
                let dx=mask[y*n+min(n-1,x+2)]-mask[y*n+max(0,x-2)]
                let dy=mask[min(n-1,y+2)*n+x]-mask[max(0,y-2)*n+x]
                let length=hypot(dx,dy)
                if length>0.001 {
                    let xx=max(0,min(n-1,Int((Float(x)+dx/length*4).rounded())))
                    let yy=max(0,min(n-1,Int((Float(y)+dy/length*4).rounded())))
                    if mask[yy*n+xx]>0.98 {colorIndex=yy*n+xx}
                }
            }
            let colorAlpha=max(1,Float(source[colorIndex*4+3]))/255
            for c in 0..<3 {cut[i*4+c]=UInt8(max(0,min(255,Float(source[colorIndex*4+c])/colorAlpha*a)))}
            cut[i*4+3]=UInt8(a*255)
        }}
        guard maxX>=minX,maxY>=minY else {return CutoutImage(size:n,pixels:source,method:"原始轮廓",retainedFraction:1)}
        let raw=CutoutImage(size:n,pixels:cut,method:method,retainedFraction:fraction)
        let crop=CGRect(x:max(0,minX-2),y:max(0,minY-2),width:min(n-minX,maxX-minX+5),height:min(n-minY,maxY-minY+5))
        guard let image=raw.cgImage()?.cropping(to:crop),let context=CGContext(data:nil,width:n,height:n,bitsPerComponent:8,bytesPerRow:n*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return raw}
        let factor=CGFloat(n-16)/CGFloat(max(image.width,image.height)),w=CGFloat(image.width)*factor,h=CGFloat(image.height)*factor
        context.interpolationQuality = .high
        context.draw(image,in:CGRect(x:(CGFloat(n)-w)/2,y:(CGFloat(n)-h)/2,width:w,height:h))
        let bytes=Array(UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:n*n*4))
        return CutoutImage(size:n,pixels:bytes,method:method,retainedFraction:fraction)
    }
}
