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
let totalTolerance = 10.0   // 总亮度偏离目标超过这么多才调光
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

    /// 手动校准：用最新一次传感器读数（不与旧读数平均）立刻把总亮度拉回目标；自动调光关着也照做一次，但不改开关状态
    func calibrateNow() {
        guard busy.isEmpty else { return }
        busy = "校准中…"
        q.async {
            self.history = []
            self.autoAdjust(force: true, oneShot: true)
            DispatchQueue.main.async { self.busy = "" }
        }
    }

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
            if want {
                lastAuto = nil; lastAutoCT = nil
                // 云端刚写入“开”时立刻读回会拿到旧状态（还是关），等几秒再按环境光调光
                q.asyncAfter(deadline: .now() + 3) { if !self.locked && !self.asleep { self.autoAdjust(force: true) } }
            } else { refresh() }
        } else {
            log("控制失败(\(why)): \(out)")
            notifyFail("灯控制失败，可能需要重新登录米家（扫码）")
        }
    }

    // MARK: 自动调光（恒定总亮度）

    func autoAdjust(force: Bool = false, oneShot: Bool = false) {
        guard !locked, !asleep else { return }
        var reading = readALS()
        for _ in 0..<3 where reading == nil { Thread.sleep(forTimeInterval: 1); reading = readALS() }   // 刚解锁/唤醒时传感器可能暂时读不到
        guard let als = reading else { log("环境光传感器读取失败，跳过本次调光"); return }
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
        guard oneShot || (autoEnabled && !manualHold) else { return }
        if !force, Date().timeIntervalSince(lastChange) < minGap { return }
        if !force, (lastAuto.map { abs(Double(cur - $0)) > 5 } ?? false) || (lastAutoCT.map { abs(Double(curCT - $0)) > 200 } ?? false) {
            DispatchQueue.main.async { self.autoEnabled = false }
            log("检测到手动调节（亮度 \(lastAuto ?? 0)→\(cur)，色温 \(lastAutoCT ?? 0)→\(curCT)），已关闭自动调光")
            lastAuto = cur; lastAutoCT = curCT
            return
        }
        let want = brightness(forContribution: target - med)
        let wantCT = Int(((ctFollow ? interpolate(med, ctPoints) : targetCT) / 100).rounded()) * 100
        let error = med + contrib - target   // 当前总亮度相对目标的偏差
        if force || (abs(error) >= totalTolerance && want != cur) || abs(Double(wantCT - curCT)) >= minChangeCT {
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

/// 当前壁纸（锁屏默认沿用桌面壁纸）：动态/航拍壁纸用系统缓存的静态缩略图，普通图片直接读文件；读不到返回 nil
func currentWallpaper() -> NSImage? {
    func firstFileURL(_ obj: Any?) -> URL? {
        if let str = obj as? String, str.hasPrefix("file://") { return URL(string: str) }
        if let d = obj as? [String: Any] { for v in d.values { if let u = firstFileURL(v) { return u } } }
        if let a = obj as? [Any] { for v in a { if let u = firstFileURL(v) { return u } } }
        return nil
    }
    let base = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper"
    if let data = FileManager.default.contents(atPath: base + "/Store/Index.plist"),
       let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let linked = (root[key] as? [String: Any])?["Linked"] as? [String: Any],
                  let content = linked["Content"] as? [String: Any],
                  let ch = (content["Choices"] as? [[String: Any]])?.first else { continue }
            if let cfgData = ch["Configuration"] as? Data,
               let cfg = try? PropertyListSerialization.propertyList(from: cfgData, format: nil) {
                if let id = (cfg as? [String: Any])?["assetID"] as? String,
                   let img = NSImage(contentsOfFile: base + "/aerials/thumbnails/\(id).png") { return img }
                if let u = firstFileURL(cfg), let img = NSImage(contentsOf: u) { return img }
            }
            if let u = firstFileURL(ch["Files"]), let img = NSImage(contentsOf: u) { return img }
        }
    }
    if let scr = NSScreen.main, let u = NSWorkspace.shared.desktopImageURL(for: scr), let img = NSImage(contentsOf: u) { return img }
    return nil
}

