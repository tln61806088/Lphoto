import Foundation
import Network
import CryptoKit // 新增：用于SHA256哈希计算
import Security // 新增：用于Keychain服务
import UIKit
import CoreTelephony
import SystemConfiguration

class APIKeyValidator {

    static let shared = APIKeyValidator() // 单例模式

    private init() {}

    // 这是您的秘密短语，务必保密！
    // 实际应用中，您可以考虑更复杂的混淆或从安全配置中加载
    private let secretPhrase = "YourVerySecretLongAndRandomPhraseHereForLPhotoApp!" // <<--- 【重要】请替换成您自己的长且随机的字符串

    // Keychain 服务标识符
    private let keychainService = "com.yourcompany.LPhoto.apiKeyBinding" // 请替换成您自己的Bundle Identifier或独特的服务名
    private let keychainAccount = "apiKeyBoundIDFV"

    // UserDefaults 键前缀
    private let defaultsKeyPrefix = "key_binding_"
    private let defaultsTimePrefix = "key_binding_time_"
    private let defaultsDevicePrefix = "key_binding_device_"

    // 绑定时间有效期（24小时）
    private let bindingTimeValidity: TimeInterval = 24 * 3600

    // 缓存相关常量
    private let cacheUpdateInterval: TimeInterval = 3600 // 1小时更新一次缓存
    private let networkTimeCacheKey = "network_time_cache"
    private let networkTimeCacheTimeKey = "network_time_cache_time"
    private let deviceBindingCacheKey = "device_binding_cache"
    private let deviceBindingCacheTimeKey = "device_binding_cache_time"

    // 缓存网络时间
    private var cachedNetworkTime: Date?
    private var lastNetworkTimeUpdate: Date?

    // 缓存设备绑定信息
    private var cachedDeviceBinding: [String: (idfv: String?, timestamp: TimeInterval?, deviceIdentifier: String?)] = [:]
    private var lastDeviceBindingUpdate: Date?

    // 定义有效期的代码和对应的日期组件
    enum ExpiryDuration: String, CaseIterable {
        case oneMonth = "M1"
        case sixMonths = "M6"
        case oneYear = "Y1"
        case twoYears = "Y2"
        case permanent = "PERM" // 永久有效，特殊处理

        func dateComponents() -> DateComponents? {
            var components = DateComponents()
            switch self {
            case .oneMonth:
                components.month = 1
            case .sixMonths:
                components.month = 6
            case .oneYear:
                components.year = 1
            case .twoYears:
                components.year = 2
            case .permanent:
                return nil // 永久有效不需要日期组件
            }
            return components
        }

        var localizedDescription: String {
            switch self {
            case .oneMonth: return "1个月"
            case .sixMonths: return "6个月"
            case .oneYear: return "1年"
            case .twoYears: return "2年"
            case .permanent: return "永久"
            }
        }
    }

