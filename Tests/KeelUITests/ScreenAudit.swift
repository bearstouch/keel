import AppKit
import SwiftUI
import XCTest

/// One element of a screen's accessibility tree as VoiceOver reads it.
struct AXNode {
    let role: NSAccessibility.Role?
    let label: String?
    let title: String?
    let placeholder: String?
    let value: String?
    let hasTitleElement: Bool
    let selected: Bool
    let enabled: Bool
    /// Has keyboard focus.
    let focused: Bool
    /// Where it is on screen.
    let frame: NSRect?
    /// Labels of the enclosing elements, outermost first, so a failure names where the control is.
    let path: [String]
    /// Roles of the enclosing elements, outermost first.
    let ancestors: [NSAccessibility.Role]
    /// Everything else the element reports, read only for unnamed controls: what a failure needs to say why.
    var details = ""

    /// What VoiceOver announces as the element's name. A placeholder is not a name: it disappears once text is typed.
    var name: String? {
        [label, title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? (hasTitleElement ? "(title element)" : nil)
    }

    /// Everything the element says: its name and its value.
    var spoken: String { [name, value].compactMap { $0 }.joined(separator: " ") }

    var description: String {
        "\(role?.rawValue ?? "?") in \(path.isEmpty ? "the window" : path.joined(separator: " › "))\(details.isEmpty ? "" : " [\(details)]")"
    }

    /// Roles a user operates: each needs a name (NFR-AX01).
    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .textArea, .comboBox, .slider, .incrementor, .link,
        .disclosureTriangle, .outline, .table, .colorWell
    ]

    var isControl: Bool { role.map(Self.controlRoles.contains) ?? false }

    /// AppKit's composite controls: their parts (a scroll bar's arrows, a date picker's stepper) are named by AppKit
    /// through the whole, which carries the label.
    static let systemComposites: Set<NSAccessibility.Role> = [.scrollBar, NSAccessibility.Role(rawValue: "AXDateTimeArea")]

    var isSystemPart: Bool { ancestors.contains(where: Self.systemComposites.contains) }
}

/// Hosts a SwiftUI view in an on-screen window and reads it the way assistive technology does: the accessibility
/// tree (what VoiceOver hears) and the window's key-view loop (where Tab goes without Full Keyboard Access).
@MainActor
final class ScreenHost {
    let window: NSWindow
    let host: NSView

