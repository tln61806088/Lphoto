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
            let tentativeExtension: String? = inputFile.fileURL?.pathExtension.lowercased()

            // Process input based on its type
            if tentativeExtension == "html", let htmlString = String(data: inputFile.data, encoding: .utf8) {
                // Case 1: Input is HTML content (often from a share link)
                print("ConvertToHEIFIntent: Input is HTML. Attempting to extract video URL.")
                if let videoURLString = VideoConverter.shared.extractVideoURL(from: htmlString),
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
            } else if inputFile.fileURL != nil {
                // Case 2: Input has a file URL
                let fileURL = inputFile.fileURL!
                print("ConvertToHEIFIntent: Using input file URL: \(fileURL.absoluteString)")
                
                // Special handling for photo library URLs (which might have misleading extensions)
                if fileURL.absoluteString.contains("ph://") || fileURL.absoluteString.contains("assets-library://") {
                    print("ConvertToHEIFIntent: Detected photo library URL, using specialized handling")
                    
                    // Try to get the data directly
                    do {
                        let data = try Data(contentsOf: fileURL)
                        dataToProcess = data
                        
                        // For photo library assets, we need to check the actual content type
                        let detectedType = detectFileType(from: data)
                        finalFileExtension = detectedType ?? "mp4" // Default to mp4 if detection fails
                        print("ConvertToHEIFIntent: Photo library asset detected as: \(finalFileExtension ?? "unknown")")
                    } catch {
                        print("ConvertToHEIFIntent Warning: Failed to read photo library asset directly: \(error.localizedDescription)")
                        // Continue with standard URL handling
                    }
                }
                
                // Special handling for Shortcuts files which often have misleading extensions
                if inputFile.fileURL?.absoluteString.contains("com.apple.WorkflowKit") == true {
                    print("ConvertToHEIFIntent: Detected file from Shortcuts, using specialized handling")
                    
                    // Try to determine if it's actually a video file regardless of extension
                    if isLikelyVideoContent(data: inputFile.data) {
                        print("ConvertToHEIFIntent: Detected multiple H.264 NAL units - likely video content")
                        finalFileExtension = "mp4"
                        
                        // Double-check file size - if it's too small, it's probably not a valid video
                        if inputFile.data.count < 10000 { // Less than 10KB is suspiciously small for a video
                            print("ConvertToHEIFIntent Warning: File size is suspiciously small for a video: \(inputFile.data.count) bytes")
                            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "The file may not be a valid video file, please check your input."])
                        }
                    } else {
                        // Check if it's an image file
                        if inputFile.data.count > 0 && inputFile.data[0] == 0xFF && inputFile.data.count > 1 && inputFile.data[1] == 0xD8 {
                            print("ConvertToHEIFIntent: File appears to be a JPEG image, not a video")
                            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please select a video file for conversion. For image files, please use another conversion method."])
                        }
                    }
                    
                    print("ConvertToHEIFIntent: Shortcuts file detected as: \(finalFileExtension ?? "unknown")")
                }
                
                // If we don't have data yet, try standard URL approach
                if dataToProcess == nil {
                    // 添加对安全作用域资源的处理
                    if fileURL.isFileURL {
                        print("ConvertToHEIFIntent: URL is a file URL, attempting direct access")
                        do {
                            // 尝试访问安全作用域资源（如果可用）
                            var didStartAccessing = false
                            if fileURL.startAccessingSecurityScopedResource() {
                                didStartAccessing = true
                                print("ConvertToHEIFIntent: Successfully started accessing security scoped resource")
                            }
                            
                            // 确保在完成后停止访问
                            defer {
                                if didStartAccessing {
                                    fileURL.stopAccessingSecurityScopedResource()
                                    print("ConvertToHEIFIntent: Stopped accessing security scoped resource")
                                }
                            }
                            
                            // 尝试直接读取文件
                            let data = try Data(contentsOf: fileURL)
                            print("ConvertToHEIFIntent: Successfully read file directly with security scope, size: \(data.count) bytes")
                            dataToProcess = data
                        } catch {
                            print("ConvertToHEIFIntent ERROR: Failed to read file with security scope: \(error.localizedDescription)")
                            // 继续使用URL会话方法
                        }
                    }
                    
                    // 如果仍然没有数据，尝试使用URL会话
                    if dataToProcess == nil {
                        let (data, response) = try await URLSession.shared.data(from: fileURL)
                        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to download video from URL: HTTP status \(httpResponse.statusCode)"])
                        }
                        dataToProcess = data
                    }
                    
                    // For URLs, try to detect the actual content type rather than trusting the extension
                    if let unwrappedData = dataToProcess {
                        let detectedType = detectFileType(from: unwrappedData)
                        if let detectedType = detectedType {
                            finalFileExtension = detectedType
                            print("ConvertToHEIFIntent: URL content detected as: \(finalFileExtension ?? "unknown")")
                        } else {
                            // Fallback to URL extension if detection fails
                            finalFileExtension = fileURL.pathExtension.lowercased().isEmpty ? "mp4" : fileURL.pathExtension.lowercased()
                            print("ConvertToHEIFIntent: Could not detect file type, using URL extension: \(finalFileExtension ?? "mp4")")
                        }
                    }
                }
                
                print("ConvertToHEIFIntent: Successfully processed data from URL. Size: \(dataToProcess?.count ?? 0) bytes.")
            } else {
                // Case 3: Input has direct data but no URL or HTML
                dataToProcess = inputFile.data
                
                // Detect actual file type from data signature instead of relying on extension
                let fileSignature = detectFileType(from: inputFile.data)
                if let detectedType = fileSignature {
                    print("ConvertToHEIFIntent: Detected file type from data signature: \(detectedType)")
                    finalFileExtension = detectedType
                    
                    // Early check for image files
                    if detectedType == "jpeg" || detectedType == "jpg" || detectedType == "png" || detectedType == "heic" {
                        // Do an extra check to make sure it's not actually a video with incorrect signature
                        if isLikelyVideoContent(data: inputFile.data) {
                            print("ConvertToHEIFIntent: File has image signature but appears to be video content")
                            finalFileExtension = "mp4"
                        } else {
                            print("ConvertToHEIFIntent: File is an image file (\(detectedType)), not a video")
                            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please select a video file for conversion. For image files, please use another conversion method."])
                        }
                    }
                } else {
                    // Fallback to tentative extension or default to mp4
                    finalFileExtension = tentativeExtension?.isEmpty ?? true ? "mp4" : tentativeExtension
                    print("ConvertToHEIFIntent: Could not detect file type from signature, using extension: \(String(describing: finalFileExtension))")
                }
                
                print("ConvertToHEIFIntent: Processing input file data directly. Size: \(dataToProcess?.count ?? 0) bytes.")
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
            print("ConvertToHEIFIntent ERROR: Failed to prepare input file with detailed error: \(error)")
            // Print URL details if available
            if let fileURL = inputFile.fileURL {
                print("ConvertToHEIFIntent ERROR: File URL details - scheme: \(fileURL.scheme ?? "nil"), host: \(fileURL.host ?? "nil"), path: \(fileURL.path)")
            }
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare input file: \(error.localizedDescription)"])
        }

        // Now use tempVideoURL for all subsequent file operations
        if !FileManager.default.fileExists(atPath: tempVideoURL.path) {
            print("ConvertToHEIFIntent Error: Local file does NOT exist at path: \(tempVideoURL.path)")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local file does not exist at path: \(tempVideoURL.path)"])
        }
        
        // Try to detect file type using AVAsset first before checking extension
        var isVideoFile = false
        do {
            // Early check for known image file extensions
            if finalFileExtension == "jpeg" || finalFileExtension == "jpg" || finalFileExtension == "png" || finalFileExtension == "heic" {
                // If it's an image file, we should handle it differently
                print("ConvertToHEIFIntent: File is an image file (\(finalFileExtension ?? "unknown")), not a video")
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please select a video file for conversion. For image files, please use another conversion method."])
            }
            
            let asset = AVURLAsset(url: tempVideoURL)
            var loadSuccess = false
            
            // Try to load the asset multiple times with increasing delays
            for attempt in 1...5 {
                do {
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    isVideoFile = !tracks.isEmpty
                    if isVideoFile {
                        print("ConvertToHEIFIntent: File confirmed as video through AVAsset")
                        loadSuccess = true
                        break
                    } else {
                        print("ConvertToHEIFIntent Warning: No video tracks found in the file")
                    }
                } catch {
                    print("ConvertToHEIFIntent Warning: Failed to load AVAsset on attempt \(attempt): \(error.localizedDescription)")
                    if attempt < 5 {
                        let delay = Double(attempt) * 0.5 // Increasing delay with each attempt
                        print("ConvertToHEIFIntent: Retrying in \(delay) seconds...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }
            
            // If we couldn't load the asset after multiple attempts, try a different approach
            if !loadSuccess {
                print("ConvertToHEIFIntent Warning: Could not load video tracks after multiple attempts")
                
                // Try to extract a thumbnail as a last resort to verify it's a video
                do {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 100, height: 100) // Small thumbnail for quick generation
                    
                    // Try to get the first frame
                    let _ = try generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 60), actualTime: nil)
                    print("ConvertToHEIFIntent: Successfully extracted thumbnail, file appears to be a valid video")
                    isVideoFile = true
                } catch {
                    print("ConvertToHEIFIntent Error: Failed to extract thumbnail: \(error.localizedDescription)")
                    
                    // If we get here, we've tried everything and it's likely not a valid video file
                    throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to process this file. Please ensure you've selected a valid video file with a duration under 10 seconds."])
                }
            }
        } catch let assetError as NSError where assetError.domain == "HEIFConversion" {
            // Re-throw our custom errors
            throw assetError
        } catch {
            print("ConvertToHEIFIntent Warning: Failed to check file as AVAsset: \(error.localizedDescription)")
            // Continue with extension-based check
        }
        
        let supportedExtensions = ["mp4", "mov", "m4v", "webm"]
        
        // Check if file type is supported or try to confirm it's a video
        if !isVideoFile && !supportedExtensions.contains(finalFileExtension ?? "") {
            print("ConvertToHEIFIntent Error: Unsupported local file type: \(String(describing: finalFileExtension))")
            
            // Try one more check - attempt to load as a video regardless of extension
            do {
                print("ConvertToHEIFIntent: Attempting to force-check file as video regardless of extension")
                let asset = AVURLAsset(url: tempVideoURL)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if !videoTracks.isEmpty {
                    print("ConvertToHEIFIntent: File confirmed as video despite extension")
                    // Override the extension since we confirmed it's a video
                    finalFileExtension = "mp4"
                    isVideoFile = true
                    // Continue processing
                } else {
                    throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported local file type: \(String(describing: finalFileExtension))"])
                }
            } catch {
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported local file type: \(String(describing: finalFileExtension))"])
            }
        }
        
        // === Check video duration with retry for timing issues ===
        var loadedAsset: AVAsset? = nil
        let maxRetries = 5 // Reduced from 11 to 5 attempts
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
        
        // IMPORTANT: Apple has a hard limit of 3 seconds for Live Photos
        // Even though we allow up to 10 seconds for user convenience, we need to warn if it's over 3 seconds
        if duration > 10.0 {
            print("ConvertToHEIFIntent Error: Video is too long (\(duration) seconds)")
            throw NSError(domain: "HEIFConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video is too long. Please select a video shorter than 10 seconds."])
        } else if duration > 3.0 {
            print("ConvertToHEIFIntent Warning: Video is longer than 3 seconds (\(duration) seconds). Live Photo may be truncated.")
            // We continue processing but warn the user
        }
        
        // === Convert video to HEIF ===
        print("ConvertToHEIFIntent: Attempting to convert local video to HEIF: \(tempVideoURL.lastPathComponent)")
        
        do {
            let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: tempVideoURL)
            try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
            print("ConvertToHEIFIntent: Local video converted to Live Photo successfully: \(tempVideoURL.lastPathComponent)")
        } catch {
            print("ConvertToHEIFIntent Error: Failed to convert video to Live Photo: \(error.localizedDescription)")
            
            // Check for specific error conditions that might cause SIGABRT
            if error.localizedDescription.contains("Cannot Open") || 
               error.localizedDescription.contains("AVFoundation") ||
               error.localizedDescription.contains("AVAsset") {
                throw NSError(domain: "HEIFConversion", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Unable to process this video file. Apple system limits Live Photos to 3 seconds, videos longer than 3 seconds may be truncated or cannot be processed."
                ])
            }
            
            // Re-throw the original error if it's not a known condition
            throw error
        }
        
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

