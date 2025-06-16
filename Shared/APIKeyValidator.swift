import Foundation
import Network
import CryptoKit // Added: For SHA256 hash calculation
import Security // Added: For Keychain service
import UIKit
import CoreTelephony
import SystemConfiguration

class APIKeyValidator {

    static let shared = APIKeyValidator() // Singleton pattern

    private init() {}

    // This is your secret phrase, keep it confidential!
    // In a real application, you might consider more complex obfuscation or loading from a secure configuration
    private let secretPhrase = "YourVerySecretLongAndRandomPhraseHereForLPhotoApp!" // <<--- [IMPORTANT] Replace with your own long and random string

    // Keychain service identifier
    private let keychainService = "com.sunfan.LPhoto.apiKeyBinding" // Replace with your own Bundle Identifier or unique service name
    private let keychainAccount = "apiKeyBoundIDFV"

    // UserDefaults key prefixes
    private let defaultsKeyPrefix = "key_binding_"
    private let defaultsTimePrefix = "key_binding_time_"
    private let defaultsDevicePrefix = "key_binding_device_"

    // Binding time validity period (24 hours)
    private let bindingTimeValidity: TimeInterval = 24 * 3600

    // Cache related constants
    private let cacheUpdateInterval: TimeInterval = 3600 // Update cache every hour
    private let networkTimeCacheKey = "network_time_cache"
    private let networkTimeCacheTimeKey = "network_time_cache_time"
    private let deviceBindingCacheKey = "device_binding_cache"
    private let deviceBindingCacheTimeKey = "device_binding_cache_time"

    // Cache network time
    private var cachedNetworkTime: Date?
    private var lastNetworkTimeUpdate: Date?

    // Cache device binding information
    private var cachedDeviceBinding: [String: (idfv: String?, timestamp: TimeInterval?, deviceIdentifier: String?)] = [:]
    private var lastDeviceBindingUpdate: Date?

