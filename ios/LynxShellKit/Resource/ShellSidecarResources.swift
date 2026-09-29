import Foundation

extension OtaPreparedResources {
    /** 将固定快照的 actor 本地读取桥接给 Lynx；销毁后的回调由每 View fetcher 屏蔽。 */
    func makeFetcher(provider: ShellTemplateProvider) -> LynxLocalResourceFetcher {
        LynxLocalResourceFetcher(provider: provider, resolver: { [self] url, completion in
            Task {
                do { completion(try await resolve(url), nil) }
                catch { completion(nil, error as NSError) }
            }
        }, localURL: { [self] url in localURL(url) })
    }
}
