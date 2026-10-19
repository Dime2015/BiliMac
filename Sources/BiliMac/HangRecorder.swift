import AppKit
import os

/// When the main thread stops answering for over a second, writes what was on screen and a `sample` of the
/// process to ~/Library/Logs/BiliMac, so a stall seen once on someone's Mac can be looked at afterwards.
/// Costs one 0.1 s timer on the main thread and a sleeping background thread; nothing leaves the Mac.
enum HangRecorder {
    private static let beat = OSAllocatedUnfairLock(initialState: CACurrentMediaTime())
    /// What the app showed, set from the main thread for the background watcher to read.
    static let context = OSAllocatedUnfairLock(initialState: "")

    static var folder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/BiliMac", isDirectory: true)
    }

    @MainActor static func start() {
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in beat.withLock { $0 = CACurrentMediaTime() } }
        RunLoop.main.add(t, forMode: .common)
        Thread.detachNewThread {
            var sampling = false
            var lastSample = 0.0
            var worst = 0.0
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                let gap = CACurrentMediaTime() - beat.withLock { $0 }
                if gap > 1 {
                    worst = max(worst, gap)
                    // One sample per stall, at most one a minute.
                    if !sampling, CACurrentMediaTime() - lastSample > 60 {
                        sampling = true
                        lastSample = CACurrentMediaTime()
                        record { sampling = false }
                    }
                } else if worst > 0 {
                    append(String(format: "main thread blocked %.1f s · %@", worst, context.withLock { $0 }))
                    worst = 0
                }
            }
        }
    }

    private static func record(done: @escaping @Sendable () -> Void) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let file = folder.appendingPathComponent("hang-\(f.string(from: Date())).txt")
        append("stall started · sampling to \(file.lastPathComponent) · \(context.withLock { $0 })")
        // Keep the newest few.
        if let old = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("hang-") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            for u in old.dropFirst(8) { try? fm.removeItem(at: u) }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in done() }
        do { try p.run() } catch { done() }
    }

    private static func append(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let url = folder.appendingPathComponent("hangs.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data("[\(f.string(from: Date()))] \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
