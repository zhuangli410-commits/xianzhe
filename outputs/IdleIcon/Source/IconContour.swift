import AppKit
import simd

// Joined closed contours, resampled uniformly before smoothing. The same contours
// drive both the face alpha and walls, avoiding cracks between two different shapes.
enum IconContour {
    static func loops(_ cut:CutoutImage)->[[SIMD2<Float>]] {
        let n=cut.size
        func a(_ x:Int,_ y:Int)->Float {Float(cut.pixels[(y*n+x)*4+3])/255}
        let pairs:[[(Int,Int)]]=[[],[(3,0)],[(0,1)],[(3,1)],[(1,2)],[(3,0),(1,2)],[(0,2)],[(3,2)],[(2,3)],[(0,2)],[(0,1),(2,3)],[(1,2)],[(1,3)],[(0,1)],[(3,0)],[]]
        var points:[Int:SIMD2<Float>]=[:],neighbors:[Int:[Int]]=[:]
        for y in 0..<n-1 {for x in 0..<n-1 {
            let values=[a(x,y),a(x+1,y),a(x+1,y+1),a(x,y+1)]
            var mask=0;for i in 0..<4 where values[i]>=0.5 {mask |= 1<<i}
            if mask==0 || mask==15 {continue}
            let corners:[SIMD2<Float>]=[SIMD2(Float(x),Float(y)),SIMD2(Float(x+1),Float(y)),SIMD2(Float(x+1),Float(y+1)),SIMD2(Float(x),Float(y+1))]
            let ids=[y*n+x,n*n+y*n+x+1,(y+1)*n+x,n*n+y*n+x]
            for (e1,e2) in pairs[mask] {
                for e in [e1,e2] where points[ids[e]]==nil {
                    let j=(e+1)%4,d=values[j]-values[e],t=abs(d)<0.00001 ? 0.5 : (0.5-values[e])/d
                    points[ids[e]]=(corners[e]+(corners[j]-corners[e])*t+SIMD2(repeating:0.5))/Float(n)
                }
                neighbors[ids[e1],default:[]].append(ids[e2]);neighbors[ids[e2],default:[]].append(ids[e1])
            }
        }}
        var seen=Set<Int>(),result:[[SIMD2<Float>]]=[]
        for start in points.keys.sorted() where !seen.contains(start) {
            var ids:[Int]=[],previous = -1,current=start,closed=false
            while !seen.contains(current),let linked=neighbors[current],linked.count==2 {
                ids.append(current);seen.insert(current)
                let next=linked[0]==previous ? linked[1] : linked[0]
                previous=current;current=next
                if current==start {closed=true;break}
            }
            guard closed,ids.count>=4 else{continue}
            let path=ids.compactMap{points[$0]}
            let perimeter=path.indices.reduce(Float(0)){$0+simd_distance(path[$1],path[($1+1)%path.count])}
            guard perimeter*Float(n)>5 else{continue}
            let count=max(8,Int(ceil(perimeter*Float(n)/1.5))),step=perimeter/Float(count)
            var uniform:[SIMD2<Float>]=[],edge=0,startLength:Float=0
            for i in 0..<count {
                let distance=Float(i)*step
                while edge<path.count-1 && startLength+simd_distance(path[edge],path[(edge+1)%path.count])<distance {
                    startLength += simd_distance(path[edge],path[(edge+1)%path.count]);edge+=1
                }
                let p=path[edge],q=path[(edge+1)%path.count],t=(distance-startLength)/max(0.0000001,simd_distance(p,q))
                uniform.append(p+(q-p)*max(0,min(1,t)))
            }
            // Taubin passes remove staircase noise with little net shrinkage.
            for _ in 0..<12 {for weight:Float in [0.5,-0.52] {
                let old=uniform
                for i in uniform.indices {uniform[i]=old[i]+((old[(i+count-1)%count]+old[(i+1)%count])*0.5-old[i])*weight}
            }}
            result.append(uniform)
        }
        return result
    }
    static func applying(_ paths:[[SIMD2<Float>]],to cut:CutoutImage)->CutoutImage {
        guard !paths.isEmpty else{return cut}
        let n=cut.size
        var edges:[(SIMD2<Float>,SIMD2<Float>)]=[]
        for path in paths {for i in path.indices {edges.append((path[i]*Float(n),path[(i+1)%path.count]*Float(n)))}}
        var alpha=[Float](repeating:0,count:n*n)
        // Four vertical samples plus exact horizontal span coverage; even-odd fill
        // preserves all holes and disjoint pieces without relying on winding order.
        for y in 0..<n {for sample in 0..<4 {
            let line=Float(y)+(Float(sample)+0.5)/4
            var crossings:[Float]=[]
            for (p,q) in edges where (p.y<=line && q.y>line) || (q.y<=line && p.y>line) {
                crossings.append(p.x+(q.x-p.x)*(line-p.y)/(q.y-p.y))
            }
            crossings.sort()
            for i in stride(from:0,to:crossings.count-1,by:2) where crossings.count>1 {
                let left=max(0,crossings[i]),right=min(Float(n),crossings[i+1])
                guard right>left else{continue}
                let first=max(0,min(n-1,Int(floor(left)))),last=max(0,min(n-1,Int(ceil(right))))
                for x in first...last {alpha[y*n+x] += max(0,min(right,Float(x+1))-max(left,Float(x)))/4}
            }
        }}
        var bytes=cut.pixels
        for i in 0..<n*n {
            let old=Float(cut.pixels[i*4+3])/255,new=max(0,min(1,alpha[i]))
            var color=SIMD3<Float>.zero
            if old>0.02 {color=SIMD3(Float(cut.pixels[i*4]),Float(cut.pixels[i*4+1]),Float(cut.pixels[i*4+2]))/(255*old)}
            else if new>0 {
                // A smoothed path can move a fraction of a pixel outside old coverage.
                // Pull edge color from its nearest opaque neighbor, never a black border.
                let x=i%n,y=i/n
                search: for radius in 1...3 {for dy in -radius...radius {for dx in -radius...radius {
                    let xx=x+dx,yy=y+dy
                    guard xx>=0,xx<n,yy>=0,yy<n else{continue}
                    let j=yy*n+xx,a=Float(cut.pixels[j*4+3])
                    if a>200 {color=SIMD3(Float(cut.pixels[j*4]),Float(cut.pixels[j*4+1]),Float(cut.pixels[j*4+2]))/a;break search}
                }}}
            }
            for c in 0..<3 {bytes[i*4+c]=UInt8(max(0,min(255,(color[c]*new*255).rounded())))}
            bytes[i*4+3]=UInt8((new*255).rounded())
        }
        return CutoutImage(size:n,pixels:bytes,method:cut.method,retainedFraction:cut.retainedFraction)
    }
}
