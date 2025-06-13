import Foundation
import AppIntents
import AVFoundation
import Photos
import UIKit

struct ConvertToHEIFIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert to HEIF"
    static var description: LocalizedStringResource = "Convert video or URL content to dynamic HEIF format"
    
    @Parameter(title: "Input URL", description: "Enter a network URL address.", default: nil)
    var inputURLString: String?
    
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
        
        // === URL Processing ===
        guard let inputURLString = inputURLString,
              let inputURL = URL(string: inputURLString) else {
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL format"])
        }
        
        if inputURL.isFileURL {
            // Handle local file URL
            print("ConvertToHEIFIntent: Detected local file URL: \(inputURL.path)")
            if !FileManager.default.fileExists(atPath: inputURL.path) {
                print("ConvertToHEIFIntent Error: Local file does NOT exist at path: \(inputURL.path)")
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local file does not exist: \(inputURL.path)"])
            }
            if inputURL.pathExtension.lowercased() == "mp4" ||
               inputURL.pathExtension.lowercased() == "mov" ||
               inputURL.pathExtension.lowercased() == "m4v" ||
               inputURL.pathExtension.lowercased() == "webm" {
                // Process video file
                print("ConvertToHEIFIntent: Attempting to convert local video to HEIF: \(inputURL.lastPathComponent)")
                let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: inputURL)
                try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                print("ConvertToHEIFIntent: Local video converted to Live Photo successfully: \(inputURL.lastPathComponent)")
            } else {
                print("ConvertToHEIFIntent Error: Unsupported local file type: \(inputURL.pathExtension)")
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported local file type: \(inputURL.pathExtension)"])
            }
        } else if inputURL.scheme?.lowercased() == "http" || inputURL.scheme?.lowercased() == "https" {
            // Handle network URL
            print("ConvertToHEIFIntent: Detected network URL. Attempting to download: \(inputURL.absoluteString)")
            
            // Download file to temporary directory
            let (data, response) = try await URLSession.shared.data(from: inputURL)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("ConvertToHEIFIntent Error: Unable to access network resource or status code not 200.")
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to access network resource or status code not 200"])
            }
            print("ConvertToHEIFIntent: Network resource downloaded successfully. MIME Type: \(httpResponse.mimeType ?? "Unknown")")

            // Determine temporary file path
            let fileExtension = inputURL.pathExtension.isEmpty ? "tmp" : inputURL.pathExtension
            let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
            print("ConvertToHEIFIntent: Temporary file path for download: \(tempFileURL.absoluteString)")

            // Save downloaded data to temporary file
            do {
                try data.write(to: tempFileURL)
                print("ConvertToHEIFIntent: Downloaded data written to temporary file: \(tempFileURL.absoluteString)")
                if FileManager.default.fileExists(atPath: tempFileURL.path) {
                    print("ConvertToHEIFIntent Info: Temporary file exists at path: \(tempFileURL.path)")
                } else {
                    print("ConvertToHEIFIntent Error: Temporary file does NOT exist after writing: \(tempFileURL.path)")
                }
            } catch {
                print("ConvertToHEIFIntent Error: Error writing downloaded data to temporary file: \(error.localizedDescription)")
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to save downloaded network content to temporary file: \(error.localizedDescription)"])
            }
            
            // Process temporary file based on MIME type or file extension
            if let mimeType = httpResponse.mimeType?.lowercased() {
                if mimeType.contains("video") || ["mp4", "mov", "m4v", "webm"].contains(tempFileURL.pathExtension.lowercased()) {
                    print("ConvertToHEIFIntent: Detected video MIME type or extension. Attempting to convert from temp file to Live Photo: \(tempFileURL.lastPathComponent)")
                    let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: tempFileURL)
                    try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                    print("ConvertToHEIFIntent: Network video converted to Live Photo successfully.")
                } else {
                    print("ConvertToHEIFIntent Error: Unsupported network content type: \(mimeType)")
                    throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported network content type"])
                }
            } else {
                print("ConvertToHEIFIntent Error: Could not determine MIME type of network resource.")
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to determine MIME type of network resource"])
            }
            
            // Clean up temporary file
            try? FileManager.default.removeItem(at: tempFileURL)

        } else {
            print("ConvertToHEIFIntent Error: Unsupported URL scheme: \(inputURL.scheme ?? "nil")")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported URL scheme: \(inputURL.scheme ?? "nil")"])
        }
        
        return .result()
    }
}

@available(iOS 16.0, *)
struct LPhotoShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertToHEIFIntent(),
            phrases: ["Convert to HEIF with \(.applicationName)"],
            shortTitle: "Convert to HEIF"
        )
    }
} 
