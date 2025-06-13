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

        let asset = AVAsset(url: videoURL)
        
        // 检查资源是否可导出
        let isExportable = try await asset.load(.isExportable)
        guard isExportable else {
            print("VideoConverter Error: Video asset is not exportable: \(videoURL.absoluteString)")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "视频资源不可导出"])
        }
        
        // 获取视频轨道
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            print("VideoConverter Error: No video track found in asset")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到视频轨道"])
        }
        
        // 获取音频轨道
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let videoSize = try await videoTrack.load(.naturalSize)
        print("VideoConverter: Video natural size: \(videoSize)")
        
        let duration = try await asset.load(.duration)
        print("VideoConverter: Video duration: \(duration.seconds) seconds")
        
        let preferredDuration = CMTime(seconds: 3.0, preferredTimescale: 600)
        let exportTimeRange: CMTimeRange
        let imageCaptureTime: CMTime
        
        if duration > preferredDuration {
            let startOffset = CMTime(seconds: (duration.seconds - preferredDuration.seconds) / 2.0, preferredTimescale: 600)
            exportTimeRange = CMTimeRange(start: startOffset, duration: preferredDuration)
            imageCaptureTime = CMTime(seconds: exportTimeRange.start.seconds + preferredDuration.seconds / 2.0, preferredTimescale: 600)
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
        let videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = try await videoTrack.load(.preferredTransform)
        assetWriter.add(videoWriterInput)

        // 音频输入
        let audioWriterInputOpt: AVAssetWriterInput?
        if audioTrack != nil {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ]
            let newAudioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
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

        // 写入静态图片时间元数据
        let frameCount = try await asset.frameCount(exact: false) // Using non-exact for performance
        let stillImagePercent = Float(imageCaptureTime.seconds / duration.seconds)
        await stillImageTimeAdaptor.append(
            AVTimedMetadataGroup(
                items: [stillImageTimeMetadataItem()],
                timeRange: try asset.makeStillImageTimeRange(percent: stillImagePercent, inFrameCount: frameCount)
            )
        )
        
        // 创建 Asset Reader 读取器
        let assetReader = try AVAssetReader(asset: asset)
        assetReader.timeRange = exportTimeRange // 设置读取范围与导出范围一致

        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ])
        videoReaderOutput.alwaysCopiesSampleData = false // Changed to false for better performance
        assetReader.add(videoReaderOutput)

        let audioReaderOutputOpt: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let newAudioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            newAudioReaderOutput.alwaysCopiesSampleData = false // Changed to false for better performance
            assetReader.add(newAudioReaderOutput)
            audioReaderOutputOpt = newAudioReaderOutput
        } else {
            audioReaderOutputOpt = nil
        }

        // 开始读取
        assetReader.startReading()

        // 并行写入视频和音频数据
        async let videoWritingFinished: Bool = withCheckedThrowingContinuation { continuation in
            videoWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoWriterInputQueue")) {
                while videoWriterInput.isReadyForMoreMediaData {
                    if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() {
                        if !videoWriterInput.append(sampleBuffer) {
                            print("VideoConverter Error: Failed to append video sample buffer.")
                            assetReader.cancelReading()
                            continuation.resume(throwing: NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "写入视频样本缓冲区失败"]))
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
                            continuation.resume(throwing: NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "写入音频样本缓冲区失败"]))
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
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "视频或音频写入失败"])
        }
        
        // 结束写入会话
        assetWriter.endSession(atSourceTime: exportTimeRange.end) // 使用导出范围的结束时间
        await assetWriter.finishWriting()

        guard assetWriter.status == .completed else {
            print("VideoConverter Error: AVAssetWriter failed with status: \(assetWriter.status.rawValue), error: \(assetWriter.error?.localizedDescription ?? "Unknown")")
            throw assetWriter.error ?? NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "视频写入失败"])
        }

        print("VideoConverter: Video export completed successfully for Live Photo paired video using AVAssetWriter.")

        // 提取静态图片，并传入视频尺寸以确保分辨率一致，并指定关键帧时间
        guard let photoData = try await generateStillImage(from: tempVideoURL, at: imageCaptureTime, size: videoSize, contentIdentifier: livePhotoUUID) else {
            print("VideoConverter Error: Failed to generate still image for Live Photo.")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法生成Live Photo静态图片"])
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
        print("VideoConverter: saveLivePhoto(photoData:, videoURL:) called.")
        
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            print("VideoConverter Error: Video file does not exist at path: \(videoURL.path)")
            throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "视频文件不存在"])
        }
        
        // 检查视频文件大小
        let videoAttributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        let videoSize = videoAttributes[.size] as? UInt64 ?? 0
        print("VideoConverter: Video file size: \(videoSize) bytes")
        
        // 检查图片数据大小
        print("VideoConverter: Photo data size: \(photoData.count) bytes")
        
        // 执行保存操作
        print("VideoConverter: Performing changes...")
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // 创建 Live Photo 资源
                let creationRequest = PHAssetCreationRequest.forAsset()
                
                // 设置创建日期
                creationRequest.creationDate = Date()
                
                // 添加图片资源
                print("VideoConverter: Adding photo resource...")
                creationRequest.addResource(with: .photo, data: photoData, options: nil)
                
                // 添加视频资源
                print("VideoConverter: Adding video resource...")
                creationRequest.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            }
            print("VideoConverter: PHPhotoLibrary.performChanges completed successfully.")
            // 只有成功保存后才清理临时文件
            try? FileManager.default.removeItem(at: videoURL)
        } catch {
            print("VideoConverter Error: PHPhotoLibrary.performChanges failed with error: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("VideoConverter Error Details:")
                print("  - Domain: \(nsError.domain)")
                print("  - Code: \(nsError.code)")
                print("  - Description: \(nsError.localizedDescription)")
                print("  - User Info: \(nsError.userInfo)")
            }
            throw error // 重新抛出错误以便上层调用者处理
        }
    }
    
    // 辅助方法：从视频中生成静态图片
    private func generateStillImage(from videoURL: URL, at time: CMTime, size: CGSize, contentIdentifier: String) async throws -> Data? {
        print("VideoConverter: generateStillImage(from:at:size:contentIdentifier:) called for video: \(videoURL.absoluteString) with size: \(size), contentIdentifier: \(contentIdentifier)")
        
        let asset = AVAsset(url: videoURL)
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
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有可用的图像"])
            }
            
            guard let mutableData = CFDataCreateMutable(nil, 0) else {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建数据缓冲区"])
            }
            
            guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.heic.identifier as CFString, images.count, nil) else {
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建图像目标"])
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
                throw NSError(domain: "VideoConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法完成HEIF数据创建"])
            }
            
            return mutableData as Data
        } catch {
            print("Error in createHEIFData: \(error)")
            return nil
        }
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
