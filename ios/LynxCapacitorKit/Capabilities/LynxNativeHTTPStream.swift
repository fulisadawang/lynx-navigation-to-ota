import Foundation

/** 下载边收边检查，不能等整个响应驻留内存后才判断超限。 */
final class LynxNativeHTTPStream: NSObject, URLSessionDataDelegate {
    static let errorDomain = "LynxNativeHTTPResponseLimit"
    private let limit: Int
    private let disableRedirects: Bool
    private let completion: (Data, URLResponse?, Error?) -> Void
    private let lock = NSLock()
    private var completed = false
    private var bytes = Data()
    private var response: URLResponse?

    init(limit: Int, disableRedirects: Bool, completion: @escaping (Data, URLResponse?, Error?) -> Void) {
        self.limit = limit
        self.disableRedirects = disableRedirects
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        if response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            finish(session, error: limitError())
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count <= limit - data.count else {
            dataTask.cancel()
            finish(session, error: limitError())
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(session, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(disableRedirects ? nil : request)
    }

    private func limitError() -> NSError {
        NSError(domain: Self.errorDomain, code: 1,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 响应超过内联上限，请使用 FileTransfer 下载到 URI"])
    }

    private func finish(_ session: URLSession, error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(bytes, response, error)
        session.invalidateAndCancel()
    }
}
