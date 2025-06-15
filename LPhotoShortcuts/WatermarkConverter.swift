import Foundation
import UIKit
import AVFoundation
import Photos

class WatermarkConverter {
    static let shared = WatermarkConverter()
    
    private init() {}
    
    // MARK: - 45度分布水印
    
    /// 为视频添加45度透明平铺水印
    /// - Parameters:
    ///   - videoURL: 输入视频URL
    ///   - watermarkText: 水印文本内容
    ///   - opacity: 水印透明度，范围0.0-1.0
    /// - Returns: 添加水印后的视频URL
    func addTiledWatermark(to videoURL: URL, text watermarkText: String, opacity: Float) async throws -> URL {
        print("WatermarkConverter: addTiledWatermark(to: \(videoURL.lastPathComponent), text: \(watermarkText), opacity: \(opacity))")
        
        // 1. 加载视频资源
        let asset = AVURLAsset(url: videoURL)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        
        guard let videoTrack = videoTrack else {
            throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到视频轨道"])
        }
        
        // 2. 获取视频尺寸
        let videoSize = try await videoTrack.load(.naturalSize)
        let videoTransform = try await videoTrack.load(.preferredTransform)
        let fixedVideoSize = videoSize.applying(videoTransform)
        let actualVideoSize = CGSize(width: abs(fixedVideoSize.width), height: abs(fixedVideoSize.height))
        print("WatermarkConverter: 视频尺寸: \(actualVideoSize)")
        
        // 3. 创建临时输出文件
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        
        // 4. 设置视频合成器
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 30 fps
        videoComposition.renderSize = actualVideoSize
        
        // 5. 添加视频轨道
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建合成视频轨道"])
        }
        
        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        
        // 6. 添加音频轨道（如果存在）
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建合成音频轨道"])
            }
            
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }
        
        // 7. 设置视频输出指令
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(videoTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        
        // 8. 设置动态水印渲染器
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: { layer in
                return self.createTiledWatermarkLayer(layer: layer, watermarkText: watermarkText, opacity: opacity, videoSize: actualVideoSize)
            },
            postProcessingAsVideoComposition: nil
        )
        
        videoComposition.instructions = [instruction]
        
        // 9. 导出处理后的视频
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        guard let exporter = exporter else {
            throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建视频导出会话"])
        }
        
        exporter.videoComposition = videoComposition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        
        await exporter.export()
        
        if let error = exporter.error {
            print("WatermarkConverter: 视频导出错误: \(error)")
            throw error
        }
        
        print("WatermarkConverter: 成功添加45度水印并导出到: \(outputURL.lastPathComponent)")
        return outputURL
    }
    
    // 创建45度平铺水印图层
    private func createTiledWatermarkLayer(layer: CALayer, watermarkText: String, opacity: Float, videoSize: CGSize) -> CALayer {
        // 设置主视频图层
        layer.frame = CGRect(origin: .zero, size: videoSize)
        
        // 创建包含所有水印的容器图层
        let watermarkContainer = CALayer()
        watermarkContainer.frame = layer.bounds
        
        // 确定水印尺寸和间距
        let watermarkHeight = videoSize.height / 10
        let fontSize = watermarkHeight * 0.7
        let spacing = watermarkHeight * 2
        
        // 计算需要多少行和列来覆盖整个视频
        let diagonalLength = sqrt(pow(videoSize.width, 2) + pow(videoSize.height, 2))
        let numRows = Int(diagonalLength / spacing) + 2
        
        // 计算起始点，确保整个视频都能被水印覆盖
        let startX = -diagonalLength / 2
        let startY = -diagonalLength / 2
        
        // 创建45度角的水印
        for row in 0..<numRows {
            // 沿着45度角方向放置水印
            let x = startX + CGFloat(row) * spacing
            let y = startY + CGFloat(row) * spacing
            
            // 创建一条对角线的水印
            for i in 0...Int((diagonalLength*2) / spacing) {
                let textLayer = CATextLayer()
                textLayer.string = watermarkText
                textLayer.font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
                textLayer.fontSize = fontSize
                textLayer.alignmentMode = .center
                textLayer.foregroundColor = UIColor.white.cgColor
                textLayer.opacity = opacity
                
                // 计算此水印的位置
                let posX = x + CGFloat(i) * spacing
                let posY = y - CGFloat(i) * spacing
                
                let textSize = (watermarkText as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fontSize)])
                textLayer.frame = CGRect(
                    x: posX,
                    y: posY,
                    width: textSize.width + 20,
                    height: textSize.height + 10
                )
                
                // 旋转文本45度
                textLayer.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
                
                // 只添加位于视频区域内的水印
                if CGRect(origin: .zero, size: videoSize).intersects(textLayer.frame) {
                    watermarkContainer.addSublayer(textLayer)
                }
            }
        }
        
        layer.addSublayer(watermarkContainer)
        return layer
    }
    
    // MARK: - 右上角水印
    
    /// 为视频添加右上角自定义水印
    /// - Parameters:
    ///   - videoURL: 输入视频URL
    ///   - watermarkText: 水印文本内容
    ///   - opacity: 水印透明度，范围0.0-1.0
    /// - Returns: 添加水印后的视频URL
    func addCornerWatermark(to videoURL: URL, text watermarkText: String, opacity: Float) async throws -> URL {
        print("WatermarkConverter: addCornerWatermark(to: \(videoURL.lastPathComponent), text: \(watermarkText), opacity: \(opacity))")
        
        // 1. 加载视频资源
        let asset = AVURLAsset(url: videoURL)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        
        guard let videoTrack = videoTrack else {
            throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到视频轨道"])
        }
        
        // 2. 获取视频尺寸
        let videoSize = try await videoTrack.load(.naturalSize)
        let videoTransform = try await videoTrack.load(.preferredTransform)
        let fixedVideoSize = videoSize.applying(videoTransform)
        let actualVideoSize = CGSize(width: abs(fixedVideoSize.width), height: abs(fixedVideoSize.height))
        print("WatermarkConverter: 视频尺寸: \(actualVideoSize)")
        
        // 3. 创建临时输出文件
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        
        // 4. 设置视频合成器
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 30 fps
        videoComposition.renderSize = actualVideoSize
        
        // 5. 添加视频轨道
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建合成视频轨道"])
        }
        
        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        
        // 6. 添加音频轨道（如果存在）
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建合成音频轨道"])
            }
            
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }
        
        // 7. 设置视频输出指令
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(videoTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        
        // 8. 设置右上角水印渲染器
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: { layer in
                return self.createCornerWatermarkLayer(layer: layer, watermarkText: watermarkText, opacity: opacity, videoSize: actualVideoSize)
            },
            postProcessingAsVideoComposition: nil
        )
        
        videoComposition.instructions = [instruction]
        
        // 9. 导出处理后的视频
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        guard let exporter = exporter else {
            throw NSError(domain: "WatermarkConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建视频导出会话"])
        }
        
        exporter.videoComposition = videoComposition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        
        await exporter.export()
        
        if let error = exporter.error {
            print("WatermarkConverter: 视频导出错误: \(error)")
            throw error
        }
        
        print("WatermarkConverter: 成功添加右上角水印并导出到: \(outputURL.lastPathComponent)")
        return outputURL
    }
    
    // 创建右上角水印图层
    private func createCornerWatermarkLayer(layer: CALayer, watermarkText: String, opacity: Float, videoSize: CGSize) -> CALayer {
        // 设置主视频图层
        layer.frame = CGRect(origin: .zero, size: videoSize)
        
        // 创建水印文本图层
        let textLayer = CATextLayer()
        textLayer.string = watermarkText
        
        // 计算适当的字体大小（基于视频宽度）
        let fontSize = videoSize.width * 0.05
        textLayer.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        textLayer.fontSize = fontSize
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.opacity = opacity
        
        // 计算水印大小
        let textSize = (watermarkText as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fontSize)])
        
        // 添加背景使文字更清晰
        let backgroundLayer = CALayer()
        backgroundLayer.backgroundColor = UIColor.black.withAlphaComponent(0.4).cgColor
        backgroundLayer.cornerRadius = 5
        
        // 设置水印位置（右上角，添加一些边距）
        let margin: CGFloat = 20
        let padding: CGFloat = 10
        backgroundLayer.frame = CGRect(
            x: videoSize.width - textSize.width - margin - (padding * 2),
            y: margin,
            width: textSize.width + (padding * 2),
            height: textSize.height + padding
        )
        
        textLayer.frame = CGRect(
            x: videoSize.width - textSize.width - margin - padding,
            y: margin + (padding / 2),
            width: textSize.width,
            height: textSize.height
        )
        
        // 添加阴影效果
        textLayer.shadowOpacity = 0.8
        textLayer.shadowOffset = CGSize(width: 1, height: 1)
        textLayer.shadowRadius = 2
        
        layer.addSublayer(backgroundLayer)
        layer.addSublayer(textLayer)
        return layer
    }
    
    // MARK: - 保存到照片库
    
    func saveToPhotos(url: URL) async throws {
        print("WatermarkConverter: saveToPhotos(url:) called with URL: \(url.absoluteString)")
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
        print("WatermarkConverter: Successfully saved to Photos: \(url.lastPathComponent)")
    }
} 