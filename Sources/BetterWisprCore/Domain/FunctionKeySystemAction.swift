import CoreFoundation

/// What macOS does with a short press of the globe/function key; the tap takes the key away while it is not Do Nothing.
public enum FunctionKeySystemAction: Int, Sendable, Equatable {
    case doNothing = 0
    case changeInputSource = 1
    case showEmojiAndSymbols = 2
    case startDictation = 3
    case startSpotlight = 4

    /// Whether macOS claims short presses of the function key instead of leaving them to apps.
    public var interceptsTaps: Bool { self != .doNothing }

    /// The stored value of `com.apple.HIToolbox`'s `AppleFnUsageType`. An absent key means the macOS default,
    /// which shows emojis and symbols.
    public static func current() -> FunctionKeySystemAction {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? Int).flatMap(FunctionKeySystemAction.init(rawValue:)) ?? .showEmojiAndSymbols
    }
}
