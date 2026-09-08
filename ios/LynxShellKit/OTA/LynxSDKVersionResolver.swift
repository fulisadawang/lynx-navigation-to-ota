import Foundation

struct LynxSDKVersionMetadata {
    let identifier: String?
    let version: String?
}

enum LynxSDKVersionResolver {
    enum ResolutionError: Error { case missingVersion, conflictingVersions }

    /** 只接受真实 Lynx 依赖的 metadata，多个可信来源必须相同；规范化由 OTA 契约提供。 */
    static func resolve(
        resources: [LynxSDKVersionMetadata],
        framework: LynxSDKVersionMetadata?,
        normalize: (String) throws -> String
    ) throws -> String {
        var candidates = resources.filter { $0.identifier == "org.cocoapods.LynxResources" }
        if let framework, framework.identifier == "org.cocoapods.Lynx" { candidates.append(framework) }
        guard !candidates.isEmpty else { throw ResolutionError.missingVersion }
        var versions: Set<String> = []
        for metadata in candidates {
            guard let version = metadata.version else { throw ResolutionError.missingVersion }
            versions.insert(try normalize(version))
        }
        guard versions.count == 1, let version = versions.first else { throw ResolutionError.conflictingVersions }
        return version
    }
}
