import SwiftUI
import AppKit
import IOKit

// MARK: - 环境光传感器（Apple Silicon 私有 HID 接口，无需摄像头）

typealias HIDClient = OpaquePointer
@_silgen_name("IOHIDEventSystemClientCreate") func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> HIDClient?
@_silgen_name("IOHIDEventSystemClientSetMatching") func IOHIDEventSystemClientSetMatching(_ c: HIDClient, _ m: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices") func IOHIDEventSystemClientCopyServices(_ c: HIDClient) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent") func IOHIDServiceClientCopyEvent(_ s: AnyObject, _ type: Int64, _ o: Int32, _ opt: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func IOHIDEventGetFloatValue(_ e: AnyObject, _ field: Int32) -> Double

func readALS() -> Double? {
    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
    IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 4] as CFDictionary)
    guard let arr = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject], let s = arr.first,
          let ev = IOHIDServiceClientCopyEvent(s, 12, 0, 0)?.takeRetainedValue() else { return nil }
    return IOHIDEventGetFloatValue(ev, 12 << 16)
}

// MARK: - 常量与工具

let home = NSHomeDirectory()
let calibrationPath = home + "/.config/lamp-calibration.json"
let logPath = home + "/Library/Logs/lightbar.log"
let ctPoints: [(Double, Double)] = [(5, 3000), (50, 3500), (150, 4000), (450, 4800), (1500, 5500)]  // 环境光 → 色温（“色温跟随环境光”开启时使用）
let pollSeconds = 300.0, minChange = 6.0, minChangeCT = 300.0, minGap = 120.0, manualPause = 1800.0

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: logPath, atomically: true, encoding: .utf8) }
}

/// 常驻的 lamp-serve 进程：保持云端连接，一次调用约 0.3 秒；所有调用串行化
final class LampClient {
    private let lock = NSLock()
    private var proc: Process?
    private var inPipe: Pipe?
    private var outPipe: Pipe?
    private var buffer = Data()
    private let path = home + "/.local/bin/lamp-serve"

    private func start() -> Bool {
        let p = Process(); p.launchPath = path
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        proc = p; inPipe = i; outPipe = o; buffer = Data()
        return true
    }

    private func readLine(timeout: TimeInterval) -> String? {
        let fd = outPipe!.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let r = buffer.firstIndex(of: 10) {
                let line = String(data: buffer[buffer.startIndex..<r], encoding: .utf8)
                buffer.removeSubrange(buffer.startIndex...r)
                return line
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, Int32(left * 1000)) <= 0 { return nil }
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: tmp[0..<n])
        }
    }

    func request(_ obj: [String: Any]) -> (Bool, String) {
        lock.lock(); defer { lock.unlock() }
        for attempt in 0..<2 {
            if proc == nil || !(proc!.isRunning) { if !start() { return (false, "无法启动 lamp-serve") } }
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return (false, "编码失败") }
            inPipe!.fileHandleForWriting.write(data + Data([10]))
            if let line = readLine(timeout: 20), let d = line.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return ((j["ok"] as? Bool) ?? false, (j["out"] as? String) ?? "")
            }
            proc?.terminate(); proc = nil   // 超时或进程异常：重启后重试一次
            if attempt == 1 { break }
        }
        return (false, "lamp-serve 无响应")
    }
}
let client = LampClient()

/// 兼容旧调用方式：lamp(["json"]) / ["on"] / ["off"] / ["set", b, ct] / ["bright", v] / ["ct", v]
@discardableResult func lamp(_ args: [String]) -> (Int32, String) {
    var m: [String: Any] = ["cmd": args.first ?? "json"]
    if args.first == "set", args.count >= 3 { m["b"] = Int(args[1]) ?? 50; m["ct"] = Int(args[2]) ?? 4500 }
    if (args.first == "bright" || args.first == "ct"), args.count >= 2 { m["v"] = Int(args[1]) ?? 50 }
    let (ok, out) = client.request(m)
    return (ok ? 0 : 1, out)
}

func interpolate(_ x: Double, _ table: [(Double, Double)]) -> Double {   // 在 log10(环境光) 上线性插值
    let lx = log10(max(x, 1))
    let pts = table.map { (log10($0.0), $0.1) }
    if lx <= pts.first!.0 { return pts.first!.1 }
    if lx >= pts.last!.0 { return pts.last!.1 }
    for i in 1..<pts.count where lx <= pts[i].0 {
        let (x0, y0) = pts[i - 1], (x1, y1) = pts[i]
        return y0 + (y1 - y0) * (lx - x0) / (x1 - x0)
    }
    return pts.last!.1
}

