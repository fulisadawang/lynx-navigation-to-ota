import Foundation
import UIKit
import Contacts
import EventKit
import CoreLocation
import CoreMotion
import UserNotifications
import BackgroundTasks

/**
 * iOS 自研 provider 能力。
 *
 * 这里的 pluginId 只是 Lynx 页面协议中的能力命名空间；所有行为直接调用 Apple
 * framework，不创建 Capacitor Bridge，也不引用任何上游 plugin。Android 的自研实现是
 * 方法和结果形状的事实源；iOS 没有等价 provider 或宿主配置时返回结构化错误。
 */
enum LynxNativeProviderCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void
    typealias EventSender = (String) -> Void

    private static let pendingLock = NSLock()
    private static var pendingOperations: [String: PendingOperation] = [:]
    private static var notificationPermissionRequestID: String?

    private static let contactsQueue = DispatchQueue(label: "lynx.native.contacts", qos: .userInitiated)
    private static let calendarQueue = DispatchQueue(label: "lynx.native.calendar", qos: .userInitiated)
    private static let notificationQueue = DispatchQueue(label: "lynx.native.notifications", qos: .utility)

    private static var locationOwner: LocationOwner?
    private static var motionState = MotionState()
    private static var backgroundIdentifiers = Set<String>()
    private static var notificationSenders: [String: EventSender] = [:]

    private static let localNotificationMarkerKey = "_lynx_native_owner"
    private static let localNotificationMarkerValue = "local"
    private static let localNotificationOwnerIDKey = "_lynx_native_owner_id"
    private static let localNotificationIDKey = "_lynx_native_notification_id"
    private static let localNotificationIdentifierPrefix = "lynx.native.local."
    private static let backgroundPayloadPrefix = "lynx.native.background."

    private static let supportedMethods: [String: Set<String>] = [
        "Contacts": ["checkPermissions", "requestPermissions", "save", "find", "remove"],
        "Calendar": ["createCalendar", "createEvent", "findEvents", "deleteEvent", "deleteCalendar", "checkPermissions", "requestPermissions", "listCalendars"],
        "Geolocation": ["checkPermissions", "requestPermissions", "getCurrentPosition"],
        "Motion": ["addListener", "removeListener", "removeAllListeners", "start", "stop"],
        "LocalNotifications": ["checkPermissions", "requestPermissions", "schedule", "getPending", "cancel", "getDeliveredNotifications", "createChannel", "listChannels"],
        "PushNotifications": ["checkPermissions", "requestPermissions", "register"],
        "BackgroundRunner": ["checkPermissions", "requestPermissions", "dispatchEvent"],
    ]

    /**
     * 返回 true 表示本 provider 认领了 pluginId。异步方法不会返回“pending 成功”占位，
     * 而是把唯一 completion 放入 pending owner，直到系统回调、取消或超时才完成。
     */
    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        eventSender: EventSender?,
        completion: @escaping Completion
    ) -> Bool {
        guard supportedMethods[call.pluginId] != nil else { return false }
        guard supportedMethods[call.pluginId]?.contains(call.methodName) == true else {
            completion(.failure(
                "UNSUPPORTED",
                "\(call.pluginId).\(call.methodName) 尚未接入当前 iOS Module"
            ))
            return true
        }

        switch call.pluginId {
        case "Contacts":
            dispatchContacts(call, presenter: presenter, completion: completion)
        case "Calendar":
            dispatchCalendar(call, presenter: presenter, completion: completion)
        case "Geolocation":
            dispatchGeolocation(call, presenter: presenter, completion: completion)
        case "Motion":
            dispatchMotion(call, presenter: presenter, eventSender: eventSender, completion: completion)
        case "LocalNotifications":
            dispatchLocalNotifications(call, presenter: presenter, eventSender: eventSender, completion: completion)
        case "PushNotifications":
            dispatchPushNotifications(call, presenter: presenter, completion: completion)
        case "BackgroundRunner":
            dispatchBackgroundRunner(call, presenter: presenter, eventSender: eventSender, completion: completion)
        default:
            return false
        }
        return true
    }

    /** 只释放指定 Lynx Module owner 的挂起请求和事件 sender。 */
    static func release(ownerID: String) {
        let operations: [PendingOperation] = pendingLock.withLock {
            let matching = pendingOperations.filter { $0.value.ownerID == ownerID }
            matching.keys.forEach { pendingOperations.removeValue(forKey: $0) }
            if let permissionID = notificationPermissionRequestID,
               matching[permissionID] != nil {
                notificationPermissionRequestID = nil
            }
            return Array(matching.values)
        }
        operations.forEach { operation in
            operation.timeout?.cancel()
            operation.cancelResource()
            operation.completion.call(.failure("MODULE_DESTROYED", "iOS Native Module 已销毁，请求已取消"))
        }
        if locationOwner?.ownerID == ownerID {
            locationOwner?.cancel()
            locationOwner = nil
        }
        motionState.removeListeners(ownerID: ownerID)
        notificationSenders.removeValue(forKey: ownerID)
    }

    /** 最后一个 Module 销毁时释放仍属于进程级能力的共享资源。 */
    static func releaseAll() {
        let operations: [PendingOperation] = pendingLock.withLock {
            let values = Array(pendingOperations.values)
            pendingOperations.removeAll()
            notificationPermissionRequestID = nil
            return values
        }
        operations.forEach { operation in
            operation.timeout?.cancel()
            operation.cancelResource()
            operation.completion.call(.failure("MODULE_DESTROYED", "iOS Native Module 已销毁，请求已取消"))
        }
        locationOwner?.cancel()
        locationOwner = nil
        motionState.stop(clearListeners: true)
        if let delegate = notificationDelegate,
           UNUserNotificationCenter.current().delegate === delegate {
            UNUserNotificationCenter.current().delegate = nil
        }
        notificationDelegate = nil
        notificationSenders.removeAll()
    }

    // MARK: - Pending owner

    private final class CompletionOnce {
        private let lock = NSLock()
        private var finished = false
        private let callback: Completion

        init(_ callback: @escaping Completion) {
            self.callback = callback
        }

        func call(_ result: LynxNativeCapabilityResult) {
            let shouldCall = lock.withLock { () -> Bool in
                guard !finished else { return false }
                finished = true
                return true
            }
            guard shouldCall else { return }
            callback(result)
        }
    }

    private final class PendingOperation {
        let ownerID: String?
        let completion: CompletionOnce
        let cancelResource: () -> Void
        var timeout: DispatchWorkItem?

        init(ownerID: String?, completion: @escaping Completion, cancelResource: @escaping () -> Void) {
            self.ownerID = ownerID
            self.completion = CompletionOnce(completion)
            self.cancelResource = cancelResource
        }
    }

    @discardableResult
    private static func makePending(
        ownerID: String? = nil,
        timeout: TimeInterval,
        timeoutResult: @escaping () -> LynxNativeCapabilityResult,
        cancelResource: @escaping () -> Void,
        completion: @escaping Completion
    ) -> String {
        let id = UUID().uuidString
        let operation = PendingOperation(ownerID: ownerID, completion: completion, cancelResource: cancelResource)
        pendingLock.withLock {
            pendingOperations[id] = operation
        }
        let timeoutWork = DispatchWorkItem {
            finishPending(id, result: timeoutResult(), cancelResource: true)
        }
        operation.timeout = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        return id
    }

    private static func finishPending(
        _ id: String,
        result: LynxNativeCapabilityResult,
        cancelResource: Bool = false
    ) {
        let operation = pendingLock.withLock { pendingOperations.removeValue(forKey: id) }
        guard let operation else { return }
        operation.timeout?.cancel()
        if cancelResource { operation.cancelResource() }
        let deliver = { operation.completion.call(result) }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private static func sceneAvailable(_ presenter: UIViewController?) -> Bool {
        if let scene = presenter?.viewIfLoaded?.window?.windowScene,
           scene.activationState == .foregroundActive {
            return true
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.activationState == .foregroundActive && !$0.windows.isEmpty }
    }

    private static func requireScene(
        _ presenter: UIViewController?,
        completion: @escaping Completion
    ) -> Bool {
        guard sceneAvailable(presenter) else {
            completion(.failure("SCENE_UNAVAILABLE", "没有可用的前台 iOS scene，无法完成系统请求"))
            return false
        }
        return true
    }

    private static func dispatchOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Contacts

    private static func dispatchContacts(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "checkPermissions":
            completion(.success(contactPermissionData()))
        case "requestPermissions":
            requestContactPermission(ownerID: call.ownerID, presenter: presenter, completion: completion)
        case "save":
            contactsQueue.async {
                completion(saveContact(call.options))
            }
        case "find":
            contactsQueue.async {
                completion(findContacts(call.options))
            }
        case "remove":
            contactsQueue.async {
                completion(removeContact(call.options))
            }
        default:
            completion(.failure("UNSUPPORTED", "Contacts.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func contactPermissionData() -> [String: Any] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        let value = contactPermissionState(status)
        return [
            "readContacts": value,
            "writeContacts": value,
        ]
    }

    private static func contactPermissionState(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "prompt"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "granted"
        default:
            if #available(iOS 18.0, *), status == .limited {
                return "limited"
            }
            return "unknown"
        }
    }

    private static func requestContactPermission(
        ownerID: String?,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        guard requireScene(presenter, completion: completion) else { return }
        guard infoString("NSContactsUsageDescription") != nil else {
            completion(.failure("PERMISSION_NOT_DECLARED", "宿主 Info.plist 未声明 NSContactsUsageDescription"))
            return
        }
        let current = CNContactStore.authorizationStatus(for: .contacts)
        guard current == .notDetermined else {
            completion(.success(contactPermissionData()))
            return
        }

        let store = CNContactStore()
        var requestID = ""
        requestID = makePending(
            ownerID: ownerID,
            timeout: 30,
            timeoutResult: { .failure("PERMISSION_REQUEST_TIMEOUT", "联系人权限请求超时") },
            cancelResource: {},
            completion: completion
        )
        // `requestAccess` 的系统 completion 是唯一完成源；这里的闭包再经过 CompletionOnce
        // 防止系统回调与超时/Module release 竞争。
        store.requestAccess(for: .contacts) { _, error in
            dispatchOnMain {
                if let error, CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                    finishPending(
                        requestID,
                        result: .failure(
                            "PERMISSION_REQUEST_FAILED",
                            error.localizedDescription,
                            details: ["domain": (error as NSError).domain, "code": (error as NSError).code]
                        )
                    )
                } else {
                    finishPending(requestID, result: .success(contactPermissionData()))
                }
            }
        }
    }

    private static func contactReadKeys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactMiddleNameKey,
            CNContactNamePrefixKey,
            CNContactNameSuffixKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactDepartmentNameKey,
            CNContactJobTitleKey,
            CNContactNoteKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
    }

    private static func canReadContacts() -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        if #available(iOS 18.0, *) { return status == .limited }
        return false
    }

    private static func ifAvailableContactsLimited(_ status: CNAuthorizationStatus) -> Bool {
        if #available(iOS 18.0, *) {
            return status == .limited
        }
        return false
    }

    private static func canWriteContacts() -> Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    private static func saveContact(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard canWriteContacts() else {
            return permissionFailure(
                status: CNContactStore.authorizationStatus(for: .contacts),
                action: "写入联系人"
            )
        }
        guard let rawContact = options["contact"] as? [String: Any] else {
            return .failure("INVALID_ARGUMENT", "contact 不能为空")
        }

        let contact = CNMutableContact()
        if let name = rawContact["name"] as? [String: Any] {
            contact.givenName = stringValue(name["givenName"])
            contact.familyName = stringValue(name["familyName"])
            contact.middleName = stringValue(name["middleName"])
            contact.namePrefix = stringValue(name["prefix"] ?? name["namePrefix"])
            contact.nameSuffix = stringValue(name["suffix"] ?? name["nameSuffix"])
        }
        contact.nickname = stringValue(rawContact["nickname"])
        contact.organizationName = stringValue((rawContact["organization"] as? [String: Any])?["company"])
        contact.departmentName = stringValue((rawContact["organization"] as? [String: Any])?["department"])
        contact.jobTitle = stringValue(
            (rawContact["organization"] as? [String: Any])?["jobTitle"]
                ?? (rawContact["organization"] as? [String: Any])?["title"]
        )
        contact.note = stringValue(rawContact["note"])

        let rawPhones = (rawContact["phones"] ?? rawContact["phoneNumbers"]) as? [[String: Any]] ?? []
        contact.phoneNumbers = rawPhones.compactMap { phone in
            let number = stringValue(phone["number"])
            guard !number.isEmpty else { return nil }
            let label = stringValue(phone["label"]).isEmpty ? CNLabelPhoneNumberMobile : stringValue(phone["label"])
            return CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: number))
        }

        let rawEmails = (rawContact["emails"] ?? rawContact["emailAddresses"]) as? [[String: Any]] ?? []
        contact.emailAddresses = rawEmails.compactMap { email in
            let address = stringValue(email["address"])
            guard !address.isEmpty else { return nil }
            let label = stringValue(email["label"]).isEmpty ? CNLabelHome : stringValue(email["label"])
            return CNLabeledValue(label: label, value: address as NSString)
        }

        let store = CNContactStore()
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            return .success(["id": contact.identifier])
        } catch let error as NSError {
            return .failure(
                error.domain == CNErrorDomain ? "NO_PROVIDER" : "NATIVE_ERROR",
                error.localizedDescription,
                details: ["domain": error.domain, "code": error.code]
            )
        }
    }

    private static func findContacts(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard canReadContacts() else {
            return permissionFailure(
                status: CNContactStore.authorizationStatus(for: .contacts),
                action: "读取联系人"
            )
        }
        let filter = stringValue(options["filter"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let multiple = boolValue(options["multiple"], default: false)
        let requestedFields = stringArray(options["fields"]) + stringArray(options["desiredFields"])
        let includeAll = requestedFields.isEmpty
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: contactReadKeys())
        request.predicate = nil
        var contacts = [[String: Any]]()

        do {
            try store.enumerateContacts(with: request) { contact, stop in
                if !filter.isEmpty && !contactMatches(contact, filter: filter) { return }
                contacts.append(contactJSON(contact, includeAll: includeAll, requestedFields: requestedFields))
                if !multiple { stop.pointee = true }
            }
            return .success(["contacts": contacts])
        } catch let error as NSError {
            return .failure(
                error.domain == CNErrorDomain ? "NO_PROVIDER" : "NATIVE_ERROR",
                error.localizedDescription,
                details: ["domain": error.domain, "code": error.code]
            )
        }
    }

    private static func contactMatches(_ contact: CNContact, filter: String) -> Bool {
        if contact.identifier.caseInsensitiveCompare(filter) == .orderedSame { return true }
        let haystacks = [
            contact.givenName,
            contact.familyName,
            contact.middleName,
            contact.namePrefix,
            contact.nameSuffix,
            contact.nickname,
            contact.organizationName,
            contact.departmentName,
            contact.jobTitle,
        ] + contact.phoneNumbers.map { $0.value.stringValue }
            + contact.emailAddresses.map { $0.value as String }
        return haystacks.contains { $0.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func contactJSON(
        _ contact: CNContact,
        includeAll: Bool,
        requestedFields: [String]
    ) -> [String: Any] {
        func wants(_ name: String, aliases: [String] = []) -> Bool {
            includeAll || requestedFields.contains { value in
                ([name] + aliases).contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            }
        }

        var result: [String: Any] = ["id": contact.identifier]
        if wants("displayName") {
            result["displayName"] = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        }
        if wants("name") {
            result["name"] = compactDictionary([
                "givenName": contact.givenName,
                "familyName": contact.familyName,
                "middleName": contact.middleName,
                "prefix": contact.namePrefix,
                "suffix": contact.nameSuffix,
            ])
        }
        if wants("phones", aliases: ["phoneNumbers"]) {
            result["phones"] = contact.phoneNumbers.map { item in
                [
                    "number": item.value.stringValue,
                    "type": androidPhoneType(item.label),
                    "label": item.label ?? "",
                ] as [String: Any]
            }
        }
        if wants("emails", aliases: ["emailAddresses"]) {
            result["emails"] = contact.emailAddresses.map { item in
                [
                    "address": item.value as String,
                    "type": androidEmailType(item.label),
                    "label": item.label ?? "",
                ] as [String: Any]
            }
        }
        if wants("organization") {
            result["organization"] = compactDictionary([
                "company": contact.organizationName,
                "department": contact.departmentName,
                "jobTitle": contact.jobTitle,
            ])
        }
        return result
    }

    private static func removeContact(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard canWriteContacts() else {
            return permissionFailure(
                status: CNContactStore.authorizationStatus(for: .contacts),
                action: "删除联系人"
            )
        }
        let identifier = stringValue(options["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return .failure("INVALID_ARGUMENT", "id 不能为空") }

        do {
            let store = CNContactStore()
            let contact = try store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: contactReadKeys()
            ).mutableCopy() as? CNMutableContact
            guard let contact else { return .success(["removed": false]) }
            let request = CNSaveRequest()
            request.delete(contact)
            try store.execute(request)
            return .success(["removed": true])
        } catch let error as NSError {
            if error.domain == CNErrorDomain && error.code == CNError.Code.recordDoesNotExist.rawValue {
                return .success(["removed": false])
            }
            return .failure(
                error.domain == CNErrorDomain ? "NO_PROVIDER" : "NATIVE_ERROR",
                error.localizedDescription,
                details: ["domain": error.domain, "code": error.code]
            )
        }
    }

    private static func permissionFailure(
        status: CNAuthorizationStatus,
        action: String
    ) -> LynxNativeCapabilityResult {
        let state = contactPermissionState(status)
        let code: String
        switch state {
        case "restricted": code = "PERMISSION_RESTRICTED"
        case "prompt": code = "PERMISSION_NOT_REQUESTED"
        case "limited": code = "LIMITED_ACCESS"
        default: code = "PERMISSION_DENIED"
        }
        return .failure(code, "未授予\(action)权限", details: contactPermissionData())
    }

    // MARK: - Calendar / EventKit

    private static func dispatchCalendar(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "checkPermissions":
            completion(.success(calendarPermissionData()))
        case "requestPermissions":
            requestCalendarPermission(ownerID: call.ownerID, options: call.options, presenter: presenter, completion: completion)
        case "listCalendars":
            calendarQueue.async { completion(listCalendars()) }
        case "createCalendar":
            calendarQueue.async { completion(createCalendar(call.options)) }
        case "createEvent":
            calendarQueue.async { completion(createEvent(call.options)) }
        case "findEvents":
            calendarQueue.async { completion(findEvents(call.options)) }
        case "deleteEvent":
            calendarQueue.async { completion(deleteEvent(call.options)) }
        case "deleteCalendar":
            calendarQueue.async { completion(deleteCalendar(call.options)) }
        default:
            completion(.failure("UNSUPPORTED", "Calendar.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func calendarPermissionData() -> [String: Any] {
        let status = EKEventStore.authorizationStatus(for: .event)
        return [
            "readCalendar": calendarPermissionState(status, forWrite: false),
            "writeCalendar": calendarPermissionState(status, forWrite: true),
        ]
    }

    private static func calendarPermissionState(
        _ status: EKAuthorizationStatus,
        forWrite: Bool
    ) -> String {
        switch status {
        case .notDetermined:
            return "prompt"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        default:
            if #available(iOS 17.0, *), status == .writeOnly {
                return forWrite ? "writeOnly" : "denied"
            }
            if #available(iOS 17.0, *), status == .fullAccess {
                return "granted"
            }
            // iOS 15/16 的 authorized 与 iOS 17+ 的 fullAccess 语义相同。
            return "granted"
        }
    }

    private static func calendarCanRead() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    private static func calendarCanWrite() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            return status == .fullAccess || status == .writeOnly
        }
        return status == .authorized
    }

    private static func requestCalendarPermission(
        ownerID: String?,
        options: [String: Any],
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        guard requireScene(presenter, completion: completion) else { return }
        let requested = requestedPermissionNames(options, defaults: ["read", "write"], accepted: ["read", "write", "calendar", "readcalendar", "writecalendar"])
        guard let requested else {
            completion(.failure("INVALID_ARGUMENT", "permissions 包含当前 Calendar 不支持的权限类型"))
            return
        }
        let wantsRead = requested.contains { ["read", "calendar", "readcalendar"].contains($0) }
        let wantsWrite = requested.contains { ["write", "calendar", "writecalendar"].contains($0) }
        guard wantsRead || wantsWrite else {
            completion(.failure("INVALID_ARGUMENT", "permissions 不能为空"))
            return
        }
        guard calendarUsageDescriptionPresent(read: wantsRead, write: wantsWrite) else {
            completion(.failure("PERMISSION_NOT_DECLARED", "宿主 Info.plist 未声明所需日历权限说明"))
            return
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .notDetermined else {
            completion(.success(calendarPermissionData()))
            return
        }
        let store = EKEventStore()
        var requestID = ""
        requestID = makePending(
            ownerID: ownerID,
            timeout: 30,
            timeoutResult: { .failure("PERMISSION_REQUEST_TIMEOUT", "日历权限请求超时") },
            cancelResource: {},
            completion: completion
        )

        if #available(iOS 17.0, *) {
            if wantsRead || wantsWrite {
                if wantsRead {
                    store.requestFullAccessToEvents { granted, error in
                        dispatchOnMain {
                            if let error, !granted {
                                finishPending(requestID, result: .failure("PERMISSION_REQUEST_FAILED", error.localizedDescription))
                            } else {
                                finishPending(requestID, result: .success(calendarPermissionData()))
                            }
                        }
                    }
                } else {
                    store.requestWriteOnlyAccessToEvents { granted, error in
                        dispatchOnMain {
                            if let error, !granted {
                                finishPending(requestID, result: .failure("PERMISSION_REQUEST_FAILED", error.localizedDescription))
                            } else {
                                finishPending(requestID, result: .success(calendarPermissionData()))
                            }
                        }
                    }
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, error in
                dispatchOnMain {
                    if let error, !granted {
                        finishPending(requestID, result: .failure("PERMISSION_REQUEST_FAILED", error.localizedDescription))
                    } else {
                        finishPending(requestID, result: .success(calendarPermissionData()))
                    }
                }
            }
        }
    }

    private static func calendarPermissionFailure(action: String, write: Bool) -> LynxNativeCapabilityResult {
        let status = EKEventStore.authorizationStatus(for: .event)
        let state = calendarPermissionState(status, forWrite: write)
        let code: String
        switch state {
        case "restricted": code = "PERMISSION_RESTRICTED"
        case "prompt": code = "PERMISSION_NOT_REQUESTED"
        case "writeOnly": code = write ? "LIMITED_ACCESS" : "PERMISSION_DENIED"
        default: code = "PERMISSION_DENIED"
        }
        return .failure(code, "未授予\(action)权限", details: calendarPermissionData())
    }

    private static func listCalendars() -> LynxNativeCapabilityResult {
        guard calendarCanRead() else { return calendarPermissionFailure(action: "读取日历", write: false) }
        let store = EKEventStore()
        let calendars = store.calendars(for: .event).map { calendar in
            [
                "id": calendar.calendarIdentifier,
                "name": calendar.title,
                "accountName": calendar.source?.title as Any,
                "accountType": calendar.source?.sourceIdentifier as Any,
                "color": hexColor(calendar.cgColor),
                "accessLevel": calendar.allowsContentModifications ? "owner" : "readOnly",
                "visible": true,
            ] as [String: Any]
        }
        return .success(["calendars": calendars])
    }

    private static func createCalendar(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard calendarCanWrite() else { return calendarPermissionFailure(action: "创建日历", write: true) }
        let name = stringValue(options["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure("INVALID_ARGUMENT", "name 不能为空") }
        let store = EKEventStore()
        guard let source = store.sources.first(where: { !$0.calendars(for: .event).isEmpty }) else {
            return .failure("NO_PROVIDER", "EventKit 没有可创建事件的 calendar source")
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        calendar.source = source
        if let color = parseUIColor(stringValue(options["color"])) {
            calendar.cgColor = color.cgColor
        }
        do {
            try store.saveCalendar(calendar, commit: true)
            return .success(["id": calendar.calendarIdentifier, "name": name])
        } catch let error as NSError {
            return .failure("NO_PROVIDER", error.localizedDescription, details: ["domain": error.domain, "code": error.code])
        }
    }

    private static func createEvent(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard calendarCanWrite() else { return calendarPermissionFailure(action: "创建日历事件", write: true) }
        let title = stringValue(options["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarID = stringValue(options["calendarId"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !calendarID.isEmpty,
              let startDate = dateValue(options["startDate"]),
              let endDate = dateValue(options["endDate"]) else {
            return .failure("INVALID_ARGUMENT", "title、calendarId、startDate 和 endDate 为必填项")
        }
        guard endDate >= startDate else { return .failure("INVALID_ARGUMENT", "endDate 不能早于 startDate") }

        let store = EKEventStore()
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            return .failure("CALENDAR_NOT_FOUND", "EventKit calendar 不存在", details: ["calendarId": calendarID])
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = stringValue(options["notes"] ?? options["description"])
        event.location = stringValue(options["location"])
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = boolValue(options["isAllDay"] ?? options["allDay"], default: false)

        if let reminders = options["reminders"] as? [[String: Any]] {
            for reminder in reminders {
                let minutes = intValue(reminder["minutes"])
                guard let minutes, minutes >= 0 else { continue }
                event.addAlarm(EKAlarm(relativeOffset: -Double(minutes) * 60.0))
            }
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return .success(["id": event.eventIdentifier as Any])
        } catch let error as NSError {
            return .failure("NO_PROVIDER", error.localizedDescription, details: ["domain": error.domain, "code": error.code])
        }
    }

    private static func findEvents(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard calendarCanRead() else { return calendarPermissionFailure(action: "读取日历事件", write: false) }
        let now = Date()
        let startDate = dateValue(options["startDate"]) ?? now.addingTimeInterval(-86_400)
        let endDate = dateValue(options["endDate"]) ?? now.addingTimeInterval(365 * 86_400)
        guard endDate > startDate else { return .failure("INVALID_ARGUMENT", "endDate 必须晚于 startDate") }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let titleFilter = stringValue(options["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarID = stringValue(options["calendarId"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarName = stringValue(options["calendarName"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let events = store.events(matching: predicate).filter { event in
            if !titleFilter.isEmpty && !(event.title ?? "").localizedCaseInsensitiveContains(titleFilter) { return false }
            if !calendarID.isEmpty && event.calendar.calendarIdentifier != calendarID { return false }
            if !calendarName.isEmpty && event.calendar.title != calendarName { return false }
            return true
        }.map(eventJSON)
        return .success(["events": events])
    }

    private static func deleteEvent(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard calendarCanWrite() else { return calendarPermissionFailure(action: "删除日历事件", write: true) }
        let identifier = stringValue(options["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return .failure("INVALID_ARGUMENT", "id 不能为空") }
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: identifier) else { return .success(["deleted": false]) }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            return .success(["deleted": true])
        } catch let error as NSError {
            return .failure("NO_PROVIDER", error.localizedDescription, details: ["domain": error.domain, "code": error.code])
        }
    }

    private static func deleteCalendar(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard calendarCanWrite() else { return calendarPermissionFailure(action: "删除日历", write: true) }
        let identifier = stringValue(options["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = stringValue(options["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty || !name.isEmpty else { return .failure("INVALID_ARGUMENT", "id 或 name 至少需要一个") }
        let store = EKEventStore()
        let targets: [EKCalendar]
        if !identifier.isEmpty {
            targets = store.calendar(withIdentifier: identifier).map { [$0] } ?? []
        } else {
            targets = store.calendars(for: .event).filter { $0.title == name }
        }
        guard !targets.isEmpty else { return .success(["deleted": false]) }
        do {
            for target in targets { try store.removeCalendar(target, commit: false) }
            try store.commit()
            return .success(["deleted": true])
        } catch let error as NSError {
            return .failure("NO_PROVIDER", error.localizedDescription, details: ["domain": error.domain, "code": error.code])
        }
    }

    private static func eventJSON(_ event: EKEvent) -> [String: Any] {
        [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "notes": event.notes ?? NSNull(),
            "location": event.location ?? NSNull(),
            "startDate": event.startDate.timeIntervalSince1970 * 1000,
            "endDate": event.endDate.timeIntervalSince1970 * 1000,
            "isAllDay": event.isAllDay,
            "calendarId": event.calendar.calendarIdentifier,
            "calendarName": event.calendar.title,
        ]
    }

    // MARK: - Geolocation / CoreLocation

    private static func dispatchGeolocation(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "checkPermissions":
            completion(locationPermissionResult())
        case "requestPermissions":
            requestLocationPermission(ownerID: call.ownerID, options: call.options, presenter: presenter, completion: completion)
        case "getCurrentPosition":
            requestCurrentPosition(call.ownerID, call.options, presenter: presenter, completion: completion)
        default:
            completion(.failure("UNSUPPORTED", "Geolocation.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func locationManagerStatus() -> CLAuthorizationStatus {
        CLLocationManager().authorizationStatus
    }

    private static func locationPermissionState(
        _ status: CLAuthorizationStatus,
        manager: CLLocationManager? = nil
    ) -> String {
        switch status {
        case .notDetermined:
            return "prompt"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways, .authorizedWhenInUse:
            if #available(iOS 14.0, *), manager?.accuracyAuthorization == .reducedAccuracy {
                return "limited"
            }
            return "granted"
        @unknown default:
            return "unknown"
        }
    }

    private static func locationPermissionResult() -> LynxNativeCapabilityResult {
        guard locationUsageDescriptionPresent(always: false) else {
            return .failure(
                "PERMISSION_NOT_DECLARED",
                "宿主 Info.plist 未声明 NSLocationWhenInUseUsageDescription"
            )
        }
        let manager = CLLocationManager()
        let state = locationPermissionState(manager.authorizationStatus, manager: manager)
        return .success([
            "location": state,
            "accuracyAuthorization": locationAccuracyState(manager),
        ])
    }

    private static func requestLocationPermission(
        ownerID: String?,
        options: [String: Any],
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        guard requireScene(presenter, completion: completion) else { return }
        let requestAlways = requestedPermissionNames(
            options,
            defaults: ["wheninuse"],
            accepted: ["wheninuse", "always", "location"]
        )?.contains { $0 == "always" } ?? false
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        if status != .notDetermined && !(requestAlways && status == .authorizedWhenInUse) {
            completion(locationPermissionResult())
            return
        }
        guard locationUsageDescriptionPresent(always: requestAlways) else {
            completion(.failure(
                "PERMISSION_NOT_DECLARED",
                requestAlways
                    ? "宿主 Info.plist 未声明定位 Always/WhenInUse 使用说明"
                    : "宿主 Info.plist 未声明 NSLocationWhenInUseUsageDescription"
            ))
            return
        }

        var requestID = ""
        let owner = LocationAuthorizationOwner(ownerID: ownerID, manager: manager) { result in
            finishPending(requestID, result: result)
        }
        requestID = makePending(
            ownerID: ownerID,
            timeout: 30,
            timeoutResult: { .failure("PERMISSION_REQUEST_TIMEOUT", "定位权限请求超时") },
            cancelResource: { owner.cancel() },
            completion: completion
        )
        owner.requestID = requestID
        manager.delegate = owner
        if requestAlways {
            manager.requestAlwaysAuthorization()
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    private static func requestCurrentPosition(
        _ ownerID: String?,
        _ options: [String: Any],
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        guard requireScene(presenter, completion: completion) else { return }
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            let state = locationPermissionState(status, manager: manager)
            let code: String
            switch state {
            case "restricted": code = "PERMISSION_RESTRICTED"
            case "prompt": code = "PERMISSION_NOT_REQUESTED"
            default: code = "PERMISSION_DENIED"
            }
            completion(.failure(code, "未授予定位权限", details: [
                "location": state,
                "accuracyAuthorization": locationAccuracyState(manager),
            ]))
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            completion(.failure("LOCATION_SERVICES_DISABLED", "系统定位服务已关闭"))
            return
        }

        let maximumAge = max(0, doubleValue(options["maximumAge"], default: 0))
        if maximumAge > 0, let cached = manager.location,
           Date().timeIntervalSince(cached.timestamp) * 1000 <= maximumAge {
            completion(.success(locationJSON(cached)))
            return
        }

        pendingLock.lock()
        let requestInProgress = locationOwner != nil
        pendingLock.unlock()
        guard !requestInProgress else {
            completion(.failure("LOCATION_REQUEST_IN_PROGRESS", "当前 iOS Module 已有定位请求未完成"))
            return
        }

        let highAccuracy = boolValue(options["enableHighAccuracy"], default: false)
        manager.desiredAccuracy = highAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        let timeout = boundedTimeout(options["timeout"], default: 10)
        var requestID = ""
        let owner = LocationOwner(ownerID: ownerID, manager: manager) { result in
            locationOwner = nil
            finishPending(requestID, result: result)
        }
        requestID = makePending(
            ownerID: ownerID,
            timeout: timeout,
            timeoutResult: {
                .failure(
                    "NO_LOCATION_FIX",
                    "CoreLocation 在超时时间内没有返回位置",
                    details: ["timeout": timeout * 1000]
                )
            },
            cancelResource: {
                owner.cancel()
                if locationOwner?.requestID == requestID { locationOwner = nil }
            },
            completion: completion
        )
        owner.requestID = requestID
        pendingLock.withLock { locationOwner = owner }
        manager.delegate = owner
        manager.requestLocation()
    }

    private final class LocationAuthorizationOwner: NSObject, CLLocationManagerDelegate {
        let ownerID: String?
        let manager: CLLocationManager
        let callback: (LynxNativeCapabilityResult) -> Void
        var requestID = ""

        init(ownerID: String?, manager: CLLocationManager, callback: @escaping (LynxNativeCapabilityResult) -> Void) {
            self.ownerID = ownerID
            self.manager = manager
            self.callback = callback
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let status = manager.authorizationStatus
            guard status != .notDetermined else { return }
            callback(.success([
                "location": locationPermissionState(status, manager: manager),
                "accuracyAuthorization": locationAccuracyState(manager),
            ]))
            cancel()
        }

        func cancel() {
            manager.delegate = nil
        }
    }

    private final class LocationOwner: NSObject, CLLocationManagerDelegate {
        let ownerID: String?
        let manager: CLLocationManager
        let callback: (LynxNativeCapabilityResult) -> Void
        var requestID = ""

        init(ownerID: String?, manager: CLLocationManager, callback: @escaping (LynxNativeCapabilityResult) -> Void) {
            self.ownerID = ownerID
            self.manager = manager
            self.callback = callback
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let location = locations.last else { return }
            callback(.success(locationJSON(location)))
            cancel()
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            let nsError = error as NSError
            let code = nsError.code == CLError.denied.rawValue ? "PERMISSION_DENIED" : "LOCATION_REQUEST_FAILED"
            callback(.failure(code, nsError.localizedDescription, details: [
                "domain": nsError.domain,
                "code": nsError.code,
            ]))
            cancel()
        }

        func cancel() {
            manager.stopUpdatingLocation()
            manager.delegate = nil
        }
    }

    private static func locationJSON(_ location: CLLocation) -> [String: Any] {
        let coords: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : NSNull(),
            "altitude": location.verticalAccuracy >= 0 ? location.altitude : NSNull(),
            "altitudeAccuracy": location.verticalAccuracy >= 0 ? location.verticalAccuracy : NSNull(),
            "heading": location.course >= 0 ? location.course : NSNull(),
            "speed": location.speed >= 0 ? location.speed : NSNull(),
        ]
        return [
            "coords": coords,
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
    }

    // MARK: - Motion / CoreMotion

    private static func dispatchMotion(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        eventSender: EventSender?,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "addListener":
            guard requireScene(presenter, completion: completion) else { return }
            completion(motionState.addListener(call.options, eventSender: eventSender, ownerID: call.ownerID))
        case "removeListener":
            completion(motionState.removeListener(call.options))
        case "removeAllListeners":
            completion(motionState.removeAllListeners())
        case "start":
            guard requireScene(presenter, completion: completion) else { return }
            completion(motionState.start())
        case "stop":
            completion(motionState.stop())
        default:
            completion(.failure("UNSUPPORTED", "Motion.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private final class MotionState {
        private let lock = NSLock()
        private let manager = CMMotionManager()
        private var listeners: [String: MotionListener] = [:]
        private var started = false
        private var lastTimestamp: TimeInterval?

        private struct MotionListener { let eventName: String; let eventSender: EventSender?; let ownerID: String? }

        func addListener(_ options: [String: Any], eventSender: EventSender?, ownerID: String?) -> LynxNativeCapabilityResult {
            let eventName = stringValue(options["eventName"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard eventName == "accel" || eventName == "orientation" else {
                return .failure("UNSUPPORTED", "Motion.addListener 只支持 accel 或 orientation")
            }
            guard manager.isDeviceMotionAvailable else {
                return .failure("UNSUPPORTED", "当前设备不支持 CoreMotion device motion")
            }
            let listenerID = stringValue(options["listenerId"] ?? options["callbackId"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                ? "motion-\(UUID().uuidString)"
                : stringValue(options["listenerId"] ?? options["callbackId"])

            lock.lock()
            listeners[listenerID] = MotionListener(eventName: eventName, eventSender: eventSender, ownerID: ownerID)
            let needsStart = !started
            lock.unlock()
            if needsStart {
                let startedResult = start()
                if startedResult.error != nil {
                    lock.withLock { listeners.removeValue(forKey: listenerID) }
                    return startedResult
                }
            }
            return .success([
                "listenerId": listenerID,
                "eventName": eventName,
                "pending": true,
            ], save: true)
        }

        func removeListener(_ options: [String: Any]) -> LynxNativeCapabilityResult {
            let listenerID = stringValue(options["listenerId"] ?? options["callbackId"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !listenerID.isEmpty else {
                return .failure("INVALID_ARGUMENT", "Motion.removeListener 需要 listenerId")
            }
            let removed = lock.withLock { listeners.removeValue(forKey: listenerID) != nil }
            let count = lock.withLock { listeners.count }
            if count == 0 { stop() }
            return .success([
                "listenerId": listenerID,
                "removed": removed,
                "pending": false,
            ])
        }

        func removeAllListeners() -> LynxNativeCapabilityResult {
            let removed = lock.withLock { () -> Int in
                let count = listeners.count
                listeners.removeAll()
                return count
            }
            stop()
            return .success(["removed": removed, "pending": false])
        }

        func removeListeners(ownerID: String) {
            let shouldStop = lock.withLock { () -> Bool in
                listeners = listeners.filter { $0.value.ownerID != ownerID }
                return listeners.isEmpty
            }
            if shouldStop { stop() }
        }

        func start() -> LynxNativeCapabilityResult {
            guard manager.isDeviceMotionAvailable else {
                return .failure("UNSUPPORTED", "当前设备不支持 CoreMotion device motion")
            }
            let listenerCount = lock.withLock { listeners.count }
            guard listenerCount > 0 else {
                return .success(["started": false, "listenerCount": 0])
            }
            if lock.withLock({ started }) {
                return .success(["started": true, "listenerCount": listenerCount])
            }
            manager.deviceMotionUpdateInterval = 0.02
            manager.startDeviceMotionUpdates(to: OperationQueue.main) { [weak self] motion, error in
                guard let self else { return }
                if let error {
                    self.lock.withLock { self.started = false }
                    _ = error
                    return
                }
                guard let motion else { return }
                self.emit(motion)
            }
            lock.withLock {
                started = manager.isDeviceMotionActive
                if started { lastTimestamp = nil }
            }
            guard lock.withLock({ started }) else {
                return .failure("UNSUPPORTED", "无法启动 CoreMotion device motion")
            }
            return .success(["started": true, "listenerCount": listenerCount])
        }

        func stop() -> LynxNativeCapabilityResult {
            let listenerCount = lock.withLock { listeners.count }
            stop(clearListeners: false)
            return .success(["stopped": true, "listenerCount": listenerCount])
        }

        func stop(clearListeners: Bool) {
            manager.stopDeviceMotionUpdates()
            lock.withLock {
                started = false
                lastTimestamp = nil
                if clearListeners { listeners.removeAll() }
            }
        }

        private func emit(_ motion: CMDeviceMotion) {
            let snapshot: [(String, MotionListener)] = lock.withLock {
                guard started else { return [] }
                return listeners.map { ($0.key, $0.value) }
            }
            guard !snapshot.isEmpty else { return }
            let interval: Double = lock.withLock {
                let previous = lastTimestamp
                lastTimestamp = motion.timestamp
                guard let previous, motion.timestamp >= previous else { return 0 }
                return (motion.timestamp - previous) * 1000
            }
            snapshot.forEach { listenerID, listener in
                guard let sender = listener.eventSender else { return }
                let eventName = listener.eventName
                let data: [String: Any]
                if eventName == "accel" {
                    data = [
                        "acceleration": vector(
                            x: motion.userAcceleration.x,
                            y: motion.userAcceleration.y,
                            z: motion.userAcceleration.z
                        ),
                        "accelerationIncludingGravity": vector(
                            x: motion.userAcceleration.x + motion.gravity.x,
                            y: motion.userAcceleration.y + motion.gravity.y,
                            z: motion.userAcceleration.z + motion.gravity.z
                        ),
                        "rotationRate": NSNull(),
                        "interval": interval,
                    ]
                } else {
                    data = [
                        "rotationRate": [
                            "alpha": motion.rotationRate.x,
                            "beta": motion.rotationRate.y,
                            "gamma": motion.rotationRate.z,
                        ],
                        "interval": interval,
                    ]
                }
                let envelope: [String: Any] = [
                    "callbackId": listenerID,
                    "pluginId": "Motion",
                    "methodName": "addListener",
                    "eventName": eventName,
                    "listenerId": listenerID,
                    "success": true,
                    "data": data,
                    "save": true,
                    "pending": false,
                ]
                guard let raw = LynxNativeJSON.encode(envelope) else { return }
                dispatchOnMain { sender(raw) }
            }
        }
        private func vector(x: Double, y: Double, z: Double) -> [String: Any] {
            ["x": x, "y": y, "z": z]
        }
    }

    // MARK: - LocalNotifications / UserNotifications

    private static func dispatchLocalNotifications(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        eventSender: EventSender?,
        completion: @escaping Completion
    ) {
        configureNotificationDelegate(eventSender, ownerID: call.ownerID ?? call.callbackId)
        switch call.methodName {
        case "checkPermissions":
            getNotificationPermission(ownerID: call.ownerID, field: "display", completion: completion)
        case "requestPermissions":
            requestNotificationPermission(ownerID: call.ownerID, field: "display", presenter: presenter, completion: completion)
        case "schedule":
            scheduleLocalNotifications(call.options, ownerID: call.ownerID, completion: completion)
        case "getPending":
            getPendingLocalNotifications(ownerID: call.ownerID, completion: completion)
        case "cancel":
            cancelLocalNotifications(call.options, completion: completion)
        case "getDeliveredNotifications":
            getDeliveredLocalNotifications(ownerID: call.ownerID, completion: completion)
        case "createChannel", "listChannels":
            completion(.failure(
                "UNSUPPORTED",
                "iOS UserNotifications 没有 Android NotificationChannel；请使用 notification category",
                details: ["platform": "ios", "equivalent": "UNNotificationCategory"]
            ))
        default:
            completion(.failure("UNSUPPORTED", "LocalNotifications.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchPushNotifications(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "checkPermissions":
            getNotificationPermission(ownerID: call.ownerID, field: "receive", completion: completion)
        case "requestPermissions":
            requestNotificationPermission(ownerID: call.ownerID, field: "receive", presenter: presenter, completion: completion)
        case "register":
            registerForRemoteNotifications(presenter: presenter, completion: completion)
        default:
            completion(.failure("UNSUPPORTED", "PushNotifications.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func notificationPermissionState(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "prompt"
        case .denied:
            return "denied"
        case .authorized:
            return "granted"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private static func notificationPermissionData(
        _ settings: UNNotificationSettings,
        field: String
    ) -> [String: Any] {
        [
            field: notificationPermissionState(settings.authorizationStatus),
            "authorizationStatus": notificationPermissionState(settings.authorizationStatus),
            "alertsEnabled": settings.alertSetting == .enabled,
            "soundEnabled": settings.soundSetting == .enabled,
            "badgeEnabled": settings.badgeSetting == .enabled,
        ]
    }

    private static func getNotificationPermission(
        ownerID: String?,
        field: String,
        completion: @escaping Completion
    ) {
        let center = UNUserNotificationCenter.current()
        var requestID = ""
        requestID = makePending(
            ownerID: ownerID,
            timeout: 10,
            timeoutResult: { .failure("PERMISSION_STATUS_TIMEOUT", "通知权限状态查询超时") },
            cancelResource: {},
            completion: completion
        )
        center.getNotificationSettings { settings in
            finishPending(
                requestID,
                result: .success(notificationPermissionData(settings, field: field))
            )
        }
    }

    private static func requestNotificationPermission(
        ownerID: String?,
        field: String,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        guard requireScene(presenter, completion: completion) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            dispatchOnMain {
                guard settings.authorizationStatus == .notDetermined else {
                    completion(.success(notificationPermissionData(settings, field: field)))
                    return
                }
                let inProgress = pendingLock.withLock { notificationPermissionRequestID != nil }
                guard !inProgress else {
                    completion(.failure("PERMISSION_REQUEST_IN_PROGRESS", "当前 iOS Module 已有通知权限请求未完成"))
                    return
                }
                var requestID = ""
                requestID = makePending(
                    ownerID: ownerID,
                    timeout: 30,
                    timeoutResult: {
                        clearNotificationPermissionOwner(requestID)
                        return .failure("PERMISSION_REQUEST_TIMEOUT", "通知权限请求超时")
                    },
                    cancelResource: { clearNotificationPermissionOwner(requestID) },
                    completion: completion
                )
                pendingLock.withLock { notificationPermissionRequestID = requestID }
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                    if let error {
                        finishNotificationPermission(
                            requestID,
                            result: .failure(
                                "PERMISSION_REQUEST_FAILED",
                                error.localizedDescription,
                                details: ["domain": (error as NSError).domain, "code": (error as NSError).code]
                            )
                        )
                        return
                    }
                    center.getNotificationSettings { updated in
                        finishNotificationPermission(
                            requestID,
                            result: .success(notificationPermissionData(updated, field: field))
                        )
                    }
                }
            }
        }
    }

    private static func clearNotificationPermissionOwner(_ id: String) {
        pendingLock.withLock {
            if notificationPermissionRequestID == id { notificationPermissionRequestID = nil }
        }
    }

    private static func finishNotificationPermission(
        _ id: String,
        result: LynxNativeCapabilityResult
    ) {
        clearNotificationPermissionOwner(id)
        finishPending(id, result: result)
    }

    private static func scheduleLocalNotifications(
        _ options: [String: Any],
        ownerID: String?,
        completion: @escaping Completion
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let state = notificationPermissionState(settings.authorizationStatus)
            guard state == "granted" || state == "provisional" || state == "ephemeral" else {
                finishNotificationResult(
                    .failure(
                        "PERMISSION_DENIED",
                        "未授予本地通知权限",
                        details: notificationPermissionData(settings, field: "display")
                    ),
                    completion: completion
                )
                return
            }
            let built = buildNotificationRequests(options, ownerID: ownerID ?? "")
            switch built {
            case .failure(let result):
                finishNotificationResult(result, completion: completion)
            case .success(let value):
                let requestIDs = value.requests.map(\.identifier)
                var pendingID = ""
                let batch = NotificationBatch(
                    center: center,
                    requests: value.requests,
                    response: value.response,
                    finish: { result in finishPending(pendingID, result: result) }
                )
                pendingID = makePending(
                    ownerID: ownerID,
                    timeout: 30,
                    timeoutResult: { .failure("NOTIFICATION_REQUEST_TIMEOUT", "本地通知调度超时") },
                    cancelResource: {
                        center.removePendingNotificationRequests(withIdentifiers: requestIDs)
                        batch.cancel()
                    },
                    completion: completion
                )
                batch.start()
            }
        }
    }

    private static func finishNotificationResult(
        _ result: LynxNativeCapabilityResult,
        completion: @escaping Completion
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
        }
    }

    private struct BuiltNotificationRequests {
        let requests: [UNNotificationRequest]
        let response: [String: Any]
    }

    private enum NotificationBuildResult {
        case success(BuiltNotificationRequests)
        case failure(LynxNativeCapabilityResult)
    }

    private static func buildNotificationRequests(
        _ options: [String: Any],
        ownerID: String
    ) -> NotificationBuildResult {
        guard let rawNotifications = options["notifications"] as? [[String: Any]], !rawNotifications.isEmpty else {
            return .failure(LynxNativeCapabilityResult.failure("INVALID_ARGUMENT", "notifications 不能为空"))
        }
        var requests: [UNNotificationRequest] = []
        var responseNotifications: [[String: Any]] = []
        for (index, notification) in rawNotifications.enumerated() {
            guard let id = intValue(notification["id"]) else {
                return .failure(LynxNativeCapabilityResult.failure("INVALID_ARGUMENT", "notifications[\(index)].id 必须是整数"))
            }
            guard let schedule = notification["schedule"] as? [String: Any] else {
                return .failure(LynxNativeCapabilityResult.failure("INVALID_ARGUMENT", "notifications[\(index)].schedule.at/in 无法解析"))
            }
            let now = Date()
            let triggerDate: Date
            if let at = schedule["at"], let parsed = dateValue(at) {
                triggerDate = parsed
            } else if let interval = nonNegativeSeconds(schedule["in"]) {
                triggerDate = now.addingTimeInterval(interval)
            } else {
                return .failure(LynxNativeCapabilityResult.failure("INVALID_ARGUMENT", "notifications[\(index)].schedule.at/in 无法解析"))
            }
            guard triggerDate.timeIntervalSinceNow >= -1 else {
                return .failure(LynxNativeCapabilityResult.failure("INVALID_ARGUMENT", "notifications[\(index)] 的触发时间不能早于当前时间"))
            }
            let content = UNMutableNotificationContent()
            content.title = stringValue(notification["title"])
            content.body = stringValue(notification["body"] ?? notification["subtitle"])
            content.subtitle = stringValue(notification["subtitle"])
            if boolValue(notification["silent"], default: false) {
                content.sound = nil
            } else {
                content.sound = .default
            }
            if let badge = intValue(notification["badge"]), badge >= 0 {
                content.badge = NSNumber(value: badge)
            }
            content.userInfo = [
                localNotificationMarkerKey: localNotificationMarkerValue,
                localNotificationOwnerIDKey: ownerID,
                localNotificationIDKey: id,
                "_lynx_native_payload": notification,
            ]
            let interval = max(1, triggerDate.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let identifier = localNotificationIdentifierPrefix + String(id)
            requests.append(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            responseNotifications.append([
                "id": id,
                "triggerAt": triggerDate.timeIntervalSince1970 * 1000,
                "exact": false,
            ])
        }
        return .success(BuiltNotificationRequests(
            requests: requests,
            response: [
                "notifications": responseNotifications,
                "scheduledBy": "UserNotifications",
                "exactAlarm": false,
                "deliveryBoundary": "system_managed_best_effort",
            ]
        ))
    }

    private final class NotificationBatch {
        private let lock = NSLock()
        private let center: UNUserNotificationCenter
        private let requests: [UNNotificationRequest]
        private let response: [String: Any]
        private let finish: (LynxNativeCapabilityResult) -> Void
        private var remaining: Int
        private var firstError: NSError?
        private var finished = false

        init(
            center: UNUserNotificationCenter,
            requests: [UNNotificationRequest],
            response: [String: Any],
            finish: @escaping (LynxNativeCapabilityResult) -> Void
        ) {
            self.center = center
            self.requests = requests
            self.response = response
            self.finish = finish
            self.remaining = requests.count
        }

        func start() {
            requests.enumerated().forEach { index, request in
                center.add(request) { [weak self] error in
                    self?.complete(index: index, error: error as NSError?)
                }
            }
        }

        func cancel() {
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier))
        }

        private func complete(index: Int, error: NSError?) {
            _ = index
            let result: LynxNativeCapabilityResult? = lock.withLock {
                guard !finished else { return nil }
                if let error, firstError == nil { firstError = error }
                remaining -= 1
                guard remaining == 0 else { return nil }
                finished = true
                if let firstError {
                    return .failure(
                        "NOTIFICATION_SCHEDULING_FAILED",
                        firstError.localizedDescription,
                        details: ["domain": firstError.domain, "code": firstError.code]
                    )
                }
                return .success(response)
            }
            if let result { finish(result) }
        }
    }

    private static func getPendingLocalNotifications(ownerID: String?, completion: @escaping Completion) {
        let center = UNUserNotificationCenter.current()
        var requestID = ""
        requestID = makePending(
            ownerID: ownerID,
            timeout: 10,
            timeoutResult: { .failure("NOTIFICATION_QUERY_TIMEOUT", "本地通知 pending 查询超时") },
            cancelResource: {},
            completion: completion
        )
        center.getPendingNotificationRequests { requests in
            let notifications = requests
                .filter(isOwnedLocalNotification)
                .compactMap(notificationPayload)
            finishPending(requestID, result: .success(["notifications": notifications]))
        }
    }

    private static func getDeliveredLocalNotifications(ownerID: String?, completion: @escaping Completion) {
        let center = UNUserNotificationCenter.current()
        var requestID = ""
        requestID = makePending(
            ownerID: ownerID,
            timeout: 10,
            timeoutResult: { .failure("NOTIFICATION_QUERY_TIMEOUT", "本地通知 delivered 查询超时") },
            cancelResource: {},
            completion: completion
        )
        center.getDeliveredNotifications { notifications in
            let values = notifications
                .filter { isOwnedLocalNotification($0.request) }
                .compactMap { notificationPayload($0.request) }
            finishPending(requestID, result: .success(["notifications": values]))
        }
    }

    private static func cancelLocalNotifications(
        _ options: [String: Any],
        completion: @escaping Completion
    ) {
        guard let rawNotifications = options["notifications"] as? [[String: Any]], !rawNotifications.isEmpty else {
            completion(.failure("INVALID_ARGUMENT", "notifications 不能为空"))
            return
        }
        var ids: [Int] = []
        for (index, notification) in rawNotifications.enumerated() {
            guard let id = intValue(notification["id"]) else {
                completion(.failure("INVALID_ARGUMENT", "notifications[\(index)].id 必须是整数"))
                return
            }
            ids.append(id)
        }
        let identifiers = ids.map { localNotificationIdentifierPrefix + String($0) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        completion(.success(["notifications": ids]))
    }

    private static func isOwnedLocalNotification(_ request: UNNotificationRequest) -> Bool {
        guard let owner = request.content.userInfo[localNotificationMarkerKey] as? String else { return false }
        return owner == localNotificationMarkerValue
    }

    private static func notificationPayload(_ request: UNNotificationRequest) -> [String: Any]? {
        if let payload = request.content.userInfo["_lynx_native_payload"] as? [String: Any] {
            return payload
        }
        let identifier = request.content.userInfo[localNotificationIDKey] ?? request.identifier.replacingOccurrences(of: localNotificationIdentifierPrefix, with: "")
        guard let id = intValue(identifier) else { return nil }
        return [
            "id": id,
            "title": request.content.title,
            "body": request.content.body,
        ]
    }

    private static var notificationDelegate: NativeNotificationDelegate?

    private static func configureNotificationDelegate(_ sender: EventSender?, ownerID: String) {
        if let sender { notificationSenders[ownerID] = sender }
        let center = UNUserNotificationCenter.current()
        if let existing = notificationDelegate {
            if center.delegate == nil || center.delegate === existing {
                center.delegate = existing
            }
            return
        }
        guard center.delegate == nil else {
            // 宿主已有 delegate 时不覆盖它；宿主可把回调转发到 emitNotificationEvent。
            return
        }
        let delegate = NativeNotificationDelegate()
        notificationDelegate = delegate
        center.delegate = delegate
    }

    private final class NativeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            if isOwnedLocalNotification(notification.request) {
                emitNotificationEvent(
                    eventName: "localNotificationReceived",
                    data: notificationPayload(notification.request) ?? [:],
                    senders: sendersForNotification(notification.request)
                )
            }
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            if isOwnedLocalNotification(response.notification.request) {
                emitNotificationEvent(
                    eventName: "localNotificationActionPerformed",
                    data: [
                        "actionId": response.actionIdentifier,
                        "notification": notificationPayload(response.notification.request) ?? [:],
                    ],
                    senders: sendersForNotification(response.notification.request)
                )
            }
            completionHandler()
        }
    }

    private static func emitNotificationEvent(
        eventName: String,
        data: [String: Any],
        senders: [EventSender]
    ) {
        let envelope: [String: Any] = [
            "callbackId": "local-notification-\(UUID().uuidString)",
            "pluginId": "LocalNotifications",
            "methodName": "addListener",
            "eventName": eventName,
            "success": true,
            "data": data,
            "save": true,
        ]
        guard let raw = LynxNativeJSON.encode(envelope) else { return }
        dispatchOnMain { senders.forEach { $0(raw) } }
    }

    private static func sendersForNotification(_ request: UNNotificationRequest) -> [EventSender] {
        if let ownerID = request.content.userInfo[localNotificationOwnerIDKey] as? String,
           let sender = notificationSenders[ownerID] {
            return [sender]
        }
        return Array(notificationSenders.values)
    }

    // MARK: - Push / BackgroundRunner

    private static func dispatchBackgroundRunner(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        eventSender: EventSender?,
        completion: @escaping Completion
    ) {
        _ = presenter
        _ = eventSender
        switch call.methodName {
        case "checkPermissions", "requestPermissions":
            completion(.success([
                "background": "notRequired",
                "execution": "systemManaged",
            ]))
        case "dispatchEvent":
            completion(.failure(
                "UNSUPPORTED_BACKGROUND_RUNNER",
                "iOS BGTask 只能提交系统调度任务，不能提供 Android Runner 的即时 dispatchEvent",
                details: ["platform": "ios", "execution": "systemManaged"]
            ))
        default:
            completion(.failure("UNSUPPORTED", "BackgroundRunner.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func registerForRemoteNotifications(
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        _ = presenter
        completion(.failure(
            "UNSUPPORTED",
            "当前 iOS Module 未配置 APNs provider/entitlement，PushNotifications.register 尚未接入",
            details: ["providerConfigured": false]
        ))
    }

    // MARK: - Shared parsing / permission helpers

    private static func infoString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private static func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        switch stringValue(value).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return defaultValue
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let converted = number.doubleValue
            guard converted.isFinite, converted.rounded() == converted else { return nil }
            return Int(exactly: converted)
        }
        return Int(stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func doubleValue(_ value: Any?, default defaultValue: Double) -> Double {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        if let converted = Double(stringValue(value)), converted.isFinite { return converted }
        return defaultValue
    }

    private static func boundedTimeout(_ value: Any?, default defaultValue: TimeInterval) -> TimeInterval {
        min(max(doubleValue(value, default: defaultValue), 0.1), 120)
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        if let date = value as? Date { return date }
        if let number = value as? NSNumber { return dateFromEpoch(number.doubleValue) }
        let raw = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(raw) { return dateFromEpoch(number) }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func dateFromEpoch(_ value: Double) -> Date? {
        guard value.isFinite else { return nil }
        return Date(timeIntervalSince1970: abs(value) > 100_000_000_000 ? value / 1000 : value)
    }

    private static func nonNegativeSeconds(_ value: Any?) -> TimeInterval? {
        let seconds = doubleValue(value, default: -1)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] { return values.map(stringValue) }
        let single = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return single.isEmpty ? [] : [single]
    }

    private static func requestedPermissionNames(
        _ options: [String: Any],
        defaults: [String],
        accepted: [String]
    ) -> Set<String>? {
        let raw = options["permissions"] ?? options["permission"]
        let values = raw == nil ? defaults : stringArray(raw)
        let normalize: (String) -> String = {
            $0.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = Set(values.map(normalize).filter { !$0.isEmpty })
        guard !normalized.isEmpty else { return nil }
        return normalized.isSubset(of: Set(accepted.map(normalize))) ? normalized : nil
    }

    private static func calendarUsageDescriptionPresent(read: Bool, write: Bool) -> Bool {
        let legacy = infoString("NSCalendarsUsageDescription")?.isEmpty == false
        let readDescription = infoString("NSCalendarsFullAccessUsageDescription")?.isEmpty == false
        let writeDescription = infoString("NSCalendarsWriteOnlyAccessUsageDescription")?.isEmpty == false
        return (!read || legacy || readDescription) && (!write || legacy || writeDescription)
    }

    private static func locationUsageDescriptionPresent(always: Bool) -> Bool {
        let whenInUse = infoString("NSLocationWhenInUseUsageDescription")?.isEmpty == false
        let alwaysDescription = infoString("NSLocationAlwaysAndWhenInUseUsageDescription")?.isEmpty == false
        return whenInUse && (!always || alwaysDescription)
    }

    private static func locationAccuracyState(_ manager: CLLocationManager) -> String {
        if #available(iOS 14.0, *) {
            return manager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced"
        }
        return "full"
    }

    private static func compactDictionary(_ values: [String: Any?]) -> [String: Any] {
        values.reduce(into: [String: Any]()) { result, item in
            guard let value = item.value, !(value is NSNull) else { return }
            if let string = value as? String, string.isEmpty { return }
            result[item.key] = value
        }
    }

    private static func androidPhoneType(_ label: String?) -> String {
        switch (label ?? "").lowercased() {
        case CNLabelHome.lowercased(): return "home"
        case CNLabelWork.lowercased(): return "work"
        case CNLabelPhoneNumberiPhone.lowercased(): return "mobile"
        default: return "mobile"
        }
    }

    private static func androidEmailType(_ label: String?) -> String {
        switch (label ?? "").lowercased() {
        case CNLabelWork.lowercased(): return "work"
        case CNLabelHome.lowercased(): return "home"
        default: return "other"
        }
    }

    private static func parseUIColor(_ value: String) -> UIColor? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard raw.count == 6 || raw.count == 8, let number = UInt64(raw, radix: 16) else { return nil }
        let alpha: UInt64 = raw.count == 8 ? number >> 24 : 0xff
        let red: UInt64 = raw.count == 8 ? (number >> 16) & 0xff : number >> 16
        let green: UInt64 = (number >> 8) & 0xff
        let blue: UInt64 = number & 0xff
        return UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    private static func hexColor(_ color: CGColor?) -> String {
        guard let color else { return "" }
        let uiColor = UIColor(cgColor: color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "" }
        return String(format: "#%02X%02X%02X%02X", Int(alpha * 255), Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
