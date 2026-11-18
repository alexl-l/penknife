import AppKit
import IOKit

/// Apple's private Touch Bar calls (DFRFoundation and private NSTouchBar class methods).
/// A menu bar app is never frontmost, so only a "system modal" bar can stay on screen.
/// Everything is looked up at runtime: if a macOS update removes a call, the Touch Bar
/// module just reports it as unavailable instead of crashing (see DECISIONS.md).
enum TouchBarPrivate {
    private typealias PresenceFunction = @convention(c) (NSString, Bool) -> Void
    private typealias CloseBoxFunction = @convention(c) (Bool) -> Void
    private typealias PresentMethod = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString) -> Void
    private typealias BarMethod = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
    private typealias ItemMethod = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void

    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let dfr, let symbol = dlsym(dfr, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static func classMethod<T>(_ cls: AnyClass, _ name: String, as type: T.Type) -> (Selector, T)? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        return (selector, unsafeBitCast(method_getImplementation(method), to: type))
    }

    private static let setPresence = function("DFRElementSetControlStripPresenceForIdentifier", as: PresenceFunction.self)
    private static let showsCloseBox = function("DFRSystemModalShowsCloseBoxWhenFrontMost", as: CloseBoxFunction.self)
    private static let presentMethod = classMethod(NSTouchBar.self, "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", as: PresentMethod.self)
    private static let minimizeMethod = classMethod(NSTouchBar.self, "minimizeSystemModalTouchBar:", as: BarMethod.self)
    private static let addTrayMethod = classMethod(NSTouchBarItem.self, "addSystemTrayItem:", as: ItemMethod.self)

    /// True when every call the bar needs exists.
    static var isAvailable: Bool {
        presentMethod != nil && minimizeMethod != nil
    }

    /// Whether this Mac has a Touch Bar (read once).
    static let hasTouchBar: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("dispdfr"))
        if service != 0 { IOObjectRelease(service) }
        return TouchBarPrivate.hasTouchBar(dispdfr: service != 0, model: TouchBarPrivate.modelName())
    }()

    /// TB-01: Apple silicon models expose the "dispdfr" display; the Intel models that run
    /// macOS 26 are listed by name. The model is read only when there is no such display.
    static func hasTouchBar(dispdfr: Bool, model: @autoclosure () -> String) -> Bool {
        if dispdfr { return true }
        let name = model()
        return ["MacBookPro15,", "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,4"].contains { name.hasPrefix($0) }
    }

    private static func modelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Puts a button in the Control Strip that brings the bar back after the system hid it.
    static func addTrayItem(_ item: NSTouchBarItem) {
        showsCloseBox?(false)
        if let (selector, add) = addTrayMethod {
            add(NSTouchBarItem.self, selector, item)
        }
        setPresence?(item.identifier.rawValue as NSString, true)
    }

    static func removeTrayItem(_ identifier: NSTouchBarItem.Identifier) {
        setPresence?(identifier.rawValue as NSString, false)
    }

    /// Shows the bar over the whole Touch Bar (placement 1 hides the Control Strip).
    static func present(_ bar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) {
        guard let (selector, present) = presentMethod else { return }
        present(NSTouchBar.self, selector, bar, 1, trayIdentifier.rawValue as NSString)
    }

    /// Hides the bar so the front app's own Touch Bar shows.
    static func minimize(_ bar: NSTouchBar) {
        guard let (selector, minimize) = minimizeMethod else { return }
        minimize(NSTouchBar.self, selector, bar)
    }
}