// MARK: - 控制器

final class Controller: ObservableObject {
    // 灯的状态
    @Published var on = false
    @Published var bright = 50.0
    @Published var ct = 4500.0
    @Published var reachable = false
    @Published var status = "连接中…"
    // 自动调光
    @Published var ambient: Double? = nil
    @Published var sensor: Double? = nil
    @Published var contribution = 0.0
    @Published var manualHold = UserDefaults.standard.bool(forKey: "manualHold") { didSet { UserDefaults.standard.set(manualHold, forKey: "manualHold") } }    // 用户手动调过：保持手动，直到点“恢复”或重新打开自动调光
    @Published var busy = ""
    @Published var autoEnabled: Bool { didSet { UserDefaults.standard.set(autoEnabled, forKey: "auto"); if autoEnabled { manualHold = false; q.async { self.autoAdjust(force: true) } } } }
    @Published var lockLinkEnabled: Bool { didSet { UserDefaults.standard.set(lockLinkEnabled, forKey: "lockLink") } }
    @Published var dayTotal: Double { didSet { UserDefaults.standard.set(dayTotal, forKey: "dayTotal"); targetsChanged() } }
    @Published var nightTotal: Double { didSet { UserDefaults.standard.set(nightTotal, forKey: "nightTotal"); targetsChanged() } }
    @Published var ctFollow: Bool { didSet { UserDefaults.standard.set(ctFollow, forKey: "ctFollow"); targetsChanged() } }
    @Published var dayCT: Double { didSet { UserDefaults.standard.set(dayCT, forKey: "dayCT"); targetsChanged() } }
    @Published var nightCT: Double { didSet { UserDefaults.standard.set(nightCT, forKey: "nightCT"); targetsChanged() } }
    @Published var dayStart: Int { didSet { UserDefaults.standard.set(dayStart, forKey: "dayStart"); targetsChanged() } }
    @Published var nightStart: Int { didSet { UserDefaults.standard.set(nightStart, forKey: "nightStart"); targetsChanged() } }

