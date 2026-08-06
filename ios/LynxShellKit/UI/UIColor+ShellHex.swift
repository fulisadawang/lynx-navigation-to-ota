import UIKit

extension UIColor {
    /** 状态栏前景色判断；使用感知亮度，避免深色 Lynx 首屏上的系统图标不可见。 */
    var shellIsLightColor: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return true
        }
        let luminance = red * 0.299 + green * 0.587 + blue * 0.114
        return luminance > 0.6
    }

    /**
     * 壳路由统一颜色解析。
     *
     * 兼容历史 #RRGGBB/#RRGGBBAA，同时支持 Skyline/Open Container 常用的
     * Android 同名解析器一致：12 个命名色、#RRGGBB/#RRGGBBAA、rgb()/rgba()。
     */
    convenience init?(shellHex: String) {
        let normalized = shellHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "black":
            self.init(white: 0, alpha: 1)
            return
        case "darkgray":
            self.init(white: CGFloat(0x44) / 255, alpha: 1)
            return
        case "gray":
            self.init(white: CGFloat(0x88) / 255, alpha: 1)
            return
        case "lightgray":
            self.init(white: CGFloat(0xCC) / 255, alpha: 1)
            return
        case "white":
            self.init(white: 1, alpha: 1)
            return
        case "red":
            self.init(red: 1, green: 0, blue: 0, alpha: 1)
            return
        case "green":
            self.init(red: 0, green: 1, blue: 0, alpha: 1)
            return
        case "blue":
            self.init(red: 0, green: 0, blue: 1, alpha: 1)
            return
        case "yellow":
            self.init(red: 1, green: 1, blue: 0, alpha: 1)
            return
        case "cyan":
            self.init(red: 0, green: 1, blue: 1, alpha: 1)
            return
        case "magenta":
            self.init(red: 1, green: 0, blue: 1, alpha: 1)
            return
        case "transparent":
            self.init(white: 0, alpha: 0)
            return
        default:
            break
        }

        if normalized.hasPrefix("#") {
            let raw = String(normalized.dropFirst())
            guard raw.count == 6 || raw.count == 8,
                  let value = UInt64(raw, radix: 16) else {
                return nil
            }
            let red = CGFloat((value >> (raw.count == 8 ? 24 : 16)) & 0xFF) / 255
            let green = CGFloat((value >> (raw.count == 8 ? 16 : 8)) & 0xFF) / 255
            let blue = CGFloat((value >> (raw.count == 8 ? 8 : 0)) & 0xFF) / 255
            let alpha = raw.count == 8 ? CGFloat(value & 0xFF) / 255 : 1
            self.init(red: red, green: green, blue: blue, alpha: alpha)
            return
        }

        let isRGBA = normalized.hasPrefix("rgba(") && normalized.hasSuffix(")")
        let isRGB = normalized.hasPrefix("rgb(") && normalized.hasSuffix(")")
        guard isRGBA || isRGB else { return nil }
        let start = normalized.index(
            normalized.startIndex,
            offsetBy: isRGBA ? 5 : 4
        )
        let end = normalized.index(before: normalized.endIndex)
        let parts = normalized[start..<end]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (isRGBA ? 4 : 3),
              let red = Self.shellColorChannel(parts[0]),
              let green = Self.shellColorChannel(parts[1]),
              let blue = Self.shellColorChannel(parts[2]) else {
            return nil
        }
        let alpha: CGFloat
        if isRGBA {
            guard let value = Self.shellAlpha(parts[3]) else {
                return nil
            }
            alpha = value
        } else {
            alpha = 1
        }
        self.init(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    private static func shellColorChannel(_ rawValue: String) -> CGFloat? {
        if rawValue.hasSuffix("%") {
            guard let percent = Double(rawValue.dropLast()),
                  (0 ... 100).contains(percent) else {
                return nil
            }
            return CGFloat((percent * 2.55).rounded()) / 255
        }
        guard let channel = Double(rawValue), (0 ... 255).contains(channel) else {
            return nil
        }
        return CGFloat(channel.rounded()) / 255
    }

    private static func shellAlpha(_ rawValue: String) -> CGFloat? {
        if rawValue.hasSuffix("%") {
            guard let percent = Double(rawValue.dropLast()),
                  (0 ... 100).contains(percent) else {
                return nil
            }
            return CGFloat((percent * 2.55).rounded()) / 255
        }
        guard let alpha = Double(rawValue), (0 ... 1).contains(alpha) else {
            return nil
        }
        return CGFloat((alpha * 255).rounded()) / 255
    }
}
