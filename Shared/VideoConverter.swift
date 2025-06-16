import Foundation
@preconcurrency import AVFoundation
import Photos
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
import UIKit
import CoreGraphics // 确保导入 CoreGraphics
import CryptoKit // 确保导入 CryptoKit

class VideoConverter {
    static let shared = VideoConverter()
    
    private init() {}
    
    func convertVideoToHEIF(from videoURL: URL) async throws -> (photoData: Data, videoURL: URL) {
        print("VideoConverter: convertVideoToHEIF(from:) called with URL: \(videoURL.absoluteString)")

        let asset = AVURLAsset(url: videoURL)
        
        // 检查资源是否可导出
        let isExportable = try await asset.load(.isExportable)
        guard isExportable else {
            print("VideoConverter Error: Video asset is not exportable: \(videoURL.absoluteString)")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video asset is not exportable"])
        }
        
        // 获取视频轨道
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            print("VideoConverter Error: No video track found in asset")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }
        
        // 获取音频轨道
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let videoSize = try await videoTrack.load(.naturalSize)
        print("VideoConverter: Video natural size: \(videoSize)")
        
        let duration = try await asset.load(.duration)
        print("VideoConverter: Video duration: \(duration.seconds) seconds")
        
        // 确保视频不超过3秒 - Apple的Live Photo硬性限制
        let maxLivePhotoDuration = CMTime(seconds: 3.0, preferredTimescale: 600)
        let preferredDuration = duration.seconds > maxLivePhotoDuration.seconds ? maxLivePhotoDuration : duration
        
        let exportTimeRange: CMTimeRange
        let imageCaptureTime: CMTime
        
        if duration > preferredDuration {
            // 如果视频长度超过3秒，取中间3秒
            let startOffset = CMTime(seconds: (duration.seconds - preferredDuration.seconds) / 2.0, preferredTimescale: 600)
            exportTimeRange = CMTimeRange(start: startOffset, duration: preferredDuration)
            imageCaptureTime = CMTime(seconds: exportTimeRange.start.seconds + preferredDuration.seconds / 2.0, preferredTimescale: 600)
            print("VideoConverter: Video exceeds 3 seconds, trimming to middle \(preferredDuration.seconds) seconds")
            
            // 对于超过3秒的视频，我们需要先导出为临时文件，然后再处理
            // 这样可以确保我们处理的是解压缩后的数据
            return try await exportAndProcessVideo(asset: asset, 
                                                exportTimeRange: exportTimeRange, 
                                                imageCaptureTime: imageCaptureTime)
        } else {
            exportTimeRange = CMTimeRange(start: .zero, duration: duration)
            imageCaptureTime = CMTime(seconds: duration.seconds / 2.0, preferredTimescale: 600)
        }
        
        print("VideoConverter: Export time range: \(exportTimeRange.start.seconds) to \(exportTimeRange.end.seconds)")
        print("VideoConverter: Image capture time: \(imageCaptureTime.seconds)")
        
        let livePhotoUUID = UUID().uuidString

        // --- 使用 AVAssetWriter 导出视频并嵌入元数据 ---
        let tempVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        
        // 创建 Asset Writer
        let assetWriter = try AVAssetWriter(outputURL: tempVideoURL, fileType: .mov)

        // 视频输入
        // 不指定输出设置，而是使用源格式
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = try await videoTrack.load(.preferredTransform)
        assetWriter.add(videoWriterInput)

        // 音频输入
        let audioWriterInputOpt: AVAssetWriterInput?
        if audioTrack != nil {
            // 不指定输出设置，而是使用源格式
            let newAudioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            newAudioWriterInput.expectsMediaDataInRealTime = false
            assetWriter.add(newAudioWriterInput)
            audioWriterInputOpt = newAudioWriterInput
        } else {
            audioWriterInputOpt = nil
        }
        
        // Live Photo 视频元数据
        let identifierMetadata = metadataItem(for: livePhotoUUID)
        let stillImageTimeAdaptor = stillImageTimeMetadataAdaptor()
        
        assetWriter.metadata = [identifierMetadata] // 设置 Live Photo 内容标识符
        assetWriter.add(stillImageTimeAdaptor.assetWriterInput)