    enum APIKeyError: Error, LocalizedError {
        case invalidFormat
        case expired
        case networkTimeUnavailable
        case hashMismatch
        case unsupportedDuration
        case alreadyBoundToAnotherDevice
        case deviceMismatch
        case bindingTimeExpired

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "API 密钥格式无效。请检查您的密钥格式是否为LPHOTO_KEY_YYYYMMDD_DURATIONCODE_YYYYMMDDHHMMSS_HASH。"
            case .expired:
                return "API 密钥已过期。请联系管理员获取新密钥。"
            case .networkTimeUnavailable:
                return "无法获取网络时间以验证密钥。请检查您的网络连接或设备时间设置。LPhoto已过期。"
            case .hashMismatch:
                return "API 密钥验证失败：哈希值不匹配。请确认密钥的完整性和正确性。"
            case .unsupportedDuration:
                return "API 密钥中包含不支持的有效期设置代码。请联系管理员。"
            case .alreadyBoundToAnotherDevice:
                return "此 API 密钥已绑定到另一台设备，无法在此设备上使用。"
            case .deviceMismatch:
                return "设备信息不匹配，请确保使用相同的设备。"
            case .bindingTimeExpired:
                return "密钥绑定时间已过期，请重新验证。"
            }
        }
    }

    /// 获取设备标识信息（使用安全的 API）
    private func getDeviceIdentifier() -> String {
        var identifierComponents: [String] = []
        
        // 设备型号（安全 API）
        let device = UIDevice.current
        identifierComponents.append(device.model)
        
        // 系统版本（安全 API）
        identifierComponents.append(device.systemVersion)
        
        // 设备名称（安全 API）
        identifierComponents.append(device.name)
        
        // 设备方向（安全 API）
        identifierComponents.append(String(device.orientation.rawValue))
        
        // 计算标识符哈希
        let identifierString = identifierComponents.joined(separator: "|")
        let identifierData = identifierString.data(using: .utf8)!
        let hash = SHA256.hash(data: identifierData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// 保存绑定信息到 UserDefaults
    private func saveToUserDefaults(key: String, idfv: String, deviceIdentifier: String) {
        let defaults = UserDefaults.standard
        let timestamp = Date().timeIntervalSince1970
        
        defaults.set(idfv, forKey: "\(defaultsKeyPrefix)\(key)")
        defaults.set(timestamp, forKey: "\(defaultsTimePrefix)\(key)")
        defaults.set(deviceIdentifier, forKey: "\(defaultsDevicePrefix)\(key)")
    }

    /// 从 UserDefaults 加载绑定信息
    private func loadFromUserDefaults(key: String) -> (idfv: String?, timestamp: TimeInterval?, deviceIdentifier: String?) {
        let defaults = UserDefaults.standard
        
        let idfv = defaults.string(forKey: "\(defaultsKeyPrefix)\(key)")
        let timestamp = defaults.object(forKey: "\(defaultsTimePrefix)\(key)") as? TimeInterval
        let deviceIdentifier = defaults.string(forKey: "\(defaultsDevicePrefix)\(key)")
        
        return (idfv, timestamp, deviceIdentifier)
    }

    /// 获取缓存的网络时间，如果缓存过期则重新获取
    private func getCachedNetworkTime() async throws -> Date {
        let defaults = UserDefaults.standard
        let currentTime = Date()
        
        // 检查内存缓存
        if let cachedTime = cachedNetworkTime,
           let lastUpdate = lastNetworkTimeUpdate,
           currentTime.timeIntervalSince(lastUpdate) < cacheUpdateInterval {
            return cachedTime
        }
        
        // 检查持久化缓存
        if let cachedTimeData = defaults.object(forKey: networkTimeCacheKey) as? Data,
           let lastUpdateData = defaults.object(forKey: networkTimeCacheTimeKey) as? Date,
           currentTime.timeIntervalSince(lastUpdateData) < cacheUpdateInterval,
           let cachedNSDate = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSDate.self, from: cachedTimeData) as? Date {
            // 更新内存缓存
            cachedNetworkTime = cachedNSDate
            lastNetworkTimeUpdate = lastUpdateData
            return cachedNSDate
        }
        
        // 缓存过期或不存在，重新获取网络时间
        let networkTime = try await fetchNetworkTime()
        
        // 更新内存缓存
        cachedNetworkTime = networkTime
        lastNetworkTimeUpdate = currentTime
        
        // 更新持久化缓存
        if let cachedTimeData = try? NSKeyedArchiver.archivedData(withRootObject: networkTime as NSDate, requiringSecureCoding: true) {
            defaults.set(cachedTimeData, forKey: networkTimeCacheKey)
            defaults.set(currentTime, forKey: networkTimeCacheTimeKey)
        }
        
        return networkTime
    }

    /// 获取缓存的设备绑定信息，如果缓存过期则重新获取
    private func getCachedDeviceBinding(for key: String) -> (idfv: String?, timestamp: TimeInterval?, deviceIdentifier: String?) {
        let defaults = UserDefaults.standard
        let currentTime = Date()
        
        // 检查内存缓存
        if let cachedBinding = cachedDeviceBinding[key],
           let lastUpdate = lastDeviceBindingUpdate,
           currentTime.timeIntervalSince(lastUpdate) < cacheUpdateInterval {
            return cachedBinding
        }
        
        // 检查持久化缓存
        if let cachedBindingData = defaults.object(forKey: "\(deviceBindingCacheKey)_\(key)") as? Data,
           let lastUpdateData = defaults.object(forKey: deviceBindingCacheTimeKey) as? Date,
           currentTime.timeIntervalSince(lastUpdateData) < cacheUpdateInterval,
           let cachedBindingDict = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSDictionary.self, from: cachedBindingData) as? [String: Any] {
            // 更新内存缓存
            let binding = (
                idfv: cachedBindingDict["idfv"] as? String,
                timestamp: cachedBindingDict["timestamp"] as? TimeInterval,
                deviceIdentifier: cachedBindingDict["deviceIdentifier"] as? String
            )
            cachedDeviceBinding[key] = binding
            lastDeviceBindingUpdate = lastUpdateData
            return binding
        }
        
        // 缓存过期或不存在，从 UserDefaults 获取
        let binding = loadFromUserDefaults(key: key)
        
        // 更新内存缓存
        cachedDeviceBinding[key] = binding
        lastDeviceBindingUpdate = currentTime
        
        // 更新持久化缓存
        let bindingDict: [String: Any] = [
            "idfv": binding.idfv as Any,
            "timestamp": binding.timestamp as Any,
            "deviceIdentifier": binding.deviceIdentifier as Any
        ]
        if let bindingData = try? NSKeyedArchiver.archivedData(withRootObject: bindingDict as NSDictionary, requiringSecureCoding: true) {
            defaults.set(bindingData, forKey: "\(deviceBindingCacheKey)_\(key)")
            defaults.set(currentTime, forKey: deviceBindingCacheTimeKey)
        }
        
        return binding
    }

    /// 验证 API 密钥的有效性。
    /// 密钥格式应为 "LPHOTO_KEY_YYYYMMDD_DURATIONCODE_YYYYMMDDHHMMSS_HASH"，其中 YYYYMMDD 是过期日期，DURATIONCODE 是有效期代码，YYYYMMDDHHMMSS 是生成时间，HASH 是 (YYYYMMDD + DURATIONCODE + YYYYMMDDHHMMSS + 秘密短语) 的 SHA256 哈希值。
    /// currentIDFV: 当前设备的 IDFV。
    func validateKey(_ key: String?, currentIDFV: String) async throws {
        guard let key = key, !key.isEmpty else {
            throw APIKeyError.invalidFormat
        }

        // 获取当前设备标识
        let currentDeviceIdentifier = getDeviceIdentifier()

        // 使用缓存的设备绑定信息
        let binding = getCachedDeviceBinding(for: key)
        
        if let boundIDFV = binding.idfv {
            if boundIDFV != currentIDFV {
                print("APIKeyValidator: Key '\(key)' is already bound to another device (IDFV: \(boundIDFV)). Current device IDFV: \(currentIDFV).")
                throw APIKeyError.alreadyBoundToAnotherDevice
            }
            
            if let bindingTime = binding.timestamp,
               let storedDeviceIdentifier = binding.deviceIdentifier {
                // 检查绑定时间是否在有效期内
                let currentTime = Date().timeIntervalSince1970
                if currentTime - bindingTime > bindingTimeValidity {
                    print("APIKeyValidator: Binding time expired for key '\(key)'")
                    throw APIKeyError.bindingTimeExpired
                }
                
                // 检查设备标识
                if storedDeviceIdentifier != currentDeviceIdentifier {
                    print("APIKeyValidator: Device identifier mismatch for key '\(key)'")
                    throw APIKeyError.deviceMismatch
                }
            }
        } else {
            // 如果都没有绑定，则进行新的绑定
            if saveBoundIDFV(key: key, idfv: currentIDFV) {
                // 同时保存到 UserDefaults 和缓存
                saveToUserDefaults(key: key, idfv: currentIDFV, deviceIdentifier: currentDeviceIdentifier)
                let binding = (idfv: currentIDFV, timestamp: Date().timeIntervalSince1970, deviceIdentifier: currentDeviceIdentifier)
                cachedDeviceBinding[key] = binding
                lastDeviceBindingUpdate = Date()
                print("APIKeyValidator: Key '\(key)' successfully bound to this device (IDFV: \(currentIDFV)).")
            }
        }

        let components = key.split(separator: "_")
        // 现在期望6个部分: LPHOTO, KEY, YYYYMMDD, DURATIONCODE, YYYYMMDDHHMMSS, HASH
        guard components.count == 6,
              components[0] == "LPHOTO",
              components[1] == "KEY",
              components[2].count == 8, // YYYYMMDD part
              let _ = ExpiryDuration(rawValue: String(components[3])), // DURATIONCODE part
              components[4].count == 14 else { // YYYYMMDDHHMMSS part
            throw APIKeyError.invalidFormat
        }

        let expiryDateString = String(components[2])
        let durationCodeString = String(components[3])
        let timestampString = String(components[4]) // 新增：时间戳字符串
        let providedHash = String(components[5]) // HASH part

        // 验证哈希值：现在哈希是基于 expiryDateString + durationCodeString + timestampString + secretPhrase 的组合
        let hashSourceString = expiryDateString + durationCodeString + timestampString + secretPhrase
        let expectedHash = SHA256.hash(data: hashSourceString.data(using: .utf8)!).compactMap { String(format: "%02x", $0) }.joined()
        
        guard expectedHash == providedHash else {
            print("APIKeyValidator: Hash mismatch. Provided: \(providedHash), Expected: \(expectedHash)")
            throw APIKeyError.hashMismatch
        }

        // 解析过期日期
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0) // 使用 GMT 时间以避免时区问题
        guard let expiryDate = dateFormatter.date(from: expiryDateString) else {
            throw APIKeyError.invalidFormat // 如果日期字符串本身无效
        }

        // 使用缓存的网络时间
        let currentTime = try await getCachedNetworkTime()
        
        // 比较日期，并额外处理永久有效的情况
        if durationCodeString == ExpiryDuration.permanent.rawValue { // 直接比较字符串
            print("APIKeyValidator: Key is permanent. Expiration: \(expiryDateString) (from key data). (Timestamp: \(timestampString))")
            return // 永久有效，直接返回成功
        }

        // 密钥是否过期判断（基于实际日期）
        if currentTime > expiryDate {
            print("APIKeyValidator: Key expired. Current time: \(currentTime), Key Expiry Date: \(expiryDate) (from key data). (Timestamp: \(timestampString))")
            throw APIKeyError.expired
        } else {
            print("APIKeyValidator: Key is valid. Current time: \(currentTime), Key Expiry Date: \(expiryDate) (from key data). Duration code: \(ExpiryDuration(rawValue: durationCodeString)?.localizedDescription ?? durationCodeString). (Timestamp: \(timestampString))")
            // 可以选择在这里计算并打印剩余有效期，如果 expiryDate > currentTime
            let remainingComponents = Calendar.current.dateComponents([.year, .month, .day, .hour], from: currentTime, to: expiryDate)
            var remainingString = "剩余有效期: "
            if let years = remainingComponents.year, years > 0 { remainingString += "\(years)年" }
            if let months = remainingComponents.month, months > 0 { remainingString += "\(months)个月" }
            if let days = remainingComponents.day, days > 0 { remainingString += "\(days)天" }
            if let hours = remainingComponents.hour, hours > 0 { remainingString += "\(hours)小时" }
            if remainingString == "剩余有效期: " { remainingString += "不足1小时" }
            print(remainingString)
        }
    }

    /// 从 Keychain 中加载指定密钥绑定的 IDFV。
    private func loadBoundIDFV(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(keychainAccount)-\(key)", // 使用密钥作为账户的一部分，实现一键一绑定
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        } else if status == errSecItemNotFound {
            return nil // 未找到绑定
        } else {
            print("APIKeyValidator: Keychain load error: \(status)")
            return nil
        }
    }

    /// 将密钥与 IDFV 绑定并保存到 Keychain 中。
    @discardableResult
    private func saveBoundIDFV(key: String, idfv: String) -> Bool {
        // 先尝试删除旧的绑定，确保只保留最新的
        deleteBoundIDFV(for: key)

        guard let idfvData = idfv.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(keychainAccount)-\(key)",
            kSecValueData as String: idfvData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock // 解锁后即可访问
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("APIKeyValidator: Keychain save error: \(status)")
            return false
        }
        return true
    }

    /// 从 Keychain 中删除指定密钥的绑定。
    @discardableResult
    private func deleteBoundIDFV(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(keychainAccount)-\(key)"
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("APIKeyValidator: Keychain delete error: \(status)")
            return false
        }
        return true
    }

    /// 从网络获取当前时间。
    private func fetchNetworkTime() async throws -> Date {
        // 国内可用的时间服务器列表
        let timeServers = [
            "https://ntp.aliyun.com",
            "https://ntp.tencent.com",
            "https://ntp.baidu.com",
            "http://www.beijing-time.org"
        ]
        
        // 配置请求超时
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5.0  // 5秒超时
        let session = URLSession(configuration: configuration)
        
        for server in timeServers {
            do {
                guard let url = URL(string: server) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                
                let (_, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse,
                   let dateString = httpResponse.allHeaderFields["Date"] as? String {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                    
                    if let networkDate = dateFormatter.date(from: dateString) {
                        print("APIKeyValidator: Successfully fetched network time from \(server)")
                        return networkDate
                    }
                }
            } catch {
                print("APIKeyValidator: Failed to fetch time from \(server): \(error.localizedDescription)")
                continue // 尝试下一个服务器
            }
        }
        
        // 如果所有服务器都失败，使用本地时间作为备用
        print("APIKeyValidator: All time servers failed, using local time as fallback")
        return Date()
    }

    /// 用于生成 SHA256 哈希值的辅助函数 (现在基于 expiryDateString + durationCodeString + timestampString + secretPhrase)
    func generateSHA256(for expiryDateString: String, durationCodeString: String, timestampString: String) -> String {
        let combinedString = expiryDateString + durationCodeString + timestampString + secretPhrase
        let data = combinedString.data(using: .utf8)! // 确保字符串是有效的 UTF8
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
} 