/// 实物示意：黑色窄边框显示器 + 哑光黑色圆柱挂灯（中间卡扣挂在顶边）。
/// 灯条下沿的发光条颜色随色温，光晕随亮度；关灯时发光条熄灭
struct LampPreview: View, Animatable {
    var level: Double      // 亮度 0–100；关灯为 0
    var ct: Double
    var wallpaper: NSImage? = nil   // 屏幕上显示的壁纸；nil 时画一幅示意的红杉林
    var animatableData: AnimatablePair<Double, Double> {   // 让亮度和色温的变化在示意图上平滑过渡
        get { AnimatablePair(level, ct) }
        set { level = newValue.first; ct = newValue.second }
    }

    var body: some View {
        let on = level > 0.5
        let glow = on ? 0.04 + 0.96 * pow(level / 100, 0.8) : 0   // 低亮度几乎暗淡，高亮度很强：对比明显
        let tint = kelvinColor(ct)
        Canvas { ctx, size in
            let w = size.width
            let cx = w / 2
            func vgrad(_ colors: [Color], _ r: CGRect) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY))
            }

            // —— 桌面投影 ——
            var sh = ctx
            sh.addFilter(.blur(radius: 3))
            sh.fill(Path(ellipseIn: CGRect(x: cx - 22, y: 80.5, width: 44, height: 4.5)), with: .color(.black.opacity(0.22)))

            // —— 支架：细颈 + 底座（黑色）——
            var neck = Path()
            neck.move(to: CGPoint(x: cx - 3.6, y: 72)); neck.addLine(to: CGPoint(x: cx + 3.6, y: 72))
            neck.addLine(to: CGPoint(x: cx + 4.6, y: 80)); neck.addLine(to: CGPoint(x: cx - 4.6, y: 80)); neck.closeSubpath()
            ctx.fill(neck, with: .linearGradient(Gradient(colors: [Color(white: 0.08), Color(white: 0.24), Color(white: 0.08)]),
                                                 startPoint: CGPoint(x: cx - 5, y: 0), endPoint: CGPoint(x: cx + 5, y: 0)))
            let base = CGRect(x: cx - 15, y: 79.5, width: 30, height: 2.6)
            ctx.fill(Path(roundedRect: base, cornerRadius: 1.3), with: vgrad([Color(white: 0.30), Color(white: 0.10)], base))

            // —— 显示器：黑色窄边框，底部略厚 ——
            let mon = CGRect(x: 3, y: 17, width: w - 6, height: 56)
            let monP = Path(roundedRect: mon, cornerRadius: 2.6)
            ctx.fill(monP, with: vgrad([Color(white: 0.20), Color(white: 0.07)], mon))
            ctx.stroke(monP, with: .color(.white.opacity(0.17)), lineWidth: 0.5)
            let screen = CGRect(x: mon.minX + 1.7, y: mon.minY + 1.7, width: mon.width - 3.4, height: mon.height - 1.7 - 3.2)
            let scP = Path(roundedRect: screen, cornerRadius: 0.8)

            // 屏幕：用户的壁纸（带迷你锁屏时钟）；读不到壁纸时画一幅示意的红杉林
            if let wp = wallpaper {
                var s = ctx
                s.clip(to: scP)
                let img = s.resolve(Image(nsImage: wp))
                let ar = wp.size.width / max(wp.size.height, 1), sr = screen.width / screen.height
                let dw = ar > sr ? screen.height * ar : screen.width, dh = ar > sr ? screen.height : screen.width / ar
                s.draw(img, in: CGRect(x: screen.midX - dw / 2, y: screen.midY - dh / 2, width: dw, height: dh))
                s.fill(scP, with: .linearGradient(Gradient(colors: [.black.opacity(0.18), .black.opacity(0.0), .black.opacity(0.22)]),
                                                  startPoint: CGPoint(x: 0, y: screen.minY), endPoint: CGPoint(x: 0, y: screen.maxY)))
                let f = DateFormatter(); f.dateFormat = "H:mm"
                s.draw(Text(f.string(from: Date())).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.92)),
                       at: CGPoint(x: screen.midX, y: screen.minY + 9.5), anchor: .center)
                s.fill(Path(roundedRect: CGRect(x: screen.midX - 7, y: screen.minY + 16.2, width: 14, height: 1.1), cornerRadius: 0.55), with: .color(.white.opacity(0.55)))
                s.fill(Path(ellipseIn: CGRect(x: screen.midX - 2.8, y: screen.maxY - 12, width: 5.6, height: 5.6)), with: .color(.white.opacity(0.55)))
                s.fill(Path(roundedRect: CGRect(x: screen.midX - 6, y: screen.maxY - 5, width: 12, height: 1.2), cornerRadius: 0.6), with: .color(.white.opacity(0.5)))
            } else {
                var s = ctx
                s.clip(to: scP)
                s.fill(scP, with: .linearGradient(Gradient(colors: [Color(red: 0.50, green: 0.58, blue: 0.76), Color(red: 0.42, green: 0.48, blue: 0.50), Color(red: 0.15, green: 0.24, blue: 0.16)]),
                                                  startPoint: CGPoint(x: 0, y: screen.minY), endPoint: CGPoint(x: 0, y: screen.maxY)))
                // 远处的树
                for i in 0..<20 {
                    let x = screen.minX + Double((i * 37) % 100) / 100 * screen.width
                    let ww = 0.9 + Double(i % 3) * 0.5
                    s.fill(Path(CGRect(x: x, y: screen.minY + Double(i % 4) * 2, width: ww, height: screen.height)), with: .color(Color(red: 0.10, green: 0.19, blue: 0.14).opacity(0.38 + Double(i % 3) * 0.10)))
                }
                // 近处的红杉树干
                for (f, tw) in [(0.15, 7.8), (0.47, 6.6), (0.72, 8.2), (0.95, 5.0)] as [(Double, Double)] {
                    let r = CGRect(x: screen.minX + screen.width * f - tw / 2, y: screen.minY, width: tw, height: screen.height)
                    s.fill(Path(r), with: .linearGradient(Gradient(colors: [Color(red: 0.25, green: 0.12, blue: 0.09), Color(red: 0.43, green: 0.22, blue: 0.15), Color(red: 0.21, green: 0.10, blue: 0.08)]),
                                                          startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
                }
                // 光束与雾
                var rays = s
                rays.blendMode = .plusLighter
                rays.addFilter(.blur(radius: 2.4))
                for k in 0..<5 {
                    var p = Path()
                    let x0 = screen.minX + 4 + Double(k) * 2.6
                    p.move(to: CGPoint(x: x0, y: screen.minY)); p.addLine(to: CGPoint(x: x0 + 3, y: screen.minY))
                    p.addLine(to: CGPoint(x: x0 + 34 + Double(k) * 9, y: screen.maxY)); p.addLine(to: CGPoint(x: x0 + 20 + Double(k) * 9, y: screen.maxY)); p.closeSubpath()
                    rays.fill(p, with: .color(Color(red: 1, green: 0.94, blue: 0.78).opacity(0.10)))
                }
                rays.fill(Path(ellipseIn: CGRect(x: screen.minX + screen.width * 0.28, y: screen.minY + screen.height * 0.40, width: screen.width * 0.5, height: screen.height * 0.55)),
                          with: .color(Color(red: 1, green: 0.97, blue: 0.9).opacity(0.10)))
                // 林下的灌木
                s.fill(Path(CGRect(x: screen.minX, y: screen.maxY - 7, width: screen.width, height: 7)),
                       with: vgrad([Color(red: 0.20, green: 0.32, blue: 0.20).opacity(0), Color(red: 0.14, green: 0.26, blue: 0.15).opacity(0.9)], CGRect(x: 0, y: screen.maxY - 7, width: 1, height: 7)))
            }

            // —— 灯光：灯条主要照亮显示器的顶部边框，只有极淡的一层漫到屏幕上沿（不能过曝）——
            if on {
                var lit = ctx
                lit.clip(to: monP)
                lit.blendMode = .plusLighter
                lit.addFilter(.blur(radius: 1.4))
                lit.fill(Path(CGRect(x: cx - 36, y: mon.minY - 1, width: 72, height: 2.6)), with: .color(tint.opacity(0.55 * glow)))
                var spill = ctx
                spill.clip(to: scP)
                spill.addFilter(.blur(radius: 3))
                spill.fill(Path(ellipseIn: CGRect(x: cx - 34, y: screen.minY - 7, width: 68, height: 7 + 5 * glow)), with: .color(tint.opacity(0.13 * glow)))
            }
            // 玻璃反光
            do {
                var gl = ctx; gl.clip(to: scP)
                var p = Path()
                p.move(to: CGPoint(x: screen.minX + screen.width * 0.58, y: screen.minY)); p.addLine(to: CGPoint(x: screen.minX + screen.width * 0.84, y: screen.minY))
                p.addLine(to: CGPoint(x: screen.minX + screen.width * 0.44, y: screen.maxY)); p.addLine(to: CGPoint(x: screen.minX + screen.width * 0.18, y: screen.maxY)); p.closeSubpath()
                gl.fill(p, with: .linearGradient(Gradient(colors: [.white.opacity(0.10), .white.opacity(0.0)]), startPoint: CGPoint(x: 0, y: screen.minY), endPoint: CGPoint(x: 0, y: screen.maxY)))
            }

            // —— 挂灯：黑色哑光圆柱灯条 + 中间卡扣 ——
            let barW = (w - 6) * 0.86
            let bar = CGRect(x: cx - barW / 2, y: 6, width: barW, height: 5.2)
            // 卡扣：从灯条中部下来，扣在显示器顶边
            let clip = CGRect(x: cx - 5.2, y: 9, width: 10.4, height: 11)
            ctx.fill(Path(roundedRect: clip, cornerRadius: 1.4), with: vgrad([Color(white: 0.20), Color(white: 0.07)], clip))
            ctx.stroke(Path(roundedRect: clip, cornerRadius: 1.4), with: .color(.white.opacity(0.10)), lineWidth: 0.4)
            // 光晕（灯条下沿）
            if on {
                var g = ctx
                g.blendMode = .plusLighter
                g.addFilter(.blur(radius: 2 + 7 * glow))
                g.fill(Path(roundedRect: CGRect(x: bar.minX + 4, y: bar.maxY - 2.4, width: bar.width - 8, height: 3.2), cornerRadius: 1.6), with: .color(tint.opacity(1.0 * glow)))
            }
            let bp = Path(roundedRect: bar, cornerRadius: bar.height / 2)
            ctx.fill(bp, with: vgrad([Color(white: 0.34), Color(white: 0.14), Color(white: 0.05)], bar))
            ctx.stroke(bp, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
            // 圆柱高光
            ctx.fill(Path(roundedRect: CGRect(x: bar.minX + 4, y: bar.minY + 0.9, width: bar.width - 8, height: 0.9), cornerRadius: 0.45), with: .color(.white.opacity(0.32)))
            // 下沿发光条
            let slot = CGRect(x: bar.minX + 3.2, y: bar.maxY - 1.7 - 0.6 * glow, width: bar.width - 6.4, height: 0.7 + 0.9 * glow)
            if on {
                ctx.fill(Path(roundedRect: slot, cornerRadius: 0.5), with: .linearGradient(Gradient(colors: [.white.opacity(0.95 * (0.3 + 0.7 * glow)), tint.opacity(0.35 + 0.65 * glow)]), startPoint: CGPoint(x: 0, y: slot.minY), endPoint: CGPoint(x: 0, y: slot.maxY)))
            }
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

final class UIState: ObservableObject {
    @Published var showSettings = false
    @Published var wallpaper: NSImage? = currentWallpaper()
}

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
                    LampPreview(level: c.on ? c.bright : 0, ct: c.ct, wallpaper: ui.wallpaper)
                        .animation(.easeInOut(duration: 0.5), value: c.on ? c.bright : 0)
                        .animation(.easeInOut(duration: 0.5), value: c.ct)
                        .frame(width: 108, height: 86)
                }
            }.disabled(!c.on)

            Card {
                HStack {
                    Toggle(isOn: $c.autoEnabled) {
                        Label("自动调光", systemImage: "sparkles")
                    }.toggleStyle(.switch)
                    Spacer()
                    Button("立即校准") { c.calibrateNow() }
                        .controlSize(.small)
                        .disabled(!c.busy.isEmpty || !c.on)
                        .help("按当前环境光立刻把总亮度调回目标")
                }
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
        .onAppear { ui.wallpaper = currentWallpaper(); c.q.async { c.refresh(); c.updateReadings() } }
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
