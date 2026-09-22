import AppKit
import Metal
import Darwin

let MiB: UInt64 = 1_048_576
let GiB: UInt64 = 1_073_741_824
func memoryText(_ bytes:UInt64) -> String {bytes >= GiB ? String(format:"%.2f GB",Double(bytes)/Double(GiB)) : String(format:"%.0f MB",Double(bytes)/Double(MiB))}

// Every mapped byte contains generated, distinct four-channel noise material.
// OS compression/reclamation remains allowed; no wiring or repeated whole-pool scans.
final class NoiseBlock {
    static let bytes = 32 * 1_048_576
    static let tileBytes = 1024 * 1024 * 4
    let pointer:UnsafeMutableRawPointer
    init?() {
        guard let p=mmap(nil,Self.bytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0),p != MAP_FAILED else{return nil}
        pointer=p
    }
    deinit {munmap(pointer,Self.bytes)}
}
final class GenerationTicket {
    private let lock=NSLock()
    private var stopped=false
    private var written:UInt64=0
    var writtenBytes:UInt64 {lock.lock();defer{lock.unlock()};return written}
    func account(_ delta:Int) {lock.lock();written=UInt64(max(0,Int64(written)+Int64(delta)));lock.unlock()}
    var cancelled:Bool {lock.lock();defer{lock.unlock()};return stopped}
    func cancel() {lock.lock();stopped=true;lock.unlock()}
}

