import AppKit
import Metal

setbuf(stdout,nil)
let out=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
var messages:[String]=[]
func check(_ good:Bool,_ message:String) {precondition(good,message);messages.append(message);print("PASS: \(message)")}
func sample(_ available:UInt64=10*GiB,total:UInt64=32*GiB,pressure:String="正常",swap:UInt64=0,compression:UInt64=0)->MemorySnapshot {
    MemorySnapshot(total:total,reclaimableEstimate:available,resident:100*MiB,pressure:pressure,footprint:100*MiB,compressed:0,swapPages:swap,compressionPages:compression)
}
var policy=MemoryPolicy()
check(policy.decide(sample(),pool:0,now:100,cap:2*GiB).add==4,"Healthy samples grow gradually")
check(policy.decide(sample(10*GiB-128*MiB),pool:128*MiB,now:101,cap:2*GiB).release==0,"Own written resources do not count as external demand")
let demand=policy.decide(sample(7*GiB),pool:128*MiB,now:102,cap:2*GiB)
check(demand.release==128*MiB,"Real external demand can release a small pool")
check(policy.decide(sample(),pool:0,now:103,cap:2*GiB).add==0,"Cooldown prevents immediate regrowth")
for pressure in ["较高","未知"] {
    var p=MemoryPolicy();check(p.decide(sample(pressure:pressure),pool:GiB,now:100,cap:UInt64.max).release==GiB,"Emergency \(pressure) releases all")
}
var warning=MemoryPolicy()
let warn=warning.decide(sample(pressure:"偏高"),pool:4*GiB,now:100,cap:UInt64.max)
check(warn.release>0 && warn.release<4*GiB,"A warning yields part of a large pool first")
let persistent=warning.decide(sample(pressure:"偏高"),pool:3*GiB,now:116,cap:UInt64.max)
check(persistent.release==3*GiB,"Persistent warning escalates to emergency release")
let page=UInt64(vm_kernel_page_size)
var swapPolicy=MemoryPolicy();_=swapPolicy.decide(sample(),pool:GiB,now:100,cap:UInt64.max)
check(swapPolicy.decide(sample(swap:128*MiB/page),pool:GiB,now:101,cap:UInt64.max).release==GiB,"Severe new swapping still releases all")
var compPolicy=MemoryPolicy();_=compPolicy.decide(sample(),pool:4*GiB,now:100,cap:UInt64.max)
let trim=compPolicy.decide(sample(compression:96*MiB/page),pool:4*GiB,now:101,cap:UInt64.max)
check(trim.release>0 && trim.release<GiB && trim.target>3*GiB,"Compression spike trims a small part and learns a ceiling")
let held=4*GiB-trim.release
for i in 2...180 {
    let d=compPolicy.decide(sample(compression:UInt64(i)*96*MiB/page),pool:held,now:100+Double(i),cap:UInt64.max)
    check(d.release==0 && d.add==0,"Sustained compression alone holds, rather than shaving to zero: \(i)")
}
let recovered=compPolicy.decide(sample(compression:180*96*MiB/page),pool:held,now:281,cap:UInt64.max)
check(recovered.add==0,"After compression ends, the learned ceiling is retained")
let probe=compPolicy.decide(sample(compression:180*96*MiB/page),pool:held,now:402,cap:UInt64.max)
check(probe.target<=held+64*MiB && probe.add<=1,"After quiet time, probe by only 64 MiB of ceiling and one block")
let repeatSignal=compPolicy.decide(sample(compression:181*96*MiB/page),pool:held+64*MiB,now:403,cap:UInt64.max)
check(repeatSignal.release>0 && repeatSignal.release<held,"A fresh compression spike during a later probe learns again without clearing all")
var zero=MemoryPolicy();_=zero.decide(sample(),pool:0,now:100,cap:UInt64.max)
_=zero.decide(sample(compression:96*MiB/page),pool:0,now:101,cap:UInt64.max)
check(zero.learnedCeiling==nil,"Pre-existing compression before allocation does not teach a zero ceiling")
var dtPolicy=MemoryPolicy();_=dtPolicy.decide(sample(),pool:GiB,now:100,cap:UInt64.max)
check(dtPolicy.decide(sample(compression:96*MiB/page),pool:GiB,now:110,cap:UInt64.max).release==0,"Counters are converted to rates across delayed samples")
for total:UInt64 in [8,16,32,64,128,192].map({$0*GiB}) {
    var p=MemoryPolicy();let result=p.decide(sample(total/2,total:total),pool:0,now:100,cap:UInt64.max)
    check(result.add>0 && result.reserve>=1536*MiB && result.target<total/2,"Capacity policy simulation \(total/GiB) GiB")
}
var large=MemoryPolicy();check(large.decide(sample(20*GiB,total:128*GiB),pool:90*GiB,now:100,cap:UInt64.max).add>0,"90 GiB pool remains possible in budget math only")
var missing=MemoryPolicy();let empty=MemorySnapshot(total:32*GiB,reclaimableEstimate:nil,resident:nil,pressure:"正常")
check(missing.decide(empty,pool:GiB,now:100,cap:UInt64.max).release==GiB,"Unavailable counters fail closed")
var bounded=MemoryPolicy();check(bounded.decide(sample(),pool:2*GiB,now:100,cap:2*GiB).add==0,"2 GiB experience cap is preserved")
if CommandLine.arguments.contains("--policy-only") {
    try JSONSerialization.data(withJSONObject:["checks":messages],options:[.prettyPrinted]).write(to:out.appendingPathComponent("policy-tests.json"));exit(0)
}
let monitor=SystemMonitor(),pool=MemoryPlayground()
let device=MTLCreateSystemDefaultDevice()
var materialPublished=false
pool.onMaterial={ texture in
    guard let texture else{return}
    var bytes=[UInt8](repeating:0,count:64*64*4)
    texture.getBytes(&bytes,bytesPerRow:64*4,from:MTLRegionMake2D(0,0,64,64),mipmapLevel:0)
    precondition(Set(bytes).count>200,"Noise texture actually contains varied bytes")
    materialPublished=true
}
func pump(_ seconds:Double) {let end=Date().addingTimeInterval(seconds);while Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.03))}}
func record(_ phase:String)->[String:Any] {
    let m=monitor.sample()
    return ["phase":phase,"timestamp":Date().timeIntervalSince1970,"allocated":pool.allocated,"target":pool.target,"cause":pool.cause,"resident":m.resident ?? 0,"footprint":m.footprint ?? 0,"compressed":m.compressed ?? 0,"pressure":m.pressure,"status":pool.status]
}
var records:[[String:Any]]=[]
for cap:UInt64 in [512,1024,2048].map({$0*MiB}) {
    let baseline=monitor.sample().resident ?? 0
    records.append(record("baseline-\(cap/MiB)"));pool.limit=cap;pool.start()
    let deadline=Date().addingTimeInterval(60)
    var maximum:UInt64=0
    while pool.allocated<cap && Date()<deadline {
        pool.tick(monitor.sample(),device:device);pump(1)
        maximum=max(maximum,pool.allocated)
        let row=record("growing-\(cap/MiB)")
        records.append(row)
        let data=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
        if maximum>0 && pool.allocated==0 {break}
    }
    records.append(record("peak-\(cap/MiB)"))
    let peak=monitor.sample().resident ?? 0
    if pool.allocated==cap {check(true,"Reached bounded \(cap/MiB) MiB checkpoint with real system policy")}
    else {messages.append("DEFERRED target \(cap/MiB) MiB: system policy yielded; maximum \(maximum/MiB) MiB")}
    try JSONSerialization.data(withJSONObject:["checks":messages,"records":records],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("memory-tests.json"))
    if pool.allocated>0 {check(peak>baseline+pool.allocated*7/10,"Resident increase reflects physically written resources at \(pool.allocated/MiB) MiB")}
    pool.stop();pump(2);records.append(record("released-\(cap/MiB)"))
    check(pool.allocated==0 && !pool.generating,"Stop releases pool and generation ticket")
    check((monitor.sample().resident ?? UInt64.max)<baseline+128*MiB,"Resident returns near baseline after \(cap/MiB) MiB release")
}
check(materialPublished,"Pool texture uploaded for actual rendering")
pool.limit=512*MiB;pool.start();pump(5.1);pool.tick(monitor.sample(),device:device);pool.stop();pump(1)
check(pool.allocated==0,"Cancelled worker cannot repopulate released pool")
pool.start();pool.setSuspended(true);pool.tick(monitor.sample(),device:device);pump(1)
check(pool.allocated==0,"Lifecycle suspension inhibits allocation")
pool.stop()
let report:[String:Any]=["checks":messages,"records":records,"machine":monitor.chip,"total":monitor.total]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("memory-tests.json"))
