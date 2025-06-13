import Foundation
import AppIntents
import AVFoundation
import Photos
import UIKit

struct ConvertToHEIFIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert to HEIF"
    static var description: LocalizedStringResource = "This app has no user interface. It provides an effective action that converts short videos to Live Photos."
    
    @Parameter(title: "Input File", description: "Select a video file or pass a media variable from Shortcuts.", default: nil)
    var inputFile: IntentFile?
    
    @Parameter(title: "API Key", description: "Key for application verification.", default: nil)
    var apiKey: String?
    
    func perform() async throws -> some IntentResult {
        print("ConvertToHEIFIntent: perform() called")

        // === API Key Validation ===
        do {
            guard let currentIDFV = await UIDevice.current.identifierForVendor?.uuidString else {
                throw NSError(domain: "APIKeyValidation", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unable to get device identifier (IDFV)."])
            }
            try await APIKeyValidator.shared.validateKey(apiKey, currentIDFV: currentIDFV)
        } catch let error as APIKeyValidator.APIKeyError {
            // Throw localized error based on APIKeyError type
            switch error {
            case .alreadyBoundToAnotherDevice:
                throw NSError(domain: "APIKeyValidation", code: -5, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
            case .deviceMismatch:
                throw NSError(domain: "APIKeyValidation", code: -6, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
            case .bindingTimeExpired:
                throw NSError(domain: "APIKeyValidation", code: -7, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
            default:
                throw NSError(domain: "APIKeyValidation", code: -2, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
            }
        }
        
        // === File Processing ===
        guard let inputFile = inputFile, let fileURL = inputFile.fileURL else {
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file selected or file unavailable."])
        }
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            print("ConvertToHEIFIntent Error: Local file does NOT exist at path: \(fileURL.path)")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local file does not exist: \(fileURL.path)"])
        }
        
        let supportedExtensions = ["mp4", "mov", "m4v", "webm"]
        guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            print("ConvertToHEIFIntent Error: Unsupported local file type: \(fileURL.pathExtension)")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported local file type: \(fileURL.pathExtension)"])
        }
        
        // === Check video duration with retry for timing issues ===
        var loadedAsset: AVAsset? = nil
        let maxRetries = 3
        let retryDelay: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds
        
        for i in 0..<maxRetries {
            do {
                let currentAsset = AVURLAsset(url: fileURL) // Use AVURLAsset as recommended
                _ = try await currentAsset.load(.tracks) // Attempt to load tracks to ensure it's a valid video asset and fully ready.
                loadedAsset = currentAsset
                print("ConvertToHEIFIntent: AVAsset loaded successfully on attempt \(i + 1).")
                break // Success, exit loop
            } catch {
                print("ConvertToHEIFIntent Warning: Failed to load AVAsset on attempt \(i + 1): \(error.localizedDescription)")
                if i < maxRetries - 1 {
                    print("ConvertToHEIFIntent: Retrying in \(Double(retryDelay) / 1_000_000_000.0) seconds...")
                    try await Task.sleep(nanoseconds: retryDelay)
                } else {
                    print("ConvertToHEIFIntent Error: Max retries reached for AVAsset loading.")
                    throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to open video file. It might be damaged or not fully available."])
                }
            }
        }
        
        guard let asset = loadedAsset else {
            // This case should ideally be caught by the loop's else block, but as a safeguard.
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load video asset after multiple attempts."])
        }

        let duration = CMTimeGetSeconds(try await asset.load(.duration)) // Use load(.duration) as recommended
        if duration > 5.0 {
            print("ConvertToHEIFIntent Error: Video is too long (\(duration) seconds)")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video is too long. Please select a video shorter than 5 seconds."])
        }
        
        // === Convert video to HEIF ===
        print("ConvertToHEIFIntent: Attempting to convert local video to HEIF: \(fileURL.lastPathComponent)")
        let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: fileURL)
        try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
        print("ConvertToHEIFIntent: Local video converted to Live Photo successfully: \(fileURL.lastPathComponent)")
        
        return .result()
    }
}

@available(iOS 16.0, *)
struct LPhotoShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertToHEIFIntent(),
            phrases: ["Convert to HEIF with \(.applicationName)"],
            shortTitle: "Convert to HEIF",
            systemImageName: "photo.on.rectangle.angled"
        )
    }
} 
