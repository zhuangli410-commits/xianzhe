import Foundation

// Pure policy: one update per sampled interval, monotonic time in seconds.
// Input cost is the sum of recent per-frame GPU times for visible animated views.
struct PerformanceBudget {
    var level=1
    private var stableSince:Double?
    private var slowCount=0
    private var lastChange:Double = -100
    private(set) var reason="正在观察运行情况"
    mutating func update(now:Double,mode:Int,manual:Int,costMS:Double?,pressure:String,thermal:Int,lowPower:Bool)->(Int,Int) {
        let ceiling=mode==0 ? 1 : mode==1 ? 2 : max(0,min(2,manual))
        let limited=pressure != "正常" || thermal>=2 || lowPower
        let budget=mode==0 ? 5.0 : 11.0
        if limited {
            level=0;stableSince=nil;slowCount=0;lastChange=now
            reason=thermal>=2 ? "温度状态偏高，已退让" : lowPower ? "低电量模式，已退让" : "内存压力升高或不可读，已退让"
        } else if let cost=costMS,cost>budget {
            stableSince=nil;slowCount+=1;reason="绘制耗时较高，正在观察"
            if slowCount>=2 && now-lastChange>=3 {level=max(0,level-1);lastChange=now;slowCount=0;reason="绘制耗时较高，已降低画质"}
        } else {
            slowCount=0
            if let cost=costMS,cost<budget*0.65 {
                if stableSince==nil {stableSince=now}
                if now-(stableSince ?? now)>=20 && now-lastChange>=20 && level<ceiling {level+=1;lastChange=now;stableSince=now}
                reason=level<ceiling ? "运行稳定，逐步提高画质" : "按当前预算绘制"
            } else {stableSince=nil;reason=costMS==nil ? "静止时不增加计算量" : "保持当前画质"}
        }
        level=min(level,ceiling)
        let fps=limited ? 15 : mode==0 ? 30 : level==0 ? 30 : 60
        return (level,fps)
    }
}

// A separate dial for real per-pixel lighting work. GPU time is a feedback
// signal, not a claim that we know the machine's unused GPU percentage.
struct LightingWorkBudget {
    private(set) var level=1
    private var stableSince:Double?
    private var slowCount=0
    private var lastChange:Double = -100
    private(set) var reason="正在观察绘制余量"
    mutating func update(now:Double,mode:Int,manual:Int,costMS:Double?,pressure:String,thermal:Int,lowPower:Bool)->Int {
        let ceiling=mode==0 ? 2 : mode==1 ? 4 : [0,2,4][max(0,min(2,manual))]
        if pressure != "正常" || thermal>=2 || lowPower {
            level=0;stableSince=nil;slowCount=0;lastChange=now
            reason="系统需要资源，已降低光影计算"
            return level
        }
        level=min(level,ceiling)
        guard let cost=costMS,cost.isFinite,cost>0 else {
            stableSince=nil;reason="等待新的 GPU 数据";return level
        }
        let target=mode==0 ? 5.0 : 11.0
        if cost>target {
            stableSince=nil;slowCount+=1;reason="绘制较慢，正在减轻计算"
            if slowCount>=2 && now-lastChange>=3 {
                level=max(0,level-1);lastChange=now;slowCount=0
            }
        } else {
            slowCount=0
            if cost<target*0.62 {
                if stableSince==nil {stableSince=now}
                if now-(stableSince ?? now)>=8 && now-lastChange>=8 && level<ceiling {
                    level+=1;lastChange=now;stableSince=now
                }
                reason=level<ceiling ? "有绘制余量，逐步增加光影采样" : "当前模式已到光影上限"
            } else {stableSince=nil;reason="保持当前光影强度"}
        }
        return level
    }
}