struct MemoryDecision {
    var add=0
    var release:UInt64=0
    var reason="观察电脑余量"
    var reserve:UInt64=0
    var target:UInt64=0
    var cause="observing"
}
// A learned ceiling survives ordinary cooldowns. Compression alone is a soft signal:
// trim a small part once, hold, and only probe again after sustained quiet time.
struct MemoryPolicy {
    var previous:MemorySnapshot?
    var previousPool:UInt64=0
    var previousTime:TimeInterval?
    var cooldownUntil:TimeInterval=0
    var burst:Double=0
    var learnedCeiling:UInt64?
    var retainedAfterTrim:UInt64?
    var quietSince:TimeInterval?
    var nextTrimTime:TimeInterval=0
    var lastProbeTime:TimeInterval=0
    var warningSince:TimeInterval?
    mutating func reset(now:TimeInterval) {
        previous=nil;previousPool=0;previousTime=nil;cooldownUntil=now+5;burst=0
        learnedCeiling=nil;retainedAfterTrim=nil;quietSince=nil;nextTrimTime=0;warningSince=nil;lastProbeTime=now
    }
    mutating func decide(_ m:MemorySnapshot,pool:UInt64,now:TimeInterval,cap:UInt64) -> MemoryDecision {
        var out=MemoryDecision()
        let base=max(1536*MiB,m.total*6/100)
        let old=previous,dt=max(0.25,min(10,now-(previousTime ?? now-1)))
        var loss:Double=0
        if let before=old?.reclaimableEstimate,let current=m.reclaimableEstimate {
            loss=max(0,Double(before)+Double(previousPool)-Double(current)-Double(pool))
        }
        burst=max(burst*pow(0.93,dt),loss)
        out.reserve=base+UInt64(min(Double(m.total)/5,burst*2))
        defer {previous=m;previousPool=pool;previousTime=now}
        guard let available=m.reclaimableEstimate,let swap=m.swapPages,let compression=m.compressionPages,m.pressure != "未知" else {
            out.release=pool;out.reason="暂时读不到系统状态，已让出内存";out.cause="unknown"
            cooldownUntil=max(cooldownUntil,now+30);quietSince=nil;return out
        }
        let swapDelta=old?.swapPages.map{swap >= $0 ? swap-$0 : 0} ?? 0
        let compressionDelta=old?.compressionPages.map{compression >= $0 ? compression-$0 : 0} ?? 0
        let page=Double(vm_kernel_page_size)
        let swapRate=Double(swapDelta)*page/dt,compressionRate=Double(compressionDelta)*page/dt
        // Include our committed and in-progress written bytes in the available budget.
        let combined=min(m.total,available+min(pool,m.total))
        let candidate=combined>out.reserve ? combined-out.reserve : 0
        out.target=min(cap,min(candidate,learnedCeiling ?? UInt64.max))
        if m.pressure == "较高" || available < 256*MiB || swapRate>Double(64*MiB) {
            out.release=pool;out.target=0;out.cause="critical"
            out.reason="内存严重紧张，紧急释放"
            learnedCeiling=pool/2;quietSince=nil;warningSince=nil
            cooldownUntil=max(cooldownUntil,now+60);nextTrimTime=now+10;return out
        }
        let warning=m.pressure == "偏高"
        if warning {if warningSince==nil {warningSince=now}} else {warningSince=nil}
        let deficit=available<out.reserve ? out.reserve-available : 0
        let external=loss>Double(256*MiB)
        let activity=compressionRate>Double(64*MiB) || swapRate>Double(8*MiB)
        if warning || activity || deficit>0 || external {
            quietSince=nil
            let severeWarning=warning && now-(warningSince ?? now)>=15
            if severeWarning {
                out.release=pool;out.target=0;out.cause="persistent-warning";out.reason="内存压力持续偏高，紧急释放"
                learnedCeiling=pool/2;cooldownUntil=max(cooldownUntil,now+60);nextTrimTime=now+10;return out
            }
            // External demand can require a larger immediate yield. Isolated compression
            // cannot repeatedly shave the pool to zero once per second.
            let compressionOnly=activity && swapRate<=Double(8*MiB) && !warning && deficit==0 && !external
            let newGrowth=retainedAfterTrim == nil || pool>(retainedAfterTrim ?? 0)+MiB
            if (now>=nextTrimTime && (!compressionOnly || newGrowth)) || deficit>256*MiB || external {
                let ordinary=max(32*MiB,min(256*MiB,pool/10))
                let requested=warning ? max(256*MiB,pool/4) : max(ordinary,max(deficit,external ? UInt64(loss) : 0))
                out.release=min(pool,requested)
                let kept=pool-out.release
                if pool>0 {learnedCeiling=min(learnedCeiling ?? UInt64.max,kept);retainedAfterTrim=kept}
                out.target=min(out.target,kept)
                nextTrimTime=now+(warning ? 5 : 30)
            }
            cooldownUntil=max(cooldownUntil,now+(warning ? 45 : 30))
            out.cause=warning ? "warning" : deficit>0 || external ? "external-demand" : "compression-or-swap"
            out.reason=out.release>0 ? "接近舒适边界，少量退让并记住用量" : "先保持当前用量，观察内存恢复"
            return out
        }
        if quietSince==nil {quietSince=now}
        if now<cooldownUntil {out.cause="cooldown";out.reason="保持当前用量，等待电脑稳定";return out}
        if let ceiling=learnedCeiling,now-(quietSince ?? now)>=120,now-lastProbeTime>=120,available>out.reserve+512*MiB {
            learnedCeiling=min(candidate,ceiling+64*MiB);lastProbeTime=now
            out.target=min(cap,min(candidate,learnedCeiling!))
        }
        if pool>=out.target || out.target-pool<UInt64(NoiseBlock.bytes) {
            out.cause="holding";out.reason=pool>=cap ? "已到本次体验上限" : "已找到当前舒适用量，保持中";return out
        }
        let headroom=available>out.reserve ? available-out.reserve : 0
        let step:UInt64=learnedCeiling == nil && headroom>2*GiB ? 128*MiB : 32*MiB
        out.add=Int(min(step,min(headroom/2,out.target-pool))/UInt64(NoiseBlock.bytes))
        out.cause=out.add>0 ? "growing" : "holding"
        out.reason=out.add>0 ? "正在慢慢靠近目标用量" : "保持当前用量"
        return out
    }
}

