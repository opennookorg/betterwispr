import ApplicationServices

extension AXUIElement {
    func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func element(_ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    func bool(_ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    var isSecureField: Bool { string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole }

    var frame: CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = axValue(kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let extent = axValue(kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func axValue(_ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