    let q = DispatchQueue(label: "lightbar")
    var locked = false, asleep = false, appliedOn: Bool? = nil
    var lastAuto: Int? = nil, lastAutoCT: Int? = nil, lastChange = Date.distantPast
    var history: [Double] = []
    var gain: [(Double, Double)] = []
    var minBright = 5.0
    var editing = false
    let rampQ = DispatchQueue(label: "lightbar.ramp")   // 渐变与手动写入都在这条串行队列上，保证先后顺序
    var rampGen = 0                                     // 递增即取消正在进行的渐变
    var lastManual = Date.distantPast
    var settling: Bool { editing || Date().timeIntervalSince(lastManual) < 8 }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["auto": true, "lockLink": true, "dayTotal": 400.0, "nightTotal": 300.0, "ctFollow": false, "dayCT": 4800.0, "nightCT": 3500.0, "dayStart": 7, "nightStart": 18])
        autoEnabled = d.bool(forKey: "auto"); lockLinkEnabled = d.bool(forKey: "lockLink")
        dayTotal = d.double(forKey: "dayTotal"); nightTotal = d.double(forKey: "nightTotal")
        ctFollow = d.bool(forKey: "ctFollow")
        dayCT = d.double(forKey: "dayCT"); nightCT = d.double(forKey: "nightCT")
        dayStart = d.integer(forKey: "dayStart"); nightStart = d.integer(forKey: "nightStart")
        gain = Controller.loadGain()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in self?.q.async { self?.locked = true; self?.applyPower("锁屏") } }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in self?.q.async { self?.locked = false; self?.asleep = false; self?.applyPower("解锁") } }
        let w = NSWorkspace.shared.notificationCenter
        w.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in self?.q.async { self?.asleep = true; self?.applyPower("屏幕关闭") } }
        w.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.q.async { self?.asleep = false; self?.applyPower("屏幕点亮") } }
        w.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in self?.q.async { self?.asleep = true; self?.applyPower("系统睡眠") } }
        w.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.q.async { self?.asleep = false; self?.applyPower("系统唤醒") } }
        Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in self?.q.async { self?.autoAdjust() } }
        q.async { self.refresh() }
        log("挂灯 App 已启动")
    }

    static func loadGain() -> [(Double, Double)] {
        var table: [(Double, Double)] = [(0, 0), (25, 70), (60, 126), (100, 184)]
        if let d = FileManager.default.contents(atPath: calibrationPath),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let base = j["base_off"] as? Double, let rows = j["rows"] as? [[Double]] {
            var byB: [Double: [Double]] = [:]
            for r in rows where r.count == 3 { byB[r[1], default: []].append(r[2] - base) }
            let t = byB.map { ($0.key, $0.value.reduce(0, +) / Double($0.value.count)) }.sorted { $0.0 < $1.0 }
            if t.count >= 2 { table = [(0, 0)] + t }
        }
        return table
    }

    func lampContribution(_ b: Double) -> Double {
        if b <= 0 { return 0 }
        for i in 1..<gain.count where b <= gain[i].0 {
            let (x0, y0) = gain[i - 1], (x1, y1) = gain[i]
            return y0 + (y1 - y0) * (b - x0) / (x1 - x0)
        }
        let (x0, y0) = gain[gain.count - 2], (x1, y1) = gain[gain.count - 1]
        return y1 + (y1 - y0) * (b - x1) / (x1 - x0)
    }

    func brightness(forContribution c: Double) -> Int {
        if c <= lampContribution(minBright) { return Int(minBright) }
        if c >= gain.last!.1 { return 100 }
        for i in 1..<gain.count where c <= gain[i].1 {
            let (x0, y0) = gain[i - 1], (x1, y1) = gain[i]
            return Int((x0 + (x1 - x0) * (c - y0) / (y1 - y0)).rounded())
        }
        return 100
    }

    var isDay: Bool { let h = Calendar.current.component(.hour, from: Date()); return h >= dayStart && h < nightStart }
    var targetTotal: Double { isDay ? dayTotal : nightTotal }
    var targetCT: Double { isDay ? dayCT : nightCT }

    func notifyFail(_ msg: String) {
        let p = Process(); p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", "display notification \"\(msg)\" with title \"挂灯\""]
        try? p.run()
    }

    // 目标亮度或白天/夜间时间改了：停手 1.5 秒后立刻按新目标重算并渐变（自动调光开着时）
    var targetsWork: DispatchWorkItem?
    func targetsChanged() {
        targetsWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.autoEnabled else { return }
            self.q.async { self.autoAdjust(force: true) }
        }
        targetsWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    // MARK: 与灯通信（都在 q 上执行）

    func refresh() {
        let (rc, out) = lamp(["json"])
        guard rc == 0, let d = out.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let o = j["on"] as? Bool, let b = j["bright"] as? Int, let k = j["ct"] as? Int else {
            DispatchQueue.main.async { self.reachable = false; self.status = "无法连接（可能需要重新登录米家）" }
            return
        }
        DispatchQueue.main.async {
            self.reachable = true; self.on = o
            if !self.settling { self.bright = Double(b); self.ct = Double(k) }
            self.status = o ? "已开启" : "已关闭"
        }
    }

    func setPower(_ v: Bool) {
        rampGen += 1
        q.async {
            let (rc, out) = lamp([v ? "on" : "off"])
            if rc == 0 { self.appliedOn = v } else { log("开关失败: \(out)"); self.notifyFail("灯控制失败，可能需要重新登录米家（扫码）") }
            self.refresh()
        }
    }

    func setManual(bright b: Int, ct k: Int) {
        lastManual = Date()
        rampGen += 1
        rampQ.async {
            let (rc, out) = lamp(["set", String(b), String(k)])
            if rc == 0 {
                self.lastAuto = b; self.lastAutoCT = k
                DispatchQueue.main.async { self.autoEnabled = false }
            } else {
                log("调节失败: \(out)")
                self.lastManual = .distantPast
                self.refresh()   // 失败：立刻读回真实状态，滑块回到灯的实际值
                return
            }
            self.lastManual = Date()
            self.q.asyncAfter(deadline: .now() + 9) { self.refresh() }   // 等云端状态落定后再校对一次（立刻读回会拿到旧值）
        }
    }

    /// 打开浮窗时刷新显示：读一次传感器，按灯当前亮度扣除其贡献；不改动灯
    func updateReadings() {
        guard on, !settling, let als = readALS() else { return }
        let amb = max(als - lampContribution(bright), 1)
        DispatchQueue.main.async { self.sensor = als; self.ambient = amb }
    }

    func resumeAuto() { manualHold = false; q.async { self.autoAdjust(force: true) } }

    // MARK: 锁屏联动

    func applyPower(_ why: String) {
        guard lockLinkEnabled else { return }
        let want = !locked && !asleep
        if appliedOn == want { return }
        rampGen += 1
        let (rc, out) = lamp([want ? "on" : "off"])
        if rc == 0 {
            appliedOn = want
            log("\(why) → 灯\(want ? "开" : "关")")
            if want { lastAuto = nil; lastAutoCT = nil; autoAdjust(force: true) } else { refresh() }
        } else {
            log("控制失败(\(why)): \(out)")
            notifyFail("灯控制失败，可能需要重新登录米家（扫码）")
        }
    }

    // MARK: 自动调光（恒定总亮度）

    func autoAdjust(force: Bool = false) {
        guard !locked, !asleep, let als = readALS() else { return }
        let (rc, out) = lamp(["json"])
        guard rc == 0, let d = out.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let cur = j["bright"] as? Int, let curCT = j["ct"] as? Int, let isOn = j["on"] as? Bool else { return }
        DispatchQueue.main.async { self.reachable = true; self.on = isOn; if !self.settling { self.bright = Double(cur); self.ct = Double(curCT) }; self.status = isOn ? "已开启" : "已关闭" }
        guard isOn else { return }
        let contrib = lampContribution(Double(cur))
        let amb = max(als - contrib, 1)
        history = Array((history + [amb]).suffix(2))
        let med = history.reduce(0, +) / Double(history.count)
        let target = targetTotal
        DispatchQueue.main.async { self.sensor = als; self.contribution = contrib; self.ambient = med }
        guard autoEnabled, !manualHold else { return }
        if !force, Date().timeIntervalSince(lastChange) < minGap { return }
        if !force, (lastAuto.map { abs(Double(cur - $0)) > 5 } ?? false) || (lastAutoCT.map { abs(Double(curCT - $0)) > 200 } ?? false) {
            DispatchQueue.main.async { self.autoEnabled = false }
            log("检测到手动调节（亮度 \(lastAuto ?? 0)→\(cur)，色温 \(lastAutoCT ?? 0)→\(curCT)），已关闭自动调光")
            lastAuto = cur; lastAutoCT = curCT
            return
        }
        let want = brightness(forContribution: target - med)
        let wantCT = Int(((ctFollow ? interpolate(med, ctPoints) : targetCT) / 100).rounded()) * 100
        if force || abs(Double(want - cur)) >= minChange || abs(Double(wantCT - curCT)) >= minChangeCT {
            lastChange = Date()
            log("传感器 \(Int(als))，扣除灯 \(Int(contrib))，环境光 \(Int(med))，目标总亮度 \(Int(target)) → 亮度 \(cur)→\(want)，色温 \(curCT)→\(wantCT)K（渐变）")
            startRamp(fromB: cur, fromCT: curCT, toB: want, toCT: wantCT)
        } else { lastAuto = cur; lastAutoCT = curCT }
    }

    // MARK: 线性渐变

    /// 亮度/色温在固定 3 秒内线性过渡：按“已过去的时间”算当前应有的值并连续发送，
    /// 所以每秒走多少由变化量自动决定，云端慢一点也总是 3 秒左右走完；任何手动操作都会取消
    func startRamp(fromB b0: Int, fromCT c0: Int, toB b1: Int, toCT c1: Int) {
        rampGen += 1
        let gen = rampGen
        let duration = 3.0
        rampQ.async {
            let t0 = Date()
            var sentB = -1, sentK = -1, sentN = 0
            while true {
                guard gen == self.rampGen else { return }
                let f = min(Date().timeIntervalSince(t0) / duration, 1)
                let b = f >= 1 ? b1 : Int((Double(b0) + Double(b1 - b0) * f).rounded())
                let k = f >= 1 ? c1 : Int(((Double(c0) + Double(c1 - c0) * f) / 10).rounded()) * 10
                if b != sentB || k != sentK {
                    let (rc, out) = lamp(["set", String(b), String(k)])
                    guard gen == self.rampGen else { return }
                    if rc != 0 { log("渐变失败: \(out)"); return }
                    sentB = b; sentK = k; sentN += 1
                    self.lastAuto = b; self.lastAutoCT = k; self.lastChange = Date()
                    DispatchQueue.main.async { self.bright = Double(b); self.ct = Double(k) }
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if f >= 1 { log("渐变完成：\(b0)→\(b1)，共 \(sentN) 步，耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒"); return }
            }
        }
    }

    // MARK: 标定

    func calibrate() {
        guard busy.isEmpty else { return }
        DispatchQueue.main.async { self.busy = "标定中…请不要改变房间光线" }
        q.async {
            func median() -> Double {
                var v: [Double] = []
                for _ in 0..<5 { if let x = readALS() { v.append(x) }; Thread.sleep(forTimeInterval: 0.4) }
                return v.isEmpty ? 0 : v.sorted()[v.count / 2]
            }
            let (_, js) = lamp(["json"])
            let prev = (try? JSONSerialization.jsonObject(with: Data(js.utf8))) as? [String: Any]
            lamp(["off"]); Thread.sleep(forTimeInterval: 4); let b1 = median()
            lamp(["on"])
            var rows: [[Double]] = []
            for k in [3000.0, 4800.0, 6500.0] {
                for b in [25.0, 60.0, 100.0] {
                    DispatchQueue.main.async { self.busy = "标定中… \(Int(k))K / \(Int(b))%" }
                    lamp(["set", String(Int(b)), String(Int(k))]); Thread.sleep(forTimeInterval: 3.5)
                    rows.append([k, b, median()])
                }
            }
            lamp(["off"]); Thread.sleep(forTimeInterval: 4); let b2 = median()
            lamp(["on"])
            lamp(["set", String(prev?["bright"] as? Int ?? 60), String(prev?["ct"] as? Int ?? 4500)])
            let base = (b1 + b2) / 2
            let obj: [String: Any] = ["base_off": base, "rows": rows, "time": "\(Date())"]
            if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: URL(fileURLWithPath: calibrationPath)) }
            self.gain = Controller.loadGain()
            log("重新标定完成：关灯基线 \(Int(base))")
            DispatchQueue.main.async { self.busy = "" }
            self.refresh()
        }
    }
}

