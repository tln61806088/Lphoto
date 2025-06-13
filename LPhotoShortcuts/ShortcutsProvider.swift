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
        guard let inputFile = inputFile else {
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file selected or file unavailable."])
        }

        var tempVideoURL: URL!
        var finalFileExtension: String! // Will hold the actual video file extension after processing

        do {
            var dataToProcess: Data?
            var tentativeExtension: String? = inputFile.fileURL?.pathExtension.lowercased()

            // Case 1: Input is HTML content (often from a share link)
            if tentativeExtension == "html", let htmlData = try? inputFile.data, let htmlString = String(data: htmlData, encoding: .utf8) {
                print("ConvertToHEIFIntent: Input is HTML. Attempting to extract video URL.")
                if let videoURLString = VideoConverter.shared.extractVideoURL(from: htmlString), // Use VideoConverter to extract video URL
                   let videoURL = URL(string: videoURLString) {
                    print("ConvertToHEIFIntent: Extracted video URL: \(videoURL.absoluteString). Downloading video data...")
                    let (data, response) = try await URLSession.shared.data(from: videoURL)
                    if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                        throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to download video from URL: HTTP status \(httpResponse.statusCode)"])
                    }
                    dataToProcess = data
                    // Determine final file extension from the downloaded video URL, default to mp4
                    finalFileExtension = videoURL.pathExtension.lowercased().isEmpty ? "mp4" : videoURL.pathExtension.lowercased()
                    print("ConvertToHEIFIntent: Successfully downloaded video data from extracted URL. Size: \(dataToProcess?.count ?? 0) bytes.")
                } else {
                    throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not extract video URL from HTML content."])
                }
            } 
            // Case 2: Input is direct file data (preferred for local files/media)
            else if let fileData = try? inputFile.data {
                dataToProcess = fileData
                // Use tentative extension or default to mp4
                finalFileExtension = tentativeExtension?.isEmpty ?? true ? "mp4" : tentativeExtension
                print("ConvertToHEIFIntent: Processing input file data directly. Size: \(dataToProcess?.count ?? 0) bytes.")
            }
            // Case 3: Fallback to fileURL (less preferred, but handle if data not available and not HTML)
            else if let fileURL = inputFile.fileURL {
                // For consistency, download data from this URL too to ensure it's in a controlled Data object
                print("ConvertToHEIFIntent: Using original input file URL and downloading data from it: \(fileURL.absoluteString)")
                let (data, response) = try await URLSession.shared.data(from: fileURL)
                if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                    throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to download video from URL: HTTP status \(httpResponse.statusCode)"])
                }
                dataToProcess = data
                // Determine final file extension from the original file URL, default to mp4
                finalFileExtension = fileURL.pathExtension.lowercased().isEmpty ? "mp4" : fileURL.pathExtension.lowercased()
                print("ConvertToHEIFIntent: Successfully downloaded video data from original URL. Size: \(dataToProcess?.count ?? 0) bytes.")
            } 
            // Case 4: No valid input found
            else {
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not obtain file data or URL from input."])
            }

            // Ensure we have data to write
            guard let data = dataToProcess else {
                 throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video data to process after all attempts."])
            }

            // Write the processed data to a temporary file in our app's sandbox
            let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            let tempFileName = UUID().uuidString + "." + (finalFileExtension ?? "mp4") // Ensure extension
            tempVideoURL = tempDirectory.appendingPathComponent(tempFileName)

            try data.write(to: tempVideoURL)
            print("ConvertToHEIFIntent: Successfully wrote processed data to temporary URL: \(tempVideoURL.path)")

        } catch {
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare input file: \(error.localizedDescription)"])
        }

        // Now use tempVideoURL for all subsequent file operations
        if !FileManager.default.fileExists(atPath: tempVideoURL.path) {
            print("ConvertToHEIFIntent Error: Local file does NOT exist at path: \(tempVideoURL.path)")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local file does not exist at path: \(tempVideoURL.path)"])
        }
        
        let supportedExtensions = ["mp4", "mov", "m4v", "webm"]
        guard supportedExtensions.contains(finalFileExtension) else {
            print("ConvertToHEIFIntent Error: Unsupported local file type: \(finalFileExtension)")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported local file type: \(finalFileExtension)"])
        }
        
        // === Check video duration with retry for timing issues ===
        var loadedAsset: AVAsset? = nil
        let maxRetries = 11
        let retryDelay: UInt64 = 1_000_000_000
        
        for i in 0..<maxRetries {
            do {
                let currentAsset = AVURLAsset(url: tempVideoURL) // Use AVURLAsset as recommended
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
        print("ConvertToHEIFIntent: Attempting to convert local video to HEIF: \(tempVideoURL.lastPathComponent)")
        let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: tempVideoURL)
        try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
        print("ConvertToHEIFIntent: Local video converted to Live Photo successfully: \(tempVideoURL.lastPathComponent)")
        
        // === Cleanup temporary file ===
        if tempVideoURL.path.contains(NSTemporaryDirectory()) {
            do {
                try FileManager.default.removeItem(at: tempVideoURL)
                print("ConvertToHEIFIntent: Successfully deleted temporary file: \(tempVideoURL.lastPathComponent)")
            } catch {
                print("ConvertToHEIFIntent Warning: Failed to delete temporary file: \(error.localizedDescription)")
            }
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
            shortTitle: "Convert to HEIF",
            systemImageName: "photo.on.rectangle.angled"
        )
    }
} 
