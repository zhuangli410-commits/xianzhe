import AppKit
let root=URL(fileURLWithPath:CommandLine.arguments[1])
func load(_ name:String)->NSBitmapImageRep {NSBitmapImageRep(data:try! Data(contentsOf:root.appendingPathComponent(name+".png")))!}
let a=load("studio-ring-left"),b=load("studio-ring-no-shadow"),c=load("studio-ring-right")
func value(_ image:NSBitmapImageRep,_ x:Int,_ y:Int)->Double {let p=image.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!;return p.redComponent+p.greenComponent+p.blueComponent}
var dark=0,different=0
for y in 0..<640 {for x in 0..<640 {
    if value(b,x,y)-value(a,x,y)>0.18 {dark+=1}
    if abs(value(a,x,y)-value(c,x,y))>0.18 {different+=1}
}}
precondition(dark>10000,"Depth shadow must affect actual output")
precondition(different>10000,"Light motion must change actual output")
let hole=value(a,470,470),solid=value(a,510,570),unshadowed=value(b,470,470)
print("Darkened pixels: \(dark); light-motion changed pixels: \(different); hole \(hole); solid shadow \(solid); no shadow \(unshadowed)")
precondition(hole>solid*1.5,"Projected ring hole remains brighter than solid shadow")
print("PASS: rendered shadow, moving light and transparent hole")

let left=load("desktop-ring-left"),right=load("desktop-ring-right"),clear=load("desktop-ring-clear"),extreme=load("desktop-extreme")
var shadowsOnly=0,clearPixels=0,moved=0
func alpha(_ image:NSBitmapImageRep,_ x:Int,_ y:Int)->Double {image.colorAt(x:x,y:y)!.alphaComponent}
for y in 0..<640 {for x in 0..<640 {
    let a=alpha(left,x,y),b=alpha(clear,x,y)
    if b<0.01 && a>0.05 {shadowsOnly+=1;precondition(a<0.65,"Shadow must be translucent")}
    if a<0.001 {clearPixels+=1}
    if abs(a-alpha(right,x,y))>0.1 {moved+=1}
    if x==0 || y==0 || x==639 || y==639 {precondition(alpha(extreme,x,y)<0.01,"Expanded desktop viewport must not clip the extreme shadow")}
}}
precondition(shadowsOnly>1000 && moved>1000 && clearPixels>300000,"Desktop shadow, motion and transparent backing")
print("PASS: translucent desktop shadow pixels \(shadowsOnly), transparent pixels \(clearPixels), moved alpha pixels \(moved); extreme edges clear")
