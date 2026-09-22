import AppKit
import UniformTypeIdentifiers

import Darwin

struct MemorySnapshot {
    let total: UInt64
    let reclaimableEstimate: UInt64?
    let resident: UInt64?
    var pressure: String
    var footprint: UInt64? = nil
    var compressed: UInt64? = nil
    var swapPages: UInt64? = nil
    var compressionPages: UInt64? = nil
    var availableText: String { reclaimableEstimate.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "暂不可用" }
    var residentText: String { resident.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "暂不可用" }
}

final class SystemMonitor {
    let chip: String
    let total = ProcessInfo.processInfo.physicalMemory
    init() {
        var size = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            chip = sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 ? String(cString: bytes) : "未知芯片"
        } else { chip = "未知芯片" }
    }
    func sample() -> MemorySnapshot {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        // Inactive pages are only potentially reclaimable; this is not a safe allocation budget.
        let estimate: UInt64? = result == KERN_SUCCESS ? min(total, (UInt64(vm.free_count) + UInt64(vm.inactive_count)) * UInt64(vm_kernel_page_size)) : nil
        var info = mach_task_basic_info_data_t()
        var taskCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let taskResult = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(taskCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &taskCount)
            }
        }
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let ok = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0
        let label = !ok ? "未知" : pressure == 1 ? "正常" : pressure == 2 ? "偏高" : pressure == 4 ? "较高" : "未知"
        var taskVM = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &taskVM) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        return MemorySnapshot(total: total, reclaimableEstimate: estimate, resident: taskResult == KERN_SUCCESS ? UInt64(info.resident_size) : nil, pressure: label,
            footprint: vmResult == KERN_SUCCESS ? taskVM.phys_footprint : nil,
            compressed: vmResult == KERN_SUCCESS ? taskVM.compressed : nil,
            swapPages: result == KERN_SUCCESS ? vm.swapins + vm.swapouts : nil,
            compressionPages: result == KERN_SUCCESS ? vm.compressions : nil)
    }
}

final class AppTracker {
    var onChange: ((NSRunningApplication) -> Void)?
    private var observer: NSObjectProtocol?
    private(set) var current: NSRunningApplication?
    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.accept(app)
        }
        if let app = NSWorkspace.shared.frontmostApplication { accept(app) }
    }
    func refresh() { if let app = NSWorkspace.shared.frontmostApplication { accept(app) } }
    private func accept(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular else { return }
        guard current?.processIdentifier != app.processIdentifier else { return }
        current = app
        onChange?(app)
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}

func imageForApp(_ app: NSRunningApplication?) -> NSImage {
    if let url = app?.bundleURL { return NSWorkspace.shared.icon(forFile: url.path) }
    if let icon = app?.icon { return icon }
    return NSWorkspace.shared.icon(for: .applicationBundle)
}
