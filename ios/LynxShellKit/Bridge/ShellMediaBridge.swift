import Foundation
import MobileCoreServices
import UIKit

/**
 * LynxShellModule 的媒体实现。
 *
 * 这是宿主内部实现类，不对 JS 单独暴露；JS 仍只调用
 * `NativeModules.LynxShellModule`。选择器使用系统 UIImagePickerController，
 * 上传、下载和 Data URL 落盘使用 Foundation，完全不依赖 Sparkling SDK。
 */
final class ShellMediaBridge: NSObject {
    static let shared = ShellMediaBridge()

    private var pickerCallback: LynxCallbackBlock?

    private override init() {
        super.init()
    }

    func chooseMedia(optionsJSON: String, callback: @escaping LynxCallbackBlock) {
        let options: [String: Any]
        do {
            options = try Self.decode(optionsJSON)
        } catch {
            callback(Self.failure(error.localizedDescription))
            return
        }

        DispatchQueue.main.async {
            guard self.pickerCallback == nil else {
                callback(Self.failure("已有媒体选择器正在显示"))
                return
            }
            guard let presenter = Self.topViewController() else {
                callback(Self.failure("找不到可显示媒体选择器的页面"))
                return
            }

            let source = (options["sourceType"] as? String) == "camera"
                ? UIImagePickerController.SourceType.camera
                : .photoLibrary
            guard UIImagePickerController.isSourceTypeAvailable(source) else {
                callback(Self.failure(source == .camera ? "当前设备没有可用相机" : "当前设备无法访问相册"))
                return
            }

            let mediaTypes = options["mediaTypes"] as? [String] ?? ["image"]
            let picker = UIImagePickerController()
            picker.sourceType = source
            picker.delegate = self
            picker.mediaTypes = mediaTypes.compactMap {
                switch $0 {
                case "image": return String(kUTTypeImage)
                case "video": return String(kUTTypeMovie)
                default: return nil
                }
            }
            if picker.mediaTypes.isEmpty {
                picker.mediaTypes = [String(kUTTypeImage)]
            }
            self.pickerCallback = callback
            presenter.present(picker, animated: true)
        }
    }

    func upload(optionsJSON: String, callback: @escaping LynxCallbackBlock) {
        let options: [String: Any]
        do {
            options = try Self.decode(optionsJSON)
        } catch {
            callback(Self.failure(error.localizedDescription))
            return
        }

        guard let rawURL = options["url"] as? String,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            callback(Self.failure("上传 URL 无效"))
            return
        }
        guard let rawPath = options["filePath"] as? String,
              let fileURL = Self.fileURL(from: rawPath),
              let fileData = try? Data(contentsOf: fileURL) else {
            callback(Self.failure("上传文件不存在或无法读取"))
            return
        }