// Add helper function to detect file type from data signature
extension ConvertToHEIFIntent {
    private func detectFileType(from data: Data) -> String? {
        // File signatures (magic numbers)
        let signatures: [String: [UInt8]] = [
            "mp4": [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70], // MP4 signature
            "mov": [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70], // MOV signature
            "jpeg": [0xFF, 0xD8, 0xFF], // JPEG signature
            "png": [0x89, 0x50, 0x4E, 0x47], // PNG signature
            "heic": [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63] // HEIC signature
        ]
        
        // Check for MP4/MOV signature at different offsets (some MP4 files have varying headers)
        let checkOffsets = [0, 4, 8]
        
        // First check for H.264 video content - common in videos from shortcuts
        if data.count > 100 {
            // H.264 NAL unit markers (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
            let nalMarker1 = Data([0x00, 0x00, 0x00, 0x01])
            let nalMarker2 = Data([0x00, 0x00, 0x01])
            
            // Check for H.264 NAL units in first 100 bytes
            for i in 0..<min(100, data.count - 4) {
                let slice = data[i..<min(i+4, data.count)]
                if slice.starts(with: nalMarker1) || (slice.count >= 3 && slice.prefix(3) == nalMarker2) {
                    // Look for SPS (NAL type 7) or PPS (NAL type 8) within next few bytes
                    if i + 4 < data.count {
                        let nalType = data[i + 4] & 0x1F // Get NAL type from first byte after marker
                        if nalType == 7 || nalType == 8 {
                            print("ConvertToHEIFIntent: Detected H.264 video content (NAL type \(nalType))")
                            return "mp4" // Treat H.264 content as MP4
                        }
                    }
                    
                    // Even if we can't identify specific NAL types, consecutive NAL markers strongly suggest video
                    var nalCount = 0
                    for j in stride(from: i, to: min(i + 1000, data.count - 4), by: 1) {
                        let sliceCheck = data[j..<min(j+4, data.count)]
                        if sliceCheck.starts(with: nalMarker1) || (sliceCheck.count >= 3 && sliceCheck.prefix(3) == nalMarker2) {
                            nalCount += 1
                            if nalCount >= 3 {
                                print("ConvertToHEIFIntent: Detected multiple H.264 NAL units - likely video content")
                                return "mp4"
                            }
                        }
                    }
                }
            }
        }
        
        // Then check for HEIC specifically - multiple possible signatures
        if data.count > 12 {
            // Check for "ftyp" marker followed by HEIC brand
            if let ftypRange = data.range(of: Data([0x66, 0x74, 0x79, 0x70])), // "ftyp" marker
               ftypRange.lowerBound < 20 { // Should be near the beginning
                
                let brandOffset = ftypRange.upperBound
                if data.count >= brandOffset + 4 {
                    let brandData = data[brandOffset..<(brandOffset + 4)]
                    
                    // Check for HEIC brands: 'heic', 'heix', 'hevc', 'hevx'
                    let heicBrands = [
                        Data([0x68, 0x65, 0x69, 0x63]), // 'heic'
                        Data([0x68, 0x65, 0x69, 0x78]), // 'heix'
                        Data([0x68, 0x65, 0x76, 0x63]), // 'hevc'
                        Data([0x68, 0x65, 0x76, 0x78])  // 'hevx'
                    ]
                    
                    for brand in heicBrands {
                        if brandData.elementsEqual(brand) {
                            return "heic"
                        }
                    }
                    
                    // If we found ftyp but not a HEIC brand, it's likely another container format
                    // Common video container brands
                    let videoContainerBrands = [
                        Data([0x6d, 0x70, 0x34, 0x32]), // 'mp42' - MP4 v2
                        Data([0x69, 0x73, 0x6f, 0x6d]), // 'isom' - ISO Base Media
                        Data([0x61, 0x76, 0x63, 0x31]), // 'avc1' - AVC video
                        Data([0x4d, 0x53, 0x4e, 0x56]), // 'MSNV' - Microsoft video
                        Data([0x6d, 0x70, 0x34, 0x31])  // 'mp41' - MP4 v1
                    ]
                    
                    for brand in videoContainerBrands {
                        if data.count >= brandOffset + 4 && brandData.elementsEqual(brand) {
                            print("ConvertToHEIFIntent: Detected video container brand: \(String(data: brand, encoding: .ascii) ?? "unknown")")
                            return "mp4"
                        }
                    }
                }
            }
        }
        
        // Check standard signatures
        for (fileType, signature) in signatures {
            // For MP4 and MOV, check at different offsets
            if fileType == "mp4" || fileType == "mov" {
                for offset in checkOffsets {
                    if data.count >= offset + signature.count {
                        let dataSlice = data[offset..<(offset + signature.count)]
                        let matches = zip(dataSlice, signature).filter { $0 == $1 }.count
                        // Allow partial match for MP4/MOV (at least 4 bytes)
                        if matches >= 4 {
                            return fileType
                        }
                    }
                }
                
                // Additional check for ftyp marker which indicates MP4 container
                if let range = data.range(of: Data([0x66, 0x74, 0x79, 0x70])), // "ftyp" marker
                   range.lowerBound < 100 { // Should be near the beginning
                    return "mp4"
                }
            } else {
                // For other formats, check at the beginning
                if data.count >= signature.count {
                    let dataSlice = data[0..<signature.count]
                    if dataSlice.elementsEqual(signature) {
                        return fileType
                    }
                }
            }
        }
        
        // Additional check for JPEG/JFIF
        if data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 {
            return "jpeg"
        }
        
        // If no match found, check for video content using additional heuristics
        // Look for common video codec markers
        let videoMarkers = [
            Data([0x00, 0x00, 0x01, 0xB0]), // MPEG header
            Data([0x00, 0x00, 0x01, 0xB3]), // MPEG header
            Data([0x00, 0x00, 0x01, 0xB8]), // MPEG header
            Data([0x67, 0x64, 0x00, 0x28]), // H.264 SPS
            Data([0x68, 0xEB, 0xE3, 0x88]), // H.264 PPS
            Data([0x06, 0x05, 0xFF, 0xFF]), // H.264 SEI
            Data([0x67, 0x42, 0x00, 0x0A]), // Another common H.264 SPS pattern
            Data([0x67, 0x64, 0x00, 0x1F])  // Another common H.264 SPS pattern
        ]
        
        for marker in videoMarkers {
            if data.count > 100 && data.contains(marker) {
                print("ConvertToHEIFIntent: Detected video codec marker")
                return "mp4" // Default to MP4 for video content
            }
        }
        
        // Last resort - scan for H.264 byte patterns in chunks
        if data.count > 1000 {
            // Sample 10 chunks from the file
            let chunkSize = 100
            let strideSize = max(1, data.count / 10)
            
            for offset in stride(from: 0, to: data.count - chunkSize, by: strideSize) {
                let chunk = data[offset..<min(offset+chunkSize, data.count)]
                
                // Check for byte patterns common in H.264 streams
                // 1. NAL unit start codes
                if chunk.contains(Data([0x00, 0x00, 0x01])) || chunk.contains(Data([0x00, 0x00, 0x00, 0x01])) {
                    // 2. Look for bytes that might indicate H.264 content
                    var h264Likelihood = 0
                    
                    // Check for bytes common in H.264 headers
                    for i in 0..<chunk.count-3 {
                        // NAL unit header check
                        if (chunk[i] == 0x00 && chunk[i+1] == 0x00 && (chunk[i+2] == 0x01 || (chunk[i+2] == 0x00 && chunk[i+3] == 0x01))) {
                            h264Likelihood += 3
                        }
                    }
                    
                    if h264Likelihood >= 3 {
                        print("ConvertToHEIFIntent: Detected possible H.264 content through pattern analysis")
                        return "mp4"
                    }
                }
            }
        }
        
        return nil
    }
    