// MARK: - 界面

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// 色温(K) → 近似 RGB（Tanner Helland 公式）
func kelvinColor(_ k: Double) -> Color {
    let t = max(1000, min(k, 12000)) / 100
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
    func c(_ v: Double) -> Double { max(0, min(255, v)) / 255 }
    return Color(red: c(r), green: c(g), blue: c(b))
}

/// 挂在显示器上的挂灯：灯条发光颜色随色温，光晕与照在屏幕上的光随亮度；关灯时灯条熄灭
struct LampPreview: View, Animatable {
    var level: Double      // 亮度 0–100；关灯为 0
    var ct: Double
    var animatableData: AnimatablePair<Double, Double> {   // 让亮度和色温的变化在示意图上平滑过渡
        get { AnimatablePair(level, ct) }
        set { level = newValue.first; ct = newValue.second }
    }

    var body: some View {
        let on = level > 0.5
        let glow = on ? min(1, 0.34 + 0.66 * level / 100) : 0
        let tint = kelvinColor(ct)
        Canvas { ctx, size in
            let w = size.width
            let cx = w / 2
            let alu = Gradient(colors: [Color(red: 0.90, green: 0.91, blue: 0.93), Color(red: 0.70, green: 0.72, blue: 0.76)])
            func vgrad(_ g: Gradient, _ r: CGRect) -> GraphicsContext.Shading {
                .linearGradient(g, startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY))
            }

            // —— 桌面投影 ——
            var shadow = ctx
            shadow.addFilter(.blur(radius: 3))
            shadow.fill(Path(ellipseIn: CGRect(x: cx - 24, y: 78.5, width: 48, height: 5)), with: .color(.black.opacity(0.22)))

            // —— 支架：颈部 + 底座 ——
            var neck = Path()
            neck.move(to: CGPoint(x: cx - 5, y: 66)); neck.addLine(to: CGPoint(x: cx + 5, y: 66))
            neck.addLine(to: CGPoint(x: cx + 7.5, y: 77.5)); neck.addLine(to: CGPoint(x: cx - 7.5, y: 77.5)); neck.closeSubpath()
            ctx.fill(neck, with: .linearGradient(Gradient(colors: [Color(red: 0.62, green: 0.64, blue: 0.68), Color(red: 0.84, green: 0.85, blue: 0.88), Color(red: 0.62, green: 0.64, blue: 0.68)]),
                                                 startPoint: CGPoint(x: cx - 7, y: 0), endPoint: CGPoint(x: cx + 7, y: 0)))
            let base = CGRect(x: cx - 18, y: 77, width: 36, height: 3.6)
            ctx.fill(Path(roundedRect: base, cornerRadius: 1.8), with: vgrad(alu, base))

            // —— 挂灯的后臂（绕过显示器顶边，在屏幕后面）——
            ctx.fill(Path(roundedRect: CGRect(x: cx - 2.5, y: 10, width: 5, height: 12), cornerRadius: 1.2), with: .color(Color(white: 0.55)))

            // —— 显示器：铝合金外框 + 黑色玻璃边 + 屏幕 ——
            let mon = CGRect(x: 5, y: 17.5, width: w - 10, height: 49)
            ctx.fill(Path(roundedRect: mon, cornerRadius: 5), with: vgrad(alu, mon))
            ctx.stroke(Path(roundedRect: mon, cornerRadius: 5), with: .color(.black.opacity(0.18)), lineWidth: 0.5)
            let glass = mon.insetBy(dx: 2, dy: 2)
            ctx.fill(Path(roundedRect: glass, cornerRadius: 3.4), with: .color(Color(red: 0.03, green: 0.03, blue: 0.04)))
            let screen = glass.insetBy(dx: 1.6, dy: 1.6)
            let sp = Path(roundedRect: screen, cornerRadius: 2.2)
            ctx.fill(sp, with: .linearGradient(Gradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.36), Color(red: 0.27, green: 0.13, blue: 0.40), Color(red: 0.08, green: 0.07, blue: 0.20)]),
                                               startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
            do {   // 屏幕上的界面：菜单栏、窗口、程序坞
                var ui = ctx
                ui.clip(to: sp)
                ui.fill(Path(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 3)), with: .color(.black.opacity(0.35)))
                let win = CGRect(x: screen.minX + 8, y: screen.minY + 9, width: screen.width * 0.52, height: screen.height * 0.5)
                ui.fill(Path(roundedRect: win, cornerRadius: 1.6), with: .color(.white.opacity(0.10)))
                ui.fill(Path(CGRect(x: win.minX, y: win.minY, width: win.width, height: 2.6)), with: .color(.white.opacity(0.10)))
                for (i, c) in [Color.red, Color.yellow, Color.green].enumerated() {
                    ui.fill(Path(ellipseIn: CGRect(x: win.minX + 1.6 + Double(i) * 2.4, y: win.minY + 0.85, width: 1.2, height: 1.2)), with: .color(c.opacity(0.75)))
                }
                for i in 0..<3 {
                    ui.fill(Path(roundedRect: CGRect(x: win.minX + 3, y: win.minY + 6 + Double(i) * 3.6, width: win.width * (i == 1 ? 0.5 : 0.7), height: 1.3), cornerRadius: 0.65), with: .color(.white.opacity(0.14)))
                }
                ui.fill(Path(roundedRect: CGRect(x: cx - 11, y: screen.maxY - 4.6, width: 22, height: 2.8), cornerRadius: 1.4), with: .color(.white.opacity(0.14)))
            }

            // —— 灯光：照在屏幕上的光锥（柔边、向下渐隐）——
            if on {
                var beam = Path()
                beam.move(to: CGPoint(x: cx - 19, y: 17)); beam.addLine(to: CGPoint(x: cx + 19, y: 17))
                beam.addLine(to: CGPoint(x: screen.maxX + 2, y: screen.maxY)); beam.addLine(to: CGPoint(x: screen.minX - 2, y: screen.maxY)); beam.closeSubpath()
                var layer = ctx
                layer.clip(to: sp)
                layer.blendMode = .plusLighter
                layer.addFilter(.blur(radius: 5))
                layer.fill(beam, with: .linearGradient(Gradient(colors: [tint.opacity(0.78 * glow), tint.opacity(0.34 * glow), tint.opacity(0.03 * glow)]),
                                                       startPoint: CGPoint(x: 0, y: 17), endPoint: CGPoint(x: 0, y: screen.maxY)))
                // 上边框被灯照亮
                var rim = ctx
                rim.clip(to: Path(roundedRect: mon, cornerRadius: 5))
                rim.blendMode = .plusLighter
                rim.addFilter(.blur(radius: 2))
                rim.fill(Path(CGRect(x: cx - 24, y: 17.5, width: 48, height: 5)), with: .color(tint.opacity(0.32 * glow)))
            }
            // 玻璃反光
            do {
                var gl = ctx; gl.clip(to: sp)
                var p = Path()
                p.move(to: CGPoint(x: screen.minX + screen.width * 0.52, y: screen.minY)); p.addLine(to: CGPoint(x: screen.minX + screen.width * 0.82, y: screen.minY))
                p.addLine(to: CGPoint(x: screen.minX + screen.width * 0.40, y: screen.maxY)); p.addLine(to: CGPoint(x: screen.minX + screen.width * 0.10, y: screen.maxY)); p.closeSubpath()
                gl.fill(p, with: .linearGradient(Gradient(colors: [.white.opacity(0.10), .white.opacity(0.0)]), startPoint: CGPoint(x: 0, y: screen.minY), endPoint: CGPoint(x: 0, y: screen.maxY)))
            }

            // —— 灯条：金属机身 + 发光槽 ——
            let bar = CGRect(x: cx - 25, y: 7.6, width: 50, height: 8.6)
            if on {   // 光晕
                var g = ctx
                g.blendMode = .plusLighter
                g.addFilter(.blur(radius: 4 + 5 * glow))
                g.fill(Path(roundedRect: CGRect(x: bar.minX + 2, y: bar.maxY - 4.5, width: bar.width - 4, height: 4), cornerRadius: 2), with: .color(tint.opacity(0.85 * glow)))
            }
            let bp = Path(roundedRect: bar, cornerRadius: 4.3)
            ctx.fill(bp, with: vgrad(Gradient(colors: [Color(red: 0.95, green: 0.95, blue: 0.97), Color(red: 0.74, green: 0.75, blue: 0.79), Color(red: 0.60, green: 0.62, blue: 0.66)]), bar))
            ctx.stroke(bp, with: .color(.black.opacity(0.22)), lineWidth: 0.6)
            // 发光槽（机身下沿）
            let slot = CGRect(x: bar.minX + 4, y: bar.maxY - 3.9, width: bar.width - 8, height: 2.3)
            let sp2 = Path(roundedRect: slot, cornerRadius: 1.15)
            if on {
                ctx.fill(sp2, with: .linearGradient(Gradient(colors: [.white.opacity(0.9), tint]), startPoint: CGPoint(x: 0, y: slot.minY), endPoint: CGPoint(x: 0, y: slot.maxY)))
            } else {
                ctx.fill(sp2, with: .color(Color(red: 0.36, green: 0.37, blue: 0.40)))
            }
            // 机身高光
            ctx.fill(Path(roundedRect: CGRect(x: bar.minX + 5, y: bar.minY + 1.0, width: bar.width - 10, height: 1.3), cornerRadius: 0.65), with: .color(.white.opacity(0.65)))
        }
    }
}

