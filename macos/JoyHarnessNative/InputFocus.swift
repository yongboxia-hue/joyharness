import AppKit
import ApplicationServices

/// Moves keyboard focus to the text input of whatever app is in front.
///
/// This is deliberately app-agnostic. Keeping a table of "this app focuses its
/// composer with this shortcut" would never finish -- every tool would need its
/// own entry, and every update could break one. The accessibility tree already
/// describes where an app's text inputs are, so the work is not finding one but
/// choosing the right one: a real tree also contains phantom fields (a 1x1
/// hidden input, offscreen leftovers) and usually more than one genuine input,
/// and focusing the wrong one is worse than doing nothing. Dictating a
/// paragraph into a search box is a worse outcome than a button that did not
/// appear to work.
enum InputFocus {
    /// Anything smaller than this is not something a person types into.
    private static let minimumUsableSize = CGSize(width: 40, height: 12)
    /// Electron apps nest deeply -- a composer can sit dozens of levels down,
    /// well past where a native app would put it. The earlier caps stopped the
    /// walk before reaching Claude's input box and settled for a small field
    /// it had already passed.
    private static let maximumDepth = 80
    private static let maximumVisited = 30000

    struct Candidate {
        let element: AXUIElement
        let role: String
        let frame: CGRect

        /// Multi-line inputs are where people compose; single-line ones are
        /// usually search. Prefer the composer, then the lowest on screen
        /// (chat inputs sit at the bottom), then the largest.
        var rank: (Int, CGFloat, CGFloat) {
            (role == kAXTextAreaRole as String ? 1 : 0, frame.maxY, frame.width * frame.height)
        }
    }

    @discardableResult
    static func focusFrontmostInput() throws -> String {
        guard AXIsProcessTrusted() else {
            throw InputGatewayError.invalidRequest("需要辅助功能权限")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw InputGatewayError.invalidRequest("没有前台应用")
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var visited = 0
        var candidates: [Candidate] = []
        collect(from: axApp, depth: 0, visited: &visited, into: &candidates)

        guard let best = candidates.max(by: { lhs, rhs in lhs.rank < rhs.rank }) else {
            // Nothing convincing. Do nothing rather than guess.
            throw InputGatewayError.invalidRequest("\(app.localizedName ?? "当前应用")里没有找到输入框")
        }

        let result = AXUIElementSetAttributeValue(
            best.element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        guard result == .success else {
            throw InputGatewayError.invalidRequest("输入框拒绝接受焦点（\(result.rawValue)）")
        }
        let considered = candidates
            .sorted { $0.rank > $1.rank }
            .prefix(6)
            .map { "\($0.role == kAXTextAreaRole as String ? "area" : "field")" +
                   "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minY))" }
            .joined(separator: " ")
        return "\(app.localizedName ?? "?") → \(best.role) " +
               "\(Int(best.frame.width))x\(Int(best.frame.height)) " +
               "[候选 \(candidates.count): \(considered)]"
    }

    private static func collect(
        from element: AXUIElement,
        depth: Int,
        visited: inout Int,
        into candidates: inout [Candidate]
    ) {
        guard depth < maximumDepth, visited < maximumVisited else { return }
        visited += 1

        if let role = string(element, kAXRoleAttribute),
           role == kAXTextFieldRole as String || role == kAXTextAreaRole as String,
           isUsable(element), acceptsFocus(element), let frame = frame(of: element),
           frame.width >= minimumUsableSize.width, frame.height >= minimumUsableSize.height {
            candidates.append(Candidate(element: element, role: role, frame: frame))
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        ) == .success, let children = childrenRef as? [AXUIElement] else { return }

        for child in children {
            collect(from: child, depth: depth + 1, visited: &visited, into: &candidates)
        }
    }

    /// Only elements that will actually take focus. A read-only or decorative
    /// field can look like a candidate and then silently refuse, which reads
    /// to the user as the button doing nothing.
    private static func acceptsFocus(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, kAXFocusedAttribute as CFString, &settable
        ) == .success else { return false }
        return settable.boolValue
    }

    private static func isUsable(_ element: AXUIElement) -> Bool {
        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let enabled = enabledRef as? Bool, !enabled { return false }
        return true
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }
}
