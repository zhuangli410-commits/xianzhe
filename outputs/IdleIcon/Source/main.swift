import AppKit
import MetalKit
import simd
import UniformTypeIdentifiers

private let mint=NSColor(srgbRed:0.74,green:0.69,blue:1.0,alpha:1)
private let muted=NSColor(srgbRed:0.60,green:0.61,blue:0.66,alpha:1)
func label(_ text:String,size:CGFloat,color:NSColor = .white,weight:NSFont.Weight = .regular) -> NSTextField {
    let l=NSTextField(labelWithString:text);l.font = .systemFont(ofSize:size,weight:weight);l.textColor=color;l.lineBreakMode = .byTruncatingTail;return l
}
func place(_ view:NSView,in parent:NSView,_ frame:NSRect) {view.frame=frame;parent.addSubview(view)}
final class Backdrop:NSView {
    override var isOpaque:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(srgbRed:0.055,green:0.057,blue:0.071,alpha:1).setFill();bounds.fill()
        NSGradient(colors:[NSColor(srgbRed:0.20,green:0.15,blue:0.34,alpha:0.23),.clear])!.draw(fromCenter:NSPoint(x:150,y:500),radius:10,toCenter:NSPoint(x:150,y:500),radius:650,options:[])
    }
}
final class Card:NSView {
    override init(frame:NSRect) {super.init(frame:frame);wantsLayer=true;layer?.backgroundColor=NSColor.white.withAlphaComponent(0.035).cgColor;layer?.cornerRadius=17;layer?.borderWidth=1;layer?.borderColor=NSColor.white.withAlphaComponent(0.07).cgColor}
    required init?(coder:NSCoder) {fatalError()}
}
final class OverlayPanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
    // Expanded transparent margins may lie offscreen; do not move the icon to fit them.
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?)->NSRect {frameRect}
}

