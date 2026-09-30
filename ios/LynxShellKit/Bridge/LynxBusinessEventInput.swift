import CoreFoundation
import Foundation

struct LynxBusinessEventInput {
    let payload: LynxMonitorBusinessEvent

    init(group: String, name: String, attributesJSON: String) throws {
        guard !group.isEmpty, !group.allSatisfy({ $0.isWhitespace }),
              !name.isEmpty, !name.allSatisfy({ $0.isWhitespace }) else {
            throw LynxMonitorBusinessRejection.invalidArgument
        }
        guard group.utf8.count + name.utf8.count + attributesJSON.utf8.count <= 32 * 1024 else {
            throw LynxMonitorBusinessRejection.eventTooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(attributesJSON.utf8))
        } catch {
            throw LynxMonitorBusinessRejection.invalidArgument
        }
        guard let raw = object as? [String: Any] else {
            throw LynxMonitorBusinessRejection.invalidArgument
        }
        var attributes: [String: LynxMonitorBusinessValue] = [:]
        for (key, value) in raw {
            guard !key.isEmpty else { throw LynxMonitorBusinessRejection.invalidArgument }
            if let number = value as? NSNumber {
                // JSON 布尔值也是 NSNumber，必须先判断 CFBoolean，不能编码成 0/1。
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    attributes[key] = .boolean(number.boolValue)
                } else {
                    guard number.doubleValue.isFinite else { throw LynxMonitorBusinessRejection.invalidArgument }
                    attributes[key] = .number(number.doubleValue)
                }
            } else if let string = value as? String {
                attributes[key] = .string(string)
            } else {
                throw LynxMonitorBusinessRejection.invalidArgument
            }
        }
        self.payload = .init(group: group, name: name, attributes: attributes)
    }
}