        // 开始写入会话
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: exportTimeRange.start)
        
        // 创建 Asset Reader 读取器
        let assetReader = try AVAssetReader(asset: asset)
        assetReader.timeRange = exportTimeRange // 设置读取范围与导出范围一致

        // 使用源格式读取视频，不进行解压缩
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoReaderOutput.alwaysCopiesSampleData = false // 提高性能
        assetReader.add(videoReaderOutput)

        // 音频使用原始格式读取
        let audioReaderOutputOpt: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let newAudioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            newAudioReaderOutput.alwaysCopiesSampleData = false // 提高性能
            assetReader.add(newAudioReaderOutput)
            audioReaderOutputOpt = newAudioReaderOutput
        } else {
            audioReaderOutputOpt = nil
        }
        
        // 开始读取
        assetReader.startReading()
        
        // 检查 assetReader 状态
        if assetReader.status != AVAssetReader.Status.reading {
            print("VideoConverter Error: AssetReader failed to start reading with status: \(assetReader.status.rawValue), error: \(assetReader.error?.localizedDescription ?? "Unknown")")
            throw assetReader.error ?? NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read video data"])
        }

        // 写入静态图片时间元数据
        let frameCount = try await asset.frameCount(exact: false) // Using non-exact for performance
        let stillImagePercent = Float(imageCaptureTime.seconds / duration.seconds)
        await stillImageTimeAdaptor.append(
            AVTimedMetadataGroup(
                items: [stillImageTimeMetadataItem()],
                timeRange: try asset.makeStillImageTimeRange(percent: stillImagePercent, inFrameCount: frameCount)
            )
        )
        
        // 并行写入视频和音频数据
        async let videoWritingFinished: Bool = withCheckedThrowingContinuation { continuation in
            videoWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoWriterInputQueue")) {
                while videoWriterInput.isReadyForMoreMediaData {
                    if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() {
                        if !videoWriterInput.append(sampleBuffer) {
                            print("VideoConverter Error: Failed to append video sample buffer.")
                            assetReader.cancelReading()
                            continuation.resume(throwing: NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to write video sample buffer"]))
                            return
                        }
                    } else {
                        videoWriterInput.markAsFinished()
                        continuation.resume(returning: true)
                        return
                    }
                }
            }
        }

        async let audioWritingFinished: Bool = withCheckedThrowingContinuation { continuation in
            guard let unwrappedAudioWriterInput = audioWriterInputOpt, 
                  let unwrappedAudioReaderOutput = audioReaderOutputOpt else {
                continuation.resume(returning: true) // No audio track, so consider it finished
                return
            }
            unwrappedAudioWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audioWriterInputQueue")) {
                while unwrappedAudioWriterInput.isReadyForMoreMediaData {
                    if let sampleBuffer = unwrappedAudioReaderOutput.copyNextSampleBuffer() {
                        if !unwrappedAudioWriterInput.append(sampleBuffer) {
                            print("VideoConverter Error: Failed to append audio sample buffer.")
                            assetReader.cancelReading()
                            continuation.resume(throwing: NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to write audio sample buffer"]))
                            return
                        }
                    } else {
                        unwrappedAudioWriterInput.markAsFinished()
                        continuation.resume(returning: true)
                        return
                    }
                }
            }
        }

        // 等待所有写入操作完成
        let (videoResult, audioResult) = try await (videoWritingFinished, audioWritingFinished)
        
        // 检查写入结果
        guard videoResult && audioResult else {
            print("VideoConverter Error: Video or audio writing failed")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video or audio writing failed"])
        }
        
        // 结束写入会话
        assetWriter.endSession(atSourceTime: exportTimeRange.end) // 使用导出范围的结束时间
        
        // 检查 assetWriter 状态
        if assetWriter.status != AVAssetWriter.Status.writing && assetWriter.status != AVAssetWriter.Status.completed {
            print("VideoConverter Error: AssetWriter is in an invalid state: \(assetWriter.status.rawValue), error: \(assetWriter.error?.localizedDescription ?? "Unknown")")
            throw assetWriter.error ?? NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video writer is in an invalid state"])
        }
        
        await assetWriter.finishWriting()

        guard assetWriter.status == AVAssetWriter.Status.completed else {
            print("VideoConverter Error: AVAssetWriter failed with status: \(assetWriter.status.rawValue), error: \(assetWriter.error?.localizedDescription ?? "Unknown")")
            throw assetWriter.error ?? NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video writing failed"])
        }

        print("VideoConverter: Video export completed successfully for Live Photo paired video using AVAssetWriter.")

        // 提取静态图片，并传入视频尺寸以确保分辨率一致，并指定关键帧时间
        guard let photoData = try await generateStillImage(from: tempVideoURL, at: imageCaptureTime, size: videoSize, contentIdentifier: livePhotoUUID) else {
            print("VideoConverter Error: Failed to generate still image for Live Photo.")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate Live Photo still image"])
        }

        return (photoData: photoData, videoURL: tempVideoURL)
    }
    
    // MARK: - Live Photo Metadata Helpers
    private func metadataItem(for identifier: String) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSCopying & NSObjectProtocol
        item.value = identifier as NSCopying & NSObjectProtocol
        return item
    }

    private func stillImageTimeMetadataAdaptor() -> AVAssetWriterInputMetadataAdaptor {
        let quickTimeMetadataKeySpace = AVMetadataKeySpace.quickTimeMetadata.rawValue
        let stillImageTimeKey = "com.apple.quicktime.still-image-time"
        let spec: [NSString : Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString : "\(quickTimeMetadataKeySpace)/\(stillImageTimeKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString : kCMMetadataBaseDataType_SInt8
        ]
        var desc : CMFormatDescription? = nil
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc
        )
        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: desc
        )
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    private func stillImageTimeMetadataItem() -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSCopying & NSObjectProtocol
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.value = 0 as NSCopying & NSObjectProtocol // 0 for the first frame as still image
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }
    
    // MARK: - Save Live Photo
    func saveLivePhoto(photoData: Data, videoURL: URL) async throws {
        // 使用 PHPhotoLibrary 请求权限并保存 Live Photo
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != .authorized {
            // 请求权限
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if newStatus != .authorized {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Photo library access permission required"])
            }
        }
        
        // 创建临时文件用于 HEIC 图片
        let tempPhotoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("heic")
        try photoData.write(to: tempPhotoURL)
        
        // 确保临时文件存在
        guard FileManager.default.fileExists(atPath: tempPhotoURL.path) else {
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create temporary image file"])
        }
        
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to find video file"])
        }
        
        // 检查文件大小，确保文件不为空
        let photoAttributes = try FileManager.default.attributesOfItem(atPath: tempPhotoURL.path)
        let videoAttributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        
        guard let photoSize = photoAttributes[.size] as? NSNumber, photoSize.intValue > 0 else {
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image file is empty"])
        }
        
        guard let videoSize = videoAttributes[.size] as? NSNumber, videoSize.intValue > 0 else {
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video file is empty"])
        }
        
        print("VideoConverter: Photo file size: \(photoSize) bytes, Video file size: \(videoSize) bytes")
        
        // 使用安全的错误处理方式保存 Live Photo
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // 创建 Live Photo 请求
                let creationRequest = PHAssetCreationRequest.forAsset()
                
                // 使用资源创建选项指定 Live Photo 内容
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true // 移动文件而不是复制，以节省空间
                
                // 添加静态图片资源
                creationRequest.addResource(with: .photo, fileURL: tempPhotoURL, options: options)
                
                // 添加配对视频资源
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = true
                creationRequest.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }
            print("VideoConverter: Live Photo saved successfully to photo library")
        } catch {
            print("VideoConverter Error: Failed to save Live Photo: \(error.localizedDescription)")
            
            // 检查是否是由于文件大小或格式限制导致的错误
            if error.localizedDescription.contains("resource value too large") {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video file is too large, cannot create Live Photo. Apple limits Live Photos to 3 seconds."])
            } else if error.localizedDescription.contains("format") || error.localizedDescription.contains("invalid") {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "File format not compatible, cannot create Live Photo."])
            } else {
                // 重新抛出原始错误
                throw error
            }
        }
        
        // 清理临时文件
        try? FileManager.default.removeItem(at: tempPhotoURL)
    }
    
    // 辅助方法：从视频中生成静态图片
    private func generateStillImage(from videoURL: URL, at time: CMTime, size: CGSize, contentIdentifier: String) async throws -> Data? {
        print("VideoConverter: generateStillImage(from:at:size:contentIdentifier:) called for video: \(videoURL.absoluteString) with size: \(size), contentIdentifier: \(contentIdentifier)")
        
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        
        // 配置图片生成器
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        // 生成图片
        let cgImage = try await generator.image(at: time).image
        print("VideoConverter: Still image generated at time: \(time.seconds)")
        
        // --- 使用 ImageIO 框架写入带元数据的 HEIC 图片 ---
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.heic.identifier as CFString, 1, nil) else {
            print("VideoConverter Error: Failed to create image destination for HEIC.")
            return nil
        }

        // 检查并确保 CGImage 具有 ICC 颜色配置文件 (sRGB)
        var finalCGImage = cgImage
        if let colorSpace = cgImage.colorSpace {
            print("DEBUG: Original CGImage color space: \(colorSpace.name ?? "nil" as CFString)")
            if colorSpace.name != CGColorSpace.sRGB {
                print("DEBUG: Original CGImage color space is not sRGB, converting to sRGB.")
                if let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
                    if let newImage = cgImage.copy(colorSpace: sRGBColorSpace) {
                        finalCGImage = newImage
                        print("DEBUG: Successfully converted CGImage to sRGB color space.")
                    } else {
                        print("DEBUG: Failed to copy CGImage with sRGB color space. Using original.")
                    }
                } else {
                    print("DEBUG: Failed to create sRGB color space. Using original.")
                }
            }
        } else {
            print("DEBUG: Original CGImage has no color space, attempting to assign sRGB.")
            if let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
                if let newImage = cgImage.copy(colorSpace: sRGBColorSpace) {
                    finalCGImage = newImage
                    print("DEBUG: Successfully assigned sRGB color space to CGImage.")
                } else {
                    print("DEBUG: Failed to copy CGImage with sRGB color space. Using original.")
                }
            } else {
                print("DEBUG: Failed to create sRGB color space. Using original.")
            }
        }

        // --- 使用 kCGImagePropertyMakerAppleDictionary 和 kCGImagePropertyLivePhoto 键设置 Live Photo 元数据 ---
        let livePhotoDict: [String: Any] = [
            "ContentIdentifier": contentIdentifier,
            "StillImageTime": time.seconds
        ]
        let makerAppleDict: [String: Any] = [
            "17": contentIdentifier, // Key 17 for content identifier
            "LivePhoto": livePhotoDict
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: makerAppleDict,
            kCGImageDestinationLossyCompressionQuality: 0.8 // 压缩质量
        ]

        // 添加图片到目标 (使用处理后的 finalCGImage)
        CGImageDestinationAddImage(destination, finalCGImage, properties as CFDictionary)

        // 完成写入
        guard CGImageDestinationFinalize(destination) else {
            print("VideoConverter Error: Failed to finalize HEIC image data with metadata.")
            return nil
        }

        // 验证生成的数据
        let heicData = mutableData as Data
        guard heicData.count > 0 else {
            print("VideoConverter Error: Generated HEIC data is empty.")
            return nil
        }

        // 尝试创建 UIImage 来验证数据 (此验证有助于调试，暂时保留)
        guard let _ = UIImage(data: heicData) else {
            print("VideoConverter Error: Generated HEIC data is not a valid image.")
            return nil
        }

        print("VideoConverter: Still image converted to HEIC Data successfully with metadata. Size: \(heicData.count) bytes")
        return heicData
    }
    
    func saveToPhotos(url: URL) async throws {
        print("VideoConverter: saveToPhotos(url:) called with URL: \(url.absoluteString)")
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
        print("VideoConverter: Successfully saved to Photos: \(url.lastPathComponent)")
    }
    
    internal func extractVideoURL(from htmlString: String) -> String? {
        // 常见的视频URL模式
        let patterns = [
            #"<video[^>]*src=["']([^"]+)["']"#,  // HTML5 video标签
            #"<source[^>]*src=["']([^"]+)["']"#,  // HTML5 source标签
            #"video_url["']?\s*:\s*["']([^"]+)["']"#,  // JSON中的video_url
            #"playUrl["']?\s*:\s*["']([^"]+)["']"#,  // JSON中的playUrl
            #"url["']?\s*:\s*["']([^"]+)["']"#,  // JSON中的url
            #"https?://[^"]+\.(mp4|m4v|mov|webm)[^"]*"#  // 直接匹配视频文件URL
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(htmlString.startIndex..., in: htmlString)
                if let match = regex.firstMatch(in: htmlString, options: [], range: range) {
                    let matchRange = match.range(at: 1)
                    if let range = Range(matchRange, in: htmlString) {
                        let url = String(htmlString[range])
                        if url.hasPrefix("http") {
                            return url
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    private func createHEIFData(from images: [UIImage], audioTrack: AVAssetTrack, duration: Double) -> Data? {
        do {
            guard !images.isEmpty else {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "No available images"])
            }
            
            guard let mutableData = CFDataCreateMutable(nil, 0) else {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create data buffer"])
            }
            
            guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.heic.identifier as CFString, images.count, nil) else {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create image destination"])
            }
            
            let options: [String: Any] = [
                kCGImageDestinationLossyCompressionQuality as String: 0.8,
                kCGImageDestinationOptimizeColorForSharing as String: true,
                kCGImagePropertyHEICSDictionary as String: [
                    "ImageCount": images.count,
                    "LoopCount": 0,
                    "DelayTime": 1.0 / 30.0
                ]
            ]
            
            CGImageDestinationSetProperties(destination, options as CFDictionary)
            
            for image in images {
                if let cgImage = image.cgImage {
                    CGImageDestinationAddImage(destination, cgImage, nil)
                }
            }
            
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to complete HEIF data creation"])
            }
            
            return mutableData as Data
        } catch {
            print("Error in createHEIFData: \(error)")
            return nil
        }
    }

    // 新增方法：对于超过3秒的视频，先导出为临时文件，然后再处理
    private func exportAndProcessVideo(asset: AVAsset, exportTimeRange: CMTimeRange, imageCaptureTime: CMTime) async throws -> (photoData: Data, videoURL: URL) {
        print("VideoConverter: Using intermediate export for video longer than 3 seconds")
        
        // 创建临时文件URL
        let tempExportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        
        // 创建导出会话
        let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
        exportSession.outputURL = tempExportURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = exportTimeRange
        exportSession.shouldOptimizeForNetworkUse = false // 不需要网络优化
        
        print("VideoConverter: Starting export of video segment with duration: \(CMTimeGetSeconds(exportTimeRange.duration)) seconds")
        
        // 执行导出
        do {
            if #available(iOS 18.0, *) {
                try await exportSession.export(to: tempExportURL, as: .mp4)
            } else {
                // 使用旧版API
                exportSession.outputURL = tempExportURL
                exportSession.outputFileType = .mp4
                await exportSession.export()
                
                // 检查导出状态
                guard exportSession.status == AVAssetExportSession.Status.completed else {
                    throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to export video segment: \(exportSession.error?.localizedDescription ?? "Unknown error")"])
                }
            }
            print("VideoConverter: Successfully exported video segment to: \(tempExportURL.path)")
        } catch {
            print("VideoConverter Error: Failed to export video segment: \(error.localizedDescription)")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to export video segment: \(error.localizedDescription)"])
        }
        
        // 使用导出的临时文件创建新的 AVAsset
        let trimmedAsset = AVURLAsset(url: tempExportURL)
        
        // 获取新的时间范围
        let newDuration = try await trimmedAsset.load(.duration)
        let newImageCaptureTime = CMTime(seconds: newDuration.seconds / 2.0, preferredTimescale: 600)
        
        print("VideoConverter: Trimmed video duration: \(newDuration.seconds) seconds")
        print("VideoConverter: New image capture time: \(newImageCaptureTime.seconds)")
        
        // 使用常规方法处理这个新的、较短的视频
        return try await convertVideoToHEIF(from: tempExportURL)
    }
}

// MARK: - AVAsset Extension for frame count and still image time
extension AVAsset {
    func frameCount(exact: Bool = false) async throws -> Int {
        let videoTracks = try await loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { return 0 }
        
        if !exact {
            let duration = CMTimeGetSeconds(try await load(.duration))
            let nominalFrameRate = Float64(try await videoTrack.load(.nominalFrameRate))
            return Int(duration * nominalFrameRate)
        }
        
        let videoReader = try AVAssetReader(asset: self)
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoReader.add(videoReaderOutput)
        videoReader.startReading()
        
        var frameCount = 0
        while let _ = videoReaderOutput.copyNextSampleBuffer() {
            frameCount += 1
        }
        videoReader.cancelReading()
        return frameCount
    }
    
    func makeStillImageTimeRange(percent: Float, inFrameCount: Int = 0) async throws -> CMTimeRange {
        var time = try await load(.duration)
        var frameCount = inFrameCount
        if frameCount == 0 {
            frameCount = try await self.frameCount(exact: true)
        }
        
        let duration = Int64(Float(time.value) / Float(frameCount))
        time.value = Int64(Float(time.value) * percent)
        return CMTimeRange(start: time, duration: CMTime(value: duration, timescale: time.timescale))
    }
} 
