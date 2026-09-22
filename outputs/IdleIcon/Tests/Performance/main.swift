import Foundation
var count=0
func check(_ ok:Bool,_ name:String) {precondition(ok,name);count+=1;print("PASS: \(name)")}
var b=PerformanceBudget()
func step(_ t:Double,_ mode:Int=1,_ cost:Double?=1,_ pressure:String="正常",_ thermal:Int=0,_ low:Bool=false,_ manual:Int=2)->(Int,Int) {
    b.update(now:t,mode:mode,manual:manual,costMS:cost,pressure:pressure,thermal:thermal,lowPower:low)
}
check(step(0).0==1,"Start at balanced quality")
check(step(19).0==1,"No early promotion")
check(step(20).0==2,"Stable rendering promotes after 20 seconds")
check(step(21,1,30).0==2,"One slow sample does not oscillate quality")
check(step(24,1,30).0==1,"Sustained GPU cost reduces quality")
check(step(25,1,30).0==1,"Cooldown prevents immediate repeated downgrade")
check(step(28,1,30).0==0,"Persistent GPU cost reaches light tier")
check(step(29,1,1,"偏高").1==15,"Memory warning reduces frame target")
check(step(30,1,1,"正常",2).0==0,"Serious thermal state forces light tier")
check(step(31,2,1,"正常",0,true).1==15,"Manual mode respects low-power protection")
check(step(32,1,1,"未知").0==0,"Unreadable pressure fails conservatively")
check(step(33,1,nil).0==0 && step(100,1,nil).0==0,"No promotion from stale or absent GPU samples")
check(step(101).0==0 && step(121).0==1 && step(141).0==2,"Recovery is gradual after stable fresh samples")
check(step(142,0).0==1 && step(142,0).1==30,"Companion mode clamps quality and rate")
check(step(143,2,1,"正常",0,false,0).0==0,"Manual cap is obeyed")
print("\(count) checks passed; policy simulation, not a real thermal stress test")