    private func isLikelyVideoContent(data: Data) -> Bool {
        // Check for H.264 NAL unit markers
        let nalMarker1 = Data([0x00, 0x00, 0x00, 0x01])
        let nalMarker2 = Data([0x00, 0x00, 0x01])
        
        // Check for NAL units in first 5KB of data
        let searchRange = min(5000, data.count)
        var nalCount = 0
        
        for i in 0..<(searchRange - 4) {
            let slice = data[i..<min(i+4, data.count)]
            if slice.starts(with: nalMarker1) || (slice.count >= 3 && slice.prefix(3) == nalMarker2) {
                nalCount += 1
                if nalCount >= 2 {
                    return true // Multiple NAL units found, likely video
                }
            }
        }
        
        // Check for common video container markers
        if let range = data.range(of: Data([0x66, 0x74, 0x79, 0x70])), // "ftyp" marker
           range.lowerBound < 100 { // Should be near the beginning
            return true // Found ftyp marker, likely a video container
        }
        
        // Check for MOOV atom
        if let range = data.range(of: Data([0x6d, 0x6f, 0x6f, 0x76])), // "moov" atom
           range.lowerBound < 1000 { // Should be relatively near the beginning
            return true
        }
        
        // Check for MDAT atom
        if let range = data.range(of: Data([0x6d, 0x64, 0x61, 0x74])), // "mdat" atom
           range.lowerBound < 1000 { // Should be relatively near the beginning
            return true
        }
        
        // Check for bytes that indicate video compression
        // Sample at different offsets to avoid scanning the entire file
        let samplePoints = [100, 500, 1000, 2000, 5000]
        for offset in samplePoints {
            if offset >= data.count - 16 {
                continue // Skip if we're past the end of the file
            }
            
            let sample = data[offset..<min(offset+16, data.count)]
            
            // Pattern common in H.264 encoded data (byte patterns that rarely occur in images)
            let patterns = [
                Data([0x00, 0x00, 0x01, 0x67]), // SPS NAL unit
                Data([0x00, 0x00, 0x01, 0x68]), // PPS NAL unit
                Data([0x00, 0x00, 0x01, 0x65]), // IDR frame
                Data([0x00, 0x00, 0x01, 0x41]), // Coded slice
                Data([0x00, 0x00, 0x01, 0x21])  // Coded slice
            ]
            
            for pattern in patterns {
                if sample.contains(pattern) {
                    return true
                }
            }
        }
        
        // Last resort - scan for H.264 byte patterns in chunks
        if data.count > 1000 {
            // Sample 10 chunks from the file
            let chunkSize = 100
            let strideSize = max(1, data.count / 10)
            
            for offset in stride(from: 0, to: data.count - chunkSize, by: strideSize) {
                let chunk = data[offset..<min(offset+chunkSize, data.count)]
                
                // Check for byte patterns common in H.264 streams
                // 1. NAL unit start codes
                if chunk.contains(Data([0x00, 0x00, 0x01])) || chunk.contains(Data([0x00, 0x00, 0x00, 0x01])) {
                    // 2. Look for bytes that might indicate H.264 content
                    var h264Likelihood = 0
                    
                    // Check for bytes common in H.264 headers
                    for i in 0..<chunk.count-3 {
                        // NAL unit header check
                        if (chunk[i] == 0x00 && chunk[i+1] == 0x00 && (chunk[i+2] == 0x01 || (chunk[i+2] == 0x00 && chunk[i+3] == 0x01))) {
                            h264Likelihood += 3
                        }
                    }
                    
                    if h264Likelihood >= 3 {
                        print("ConvertToHEIFIntent: Detected possible H.264 content through pattern analysis")
                        return true
                    }
                }
            }
        }
        
        return false // No video indicators found
    }
} 
