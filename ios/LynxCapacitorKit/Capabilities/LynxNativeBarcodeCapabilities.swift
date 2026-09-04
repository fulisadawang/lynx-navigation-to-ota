import AVFoundation
import Foundation
import UIKit

/** AVFoundation metadata scanner 对译 Android BarcodeScanActivity。 */
enum LynxNativeBarcodeCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void

    private static let lock = NSLock()
    private static var pending: PendingScan?
    private static var controller: BarcodeScannerViewController?

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) -> Bool {
        guard call.pluginId == "CapacitorBarcodeScanner" else { return false }
        guard call.methodName == "scanBarcode" else {
            completion(.failure("UNSUPPORTED", "CapacitorBarcodeScanner.\(call.methodName) 尚未接入当前 iOS Module"))
            return true
        }
        guard let presenter, sceneAvailable(presenter) else {
            completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法打开扫码器"))
            return true
        }
        guard infoString("NSCameraUsageDescription") != nil else {
            completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSCameraUsageDescription"))
            return true
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            completion(.failure("PERMISSION_DENIED", "未授予相机权限，请先调用 Camera.requestPermissions"))
            return true
        }
        guard lock.withLock({ pending == nil }) else {
            completion(.failure("BUSY", "已有扫码请求正在进行"))
            return true
        }

        let scan = PendingScan(ownerID: call.ownerID, options: call.options, completion: completion)
        let scanner = BarcodeScannerViewController(options: call.options) { result in
            finish(result)
        }
        lock.withLock {
            pending = scan
            controller = scanner
        }
        scanner.onCancelled = {
            finish(.failure("CANCELLED", "用户取消了扫码"))
        }
        presenter.present(scanner, animated: true)
        return true
    }

    static func release(ownerID: String) {
        let values = lock.withLock { () -> (PendingScan?, BarcodeScannerViewController?) in
            guard pending?.ownerID == ownerID else { return (nil, nil) }
            let current = pending
            let currentController = controller
            pending = nil
            controller = nil
            return (current, currentController)
        }
        values.1?.dismiss(animated: false)
        values.0?.completion(.failure("MODULE_DESTROYED", "扫码请求已取消"))
    }

    static func releaseAll() {
        let values = lock.withLock { () -> (PendingScan?, BarcodeScannerViewController?) in
            let current = pending
            let currentController = controller
            pending = nil
            controller = nil
            return (current, currentController)
        }
        values.1?.dismiss(animated: false)
        values.0?.completion(.failure("MODULE_DESTROYED", "扫码请求已取消"))
    }

    private static func finish(_ result: LynxNativeCapabilityResult) {
        let values = lock.withLock { () -> (PendingScan?, BarcodeScannerViewController?) in
            let current = pending
            let currentController = controller
            pending = nil
            controller = nil
            return (current, currentController)
        }
        guard let scan = values.0 else { return }
        if let controller = values.1 {
            controller.dismiss(animated: true) { scan.completion(result) }
        } else {
            scan.completion(result)
        }
    }

    private final class PendingScan {
        let ownerID: String?
        let options: [String: Any]
        let completion: Completion
        init(ownerID: String?, options: [String: Any], completion: @escaping Completion) {
            self.ownerID = ownerID
            self.options = options
            self.completion = completion
        }
    }

    private static func sceneAvailable(_ presenter: UIViewController) -> Bool {
        if let scene = presenter.viewIfLoaded?.window?.windowScene { return scene.activationState == .foregroundActive }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.activationState == .foregroundActive }
    }

    private static func infoString(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

    private final class BarcodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let options: [String: Any]
        private let resultHandler: (LynxNativeCapabilityResult) -> Void
        private let sessionQueue = DispatchQueue(label: "lynx.native.barcode.session")
        private var session: AVCaptureSession?
        private var finished = false
        var onCancelled: (() -> Void)?

        init(options: [String: Any], resultHandler: @escaping (LynxNativeCapabilityResult) -> Void) {
            self.options = options
            self.resultHandler = resultHandler
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .fullScreen
        }

        required init?(coder: NSCoder) { fatalError("BarcodeScannerViewController 不支持 storyboard") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let session = AVCaptureSession()
            self.session = session
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                finish(.failure("HARDWARE_UNAVAILABLE", "当前设备没有可用相机")); return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { finish(.failure("SCANNER_UNAVAILABLE", "无法创建扫码输出")); return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            let requested = (options["formats"] as? [Any] ?? []).compactMap { metadataType(string($0)) }
            let available = output.availableMetadataObjectTypes
            let selected = requested.isEmpty ? available : requested.filter(available.contains)
            guard !selected.isEmpty else {
                finish(.failure("UNSUPPORTED_FORMAT", "当前设备不支持请求的扫码格式"))
                return
            }
            output.metadataObjectTypes = selected
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            let close = UIButton(type: .system)
            close.setTitle("关闭", for: .normal)
            close.tintColor = .white
            close.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            close.layer.cornerRadius = 8
            close.frame = CGRect(x: 20, y: 50, width: 64, height: 40)
            close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
            view.addSubview(close)
            sessionQueue.async { session.startRunning() }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if let session { sessionQueue.async { session.stopRunning() } }
            if !finished { onCancelled?(); finished = true }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            _ = output; _ = connection
            guard let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let value = object.stringValue, !value.isEmpty else { return }
            let format = object.type.rawValue
            finish(.success(["content": value, "format": format, "hasContent": true]))
        }

        @objc private func cancel() { finish(.failure("CANCELLED", "用户取消了扫码")) }

        private func finish(_ result: LynxNativeCapabilityResult) {
            guard !finished else { return }
            finished = true
            if let session { sessionQueue.async { session.stopRunning() } }
            resultHandler(result)
        }

        private func metadataType(_ value: String) -> AVMetadataObject.ObjectType? {
            switch value.lowercased() {
            case "qr", "qr_code", "qrcode": return .qr
            case "ean13": return .ean13
            case "ean8": return .ean8
            case "code128": return .code128
            case "code39": return .code39
            case "code93": return .code93
            case "upce": return .upce
            case "pdf417": return .pdf417
            case "aztec": return .aztec
            case "datamatrix": return .dataMatrix
            default: return AVMetadataObject.ObjectType(rawValue: value)
            }
        }

        private func string(_ value: Any?) -> String { guard let value, !(value is NSNull) else { return "" }; return value as? String ?? String(describing: value) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
