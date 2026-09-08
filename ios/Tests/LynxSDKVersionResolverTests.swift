import Foundation

@main
struct LynxSDKVersionResolverTests {
    static func main() throws {
        let resource = LynxSDKVersionMetadata(identifier: "org.cocoapods.LynxResources", version: "4.0.0")
        let framework = LynxSDKVersionMetadata(identifier: "org.cocoapods.Lynx", version: "4.0.0")
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool) rethrows {
            let valid = try condition()
            precondition(valid); count += 1
        }
        func resolve(_ resources: [LynxSDKVersionMetadata], _ framework: LynxSDKVersionMetadata? = nil) throws -> String {
            try LynxSDKVersionResolver.resolve(resources: resources, framework: framework, normalize: { value in
                if value.isEmpty { throw LynxSDKVersionResolver.ResolutionError.missingVersion }
                return value
            })
        }
        func rejects(_ resources: [LynxSDKVersionMetadata], _ framework: LynxSDKVersionMetadata? = nil) {
            do { _ = try resolve(resources, framework); preconditionFailure("必须拒绝无效或冲突 metadata") }
            catch { count += 1 }
        }
        try check(resolve([resource]) == "4.0.0")
        try check(resolve([], framework) == "4.0.0")
        try check(resolve([resource, resource], framework) == "4.0.0")
        rejects([resource], .init(identifier: "org.cocoapods.Lynx", version: "4.1.0"))
        rejects([.init(identifier: "business.same-name-resource", version: "4.0.0")])
        rejects([], .init(identifier: "business.same-name-framework", version: "4.0.0"))
        rejects([])
        rejects([.init(identifier: "org.cocoapods.LynxResources", version: nil)])
        rejects([.init(identifier: "org.cocoapods.LynxResources", version: "")])
        print("LynxSDKVersionResolverTests PASS: \(count) checks")
    }
}