        let boundary = "LynxShell-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        (options["header"] as? [String: Any])?.forEach { key, value in
            request.setValue(String(describing: value), forHTTPHeaderField: key)
        }

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"file\"; " +
                "filename=\"\(fileURL.lastPathComponent)\"\r\n"
        )
        body.appendUTF8("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            if let error {
                callback(Self.failure("上传失败: \(error.localizedDescription)"))
                return
            }
            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(httpCode) else {
                callback(Self.failure("上传失败，HTTP \(httpCode)"))
                return
            }
            callback(Self.success(data: [
                "url": rawURL,
                "clientCode": 0,
                "response": Self.responseObject(data),
            ]))
        }.resume()
    }

    func download(optionsJSON: String, callback: @escaping LynxCallbackBlock) {
        let options: [String: Any]
        do {
            options = try Self.decode(optionsJSON)
        } catch {
            callback(Self.failure(error.localizedDescription))
            return
        }

        guard let rawURL = options["url"] as? String,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            callback(Self.failure("下载 URL 无效"))
            return
        }
        let fileExtension = Self.safeExtension(options["extension"] as? String) ?? "bin"

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error {
                callback(Self.failure("下载失败: \(error.localizedDescription)"))
                return
            }
            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(httpCode), let data else {
                callback(Self.failure("下载失败，HTTP \(httpCode)"))
                return
            }
            guard data.count <= 20 * 1024 * 1024 else {
                callback(Self.failure("下载文件超过 20 MB 限制"))
                return
            }

            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("lynx-download-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            do {
                try data.write(to: output, options: .atomic)
                callback(Self.success(data: [
                    "httpCode": httpCode,
                    "clientCode": 0,
                    "filePath": output.absoluteString,
                ]))
            } catch {
                callback(Self.failure("保存下载文件失败: \(error.localizedDescription)"))
            }
        }.resume()
    }

    func saveDataURL(optionsJSON: String, callback: @escaping LynxCallbackBlock) {
        let options: [String: Any]
        do {
            options = try Self.decode(optionsJSON)
        } catch {
            callback(Self.failure(error.localizedDescription))
            return
        }

        guard let dataURL = options["dataURL"] as? String,
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].contains(";base64"),
              let decoded = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            callback(Self.failure("dataURL 必须是合法的 Base64 Data URL"))
            return
        }
        guard decoded.count <= 20 * 1024 * 1024 else {
            callback(Self.failure("Data URL 超过 20 MB 限制"))
            return
        }

        let rawName = options["filename"] as? String ?? "lynx-file"
        let safeName = rawName.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        let fileExtension = Self.safeExtension(options["extension"] as? String) ?? "bin"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName.isEmpty ? "lynx-file" : safeName)
            .appendingPathExtension(fileExtension)

        do {
            try decoded.write(to: output, options: .atomic)
            callback(Self.success(data: ["filePath": output.absoluteString]))
        } catch {
            callback(Self.failure("Data URL 落盘失败: \(error.localizedDescription)"))
        }
    }

    private static func decode(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LynxRouteError.invalidJSON("media options")
        }
        return value
    }

    private static func fileURL(from value: String) -> URL? {
        if value.lowercased().hasPrefix("file://") {
            return URL(string: value)
        }
        return URL(fileURLWithPath: value)
    }

    private static func safeExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard trimmed.range(of: "^[A-Za-z0-9]{1,10}$", options: .regularExpression) != nil else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func responseObject(_ data: Data?) -> Any {
        guard let data, !data.isEmpty else { return [:] }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func success(data: [String: Any]) -> NSDictionary {
        ["code": 0, "msg": "ok", "data": data]
    }

    private static func failure(_ message: String) -> NSDictionary {
        ["code": -1, "msg": message]
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return topViewController(from: root)
    }

    private static func topViewController(from controller: UIViewController?) -> UIViewController? {
        if let presented = controller?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        return controller
    }
}

extension ShellMediaBridge: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        let callback = pickerCallback
        pickerCallback = nil
        picker.dismiss(animated: true) {
            callback?(Self.failure("用户取消了媒体选择"))
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let callback = pickerCallback
        pickerCallback = nil

        do {
            let result = try Self.makePickedFile(info)
            picker.dismiss(animated: true) {
                callback?(Self.success(data: ["tempFiles": [result]]))
            }
        } catch {
            picker.dismiss(animated: true) {
                callback?(Self.failure(error.localizedDescription))
            }
        }
    }

    private static func makePickedFile(
        _ info: [UIImagePickerController.InfoKey: Any]
    ) throws -> [String: Any] {
        let sourceURL: URL
        let mediaType: String
        let mimeType: String

        if let videoURL = info[.mediaURL] as? URL {
            sourceURL = videoURL
            mediaType = "video"
            mimeType = "video/quicktime"
        } else if let imageURL = info[.imageURL] as? URL {
            sourceURL = imageURL
            mediaType = "image"
            mimeType = "image/jpeg"
        } else if let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.92) {
            sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lynx-image-\(UUID().uuidString).jpg")
            try data.write(to: sourceURL, options: .atomic)
            mediaType = "image"
            mimeType = "image/jpeg"
        } else {
            throw LynxRouteError.invalidArgument("系统选择器没有返回可读取的媒体文件")
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynx-media-\(UUID().uuidString)")
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension)
        if sourceURL != output {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: sourceURL, to: output)
        }
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return [
            "tempFilePath": output.absoluteString,
            "tempFileAbsolutePath": output.path,
            "size": size,
            "mediaType": mediaType,
            "mimeType": mimeType,
        ]
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(value.data(using: .utf8) ?? Data())
    }
}