final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let monitor=SystemMonitor(),tracker=AppTracker(),clock=RotationClock()
    let playground=MemoryPlayground()
    var poolLabel:NSTextField!,poolDetail:NSTextField!,poolStatus:NSTextField!,poolButton:NSButton!,poolMode:NSPopUpButton!,poolMenu:NSMenuItem!
    var historyView:MemoryHistory!
    var qaLimit:UInt64?
    var baseAsset:RenderAsset?
    var lightX=UserDefaults.standard.object(forKey:"lightX") as? Float ?? -2
    var lightY=UserDefaults.standard.object(forKey:"lightY") as? Float ?? 2.5
    var lightZ=UserDefaults.standard.object(forKey:"lightZ") as? Float ?? 4
    var lightPanel:NSPanel?,lightPad:LightPositionPad?
    var lightPositionSliders:[NSSlider]=[]
    var quickPower:NSSlider?,quickColor:NSPopUpButton?
    var lightPower=UserDefaults.standard.object(forKey:"lightPower") as? Float ?? 1
    var lightHex=UserDefaults.standard.string(forKey:"lightHex") ?? "#FFECD4"
    var performanceMode=UserDefaults.standard.integer(forKey:"performanceMode")
    var manualQuality=UserDefaults.standard.object(forKey:"manualQuality") as? Int ?? 2
    var budget=PerformanceBudget()
    var performanceLabel:NSTextField?,lightPadLabel:NSTextField?
    var lightPreset:NSPopUpButton?
    var lightPowerSlider:NSSlider?,lightColorWell:NSColorWell?,performancePopup:NSPopUpButton?,qualityPopup:NSPopUpButton?
    var lastGPUSamples=0
    var inspector:NSWindow?,inspectorRenderer:IconRenderer?,inspectorView:InspectorCanvas?
    var finishPopup:NSPopUpButton?,thicknessSlider:NSSlider?,inspectionAuto:NSButton?,inspectionAngle:NSSlider?
    var finishIndex=1,bodyThickness:Float=1
    var renderers:[IconRenderer] {[previewRenderer,floatingRenderer,inspectorRenderer].compactMap{$0}}
    var colorPopup:NSPopUpButton!,colorWell:NSColorWell!,paletteInfo:NSTextField!
    var colorApply:NSButton!,colorReset:NSButton!,colorPresets:[NSButton]=[]
    let paintQueue=OperationQueue()
    var paintID=UUID()
    let presetColors=["#B8A5FF","#65D6AA","#FFB56B","#70B5FF"]
    let presetNames=["浅紫","薄荷","暖橙","天蓝"]
    let processor=OperationQueue()
    var requestID=UUID()
    var source:CGImage?
    var cache:[String:RenderAsset]=[:],cacheKeys:[String]=[]
    var appKey="fallback"
    var method="正在读取图标…"
    var panel:NSWindow!,overlay:OverlayPanel!,status:NSStatusItem!
    var canvas:DesktopCanvas!,preview:MTKView!,floating:MTKView!
    var previewRenderer:IconRenderer!,floatingRenderer:IconRenderer!
    var nameLabel:NSTextField!,methodLabel:NSTextField!,positionLabel:NSTextField!
    var availableLabel:NSTextField!,residentLabel:NSTextField!,pressureLabel:NSTextField!
    var sizeValue:NSTextField!,speedValue:NSTextField!,original:NSImageView!
    var playButton:NSButton!,visibilityButton:NSButton!,toggleItem:NSMenuItem!,overlayItem:NSMenuItem!
    var sizeSlider:NSSlider!,speedSlider:NSSlider!,cutoutPopup:NSPopUpButton!,screenPopup:NSPopUpButton!
    var timer:Timer?,lifecycleObservers:[NSObjectProtocol]=[]
    var paused=false,overlayVisible=true,sleeping=false
    var position=NSPoint(x:0.75,y:0.25),iconSide:CGFloat=300,cutoutMode=0
    var selectedScreenID:UInt32=0
    var qaDir:URL?,fixtureURL:URL?
    let qaQueue=DispatchQueue(label:"local.xianzhe.diagnostics",qos:.utility)
    var qaBusy=false,qaCommands=false
    var appHistory:[[String:String]]=[]
    var device:MTLDevice!
    var screen:NSScreen {NSScreen.screens.first{displayID($0)==selectedScreenID} ?? NSScreen.main ?? NSScreen.screens[0]}
    func displayID(_ screen:NSScreen)->UInt32 {(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0}
    func applicationDidFinishLaunching(_ notification:Notification) {
        let args=CommandLine.arguments
        qaCommands=args.contains("--qa-commands")
        if let i=args.firstIndex(of:"--qa-dir"),args.indices.contains(i+1) {qaDir=URL(fileURLWithPath:args[i+1]);try? FileManager.default.createDirectory(at:qaDir!,withIntermediateDirectories:true)}
        if let i=args.firstIndex(of:"--icon-fixture"),args.indices.contains(i+1) {fixtureURL=URL(fileURLWithPath:args[i+1])}
        if let i=args.firstIndex(of:"--memory-limit-mib"),args.indices.contains(i+1),let value=UInt64(args[i+1]),value<=8192 {qaLimit=value*MiB;playground.limit=value*MiB}
        guard let gpu=MTLCreateSystemDefaultDevice(),!NSScreen.screens.isEmpty else {fail("这台 Mac 暂时无法启动图形预览。");return};device=gpu
        paintQueue.maxConcurrentOperationCount=1;paintQueue.qualityOfService = .userInitiated
        processor.maxConcurrentOperationCount=1;processor.qualityOfService = .userInitiated
        let d=UserDefaults.standard
        finishIndex=max(0,min(2,d.object(forKey:"finishIndex") == nil ? 1 : d.integer(forKey:"finishIndex")))
        bodyThickness=d.object(forKey:"bodyThickness") == nil ? 1 : max(0.4,min(2.5,d.float(forKey:"bodyThickness")))
        if d.object(forKey:"positionX") != nil {position=DesktopPlacement.clamped(NSPoint(x:d.double(forKey:"positionX"),y:d.double(forKey:"positionY")))}
        if d.object(forKey:"iconSide") != nil {iconSide=max(120,min(600,d.double(forKey:"iconSide")))}
        if d.object(forKey:"rotationSpeed") != nil {clock.speed=max(0,min(4,d.double(forKey:"rotationSpeed")))}
        selectedScreenID=UInt32(clamping:d.integer(forKey:"screenID"))
        do {try buildPanel();try buildOverlay();buildMenu()} catch {fail("图形预览未能启动：\(error.localizedDescription)");return}
        // Legacy noise allocation is intentionally disabled in the visual review build.
        tracker.onChange={ [weak self] app in guard self?.fixtureURL==nil else{return};self?.updateApp(app) }
        tracker.start()
        if let url=fixtureURL,let image=NSImage(contentsOf:url) {appKey="fixture";nameLabel.stringValue="图标素材测试";original.image=image;source=IconCutout.sourceImage(image);prepareIcon()}
        else if tracker.current==nil {source=IconCutout.sourceImage(imageForApp(nil));nameLabel.stringValue="切换一个应用试试";prepareIcon()}
        let nc=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.screensDidSleepNotification] {nc.addObserver(self,selector:#selector(sleepNow),name:name,object:nil)}
        for name in [NSWorkspace.didWakeNotification,NSWorkspace.screensDidWakeNotification] {nc.addObserver(self,selector:#selector(wakeNow),name:name,object:nil)}
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        for (name,asleep) in [("com.apple.screenIsLocked",true),("com.apple.screenIsUnlocked",false)] {
            lifecycleObservers.append(DistributedNotificationCenter.default().addObserver(forName:Notification.Name(name),object:nil,queue:.main) { [weak self] _ in self?.sleeping=asleep;self?.applyPlayback() })
        }
        timer=Timer(timeInterval:1,target:self,selector:#selector(sample),userInfo:nil,repeats:true);RunLoop.main.add(timer!,forMode:.common)
        applyLight(save:false);applyFinish();screensChanged();sample();showPanel()
    }
    func fail(_ message:String) {let a=NSAlert();a.messageText="闲着暂时无法启动";a.informativeText=message;a.runModal();NSApp.terminate(nil)}
    func buildPanel() throws {
        panel=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:950),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        panel.title="闲着 · 桌面实验室";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.isReleasedWhenClosed=false;panel.delegate=self;panel.appearance=NSAppearance(named:.darkAqua)
        let root=Backdrop(frame:NSRect(x:0,y:0,width:1000,height:950));panel.contentView=root
        place(label("闲着",size:32,weight:.semibold),in:root,NSRect(x:30,y:767,width:100,height:43))
        place(label("给空余内存，一点无用的快乐。",size:13,color:muted),in:root,NSRect(x:33,y:741,width:500,height:22))
        let badge=Card(frame:NSRect(x:818,y:778,width:152,height:30));root.addSubview(badge)
        place(label("✦  桌面光影 / 0.6.1",size:11,color:mint,weight:.medium),in:badge,NSRect(x:13,y:6,width:132,height:19))
        place(label("桌面预览",size:12,weight:.medium),in:root,NSRect(x:33,y:707,width:200,height:21))
        screenPopup=NSPopUpButton(frame:NSRect(x:397,y:705,width:245,height:26));screenPopup.target=self;screenPopup.action=#selector(selectScreen);root.addSubview(screenPopup)
        canvas=DesktopCanvas(frame:NSRect(x:30,y:369,width:612,height:330));root.addSubview(canvas)
        preview=MTKView(frame:.zero,device:device);canvas.install(preview)
        previewRenderer=try IconRenderer(view:preview,device:device,clock:clock);previewRenderer.transparentShadow=true;previewRenderer.viewportPadding=Float(IconRenderer.desktopPadding)
        canvas.onMove={ [weak self] point in self?.position=point;self?.savePlacement();self?.reposition() }
        let controls=Card(frame:NSRect(x:660,y:350,width:310,height:349));root.addSubview(controls)
        original=NSImageView(frame:NSRect(x:18,y:287,width:44,height:44));original.imageScaling = .scaleProportionallyUpOrDown;controls.addSubview(original)
        nameLabel=label("正在读取…",size:23,weight:.medium);place(nameLabel,in:controls,NSRect(x:73,y:301,width:210,height:31))
        methodLabel=label("正在抠图…",size:11,color:mint);place(methodLabel,in:controls,NSRect(x:75,y:279,width:212,height:20))
        place(label("大小",size:13,weight:.medium),in:controls,NSRect(x:20,y:231,width:85,height:21))
        sizeValue=label("100%",size:13,color:mint);sizeValue.alignment = .right;place(sizeValue,in:controls,NSRect(x:183,y:231,width:88,height:21))
        sizeSlider=NSSlider(value:Double(iconSide/3),minValue:40,maxValue:200,target:self,action:#selector(changeSize(_:)));sizeSlider.isContinuous=true;sizeSlider.setAccessibilityLabel("图标大小，百分比")
        place(sizeSlider,in:controls,NSRect(x:18,y:202,width:257,height:25))
        place(label("旋转速度",size:13,weight:.medium),in:controls,NSRect(x:20,y:163,width:115,height:21))
        speedValue=label("1.0×",size:13,color:mint);speedValue.alignment = .right;place(speedValue,in:controls,NSRect(x:183,y:163,width:88,height:21))
        speedSlider=NSSlider(value:clock.speed,minValue:0,maxValue:4,target:self,action:#selector(changeSpeed(_:)));speedSlider.isContinuous=true;speedSlider.setAccessibilityLabel("旋转速度，0 到 4 倍")
        place(speedSlider,in:controls,NSRect(x:18,y:134,width:257,height:25))
        place(label("静止",size:10,color:muted),in:controls,NSRect(x:20,y:111,width:65,height:18))
        let fast=label("快转",size:10,color:muted);fast.alignment = .right;place(fast,in:controls,NSRect(x:207,y:111,width:64,height:18))
        place(label("抠图方式",size:12,color:muted),in:controls,NSRect(x:20,y:72,width:70,height:21))
        cutoutPopup=NSPopUpButton(frame:NSRect(x:106,y:68,width:168,height:28));cutoutPopup.addItems(withTitles:["智能抠图","去除底色","原始轮廓"]);cutoutPopup.target=self;cutoutPopup.action=#selector(changeCutout);controls.addSubview(cutoutPopup)
        let inspect=NSButton(title:"灯光摄影棚",target:self,action:#selector(showInspector));inspect.bezelStyle = .rounded;place(inspect,in:controls,NSRect(x:18,y:22,width:163,height:33))
        let quick=NSButton(title:"桌面调光",target:self,action:#selector(showLightPanel));quick.bezelStyle = .rounded;place(quick,in:controls,NSRect(x:186,y:22,width:96,height:33))
        positionLabel=label("拖动图标，位置实时同步",size:10,color:muted);place(positionLabel,in:root,NSRect(x:33,y:340,width:470,height:20))
        let center=NSButton(title:"居中",target:self,action:#selector(centerIcon));center.bezelStyle = .rounded;place(center,in:root,NSRect(x:573,y:335,width:70,height:28))
        let titles=["芯片","总内存","可回收余量 · 估算","程序内存负担"]
        var values:[NSTextField]=[]
        for i in 0..<4 {
            let card=Card(frame:NSRect(x:30+CGFloat(i)*239,y:242,width:223,height:78));root.addSubview(card)
            place(label(titles[i],size:11,color:muted),in:card,NSRect(x:16,y:47,width:192,height:18))
            let value=label("—",size:23,weight:.medium);place(value,in:card,NSRect(x:15,y:12,width:194,height:32));values.append(value)
        }
        values[0].stringValue=monitor.chip;values[1].stringValue="\(monitor.total/GiB) GB";availableLabel=values[2];residentLabel=values[3]
        availableLabel.toolTip="空闲页 + 非活跃页的估算，不是保证可申请额度。界面 GB 按 1024³ 字节。"
        residentLabel.toolTip="macOS 的进程内存负担 phys_footprint，含压缩部分；不是当前实际驻留量。悬停底部状态可看驻留与压缩。"
        let memory=Card(frame:NSRect(x:30,y:74,width:940,height:150));root.addSubview(memory)
        place(label("视觉资源 · 重建中",size:12,color:mint,weight:.medium),in:memory,NSRect(x:20,y:113,width:230,height:21))
        poolLabel=label("0 MB",size:34,weight:.medium);place(poolLabel,in:memory,NSRect(x:18,y:60,width:260,height:48))
        poolDetail=label("0 份噪声纹理 · 等待开始",size:11,color:muted);place(poolDetail,in:memory,NSRect(x:22,y:35,width:330,height:21))
        poolStatus=label("准备好了，随时可以挥霍",size:11,color:muted);place(poolStatus,in:memory,NSRect(x:22,y:10,width:640,height:20))
        historyView=MemoryHistory(frame:NSRect(x:322,y:62,width:316,height:57));memory.addSubview(historyView)
        place(label("下一档：可浏览的作品与转动影集",size:10,color:muted),in:memory,NSRect(x:325,y:38,width:300,height:18))
        poolMode=NSPopUpButton(frame:NSRect(x:689,y:99,width:229,height:27));poolMode.addItems(withTitles:["自动 · 随电脑余量调整","体验 · 最多收藏 2 GB"]);poolMode.target=self;poolMode.action=#selector(changePoolMode);memory.addSubview(poolMode)
        if let qaLimit {poolMode.item(at:1)?.title="开发检查 · \(memoryText(qaLimit)) 上限";poolMode.selectItem(at:1);poolMode.isEnabled=false}
        poolButton=NSButton(title:"开始挥霍",target:self,action:#selector(togglePool));poolButton.bezelStyle = .rounded;poolButton.bezelColor=mint;poolButton.contentTintColor = .black;place(poolButton,in:memory,NSRect(x:687,y:53,width:233,height:38))
        place(label("电脑忙起来时，自动让路。",size:10,color:muted),in:memory,NSRect(x:709,y:25,width:210,height:20))
        visibilityButton=NSButton(checkboxWithTitle:"显示桌面图标",target:self,action:#selector(toggleOverlay));visibilityButton.state = .on;place(visibilityButton,in:root,NSRect(x:31,y:26,width:160,height:25))
        pressureLabel=label("",size:10,color:mint);place(pressureLabel,in:root,NSRect(x:210,y:27,width:445,height:22))
        playButton=NSButton(title:"暂停并释放",target:self,action:#selector(togglePause));playButton.bezelStyle = .rounded;place(playButton,in:root,NSRect(x:750,y:23,width:135,height:32))
        let quitButton=NSButton(title:"退出",target:self,action:#selector(quit));quitButton.bezelStyle = .rounded;place(quitButton,in:root,NSRect(x:893,y:23,width:77,height:32))
        for view in root.subviews where view.frame.minY>=330 {view.frame.origin.y += 100}
        buildColorControls(in:root)
        if let visible=NSScreen.main?.visibleFrame,visible.height<986 {
            let height=max(560,visible.height-60)
            let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:1000,height:height))
            scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.documentView=root
            panel.contentView=scroll;panel.setContentSize(NSSize(width:1000,height:height))
            scroll.contentView.scroll(to:NSPoint(x:0,y:950-height));scroll.reflectScrolledClipView(scroll.contentView)
        }
        panel.center()
    }
    @objc func showInspector() {
        if inspector==nil {
            let h:CGFloat=min(840,(NSScreen.main?.visibleFrame.height ?? 900)-70)
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:h),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title="闲着 · 灯光摄影棚";w.isReleasedWhenClosed=false;w.delegate=self;w.appearance=NSAppearance(named:.darkAqua)
            let root=Backdrop(frame:NSRect(x:0,y:0,width:740,height:h));w.contentView=root
            let view=InspectorCanvas(frame:NSRect(x:40,y:270,width:660,height:h-300),device:device)
            view.setAccessibilityElement(true);view.setAccessibilityRole(.image)
            view.setAccessibilityLabel("大图检视：拖动转动图标，滚轮缩放")
            root.addSubview(view)
            do {inspectorRenderer=try IconRenderer(view:view,device:device,clock:clock)} catch{return}
            inspector=w;inspectorView=view;inspectorRenderer?.fixedAngle=0.85;inspectorRenderer?.studio=true
            view.moveLight={ [weak self] x,y in
                guard let self else{return};self.lightX=max(-4,min(4,self.lightX+x));self.lightY=max(-4,min(4,self.lightY+y));self.applyLight(save:true)
            }
            view.orbit={ [weak self] x,y in
                guard let self,let r=self.inspectorRenderer else{return}
                r.fixedAngle=(r.fixedAngle ?? self.clock.current)+x;r.pitch=max(-1.3,min(1.3,r.pitch+y));self.inspectionAuto?.state = .off;self.inspectionAngle?.doubleValue=Double((r.fixedAngle ?? 0)*180/Float.pi);self.applyPlayback();view.draw()
            }
            view.magnify={ [weak self] delta in guard let r=self?.inspectorRenderer else{return};r.zoom=max(0.65,min(1.3,r.zoom+delta));view.draw() }
            place(label("拖动转动图标 · 按住 Shift 拖动灯光 · 滚轮缩放",size:12,color:muted),in:root,NSRect(x:40,y:244,width:650,height:22))
            let style=NSPopUpButton(frame:NSRect(x:40,y:84,width:205,height:30));style.addItems(withTitles:["柔和 · 哑光","陶瓷 · 柔亮","金属 · 反光"]);style.selectItem(at:finishIndex);style.target=self;style.action=#selector(changeFinish(_:));style.setAccessibilityLabel("图标材质");root.addSubview(style);finishPopup=style
            place(label("厚度",size:12,color:muted),in:root,NSRect(x:267,y:87,width:48,height:23))
            let thickness=NSSlider(value:Double(bodyThickness),minValue:0.4,maxValue:2.5,target:self,action:#selector(changeThickness(_:)));thickness.isContinuous=true;thickness.setAccessibilityLabel("图标厚度");place(thickness,in:root,NSRect(x:317,y:84,width:201,height:28));thicknessSlider=thickness
            let auto=NSButton(checkboxWithTitle:"自动转动",target:self,action:#selector(toggleInspectionAuto(_:)));place(auto,in:root,NSRect(x:555,y:84,width:140,height:28));inspectionAuto=auto
            let reset=NSButton(title:"重置观察角度",target:self,action:#selector(resetInspection));reset.bezelStyle = .rounded;place(reset,in:root,NSRect(x:40,y:35,width:160,height:32))
            place(label("视角",size:12,color:muted),in:root,NSRect(x:267,y:38,width:48,height:24))
            let angle=NSSlider(value:0.85*180/Double.pi,minValue:-180,maxValue:180,target:self,action:#selector(changeInspectionAngle(_:)));angle.isContinuous=true;angle.setAccessibilityLabel("检视角度");place(angle,in:root,NSRect(x:317,y:35,width:330,height:28));inspectionAngle=angle
            let dragLight=NSButton(checkboxWithTitle:"拖动灯光（关闭后拖动图标）",target:self,action:#selector(toggleLightDrag(_:)));place(dragLight,in:root,NSRect(x:40,y:116,width:320,height:25))
            let quick=NSButton(title:"打开悬浮调光板",target:self,action:#selector(showLightPanel));quick.bezelStyle = .rounded;place(quick,in:root,NSRect(x:487,y:114,width:207,height:28))
            let resetLight=NSButton(title:"重置灯光",target:self,action:#selector(resetLight));resetLight.bezelStyle = .rounded;place(resetLight,in:root,NSRect(x:40,y:199,width:105,height:30))
            let power=NSSlider(value:Double(lightPower),minValue:0.1,maxValue:3,target:self,action:#selector(changeLightPower(_:)));power.isContinuous=true;power.setAccessibilityLabel("灯光亮度");place(power,in:root,NSRect(x:195,y:200,width:180,height:28));lightPowerSlider=power
            place(label("亮度",size:12,color:muted),in:root,NSRect(x:154,y:203,width:40,height:22))
            let preset=NSPopUpButton(frame:NSRect(x:386,y:199,width:115,height:30));preset.addItems(withTitles:["灯色 · 暖白","灯色 · 日光","灯色 · 冰蓝","灯色 · 紫色"]);preset.target=self;preset.action=#selector(changeLightPreset(_:));preset.setAccessibilityLabel("灯光预设颜色");root.addSubview(preset);lightPreset=preset
            let well=NSColorWell(frame:NSRect(x:509,y:200,width:40,height:28));well.color=NSColor(srgbRed:1,green:0.93,blue:0.83,alpha:1);well.target=self;well.action=#selector(changeLightColor(_:));well.setAccessibilityLabel("灯光颜色");root.addSubview(well);lightColorWell=well
            let info=label("",size:11,color:muted);place(info,in:root,NSRect(x:558,y:202,width:145,height:23));lightPadLabel=info
            let mode=NSPopUpButton(frame:NSRect(x:40,y:156,width:180,height:30));mode.addItems(withTitles:["日常陪伴 · 自动","尽兴展示 · 自动","手动上限"]);mode.selectItem(at:performanceMode);mode.target=self;mode.action=#selector(changePerformance(_:));mode.setAccessibilityLabel("性能模式");root.addSubview(mode);performancePopup=mode
            let quality=NSPopUpButton(frame:NSRect(x:232,y:156,width:120,height:30));quality.addItems(withTitles:["轻量画质","精细画质","极细画质"]);quality.selectItem(at:manualQuality);quality.target=self;quality.action=#selector(changeQuality(_:));quality.setAccessibilityLabel("手动画质上限");root.addSubview(quality);qualityPopup=quality
            let status=label("正在采样",size:11,color:muted);place(status,in:root,NSRect(x:365,y:148,width:330,height:44));status.maximumNumberOfLines=2;performanceLabel=status
            w.center()
        }
        if let asset=previewRenderer.asset {inspectorRenderer?.setAsset(asset)}
        applyLight(save:false);applyFinish();inspector?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);applyPlayback()
    }
    @objc func showLightPanel() {
        if lightPanel==nil {
            let w=NSPanel(contentRect:NSRect(x:0,y:0,width:350,height:450),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
            w.title="闲着 · 随时调光";w.level = .floating;w.hidesOnDeactivate=false;w.isReleasedWhenClosed=false
            w.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];w.appearance=NSAppearance(named:.darkAqua)
            let root=Backdrop(frame:NSRect(x:0,y:0,width:350,height:450));w.contentView=root
            place(label("拖动光点，桌面与摄影棚一起变化",size:13,color:muted),in:root,NSRect(x:20,y:413,width:315,height:24))
            let pad=LightPositionPad(frame:NSRect(x:20,y:211,width:310,height:193));root.addSubview(pad);lightPad=pad
            pad.onMove={ [weak self] p in guard let self else{return};self.lightX=p.x;self.lightY=p.y;self.applyLight(save:true) }
            for (i,title) in ["左右","上下","远近"].enumerated() {
                let y:CGFloat=172-CGFloat(i)*36
                place(label(title,size:12,color:muted),in:root,NSRect(x:20,y:y+3,width:45,height:23))
                let slider=NSSlider(value:0,minValue:i==2 ? 3 : -4,maxValue:i==2 ? 8 : 4,target:self,action:#selector(changeLightPosition(_:)))
                slider.tag=i;slider.isContinuous=true;slider.setAccessibilityLabel("灯光"+title);place(slider,in:root,NSRect(x:70,y:y,width:260,height:28));lightPositionSliders.append(slider)
            }
            place(label("亮度",size:12,color:muted),in:root,NSRect(x:20,y:67,width:45,height:23))
            let power=NSSlider(value:Double(lightPower),minValue:0.1,maxValue:3,target:self,action:#selector(changeLightPower(_:)));power.isContinuous=true;power.setAccessibilityLabel("桌面灯光亮度");place(power,in:root,NSRect(x:70,y:64,width:260,height:28));quickPower=power
            let color=NSPopUpButton(frame:NSRect(x:20,y:19,width:175,height:30));color.addItems(withTitles:["灯色 · 暖白","灯色 · 日光","灯色 · 冰蓝","灯色 · 紫色"]);color.target=self;color.action=#selector(changeLightPreset(_:));root.addSubview(color);quickColor=color
            let reset=NSButton(title:"重置灯光",target:self,action:#selector(resetLight));reset.bezelStyle = .rounded;place(reset,in:root,NSRect(x:210,y:19,width:120,height:30))
            w.center();lightPanel=w
        }
        applyLight(save:false);lightPanel?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func changeLightPosition(_ sender:NSSlider) {
        if sender.tag==0 {lightX=sender.floatValue} else if sender.tag==1 {lightY=sender.floatValue} else {lightZ=sender.floatValue}
        applyLight(save:true)
    }
    func applyLight(save:Bool) {
        let c=IconColor(hex:lightHex)?.rgb ?? SIMD3<Float>(1,0.93,0.83)
        for r in renderers {r.lightPosition=SIMD3(lightX,lightY,lightZ);r.lightPower=lightPower;r.lightColor=c}
        let colors=["#FFECD4","#FFFFFF","#91CAFF","#D8A4FF"];lightPreset?.selectItem(at:colors.firstIndex(of:lightHex) ?? 0)
        lightColorWell?.color=NSColor(srgbRed:Double(c.x),green:Double(c.y),blue:Double(c.z),alpha:1)
        lightPowerSlider?.floatValue=lightPower
        lightPadLabel?.stringValue=String(format:"光源位置 %.1f / %.1f",lightX,lightY)
        lightPad?.position=SIMD2(lightX,lightY)
        for (i,v) in [lightX,lightY,lightZ].enumerated() where i<lightPositionSliders.count {lightPositionSliders[i].floatValue=v}
        quickPower?.floatValue=lightPower;quickColor?.selectItem(at:colors.firstIndex(of:lightHex) ?? 0)
        if save {let d=UserDefaults.standard;d.set(lightZ,forKey:"lightZ");d.set(lightX,forKey:"lightX");d.set(lightY,forKey:"lightY");d.set(lightPower,forKey:"lightPower");d.set(lightHex,forKey:"lightHex")}
        preview?.draw();floating?.draw();inspectorView?.draw()
    }
    @objc func toggleLightDrag(_ sender:NSButton) {inspectorView?.draggingLight=sender.state == .on}
    @objc func resetLight() {lightX = -2;lightY=2.5;lightZ=4;lightPower=1;lightHex="#FFECD4";applyLight(save:true)}
    @objc func changeLightPower(_ sender:NSSlider) {lightPower=sender.floatValue;applyLight(save:true)}
    @objc func changeLightPreset(_ sender:NSPopUpButton) {lightHex=["#FFECD4","#FFFFFF","#91CAFF","#D8A4FF"][sender.indexOfSelectedItem];applyLight(save:true)}
    @objc func changeLightColor(_ sender:NSColorWell) {
        guard let c=sender.color.usingColorSpace(.sRGB) else{return}
        lightHex=String(format:"#%02X%02X%02X",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255));applyLight(save:true)
    }
    @objc func changePerformance(_ sender:NSPopUpButton) {performanceMode=sender.indexOfSelectedItem;UserDefaults.standard.set(performanceMode,forKey:"performanceMode");sample()}
    @objc func changeQuality(_ sender:NSPopUpButton) {manualQuality=sender.indexOfSelectedItem;UserDefaults.standard.set(manualQuality,forKey:"manualQuality");sample()}
    func updatePerformance(_ m:MemorySnapshot) {
        let active=renderers.filter{!$0.paused}
        let count=active.reduce(0){$0+$1.gpuSamples}
        let cost:Double?=count != lastGPUSamples && !active.isEmpty ? active.reduce(0){$0+$1.gpuMilliseconds} : nil
        lastGPUSamples=count
        let (q,fps)=budget.update(now:ProcessInfo.processInfo.systemUptime,mode:performanceMode,manual:manualQuality,costMS:cost,pressure:m.pressure,thermal:ProcessInfo.processInfo.thermalState.rawValue,lowPower:ProcessInfo.processInfo.isLowPowerModeEnabled)
        for r in renderers {let changed=r.quality != q;r.quality=q;r.targetFPS=fps;if changed && r === inspectorRenderer && (inspector?.isVisible ?? false) {inspectorView?.draw()}}
        qualityPopup?.isEnabled=performanceMode==2
        let names=["轻量","精细","极细"]
        let ms=inspectorRenderer?.gpuMilliseconds ?? 0
        performanceLabel?.stringValue=String(format:"%@ · 目标 %d 帧/秒 · GPU %.1f ms/帧\n%@",names[q],fps,ms,budget.reason)
        performanceLabel?.toolTip="GPU 时间为摄影棚最近完成帧的平滑耗时，不是整机使用率；静止时保留最近值。保护机制也适用于手动上限。"
    }
    func applyFinish() {for r in renderers {r.finish=Float(finishIndex);r.depthScale=bodyThickness};preview?.draw();floating?.draw();inspectorView?.draw()}
    @objc func changeFinish(_ sender:NSPopUpButton) {finishIndex=sender.indexOfSelectedItem;UserDefaults.standard.set(finishIndex,forKey:"finishIndex");applyFinish()}
    @objc func changeThickness(_ sender:NSSlider) {bodyThickness=Float(sender.doubleValue);UserDefaults.standard.set(bodyThickness,forKey:"bodyThickness");applyFinish()}
    @objc func toggleInspectionAuto(_ sender:NSButton) {inspectorRenderer?.fixedAngle=sender.state == .on ? nil : clock.current;applyPlayback();inspectorView?.draw()}
    @objc func changeInspectionAngle(_ sender:NSSlider) {inspectorRenderer?.fixedAngle=Float(sender.doubleValue)*Float.pi/180;inspectionAuto?.state = .off;applyPlayback();inspectorView?.draw()}
    @objc func resetInspection() {inspectorRenderer?.fixedAngle=0.85;inspectorRenderer?.pitch = -0.10;inspectorRenderer?.zoom=1;inspectionAngle?.doubleValue=0.85*180/Double.pi;inspectionAuto?.state = .off;applyPlayback();inspectorView?.draw()}
    func swatch(_ color:NSColor)->NSImage {
        NSImage(size:NSSize(width:18,height:18),flipped:false) { rect in
            color.setFill();NSBezierPath(roundedRect:rect.insetBy(dx:1,dy:1),xRadius:5,yRadius:5).fill()
            NSColor.white.withAlphaComponent(0.22).setStroke();NSBezierPath(roundedRect:rect.insetBy(dx:1,dy:1),xRadius:5,yRadius:5).stroke();return true
        }
    }
    func buildColorControls(in root:NSView) {
        let card=Card(frame:NSRect(x:30,y:338,width:940,height:92));root.addSubview(card)
        place(label("识别到的图标颜色",size:12,color:mint,weight:.medium),in:card,NSRect(x:18,y:59,width:238,height:21))
        colorPopup=NSPopUpButton(frame:NSRect(x:16,y:20,width:244,height:28));colorPopup.addItem(withTitle:"正在识别颜色…");colorPopup.isEnabled=false;card.addSubview(colorPopup)
        place(label("选一种新颜色，点击色块立即替换",size:11,color:muted),in:card,NSRect(x:281,y:59,width:365,height:20))
        for i in 0..<4 {
            let color=IconColor(hex:presetColors[i])!
            let b=NSButton(image:swatch(color.nsColor),target:self,action:#selector(usePreset(_:)))
            b.bezelStyle = .rounded;b.tag=i;b.toolTip=presetNames[i];b.setAccessibilityLabel("换成"+presetNames[i]);b.isEnabled=false
            place(b,in:card,NSRect(x:279+CGFloat(i)*41,y:18,width:35,height:32));colorPresets.append(b)
        }
        colorWell=NSColorWell(frame:NSRect(x:459,y:21,width:52,height:28));colorWell.color=IconColor(hex:presetColors[0])!.nsColor;colorWell.toolTip="自定义目标颜色";colorWell.setAccessibilityLabel("自定义目标颜色");card.addSubview(colorWell)
        colorApply=NSButton(title:"一键换色",target:self,action:#selector(applyColor));colorApply.bezelStyle = .rounded;colorApply.isEnabled=false;place(colorApply,in:card,NSRect(x:526,y:18,width:113,height:32))
        colorReset=NSButton(title:"恢复原色",target:self,action:#selector(resetColors));colorReset.bezelStyle = .rounded;colorReset.isEnabled=false;place(colorReset,in:card,NSRect(x:651,y:18,width:112,height:32))
        paletteInfo=label("仅改变玩具中的图标",size:10,color:muted);paletteInfo.maximumNumberOfLines=2;paletteInfo.lineBreakMode = .byWordWrapping;place(paletteInfo,in:card,NSRect(x:785,y:23,width:138,height:46))
    }
    var replacements:[String:String] {UserDefaults.standard.dictionary(forKey:"palette.\(appKey)") as? [String:String] ?? [:]}
    func refreshPalette() {
        colorPopup.removeAllItems()
        for color in baseAsset?.palette ?? [] {
            colorPopup.addItem(withTitle:"\(color.hex) · 约 \(Int(color.share*100))%")
            colorPopup.lastItem?.image=swatch(color.nsColor)
        }
        let ready=(baseAsset?.palette.isEmpty==false)
        if !ready {colorPopup.addItem(withTitle:"没有识别到可替换颜色")}
        colorPopup.isEnabled=ready;colorApply.isEnabled=ready;colorReset.isEnabled=ready
        colorPresets.forEach{$0.isEnabled=ready}
    }
    @objc func usePreset(_ sender:NSButton) {colorWell.color=IconColor(hex:presetColors[sender.tag])!.nsColor;applyColor()}
    @objc func applyColor() {
        guard let asset=baseAsset,asset.palette.indices.contains(colorPopup.indexOfSelectedItem) else{return}
        let selected=asset.palette[colorPopup.indexOfSelectedItem]
        var mapping=replacements.filter { key,_ in
            guard let old=IconColor(hex:key) else{return false}
            let oldLab=IconPalette.lab(old.rgb),labs=asset.palette.map{IconPalette.lab($0.rgb)}
            let nearest=labs.indices.min(by:{simd_distance_squared(oldLab,labs[$0])<simd_distance_squared(oldLab,labs[$1])})!
            return nearest != colorPopup.indexOfSelectedItem || simd_distance(oldLab,labs[nearest])>=0.06
        }
        mapping[selected.hex]=IconColor(colorWell.color).hex
        UserDefaults.standard.set(mapping,forKey:"palette.\(appKey)");showAppearance()
    }
    @objc func resetColors() {UserDefaults.standard.removeObject(forKey:"palette.\(appKey)");showAppearance()}
    func showAppearance() {
        guard let asset=baseAsset else{return}
        paintID=UUID();let token=paintID,key=appKey,iconToken=requestID,mapping=replacements,gpu=device!
        paintQueue.cancelAllOperations()
        if mapping.isEmpty {
            renderers.forEach{$0.setAsset(asset)};paletteInfo.stringValue="原始配色 · \(asset.palette.count) 种主要颜色";return
        }
        paletteInfo.stringValue="正在替换颜色…"
        paintQueue.addOperation { [weak self] in
            let cut=IconPalette.recolor(asset.source,palette:asset.palette,replacements:mapping)
            let painted=try? asset.replacingTexture(cut,device:gpu)
            DispatchQueue.main.async {
                guard let self,self.paintID==token,self.requestID==iconToken,self.appKey==key else{return}
                if let painted {
                    self.renderers.forEach{$0.setAsset(painted)}
                    self.paletteInfo.stringValue="已换色 · 正面侧面同步\n仅改变玩具中的图标"
                    if let dir=self.qaDir,let image=cut.cgImage(),let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {self.qaQueue.async {try? png.write(to:dir.appendingPathComponent("recolored.png"))}}
                } else {self.paletteInfo.stringValue="换色暂未成功，请重试"}
            }
        }
    }
    func buildOverlay() throws {
        overlay=OverlayPanel(contentRect:NSRect(x:0,y:0,width:iconSide,height:iconSide),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        overlay.title="闲着 · 桌面光影"
        overlay.backgroundColor = .clear;overlay.isOpaque=false;overlay.hasShadow=false;overlay.ignoresMouseEvents=true;overlay.level = .floating;overlay.hidesOnDeactivate=false
        overlay.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle];overlay.isReleasedWhenClosed=false
        floating=MTKView(frame:NSRect(x:0,y:0,width:iconSide,height:iconSide),device:device);overlay.contentView=floating
        floatingRenderer=try IconRenderer(view:floating,device:device,clock:clock);floatingRenderer.transparentShadow=true;floatingRenderer.viewportPadding=Float(IconRenderer.desktopPadding)
        reposition();overlay.orderFrontRegardless()
    }
    func buildMenu() {
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength);status.button?.image=NSImage(systemSymbolName:"circle.hexagongrid",accessibilityDescription:"闲着")
        let menu=NSMenu()
        func item(_ title:String,_ action:Selector,_ key:String="")->NSMenuItem {let i=NSMenuItem(title:title,action:action,keyEquivalent:key);i.target=self;menu.addItem(i);return i}
        _=item("打开桌面实验室",#selector(showPanel));_=item("随时调节桌面灯光",#selector(showLightPanel));poolMenu=item("开始挥霍",#selector(togglePool));toggleItem=item("暂停并释放",#selector(togglePause));overlayItem=item("隐藏悬浮图标",#selector(toggleOverlay));menu.addItem(.separator());_=item("退出闲着",#selector(quit),"q");status.menu=menu
    }
    func updateApp(_ app:NSRunningApplication) {
        appKey=app.bundleIdentifier ?? String(app.processIdentifier);nameLabel.stringValue=app.localizedName ?? "当前应用"
        let icon=imageForApp(app);original.image=icon;source=IconCutout.sourceImage(icon)
        cutoutMode=max(0,min(2,UserDefaults.standard.integer(forKey:"cutout.\(appKey)")));cutoutPopup.selectItem(at:cutoutMode)
        prepareIcon()
        if qaDir != nil {appHistory.append(["name":nameLabel.stringValue,"bundle":appKey]);if appHistory.count>100 {appHistory.removeFirst()}}
    }
    func prepareIcon() {
        requestID=UUID();processor.cancelAllOperations()
        paintID=UUID();paintQueue.cancelAllOperations();baseAsset=nil;refreshPalette()
        guard let source else {methodLabel.stringValue="图标暂不可用";return}
        let token=requestID,key="\(appKey):\(cutoutMode)",mode=cutoutMode
        if let asset=cache[key] {applyAsset(asset);return}
        methodLabel.stringValue="正在抠图…"
        let gpu=device!
        processor.addOperation { [weak self] in
            let cut=IconCutout.prepare(source,mode:mode)
            do {
                let asset=try RenderAsset.make(cut,device:gpu)
                DispatchQueue.main.async {
                    guard let self,self.requestID==token else{return}
                    self.cache[key]=asset;self.cacheKeys.removeAll{$0==key};self.cacheKeys.append(key)
                    while self.cacheKeys.count>5 {self.cache.removeValue(forKey:self.cacheKeys.removeFirst())}
                    self.applyAsset(asset)
                    if let dir=self.qaDir,let image=cut.cgImage(),let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {self.qaQueue.async {try? data.write(to:dir.appendingPathComponent("cutout.png"))}}
                }
            } catch {DispatchQueue.main.async {guard let self,self.requestID==token else{return};self.methodLabel.stringValue="生成失败，可切换抠图方式"}}
        }
    }
    func applyAsset(_ asset:RenderAsset) {method=asset.method;methodLabel.stringValue="\(asset.method) · 立体轮廓";baseAsset=asset;refreshPalette();showAppearance()}
    @objc func screensChanged() {
        let list=NSScreen.screens;guard !list.isEmpty else{return}
        if !list.contains(where:{displayID($0)==selectedScreenID}) {selectedScreenID=displayID(NSScreen.main ?? list[0])}
        screenPopup.removeAllItems();screenPopup.addItems(withTitles:list.map{$0.localizedName})
        screenPopup.selectItem(at:list.firstIndex{displayID($0)==selectedScreenID} ?? 0);reposition()
    }
    @objc func selectScreen() {let i=screenPopup.indexOfSelectedItem;guard NSScreen.screens.indices.contains(i) else{return};selectedScreenID=displayID(NSScreen.screens[i]);UserDefaults.standard.set(Int(selectedScreenID),forKey:"screenID");reposition()}
    func reposition() {
        guard overlay != nil,canvas != nil,!NSScreen.screens.isEmpty else{return}
        let area=screen.visibleFrame
        overlay.setFrame(DesktopPlacement.shadowFrame(DesktopPlacement.frame(in:area,side:iconSide,position:position)),display:true)
        canvas.worldSize=area.size;canvas.iconSide=iconSide;canvas.position=position
        positionLabel.stringValue=String(format:"位置：横向 %.0f%% · 纵向 %.0f%%  /  拖动图标即可调整",position.x*100,position.y*100)
        sizeValue.stringValue=String(format:"%.0f%%",iconSide/3)
        speedValue.stringValue=clock.speed<0.005 ? "静止" : String(format:"%.1f×",clock.speed)
    }
    func savePlacement() {UserDefaults.standard.set(position.x,forKey:"positionX");UserDefaults.standard.set(position.y,forKey:"positionY")}
    @objc func centerIcon() {position=NSPoint(x:0.5,y:0.5);savePlacement();reposition()}
    @objc func changeSize(_ sender:NSSlider) {iconSide=CGFloat(sender.doubleValue*3);UserDefaults.standard.set(iconSide,forKey:"iconSide");reposition();preview.draw();floating.draw()}
    @objc func changeSpeed(_ sender:NSSlider) {clock.speed=sender.doubleValue;UserDefaults.standard.set(clock.speed,forKey:"rotationSpeed");reposition();applyPlayback()}
    @objc func changeCutout() {cutoutMode=cutoutPopup.indexOfSelectedItem;UserDefaults.standard.set(cutoutMode,forKey:"cutout.\(appKey)");prepareIcon()}
    @objc func showPanel() {panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);applyPlayback()}
    func windowShouldClose(_ sender:NSWindow)->Bool {sender.orderOut(nil);applyPlayback();return false}
    func windowDidMiniaturize(_ notification:Notification) {applyPlayback()}
    func windowDidDeminiaturize(_ notification:Notification) {applyPlayback()}
    @objc func togglePause() {paused.toggle();playButton.title=paused ? "继续运行" : "暂停并释放";toggleItem.title=playButton.title;applyPlayback()}
    func applyPlayback() {
        guard previewRenderer != nil,floatingRenderer != nil else{return}
        playground.setSuspended(paused || sleeping)
        clock.paused=paused || sleeping
        previewRenderer.paused=paused || sleeping || clock.speed==0 || !panel.isVisible || panel.isMiniaturized
        floatingRenderer.paused=paused || sleeping || clock.speed==0 || !overlayVisible
        inspectorRenderer?.paused=paused || sleeping || clock.speed==0 || !(inspector?.isVisible ?? false) || (inspector?.isMiniaturized ?? false) || inspectorRenderer?.fixedAngle != nil
    }
    @objc func toggleOverlay() {overlayVisible.toggle();if overlayVisible {overlay.orderFrontRegardless()} else {overlay.orderOut(nil)};visibilityButton.state=overlayVisible ? .on : .off;overlayItem.title=overlayVisible ? "隐藏悬浮图标" : "显示悬浮图标";applyPlayback()}
    @objc func sleepNow() {sleeping=true;applyPlayback()}
    @objc func wakeNow() {sleeping=false;applyPlayback();reposition()}
    @objc func togglePool() {
        playground.stop() // No random filler in the visual review build.
        sample()
    }
    @objc func changePoolMode() {
        playground.stop();playground.limit=poolMode.indexOfSelectedItem==1 ? 2*GiB : UInt64.max
        sample()
    }
    @objc func quit() {NSApp.terminate(nil)}
    @objc func sample() {
        tracker.refresh()
        let m=monitor.sample();updatePerformance(m);availableLabel.stringValue=m.availableText;residentLabel.stringValue=m.footprint.map{memoryText($0)} ?? "暂不可用"
        // Stage 3 will attach budget decisions to real, browsable visual resources.
        poolLabel.stringValue="灯光摄影棚"
        poolDetail.stringValue="\(playground.textureCount) 份材质 · 程序驻留 \(m.resident.map{memoryText($0)} ?? "未知")"
        poolStatus.stringValue=(paused || sleeping) && playground.enabled ? "已暂停并释放，继续运行后再慢慢增加" : playground.enabled ? "\(playground.status) · 当前目标 \(memoryText(playground.target))" : playground.status
        poolButton.title=playground.enabled ? "停止挥霍并释放" : "开始挥霍";poolMenu.title=poolButton.title
        poolButton.title="打开大图检视";poolButton.action=#selector(showInspector);poolButton.isEnabled=true;poolMenu.isEnabled=false;poolMode.isEnabled=false;historyView.isHidden=true
        if poolMode.numberOfItems != 1 {poolMode.removeAllItems();poolMode.addItem(withTitle:"真实视觉资源池待接入")}
        poolStatus.stringValue="灯光和阴影实时计算；可浏览的大内存资源池待接入"
        poolDetail.stringValue="当前仅保留实际图标与渲染资源"
        historyView.append(playground.allocated,total:m.total)
        pressureLabel.toolTip="驻留：\(m.residentText)；压缩：\(m.compressed.map{memoryText($0)} ?? "未知")；动态预留：\(memoryText(playground.reserve))。材质分配量不等于物理驻留。"
        pressureLabel.stringValue="● 内存压力\(m.pressure) · 灯光摄影棚";pressureLabel.textColor=m.pressure == "正常" ? mint : .systemOrange
        guard let dir=qaDir,!qaBusy else{return}
        let of=overlay.frame,cf=canvas.iconFrame,dr=canvas.desktopRect
        let data:[String:Any]=["quality":budget.level,"performanceMode":performanceMode,"performanceReason":budget.reason,"gpuMS":inspectorRenderer?.gpuMilliseconds ?? 0,"gpuErrors":renderers.reduce(0){$0+$1.gpuErrors},"targetFPS":inspectorRenderer?.targetFPS ?? 30,"shadowBytes":inspectorRenderer?.shadowBytes ?? 0,"lightPosition":[lightX,lightY,lightZ],"desktopShadow":floatingRenderer.transparentShadow,"desktopShadowBytes":floatingRenderer.shadowBytes,"lightPanelVisible":lightPanel?.isVisible ?? false,"lightPower":lightPower,"lightHex":lightHex,"finishIndex":finishIndex,"bodyThickness":bodyThickness,"inspectionAngle":inspectorRenderer?.fixedAngle as Any? ?? NSNull(),"inspectionPitch":inspectorRenderer?.pitch ?? 0,"inspectionZoom":inspectorRenderer?.zoom ?? 1,"inspectionFrames":inspectorRenderer?.frames ?? 0,"inspectionVisible":inspector?.isVisible ?? false,"chip":monitor.chip,"totalBytes":m.total,"residentBytes":m.resident as Any? ?? NSNull(),"pressure":m.pressure,"activeApp":tracker.current?.localizedName ?? "","fixture":fixtureURL != nil,"history":appHistory,"previewFrames":previewRenderer.frames,"overlayFrames":floatingRenderer.frames,"paused":paused,"speed":clock.speed,"angle":clock.current,"iconSide":iconSide,"position":[position.x,position.y],"overlayFrame":[of.origin.x,of.origin.y,of.width,of.height],"canvasIcon":[cf.origin.x,cf.origin.y,cf.width,cf.height],"canvasDesktop":[dr.origin.x,dr.origin.y,dr.width,dr.height],"screenVisible":[screen.visibleFrame.origin.x,screen.visibleFrame.origin.y,screen.visibleFrame.width,screen.visibleFrame.height],"method":method,"meshSides":previewRenderer.asset?.sideSegments ?? 0,"overlayVisible":overlayVisible,"overlayIgnoresMouse":overlay.ignoresMouseEvents,"memoryFillerEnabled":playground.enabled,"targetBytes":playground.target,"poolCause":playground.cause,"inFlightBytes":playground.inFlightBytes,"palette":baseAsset?.palette.map{$0.hex} ?? [],"replacements":replacements,"timestamp":Date().timeIntervalSince1970,"poolBytes":playground.allocated,"poolTextures":playground.textureCount,"poolStatus":playground.status,"poolLimit":playground.limit,"reserveBytes":playground.reserve,"footprintBytes":m.footprint as Any? ?? NSNull(),"compressedBytes":m.compressed as Any? ?? NSNull(),"swapPages":m.swapPages as Any? ?? NSNull(),"compressionPages":m.compressionPages as Any? ?? NSNull(),"reclaimableBytes":m.reclaimableEstimate as Any? ?? NSNull(),"generating":playground.generating]
        guard let json=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]) else{return}
        // Diagnostic files can stall in the OS file stack. Never read or write them
        // on the UI thread, and never queue an unbounded backlog of snapshots.
        qaBusy=true
        let readCommands=qaCommands
        qaQueue.async { [weak self] in
            try? json.write(to:dir.appendingPathComponent("telemetry.json"),options:.atomic)
            var received:[String:Any]?
            if readCommands {
                let command=dir.appendingPathComponent("command.json")
                if let bytes=try? Data(contentsOf:command),let cmd=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] {
                    try? FileManager.default.removeItem(at:command);received=cmd
                }
            }
            let command=received
            DispatchQueue.main.async {
                guard let self else{return};self.qaBusy=false
                if let command {self.applyQACommand(command)}
            }
        }
    }
    func applyQACommand(_ cmd:[String:Any]) {
        if let action=cmd["memory"] as? String {
            if action=="start" {playground.stop()}
            if action=="stop" {playground.stop()}
            if action=="pause" {paused=true;applyPlayback()}
            if action=="resume" {paused=false;applyPlayback()}
        }
        if let index=cmd["sourceColor"] as? Int,(baseAsset?.palette.indices.contains(index) ?? false) {colorPopup.selectItem(at:index)}
        if let hex=cmd["targetColor"] as? String,let color=IconColor(hex:hex) {colorWell.color=color.nsColor;applyColor()}
        if cmd["resetColors"] as? Bool == true {resetColors()}
        if let angle=cmd["angle"] as? Double {previewRenderer.fixedAngle=Float(angle);floatingRenderer.fixedAngle=Float(angle);preview.draw();floating.draw()}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showPanel();return true}
    func applicationWillTerminate(_ notification:Notification) {playground.stop();timer?.invalidate();processor.cancelAllOperations();paintQueue.cancelAllOperations();NSWorkspace.shared.notificationCenter.removeObserver(self);NotificationCenter.default.removeObserver(self);for token in lifecycleObservers {DistributedNotificationCenter.default().removeObserver(token)}}
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate=AppDelegate();app.delegate=delegate;app.run()
