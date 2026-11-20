#if DEBUG
import AppKit

/// Debug-only: `-debugSnapshot /path/file.png [-debugSnapshotDelay 8]` writes a PNG of the main window
/// after a delay, then quits. Lets UI be checked from a script without screen-recording permission.
enum DebugSnapshot {
    @MainActor static func scheduleIfRequested() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "debugSnapshot") else { return }
        let delay = defaults.double(forKey: "debugSnapshotDelay")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 8))
            for w in NSApp.windows {
                FileHandle.standardError.write(Data("window \(type(of: w)) visible=\(w.isVisible) frame=\(w.frame) title=\(w.title)\n".utf8))
            }
            // `-debugSnapshotWindow <title>` picks a window by title; otherwise the largest visible one.
            let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            let titled = defaults.string(forKey: "debugSnapshotWindow").flatMap { t in visible.first { $0.title == t } }
            guard let window = titled ?? visible
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            if defaults.bool(forKey: "debugSnapshotKeepOpen") == false { NSApp.terminate(nil) }
        }
    }
}
#endif