struct SliderRow: View {
    let icon: String, title: String, unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>, step: Double
    let tint: Color
    let onCommit: () -> Void
    var onEditing: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Int(value))\(unit)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: { editing in onEditing(editing); if !editing { onCommit() } }).tint(tint)
        }
    }
}

final class UIState: ObservableObject { @Published var showSettings = false }

struct Popover: View {
    @ObservedObject var c: Controller
    @StateObject private var ui = UIState()

    var powerBinding: Binding<Bool> { Binding(get: { c.on }, set: { c.on = $0; c.setPower($0) }) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: c.on ? "lightbulb.fill" : "lightbulb")
                    .font(.title2).foregroundStyle(c.on ? Color.yellow : Color.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("米家显示器挂灯 2").font(.system(size: 13, weight: .semibold))
                    Text(c.status).font(.caption).foregroundStyle(c.reachable ? Color.secondary : Color.red)
                }
                Spacer()
                Toggle("", isOn: powerBinding).toggleStyle(.switch).labelsHidden().disabled(!c.reachable)
            }

            Card {
                HStack(spacing: 14) {
                    VStack(spacing: 12) {
                        SliderRow(icon: "sun.max.fill", title: "亮度", unit: "%", value: $c.bright, range: 1...100, step: 1, tint: .orange, onCommit: {
                            c.setManual(bright: Int(c.bright), ct: Int(c.ct))
                        }, onEditing: { c.editing = $0 })
                        SliderRow(icon: "thermometer.medium", title: "色温", unit: "K", value: $c.ct, range: 2700...6500, step: 100, tint: .blue, onCommit: {
                            c.setManual(bright: Int(c.bright), ct: Int(c.ct))
                        }, onEditing: { c.editing = $0 })
                    }
                    LampPreview(level: c.on ? c.bright : 0, ct: c.ct)
                        .animation(.easeInOut(duration: 0.5), value: c.on ? c.bright : 0)
                        .animation(.easeInOut(duration: 0.5), value: c.ct)
                        .frame(width: 92, height: 86)
                }
            }.disabled(!c.on)

            Card {
                Toggle(isOn: $c.autoEnabled) {
                    Label("自动调光", systemImage: "sparkles")
                }.toggleStyle(.switch)
                HStack(alignment: .top) {
                    stat("环境光", c.ambient.map { String(Int($0)) } ?? "—")
                    Divider().frame(height: 28)
                    stat("灯贡献", c.on ? String(Int(c.lampContribution(c.bright))) : "—")
                    Divider().frame(height: 28)
                    stat("总亮度", c.ambient.map { String(Int($0 + (c.on ? c.lampContribution(c.bright) : 0))) } ?? "—")
                    Divider().frame(height: 28)
                    stat(c.isDay ? "白天目标" : "夜间目标", String(Int(c.targetTotal)))
                }
                Toggle(isOn: $c.ctFollow) {
                    Label("色温跟随环境光", systemImage: "thermometer.sun")
                }.toggleStyle(.switch)
                HStack {
                    Text("目标色温").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(c.ctFollow ? "随环境光（越暗越暖）" : "\(Int(c.targetCT))K（\(c.isDay ? "白天" : "夜间")）")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !c.autoEnabled {
                    Text("自动调光已关闭，灯保持你的设置；打开开关后恢复自动。").font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $c.lockLinkEnabled) {
                    Label("锁屏关灯 / 解锁开灯", systemImage: "lock.fill")
                }.toggleStyle(.switch)
            }

            DisclosureGroup(isExpanded: $ui.showSettings) {
                VStack(spacing: 10) {
                    settingRow("白天目标亮度", "\(Int(c.dayTotal))") { Stepper("", value: $c.dayTotal, in: 100...1000, step: 50).labelsHidden() }
                    settingRow("夜间目标亮度", "\(Int(c.nightTotal))") { Stepper("", value: $c.nightTotal, in: 100...1000, step: 50).labelsHidden() }
                    settingRow("白天目标色温", "\(Int(c.dayCT))K") { Stepper("", value: $c.dayCT, in: 2700...6500, step: 100).labelsHidden() }.opacity(c.ctFollow ? 0.4 : 1).disabled(c.ctFollow)
                    settingRow("夜间目标色温", "\(Int(c.nightCT))K") { Stepper("", value: $c.nightCT, in: 2700...6500, step: 100).labelsHidden() }.opacity(c.ctFollow ? 0.4 : 1).disabled(c.ctFollow)
                    settingRow("白天开始", "\(c.dayStart):00") { Stepper("", value: $c.dayStart, in: 0...12).labelsHidden() }
                    settingRow("夜间开始", "\(c.nightStart):00") { Stepper("", value: $c.nightStart, in: 13...23).labelsHidden() }
                    HStack {
                        Button("重新标定") { c.calibrate() }.disabled(!c.busy.isEmpty || !c.on)
                        if !c.busy.isEmpty { Text(c.busy).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }
                }.padding(.top, 8)
            } label: {
                Text("设置").font(.subheadline)
            }

            HStack {
                Text("目标亮度 = 环境光 + 灯").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { c.q.async { c.refresh(); c.updateReadings() } }
    }

    func settingRow<S: View>(_ title: String, _ value: String, @ViewBuilder _ control: () -> S) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            control()
        }
    }

    func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .medium, design: .rounded).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

@main
struct LightBarApp: App {
    @StateObject private var c = Controller()
    var body: some Scene {
        MenuBarExtra {
            Popover(c: c)
        } label: {
            Image(systemName: c.on ? "lightbulb.fill" : "lightbulb")
        }
        .menuBarExtraStyle(.window)
    }
}