    init<Content: View>(_ content: Content, size: CGSize = CGSize(width: 1180, height: 760)) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: content)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        // SwiftUI builds its accessibility nodes only for an assistive client; this attribute is how VoiceOver asks.
        NSApp.perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"), with: NSNumber(value: true))
    }

    /// Lets SwiftUI lay out, run `.task`/`.onAppear` work and publish model changes. It suspends rather than spin the
    /// run loop: a nested `RunLoop.run` inside a task runs other main-actor jobs within it, which aborts the concurrency
    /// runtime ("freed pointer was not the last allocation") on newer toolchains.
    func settle(_ seconds: TimeInterval = 0.15) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(seconds))
        host.layoutSubtreeIfNeeded()
    }

    /// Also turns the app-wide accessibility attribute off again, so later tests run as without an assistive client.
    func close() {
        window.orderOut(nil); window.contentView = nil
        NSApp.perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"), with: NSNumber(value: false))
    }

    /// Every element of the window's content, depth first.
    var nodes: [AXNode] {
        var found: [AXNode] = []
        Self.walk(host, path: [], depth: 0, into: &found)
        return found
    }

    /// Controls VoiceOver can't name.
    var unlabeledControls: [AXNode] { nodes.filter { $0.isControl && !$0.isSystemPart && $0.name == nil } }

    /// Elements whose name or value contains `text`.
    func nodes(saying text: String) -> [AXNode] { nodes.filter { $0.spoken.localizedCaseInsensitiveContains(text) } }

    /// Where Tab goes, pressed `limit` times from the window's start: each stop named as VoiceOver names the focused
    /// element. Stops repeat once the loop wraps around.
    func tabStops(limit: Int = 12) async -> [String] {
        window.makeFirstResponder(nil)
        var stops: [String] = []
        for _ in 0..<limit { await pressTab(); stops.append(focusedName) }
        return stops
    }

    /// Sends a key press to the window as the keyboard would.
    func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            event.map(window.sendEvent)
        }
        await settle(0.05)
    }

    func pressTab(_ modifiers: NSEvent.ModifierFlags = []) async { await press(keyCode: 48, characters: "\t", modifiers: modifiers) }
    func pressDown() async { await press(keyCode: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!)) }
    func pressUp() async { await press(keyCode: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!)) }

    /// The focused element as VoiceOver names it. SwiftUI's focusable views are key-view proxies without a name or a
    /// focused node of their own, so a responder is named by the outermost named element over the same frame; else by a
    /// node that reports focus, else by its own name.
    var focusedName: String {
        guard var responder: Any = window.firstResponder, !(responder is NSWindow) else {
            return "(window; key \(window.isKeyWindow), main \(window.isMainWindow), app active \(NSApp.isActive), \(NSApp.activationPolicy().rawValue))"
        }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField { responder = field }
        let all = nodes
        if let view = responder as? NSView, let screen = view.window?.convertToScreen(view.convert(view.bounds, to: nil)),
            let named = all.first(where: { $0.name != nil && $0.frame.map { Self.same($0, screen) } == true })?.name
        {
            return named
        }
        if let named = all.last(where: { $0.focused && $0.name != nil })?.name { return named }
        for name in [NSAccessibility.Attribute.description, .title, .placeholderValue] {
            if let text = Self.attribute(name, of: responder) as? String, !text.isEmpty { return text }
        }
        return "\(type(of: responder))"
    }

    private static func same(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// `accessibilityFrame` returns a struct, which `perform` can't; key-value coding boxes it.
    private static func frame(of element: Any) -> NSRect? {
        guard let object = element as? NSObject, object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }

    /// Reads an attribute the way an assistive client does: through its `NSAccessibility` method when the element has
    /// one (SwiftUI's nodes), else through `accessibilityAttributeValue:` (AppKit's table rows and columns). Neither kind
    /// adopts the protocol, so both are sent dynamically.
    static func attribute(_ name: NSAccessibility.Attribute, of element: Any) -> Any? {
        guard let object = element as? NSObject else { return nil }
        if let method = methods[name], object.responds(to: method) {
            guard let result = object.perform(method) else { return nil }
            return result.takeUnretainedValue()
        }
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter, with: name.rawValue)?.takeUnretainedValue()
    }

    private static let getter = NSSelectorFromString("accessibilityAttributeValue:")
    /// Object-valued attributes only: `perform` can't return a `BOOL`, so flags go through the attribute getter.
    private static let methods: [NSAccessibility.Attribute: Selector] = [
        .role: NSSelectorFromString("accessibilityRole"), .description: NSSelectorFromString("accessibilityLabel"),
        .title: NSSelectorFromString("accessibilityTitle"), .value: NSSelectorFromString("accessibilityValue"),
        .placeholderValue: NSSelectorFromString("accessibilityPlaceholderValue"), .children: NSSelectorFromString("accessibilityChildren"),
        .titleUIElement: NSSelectorFromString("accessibilityTitleUIElement")
    ]

    /// Class, subrole, role description, identifier, help, value, frame and first children of an element.
    private static func details(of element: Any, parent: String?) -> String {
        func text(_ value: Any?) -> String? {
            guard let value else { return nil }
            let string = "\(value)"
            return string.isEmpty ? nil : string
        }
        var parts = ["class \(type(of: element))"]
        let names: [(String, NSAccessibility.Attribute)] = [
            ("subrole", .subrole), ("roleDescription", .roleDescription), ("identifier", .identifier), ("help", .help), ("value", .value),
            ("description", .description), ("title", .title)
        ]
        for (label, name) in names { if let value = text(attribute(name, of: element)) { parts.append("\(label) \(value)") } }
        if let frame = frame(of: element) { parts.append("frame \(Int(frame.width))×\(Int(frame.height))") }
        let children = (attribute(.children, of: element) as? [Any] ?? []).prefix(4).map { child in
            [attribute(.role, of: child), attribute(.description, of: child), attribute(.title, of: child), attribute(.value, of: child)]
                .compactMap(text).joined(separator: " ")
        }
        if !children.isEmpty { parts.append("children \(children)") }
        if let parent { parts.append("inside \"\(parent)\"") }
        return parts.joined(separator: "; ")
    }

    private static func walk(_ element: Any, path: [String], ancestors: [NSAccessibility.Role] = [], depth: Int, into found: inout [AXNode]) {
        guard depth < 60 else { return }
        func string(_ name: NSAccessibility.Attribute) -> String? { attribute(name, of: element) as? String }
        func flag(_ name: NSAccessibility.Attribute) -> Bool? { (attribute(name, of: element) as? NSNumber)?.boolValue }
        let node = AXNode(
            role: string(.role).map(NSAccessibility.Role.init(rawValue:)), label: string(.description), title: string(.title),
            placeholder: string(.placeholderValue), value: string(.value), hasTitleElement: attribute(.titleUIElement, of: element) != nil,
            selected: flag(.selected) ?? false, enabled: flag(.enabled) ?? true,
            focused: flag(.focused) ?? false, frame: frame(of: element), path: path, ancestors: ancestors)
        var described = node
        if node.isControl && node.name == nil { described.details = details(of: element, parent: path.last) }
        found.append(described)
        let inner = node.name.map { path + [$0] } ?? path
        let roles = ancestors + [node.role ?? .unknown]
        for child in attribute(.children, of: element) as? [Any] ?? [] { walk(child, path: inner, ancestors: roles, depth: depth + 1, into: &found) }
    }
}
