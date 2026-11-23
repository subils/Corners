import AppKit

/// Click-through borderless window covering one corner of one screen.
///
/// The window covers only the corner, not the whole screen. A full-screen window, even a
/// click-through one, is always under the cursor, and the window server wakes its owner on
/// every mouse move (measured: ~3,300 wakeups in 30 s of normal use, against ~30 for a
/// corner-sized window).
///
/// The corner is drawn by Core Animation itself, with Apple's continuous ("squircle") curve:
/// a screen-sized layer with a thick black border. Its outer edge sits off-screen and its inner
/// edge, `cornerRadius - borderWidth` = `radius`, is the rounded outline of the screen. The
/// render server draws it on the GPU; the layer is only touched when something changes.
final class Overlay: NSWindow {
    let corner: CACornerMask
    private let edge = CALayer()

    init(corner: CACornerMask) {
        self.corner = corner
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none
        isReleasedWhenClosed = false
        animationBehavior = .none
        edge.borderColor = .black
        edge.cornerCurve = .continuous
        edge.maskedCorners = corner
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(edge)
        contentView = view
    }

    func show(on screen: NSScreen, radius: CGFloat) {
        let s = screen.frame
        let size = (radius * 1.6).rounded(.up) + 2  // the continuous curve meets the edges at ~1.53 r
        let left = !corner.isDisjoint(with: [.layerMinXMinYCorner, .layerMinXMaxYCorner])
        let bottom = !corner.isDisjoint(with: [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        let box = NSRect(x: left ? s.minX : s.maxX - size, y: bottom ? s.minY : s.maxY - size, width: size, height: size)
        let pad = radius * 2  // enough to push the layer's own outer rounding off-screen
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != box { setFrame(box, display: false) }
        edge.frame = CGRect(x: s.minX - box.minX, y: s.minY - box.minY, width: s.width, height: s.height)
            .insetBy(dx: -pad, dy: -pad)
        edge.borderWidth = pad
        edge.cornerRadius = radius + pad
        CATransaction.commit()
        if !isVisible {
            orderFrontRegardless()
            OverlaySpace.adopt(self)
        }
    }
}

/// A private window-server space that sits above every user space, the way the menu bar and the
/// Dock do. Windows in it stay put while the user swipes between Spaces or enters full screen;
/// a `.canJoinAllSpaces` window would slide away with the old space and reappear afterwards.
/// SkyLight SPI, looked up at runtime: if any of it is missing, the windows simply stay in the
/// normal spaces (thanks to `.canJoinAllSpaces`).
@MainActor
enum OverlaySpace {
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(sky, name).map { unsafeBitCast($0, to: T.self) } }

    private static let connection = fn("SLSMainConnectionID", (@convention(c) () -> Int32).self)?() ?? 0
    private static let addWindows = fn("SLSSpaceAddWindowsAndRemoveFromSpaces",
                                       (@convention(c) (Int32, UInt64, CFArray, Int32) -> Int32).self)

    /// Created once, on first use, and destroyed by the window server when the app exits.
    private static let space: UInt64 = {
        guard connection != 0,
              let create = fn("SLSSpaceCreate", (@convention(c) (Int32, Int32, CFDictionary?) -> UInt64).self),
              let setLevel = fn("SLSSpaceSetAbsoluteLevel", (@convention(c) (Int32, UInt64, Int32) -> Int32).self),
              let show = fn("SLSShowSpaces", (@convention(c) (Int32, CFArray) -> Int32).self)
        else { return 0 }
        let id = create(connection, 1, nil)
        guard id != 0 else { return 0 }
        _ = setLevel(connection, id, 100)  // user spaces are at 0
        _ = show(connection, [id] as CFArray)
        return id
    }()

    static func adopt(_ window: NSWindow) {
        guard space != 0, let addWindows else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}

extension NSScreen {
    private typealias GetCornerRadii = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Double>?,
        UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32

    /// SkyLight's own record of the panel's physical corner radius (35.44 px on a MacBook Air M3),
    /// in points of the current display mode. Private, so it is looked up at runtime.
    private static let getCornerRadii = dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                                                     RTLD_LAZY), "SLSDisplayGetCornerRadii")
        .map { unsafeBitCast($0, to: GetCornerRadii.self) }

    /// Radius of the display's rounded hardware corners in points, or 0 if it has none
    /// (external monitors, letterboxed modes) or the system doesn't report it.
    var hardwareCornerRadius: CGFloat {
        guard let get = Self.getCornerRadii,
              let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return 0 }
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0
        return get(id, &a, &b, &c, &d) == 0 ? max(a, b, c, d) : 0
    }
}