    // Define expiry duration codes and corresponding date components
    enum ExpiryDuration: String, CaseIterable {
        case oneMonth = "M1"
        case sixMonths = "M6"
        case oneYear = "Y1"
        case twoYears = "Y2"
        case permanent = "PERM" // Permanent validity, special handling

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
                return nil // Permanent validity doesn't need date components
            }
            return components
        }

        var localizedDescription: String {
            switch self {
            case .oneMonth: return "1 month"
            case .sixMonths: return "6 months"
            case .oneYear: return "1 year"
            case .twoYears: return "2 years"
            case .permanent: return "Permanent"
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
                return "Invalid API key format. Please check if your key format is LPHOTO_KEY_YYYYMMDD_DURATIONCODE_YYYYMMDDHHMMSS_HASH."
            case .expired:
                return "API key has expired. Please contact the administrator for a new key."
            case .networkTimeUnavailable:
                return "Unable to get network time to verify the key. Please check your network connection or device time settings. LPhoto has expired."
            case .hashMismatch:
                return "API key verification failed: Hash mismatch. Please confirm the integrity and correctness of the key."
            case .unsupportedDuration:
                return "The API key contains an unsupported validity period code. Please contact the administrator."
            case .alreadyBoundToAnotherDevice:
                return "This API key is already bound to another device and cannot be used on this device."
            case .deviceMismatch:
                return "Device information mismatch, please ensure you are using the same device."
            case .bindingTimeExpired:
                return "Key binding time has expired, please verify again."
            }
        }
    }

    /// Get device identifier information (using secure APIs)
    private func getDeviceIdentifier() -> String {
        // 只用 identifierForVendor 作为唯一标识
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            return idfv
        } else {
            // 兜底方案：用 model + systemVersion
            let device = UIDevice.current
            let identifierString = device.model + "|" + device.systemVersion
            let identifierData = identifierString.data(using: .utf8)!
            let hash = SHA256.hash(data: identifierData)
            return hash.compactMap { String(format: "%02x", $0) }.joined()
        }
    }

    /// Save binding information to UserDefaults
    private func saveToUserDefaults(key: String, idfv: String, deviceIdentifier: String) {
        let defaults = UserDefaults.standard
        let timestamp = Date().timeIntervalSince1970
        
        defaults.set(idfv, forKey: "\(defaultsKeyPrefix)\(key)")
        defaults.set(timestamp, forKey: "\(defaultsTimePrefix)\(key)")
        defaults.set(deviceIdentifier, forKey: "\(defaultsDevicePrefix)\(key)")
    }

    /// Load binding information from UserDefaults
    private func loadFromUserDefaults(key: String) -> (idfv: String?, timestamp: TimeInterval?, deviceIdentifier: String?) {
        let defaults = UserDefaults.standard
        
        let idfv = defaults.string(forKey: "\(defaultsKeyPrefix)\(key)")
        let timestamp = defaults.object(forKey: "\(defaultsTimePrefix)\(key)") as? TimeInterval
        let deviceIdentifier = defaults.string(forKey: "\(defaultsDevicePrefix)\(key)")
        
        return (idfv, timestamp, deviceIdentifier)
    }

    /// Get cached network time, if cache expires then fetch again
    private func getCachedNetworkTime() async throws -> Date {
        let defaults = UserDefaults.standard
        let currentTime = Date()
        
        // Check memory cache
        if let cachedTime = cachedNetworkTime,
           let lastUpdate = lastNetworkTimeUpdate,
           currentTime.timeIntervalSince(lastUpdate) < cacheUpdateInterval {
            return cachedTime
        }
        
        // Check persistent cache
        if let cachedTimeData = defaults.object(forKey: networkTimeCacheKey) as? Data,
           let lastUpdateData = defaults.object(forKey: networkTimeCacheTimeKey) as? Date,
           currentTime.timeIntervalSince(lastUpdateData) < cacheUpdateInterval {
            
            let allowedClasses = NSSet(array: [NSDate.self as AnyClass])
            if let cachedNSDate = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses as! Set<AnyHashable>, from: cachedTimeData) as? Date {
                // Update memory cache
                cachedNetworkTime = cachedNSDate
                lastNetworkTimeUpdate = lastUpdateData
                return cachedNSDate
            }
        }
        
        // Cache expired or doesn't exist, fetch network time again
        let networkTime = try await fetchNetworkTime()
        
        // Update memory cache
        cachedNetworkTime = networkTime
        lastNetworkTimeUpdate = currentTime
        
        // Update persistent cache
        if let cachedTimeData = try? NSKeyedArchiver.archivedData(withRootObject: networkTime as NSDate, requiringSecureCoding: true) {
            defaults.set(cachedTimeData, forKey: networkTimeCacheKey)
            defaults.set(currentTime, forKey: networkTimeCacheTimeKey)
        }
        
        return networkTime
    }

    /// Get cached device binding information, if cache expires then fetch again
    private func getCachedDeviceBinding(for key: String) -> (idfv: String?, timestamp: TimeInterval?, deviceIdentifier: String?) {
        let defaults = UserDefaults.standard
        let currentTime = Date()
        
        // Check memory cache
        if let cachedBinding = cachedDeviceBinding[key],
           let lastUpdate = lastDeviceBindingUpdate,
           currentTime.timeIntervalSince(lastUpdate) < cacheUpdateInterval {
            return cachedBinding
        }
        
        // Check persistent cache
        if let cachedBindingData = defaults.object(forKey: "\(deviceBindingCacheKey)_\(key)") as? Data,
           let lastUpdateData = defaults.object(forKey: deviceBindingCacheTimeKey) as? Date,
           currentTime.timeIntervalSince(lastUpdateData) < cacheUpdateInterval {
            
            let allowedClasses = NSSet(array: [NSDictionary.self as AnyClass, NSString.self as AnyClass, NSNumber.self as AnyClass])
            if let cachedBindingDict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses as! Set<AnyHashable>, from: cachedBindingData) as? [String: Any] {
                // Update memory cache
                let binding = (
                    idfv: cachedBindingDict["idfv"] as? String,
                    timestamp: cachedBindingDict["timestamp"] as? TimeInterval,
                    deviceIdentifier: cachedBindingDict["deviceIdentifier"] as? String
                )
                cachedDeviceBinding[key] = binding
                lastDeviceBindingUpdate = lastUpdateData
                return binding
            }
        }
        
        // Cache expired or doesn't exist, get from UserDefaults
        let binding = loadFromUserDefaults(key: key)
        
        // Update memory cache
        cachedDeviceBinding[key] = binding
        lastDeviceBindingUpdate = currentTime
        
        // Update persistent cache
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

    /// Validate the API key.
    /// Key format should be "LPHOTO_KEY_YYYYMMDD_DURATIONCODE_YYYYMMDDHHMMSS_HASH", where YYYYMMDD is the expiry date, DURATIONCODE is the validity period code, YYYYMMDDHHMMSS is the generation time, and HASH is the SHA256 hash of (YYYYMMDD + DURATIONCODE + YYYYMMDDHHMMSS + secret phrase).
    /// currentIDFV: The current device's IDFV.
    func validateKey(_ key: String?, currentIDFV: String) async throws {
        print("APIKeyValidator: Starting validateKey for key: \(key ?? "nil")")
        print("APIKeyValidator: Current IDFV: \(currentIDFV)")
        
        // Test key bypass removed for security reasons
        // No special keys allowed
        
        guard var key = key, !key.isEmpty else {
            throw APIKeyError.invalidFormat
        }

        // Trim leading/trailing whitespaces and newlines to prevent format errors
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        print("APIKeyValidator: Trimmed key for validation: \(key)")

        // Get current device identifier
        let currentDeviceIdentifier = getDeviceIdentifier()
        print("APIKeyValidator: Current Device Identifier Hash (from validateKey): \(currentDeviceIdentifier)")

        // Use cached device binding information
        let binding = getCachedDeviceBinding(for: key)
        
        if let boundIDFV = binding.idfv {
            print("APIKeyValidator: Key '\(key)' is already bound. Stored IDFV: \(boundIDFV)")
            if boundIDFV != currentIDFV {
                print("APIKeyValidator: Key '\(key)' is already bound to another device (IDFV: \(boundIDFV)). Current device IDFV: \(currentIDFV).")
                throw APIKeyError.alreadyBoundToAnotherDevice
            }
            
            if let bindingTime = binding.timestamp,
               let storedDeviceIdentifier = binding.deviceIdentifier {
                print("APIKeyValidator: Stored Binding Time: \(bindingTime), Stored Device Identifier: \(storedDeviceIdentifier)")
                // Check if binding time is within validity period
                let currentTime = Date().timeIntervalSince1970
                if currentTime - bindingTime > bindingTimeValidity {
                    print("APIKeyValidator: Binding time expired for key '\(key)'")
                    throw APIKeyError.bindingTimeExpired
                }
                
                // Check device identifier
                if storedDeviceIdentifier != currentDeviceIdentifier {
                    print("APIKeyValidator: Device identifier mismatch for key '\(key)'")
                    throw APIKeyError.deviceMismatch
                }
            }
        } else {
            print("APIKeyValidator: Key '\(key)' is not yet bound. Proceeding with new binding.")
            // If not bound, perform new binding
            if saveBoundIDFV(key: key, idfv: currentIDFV) {
                // Save to both UserDefaults and cache
                saveToUserDefaults(key: key, idfv: currentIDFV, deviceIdentifier: currentDeviceIdentifier)
                let binding = (idfv: currentIDFV, timestamp: Date().timeIntervalSince1970, deviceIdentifier: currentDeviceIdentifier)
                cachedDeviceBinding[key] = binding
                lastDeviceBindingUpdate = Date()
                print("APIKeyValidator: Key '\(key)' successfully bound to this device (IDFV: \(currentIDFV)).")
            }
        }

        let components = key.split(separator: "_")
        // Now expecting 6 parts: LPHOTO, KEY, YYYYMMDD, DURATIONCODE, YYYYMMDDHHMMSS, HASH
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
        let timestampString = String(components[4]) // Added: Timestamp string
        let providedHash = String(components[5]) // HASH part

        // --- DEBUG PRINTS START ---
        print("APIKeyValidator: Key components extracted:")
        print("APIKeyValidator:   Expiry Date String: \(expiryDateString)")
        print("APIKeyValidator:   Duration Code String: \(durationCodeString)")
        print("APIKeyValidator:   Timestamp String: \(timestampString)")
        print("APIKeyValidator:   Provided Hash: \(providedHash)")
        // --- DEBUG PRINTS END ---

        // Verify hash: Now hash is based on expiryDateString + durationCodeString + timestampString + secretPhrase combination
        let hashSourceString = expiryDateString + durationCodeString + timestampString + secretPhrase
        // --- DEBUG PRINTS START ---
        print("APIKeyValidator: Hash Source String (for expectedHash): \(hashSourceString)")
        // --- DEBUG PRINTS END ---
        let expectedHash = SHA256.hash(data: hashSourceString.data(using: .utf8)!).compactMap { String(format: "%02x", $0) }.joined()
        
        guard expectedHash == providedHash else {
            print("APIKeyValidator: Hash mismatch. Provided: \(providedHash), Expected: \(expectedHash)")
            throw APIKeyError.hashMismatch
        }

        // Parse expiry date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0) // Use GMT time to avoid timezone issues
        guard let expiryDate = dateFormatter.date(from: expiryDateString) else {
            throw APIKeyError.invalidFormat // If the date string itself is invalid
        }

        // Use cached network time
        let currentTime = try await getCachedNetworkTime()
        
        // Compare dates, and handle permanent validity case
        if durationCodeString == ExpiryDuration.permanent.rawValue { // Direct string comparison
            print("APIKeyValidator: Key is permanent. Expiration: \(expiryDateString) (from key data). (Timestamp: \(timestampString))")
            return // Permanent validity, return success directly
        }

        // Check if key is expired (based on actual date)
        if currentTime > expiryDate {
            print("APIKeyValidator: Key expired. Current time: \(currentTime), Key Expiry Date: \(expiryDate) (from key data). (Timestamp: \(timestampString))")
            throw APIKeyError.expired
        } else {
            print("APIKeyValidator: Key is valid. Current time: \(currentTime), Key Expiry Date: \(expiryDate) (from key data). Duration code: \(ExpiryDuration(rawValue: durationCodeString)?.localizedDescription ?? durationCodeString). (Timestamp: \(timestampString))")
            // Optionally calculate and print remaining validity period if expiryDate > currentTime
            let remainingComponents = Calendar.current.dateComponents([.year, .month, .day, .hour], from: currentTime, to: expiryDate)
            var remainingString = "Remaining validity: "
            if let years = remainingComponents.year, years > 0 { remainingString += "\(years) years" }
            if let months = remainingComponents.month, months > 0 { remainingString += "\(months) months" }
            if let days = remainingComponents.day, days > 0 { remainingString += "\(days) days" }
            if let hours = remainingComponents.hour, hours > 0 { remainingString += "\(hours) hours" }
            if remainingString == "Remaining validity: " { remainingString += "Less than 1 hour" }
            print(remainingString)
        }
    }

    /// Load the IDFV bound to the specified key from Keychain.
    private func loadBoundIDFV(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(keychainAccount)-\(key)", // Use key as part of account, implement one-key-one-binding
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        } else if status == errSecItemNotFound {
            return nil // Binding not found
        } else {
            print("APIKeyValidator: Keychain load error: \(status)")
            return nil
        }
    }

    /// Bind the key with IDFV and save to Keychain.
    @discardableResult
    private func saveBoundIDFV(key: String, idfv: String) -> Bool {
        // First try to delete old binding to ensure only the latest is kept
        deleteBoundIDFV(for: key)

        guard let idfvData = idfv.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(keychainAccount)-\(key)",
            kSecValueData as String: idfvData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock // Accessible after first unlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("APIKeyValidator: Keychain save error: \(status)")
            return false
        }
        return true
    }

    /// Delete the binding for the specified key from Keychain.
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

    /// Fetch current time from network.
    private func fetchNetworkTime() async throws -> Date {
        // List of time servers available in China
        let timeServers = [
            "https://www.baidu.com",
            "https://www.aliyun.com",
            "https://www.qq.com",
        ]
        
        // Configure request timeout
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5.0  // 5 second timeout
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
                continue // Try next server
            }
        }
        
        // If all servers fail, use local time as fallback
        print("APIKeyValidator: All time servers failed, using local time as fallback")
        return Date()
    }

    /// Helper function for generating SHA256 hash (now based on expiryDateString + durationCodeString + timestampString + secretPhrase)
    func generateSHA256(for expiryDateString: String, durationCodeString: String, timestampString: String) -> String {
        let combinedString = expiryDateString + durationCodeString + timestampString + secretPhrase
        let data = combinedString.data(using: .utf8)! // Ensure string is valid UTF8
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
} 
