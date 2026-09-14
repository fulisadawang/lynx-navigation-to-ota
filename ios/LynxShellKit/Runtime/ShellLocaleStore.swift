import Foundation

/** iOS 壳支持的语言状态；实际翻译资源由各个 Lynx Bundle 自己提供。 */
public struct LynxLocaleState: Equatable {
    public let schemaVersion: Int
    public let revision: UInt64
    public let systemLocale: String
    public let appLocale: String?
    public let locale: String
    public let language: String
    public let source: String
    public let status: String
    public let direction: String

    init(
        schemaVersion: Int = 1,
        revision: UInt64,
        systemLocale: String,
        appLocale: String?,
        locale: String,
        language: String,
        source: String,
        status: String = "ready",
        direction: String = "ltr"
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.systemLocale = systemLocale
        self.appLocale = appLocale
        self.locale = locale
        self.language = language
        self.source = source
        self.status = status
        self.direction = direction
    }

    /** 只返回 JSON 可编码的 Foundation 类型，供 GlobalProps 和 NativeModule 使用。 */
    public var dictionary: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "revision": revision,
            "systemLocale": systemLocale,
            "appLocale": appLocale ?? NSNull(),
            "appLocaleOverride": appLocale ?? NSNull(),
            "locale": locale,
            "effectiveLocale": locale,
            "formatLocale": locale,
            "language": language,
            "source": source,
            "status": status,
            "direction": direction,
        ]
    }

    public var isAppOverride: Bool { appLocale != nil }
}

enum ShellLocaleStore {
    static let supportedLocales = ["zh-CN", "en-US"]
    private static let appLocaleKey = "lynx.shell.app.locale"
    private static let lock = NSLock()
    private static var revision: UInt64 = 0
    private static var cachedState: LynxLocaleState?
    private static var systemLocaleObserver: NSObjectProtocol?

    /** 监听系统语言变化；有 App 覆盖时也更新 systemLocale 元数据。 */
    static func startObserving(onChange: @escaping (LynxLocaleState) -> Void) {
        lock.lock()
        let alreadyObserving = systemLocaleObserver != nil
        lock.unlock()
        guard !alreadyObserving else { return }

        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSCurrentLocaleDidChangeNotification"),
            object: nil,
            queue: .main
        ) { _ in
            guard let state = refreshForSystemChange() else { return }
            onChange(state)
        }
        lock.lock()
        if systemLocaleObserver == nil {
            systemLocaleObserver = token
            lock.unlock()
        } else {
            lock.unlock()
            NotificationCenter.default.removeObserver(token)
        }
    }

    static func current() -> LynxLocaleState {
        lock.lock()
        defer { lock.unlock() }
        return currentLocked()
    }

    /** 设置 App 覆盖；nil 清除覆盖并恢复跟随系统。 */
    static func set(appLocale: String?) throws -> LynxLocaleState {
        let normalized: String?
        if let appLocale {
            normalized = appLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system"
                ? nil
                : try normalizeSupportedLocale(appLocale)
        } else {
            normalized = nil
        }

        lock.lock()
        defer { lock.unlock() }
        if let normalized {
            UserDefaults.standard.set(normalized, forKey: appLocaleKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appLocaleKey)
        }
        return currentLocked()
    }

    /** 系统语言变化时刷新快照；没有变化或页面没有 App 覆盖时仍保留稳定 revision。 */
    private static func refreshForSystemChange() -> LynxLocaleState? {
        lock.lock()
        defer { lock.unlock() }
        let previous = cachedState
        let next = currentLocked()
        guard previous != next else { return nil }
        return next
    }

    private static func currentLocked() -> LynxLocaleState {
        let system = systemLocaleSnapshot()
        let appLocale = UserDefaults.standard.string(forKey: appLocaleKey)
            .flatMap { try? normalizeSupportedLocale($0) }
        let resolvedLocale = appLocale ?? system.supportedLocale ?? "zh-CN"
        let source: String
        if appLocale != nil {
            source = "app"
        } else if system.supportedLocale != nil {
            source = "system"
        } else {
            source = "fallback"
        }

        if let cachedState,
           cachedState.systemLocale == system.tag,
           cachedState.appLocale == appLocale,
           cachedState.locale == resolvedLocale,
           cachedState.source == source {
            return cachedState
        }

        revision = revision == UInt64.max ? 1 : revision + 1
        let state = LynxLocaleState(
            revision: revision,
            systemLocale: system.tag,
            appLocale: appLocale,
            locale: resolvedLocale,
            language: resolvedLocale == "en-US" ? "en" : "zh",
            source: source
        )
        cachedState = state
        return state
    }

    private static func systemLocaleSnapshot() -> (tag: String, supportedLocale: String?) {
        let raw = Locale.preferredLanguages.first ?? Locale.current.identifier
        let tag = raw.replacingOccurrences(of: "_", with: "-")
        let languageCode = Locale(identifier: tag).languageCode?.lowercased()
        switch languageCode {
        case "zh": return (tag, "zh-CN")
        case "en": return (tag, "en-US")
        default: return (tag.isEmpty ? "und" : tag, nil)
        }
    }

    private static func normalizeSupportedLocale(_ value: String) throws -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        switch normalized {
        case "zh", "zh-cn", "zh-hans", "zh-hans-cn": return "zh-CN"
        case "en", "en-us", "en-latn-us": return "en-US"
        default:
            throw NSError(
                domain: "LynxRouter",
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "locale 仅支持 zh-CN 和 en-US，收到：\(value)",
                ]
            )
        }
    }
}
