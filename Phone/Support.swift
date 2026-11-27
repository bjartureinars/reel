import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// "iPhone", "iPad" or "Mac", for text that names the device Reel is running on.
enum Device {
    #if os(macOS)
    /// The Mac gets the wide layout everywhere.
    static let isPad = true
    static let isMac = true
    static let name = "Mac"
    #else
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let isMac = false
    static let name = isPad ? "iPad" : "iPhone"
    #endif
}

/// Compact on an iPhone (and an iPad sharing its screen), regular on a wide iPad and on the Mac.
enum ReelSizeClass { case compact, regular }

extension EnvironmentValues {
    var reelSizeClass: ReelSizeClass {
        #if os(iOS)
        horizontalSizeClass == .regular ? .regular : .compact
        #else
        .regular
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Top right on iPhone and iPad; the toolbar's main place on the Mac.
    static var reelTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// The backdrop shows through the bar on iPhone and iPad; the Mac keeps its window toolbar.
    func reelClearNavigationBar() -> some View {
        #if os(iOS)
        self.toolbarBackground(.hidden, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension View {
    /// A context menu with a peek preview on iPhone and iPad. On the Mac a preview isn't shown, and with one the
    /// menu took over the click, so posters didn't open.
    @ViewBuilder
    func reelContextMenu<M: View, P: View>(@ViewBuilder menuItems: () -> M, @ViewBuilder preview: () -> P) -> some View {
        #if os(iOS)
        contextMenu(menuItems: menuItems, preview: preview)
        #else
        contextMenu(menuItems: menuItems)
        #endif
    }
}

/// Cards answer the pointer: on the Mac they lift a little, with a shadow and a thin edge (only the edge with Reduce Motion);
/// on iPad with a trackpad, the system lift.
struct HoverLift: ViewModifier {
    var cornerRadius: CGFloat = 10
    var scale: CGFloat = 1.04
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.4 : 0), lineWidth: 1.5)
            }
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.55 : 0), radius: hovering ? 14 : 0, y: hovering ? 8 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
        #else
        content
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.lift)
        #endif
    }
}

extension View {
    func reelHoverLift(cornerRadius: CGFloat = 10, scale: CGFloat = 1.04) -> some View {
        modifier(HoverLift(cornerRadius: cornerRadius, scale: scale))
    }
}

enum AppState {
    static var voiceOverRunning: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning
        #else
        NSWorkspace.shared.isVoiceOverEnabled
        #endif
    }

    static var inBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }
}

#if os(macOS)
typealias UIImage = NSImage
typealias UIColor = NSColor

extension NSImage {
    func preparingForDisplay() -> NSImage? { self }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}
#endif

/// Sizes that grow with the screen. Regular width means an iPad that isn't sharing its screen with a narrow app.
enum Metrics {
    static func margin(_ regular: Bool) -> CGFloat { regular ? 32 : 16 }
    static func poster(_ regular: Bool) -> CGFloat { regular ? 168 : 124 }
    static func gridPoster(_ regular: Bool) -> CGFloat { regular ? 150 : 108 }
    static func wide(_ regular: Bool) -> CGFloat { regular ? 360 : 260 }
    /// Text and buttons stay this narrow on a big screen, so lines stay readable.
    static let readableWidth: CGFloat = 720
}

enum Theme {
    /// Projector-lamp gold, the one brand colour: the main action, progress and selection. 10.6:1 on black.
    static let gold = Color(red: 0.96, green: 0.73, blue: 0.29)
    static let goldUI = UIColor(red: 0.96, green: 0.73, blue: 0.29, alpha: 1)
    static let card = Color(white: 0.13)
}

struct CloudError: LocalizedError {
    let message: String
    var needsSignIn = false

    init(_ message: String, needsSignIn: Bool = false) {
        self.message = message
        self.needsSignIn = needsSignIn
    }

    var errorDescription: String? { message }
}

extension Int64 {
    var fileSize: String { formatted(.byteCount(style: .file)) }
}

extension Double {
    /// "2 h 25 min"
    var runtimeText: String {
        let minutes = Int(self / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(1, minutes)) min"
    }

    /// "1:02:03" or "2:03"
    var clockText: String {
        guard isFinite else { return "–:––" }
        let total = Int(max(0, self))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum Folders {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let downloads: URL = {
        var url = support.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Films can be downloaded again from Drive, so they don't belong in iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static let artwork: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var freeSpace: Int64 {
        let values = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// Saves a Codable value as JSON in Application Support.
enum Store {
    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: Folders.support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]   // macOS has no file protection classes: with one, the write fails
        #endif
        try? data.write(to: Folders.support.appendingPathComponent(name), options: options)
    }
}
