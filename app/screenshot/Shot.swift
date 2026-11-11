import SwiftUI

/// Renders the menu bar panel offscreen, in light and dark, for the README.
@main
struct Shot {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Never draw real sessions: the model must run the bundled fake-tend.
        guard Model.tend.contains("Screenshot.app/") else {
            fatalError("Run this from app/screenshot/make.sh, which bundles fake-tend. Model.tend is \(Model.tend)")
        }
        let model = Model()
        // Wait for the model's first refresh, and then a moment for the views.
        let deadline = Date().addingTimeInterval(30)
        while model.sessions.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        guard !model.sessions.isEmpty else { fatalError("The model didn't load any sessions from fake-tend.") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let out = CommandLine.arguments[1]
        for (name, file) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let panel = ContentView()
                .environmentObject(model)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15)))
                .padding(1)
            let host = NSHostingView(rootView: panel)
            host.appearance = NSAppearance(named: name)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: host.frame.width, height: host.frame.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: name)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            // Twice the point size, for Retina displays.
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("no bitmap") }
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/screenshot-\(file).png"))
            print("wrote \(file): \(rep.pixelsWide)x\(rep.pixelsHigh)")
            window.orderOut(nil)
        }
    }
}
