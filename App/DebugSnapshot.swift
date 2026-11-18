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
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            if defaults.bool(forKey: "debugSnapshotKeepOpen") == false { NSApp.terminate(nil) }
        }
    }
}
#endif
