import Darwin
import Foundation

/// One look at how the Mac is doing: memory pressure, swap, CPU load, what uses them, disk, battery, heat.
public struct HealthReport: Codable, Sendable {
    public struct Process: Codable, Sendable, Identifiable, Hashable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var name: String
        public var cpu: Double
        public var memory: Int64
    }
    public struct Battery: Codable, Sendable, Hashable {
        public var percent: Int
        public var charging: Bool
        public var cycles: Int?
        /// Full-charge capacity as a share of the design capacity.
        public var health: Int?
        public var condition: String?
    }
    public enum Pressure: String, Codable, Sendable { case normal, warning, critical }

    public var date = Date()
    public var memoryTotal: Int64 = 0
    /// App memory + wired + compressed: what Activity Monitor calls "Memory Used".
    public var memoryUsed: Int64 = 0
    public var memoryCompressed: Int64 = 0
    public var pressure: Pressure = .normal
    public var swapUsed: Int64 = 0
    public var swapTotal: Int64 = 0
    public var load: [Double] = []
    public var cores: Int = 0
    public var topCPU: [Process] = []
    public var topMemory: [Process] = []
    public var volume: VolumeInfo?
    public var battery: Battery?
    public var thermal: String = "Normal"
    public var uptime: TimeInterval = 0

    /// 0–100. Starts at 100 and loses points for memory pressure, swap, load, low disk, heat and a worn battery.
    public var score: Int {
        var s = 100
        switch pressure { case .warning: s -= 20; case .critical: s -= 40; case .normal: break }
        if swapTotal > 0 { s -= Int(15 * Double(swapUsed) / Double(swapTotal)) }
        if cores > 0, let l = load.first { s -= min(20, Int(max(0, l / Double(cores) - 0.7) * 25)) }
        if let v = volume, v.total > 0 {
            let free = Double(v.available) / Double(v.total)
            if free < 0.05 { s -= 25 } else if free < 0.10 { s -= 15 } else if free < 0.20 { s -= 5 }
        }
        if thermal == "Serious" { s -= 10 } else if thermal == "Critical" { s -= 25 }
        if let h = battery?.health, h < 80 { s -= 5 }
        return max(0, min(100, s))
    }

    public var verdict: String {
        switch score {
        case 85...: "Running well"
        case 65..<85: "A little strained"
        case 40..<65: "Under pressure"
        default: "Struggling"
        }
    }

    /// Plain-language reasons the score is not 100, most important first.
    public var advice: [String] {
        var out: [String] = []
        if pressure != .normal {
            let hog = topMemory.first.map { " \($0.name) uses the most (\(Format.bytes($0.memory)))." } ?? ""
            out.append("Memory is \(pressure == .critical ? "nearly full" : "tight"), so macOS is compressing and swapping.\(hog) Quit apps you aren't using.")
        }
        if swapTotal > 0, Double(swapUsed) / Double(swapTotal) > 0.5 {
            out.append("Swap is \(Int(100 * Double(swapUsed) / Double(swapTotal)))% full (\(Format.bytes(swapUsed))). A restart clears it.")
        }
        if cores > 0, let l = load.first, l > Double(cores) {
            let hog = topCPU.first.map { " \($0.name) is the busiest at \(Int($0.cpu))% CPU." } ?? ""
            out.append("The processor is busier than its \(cores) cores can keep up with.\(hog)")
        }
        if let v = volume, v.total > 0, Double(v.available) / Double(v.total) < 0.15 {
            out.append("Only \(Format.bytes(v.available)) free. macOS needs room for swap and updates; aim for 15% or more.")
        }
        if thermal == "Serious" || thermal == "Critical" { out.append("The Mac is running hot and slowing itself down to cool off.") }
        if let b = battery, let h = b.health, h < 80 { out.append("The battery holds \(h)% of its original charge after \(b.cycles ?? 0) cycles. Consider a service.") }
        return out
    }
}

public enum Health {
    public static func report() -> HealthReport {
        var r = HealthReport()
        r.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        r.cores = ProcessInfo.processInfo.activeProcessorCount
        r.uptime = ProcessInfo.processInfo.systemUptime
        r.thermal = ["Normal", "Fair", "Serious", "Critical"][min(3, ProcessInfo.processInfo.thermalState.rawValue)]

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            r.memoryCompressed = Int64(stats.compressor_page_count) * page
            r.memoryUsed = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        }
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            r.pressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            r.swapUsed = Int64(swap.xsu_used); r.swapTotal = Int64(swap.xsu_total)
        }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { r.load = loads }

        // Chromium and Electron apps run dozens of helpers; count them under the app.
        var grouped: [String: HealthReport.Process] = [:]
        for p in processes() {
            var name = p.name
            if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }
            if name == "Browser" { name = "Arc" }
            grouped[name, default: .init(pid: p.pid, name: name, cpu: 0, memory: 0)].cpu += p.cpu
            grouped[name]!.memory += p.memory
        }
        let procs = Array(grouped.values)
        r.topCPU = Array(procs.sorted { $0.cpu > $1.cpu }.prefix(6))
        r.topMemory = Array(procs.sorted { $0.memory > $1.memory }.prefix(6))
        r.volume = SystemProbe.volume()
        r.battery = battery()
        return r
    }

    /// Every process with its CPU share and resident memory, apps grouped under their own name.
    static func processes() -> [HealthReport.Process] {
        let out = Shell.run(["ps", "-Aceo", "pid=,pcpu=,rss=,comm="], timeout: 5).out
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = Int64(f[2]) else { return nil }
            return HealthReport.Process(pid: pid, name: String(f[3]), cpu: cpu, memory: rss * 1024)
        }
    }

    static func battery() -> HealthReport.Battery? {
        let out = Shell.run(["pmset", "-g", "batt"], timeout: 5).out
        guard let m = out.range(of: "[0-9]+%", options: .regularExpression), let pct = Int(out[m].dropLast()) else { return nil }
        var b = HealthReport.Battery(percent: pct, charging: out.contains("AC Power") && !out.contains("discharging"))
        let reg = Shell.run(["ioreg", "-rn", "AppleSmartBattery"], timeout: 5).out
        func value(_ key: String) -> Int? {
            guard let r = reg.range(of: "\"\(key)\" = [0-9]+", options: .regularExpression) else { return nil }
            return Int(reg[r].split(separator: " ").last ?? "")
        }
        b.cycles = value("CycleCount")
        if let maxCap = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity"), let design = value("DesignCapacity"), design > 0 {
            b.health = min(100, Int((Double(maxCap) / Double(design) * 100).rounded()))
        }
        let cond = Shell.run(["system_profiler", "SPPowerDataType"], timeout: 10).out
        if let r = cond.range(of: "Condition: [A-Za-z ]+", options: .regularExpression) {
            b.condition = String(cond[r].dropFirst("Condition: ".count)).trimmingCharacters(in: .whitespaces)
        }
        return b
    }
}