// All pool ownership and published state are main-thread confined. Workers only own
// the block being filled and a locked cancellation token. Completion never resurrects
// resources after release because both ticket identity and enabled state are checked.
final class MemoryPlayground {
    private var blocks:[NoiseBlock]=[]
    private var ticket:GenerationTicket?
    private let worker=DispatchQueue(label:"local.xianzhe.materials",qos:.utility)
    private var policy=MemoryPolicy()
    private var pressureSource:DispatchSourceMemoryPressure?
    private var notificationPressure="正常"
    private var tickNumber=0
    private var textureCursor=0
    private var suspended=false
    var enabled=false
    var limit:UInt64=UInt64.max
    private(set) var status="准备好了，随时可以挥霍"
    private(set) var reserve:UInt64=0
    private(set) var target:UInt64=0
    private(set) var cause="idle"
    private var lastTick:TimeInterval=0
    private(set) var material:MTLTexture?
    var onMaterial:((MTLTexture?)->Void)?
    var allocated:UInt64 {UInt64(blocks.count)*UInt64(NoiseBlock.bytes)}
    var textureCount:Int {blocks.count*8}
    var generating:Bool {ticket != nil}
    var inFlightBytes:UInt64 {ticket?.writtenBytes ?? 0}
    init(listenForPressure:Bool=true) {
        if listenForPressure {
            let source=DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical],queue:.main)
            source.setEventHandler { [weak self,weak source] in
                guard let self,let source else{return}
                self.notificationPressure = source.data.contains(.critical) ? "较高" : source.data.contains(.warning) ? "偏高" : "正常"
                if self.notificationPressure == "较高" {self.releaseAll(reason:"系统通知内存严重紧张，紧急释放")}
                else if self.notificationPressure == "偏高" {self.ticket?.cancel();self.ticket=nil}
            }
            source.resume();pressureSource=source
        }
    }
    deinit {ticket?.cancel();pressureSource?.cancel()}
    func start() {enabled=true;lastTick=0;policy.reset(now:ProcessInfo.processInfo.systemUptime);status="先观察 5 秒，再慢慢增加"}
    func stop() {enabled=false;releaseAll(reason:"已停止挥霍，额外内存已释放")}
    func setSuspended(_ value:Bool) {
        guard value != suspended else{return};suspended=value
        if value {releaseAll(reason:"已暂停，额外内存已释放")} else {policy.reset(now:ProcessInfo.processInfo.systemUptime)}
    }
    func releaseAll(reason:String) {
        ticket?.cancel();ticket=nil;blocks.removeAll();material=nil;onMaterial?(nil)
        policy.reset(now:ProcessInfo.processInfo.systemUptime);policy.cooldownUntil=ProcessInfo.processInfo.systemUptime+45
        status=reason;cause="released";target=0
    }
    func tick(_ m:MemorySnapshot,device:MTLDevice?) {
        guard enabled,!suspended else{return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastTick>=0.75 else{return};lastTick=now
        if notificationPressure == "较高" {status="等待系统严重压力恢复";return}
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            releaseAll(reason:"电脑有些热，先歇一会");return
        }
        var observed=m
        if notificationPressure == "偏高",observed.pressure == "正常" {observed.pressure="偏高"}
        let decision=policy.decide(observed,pool:allocated+inFlightBytes,now:now,cap:limit)
        reserve=decision.reserve;target=decision.target;status=decision.reason;cause=decision.cause
        if decision.add==0 {ticket?.cancel();ticket=nil}
        if decision.release > 0 {
            ticket?.cancel();ticket=nil
            let count=min(blocks.count,Int((decision.release+UInt64(NoiseBlock.bytes)-1)/UInt64(NoiseBlock.bytes)))
            blocks.removeLast(count)
            material=nil;onMaterial?(nil)
        } else if decision.add > 0,ticket==nil {generate(decision.add)}
        tickNumber += 1
        if tickNumber%5 == 0,!blocks.isEmpty,let device {publishMaterial(device)}
    }
    private func generate(_ count:Int) {
        let token=GenerationTicket();ticket=token
        worker.async { [weak self] in
            for _ in 0..<count {
                if token.cancelled {break}
                guard let block=NoiseBlock() else {
                    DispatchQueue.main.async {
                        guard let self,self.ticket === token else{return}
                        self.enabled=false;self.releaseAll(reason:"生成失败，已停止并释放内存")
                    };break
                }
                for offset in stride(from:0,to:NoiseBlock.bytes,by:1_048_576) {
                    if token.cancelled {break}
                    arc4random_buf(block.pointer.advanced(by:offset),1_048_576)
                    token.account(1_048_576)
                }
                if token.cancelled {break}
                DispatchQueue.main.async {
                    guard let self,self.ticket === token,self.enabled,!self.suspended,!token.cancelled else{return}
                    token.account(-NoiseBlock.bytes)
                    if self.allocated+UInt64(NoiseBlock.bytes)<=self.limit {self.blocks.append(block)}
                }
            }
            DispatchQueue.main.async { [weak self] in if self?.ticket === token {self?.ticket=nil} }
        }
    }
    private func publishMaterial(_ device:MTLDevice) {
        // Upload one 4 MiB tile every five seconds. The two views share it; pool size
        // never increases the per-frame work. Command buffers retain textures in use.
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1024,height:1024,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:descriptor) else {releaseAll(reason:"图形资源不足，已让出内存");return}
        textureCursor=(textureCursor+1)%textureCount
        let pointer=blocks[textureCursor/8].pointer.advanced(by:(textureCursor%8)*NoiseBlock.tileBytes)
        texture.replace(region:MTLRegionMake2D(0,0,1024,1024),mipmapLevel:0,withBytes:pointer,bytesPerRow:4096)
        material=texture;onMaterial?(texture)
    }
}
