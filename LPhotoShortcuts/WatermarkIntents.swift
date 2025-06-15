import Foundation
import AppIntents
import AVFoundation
import Photos
import UIKit

// MARK: - 添加45度平铺水印的意图

struct AddTiledWatermarkIntent: AppIntent {
    static var title: LocalizedStringResource = "添加45度平铺水印"
    static var description: LocalizedStringResource = "为视频添加45度角分布的半透明水印，防盗用。"
    
    @Parameter(title: "输入视频", description: "选择一个视频文件或从快捷指令传入媒体变量。", default: nil)
    var inputFile: IntentFile?
    
    @Parameter(title: "水印内容", description: "水印的文字内容。", default: "版权所有")
    var watermarkText: String
    
    @Parameter(title: "透明度", description: "水印的透明度，范围0.1-1.0。", default: 0.5)
    var opacity: Double
    
    func perform() async throws -> some IntentResult {
        print("AddTiledWatermarkIntent: perform() called")

        // 验证输入文件
        guard let inputFile = inputFile else {
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择文件或文件不可用。"])
        }

        // 限制透明度范围
        let finalOpacity = min(max(Float(opacity), 0.1), 1.0)
        
        // 准备临时文件
        var tempVideoURL: URL!
        var finalFileExtension: String!

        do {
            // 从输入获取视频数据
            var dataToProcess: Data?
            var tentativeExtension: String? = inputFile.fileURL?.pathExtension.lowercased()

            if let fileData = try? inputFile.data {
                dataToProcess = fileData
                finalFileExtension = tentativeExtension?.isEmpty ?? true ? "mp4" : tentativeExtension
                print("AddTiledWatermarkIntent: 直接处理输入文件数据。大小: \(dataToProcess?.count ?? 0) bytes")
            }
            else if let fileURL = inputFile.fileURL {
                let (data, response) = try await URLSession.shared.data(from: fileURL)
                dataToProcess = data
                finalFileExtension = fileURL.pathExtension.lowercased().isEmpty ? "mp4" : fileURL.pathExtension.lowercased()
                print("AddTiledWatermarkIntent: 已从原始URL下载视频数据。大小: \(dataToProcess?.count ?? 0) bytes")
            }
            else {
                throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取文件数据或URL。"])
            }

            // 确保有数据可写入
            guard let data = dataToProcess else {
                throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "处理后没有可用的视频数据。"])
            }

            // 写入临时文件
            let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            let tempFileName = UUID().uuidString + "." + (finalFileExtension ?? "mp4")
            tempVideoURL = tempDirectory.appendingPathComponent(tempFileName)

            try data.write(to: tempVideoURL)
            print("AddTiledWatermarkIntent: 成功将处理后的数据写入临时URL: \(tempVideoURL.path)")

        } catch {
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "准备输入文件失败: \(error.localizedDescription)"])
        }

        // 验证文件
        if !FileManager.default.fileExists(atPath: tempVideoURL.path) {
            print("AddTiledWatermarkIntent Error: 本地文件不存在: \(tempVideoURL.path)")
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "本地文件不存在: \(tempVideoURL.path)"])
        }
        
        let supportedExtensions = ["mp4", "mov", "m4v"]
        guard supportedExtensions.contains(finalFileExtension) else {
            print("AddTiledWatermarkIntent Error: 不支持的文件类型: \(finalFileExtension ?? "unknown")")
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的文件类型: \(finalFileExtension ?? "unknown")"])
        }
        
        // 添加水印
        print("AddTiledWatermarkIntent: 开始添加45度平铺水印到视频: \(tempVideoURL.lastPathComponent)")
        let resultURL = try await WatermarkConverter.shared.addTiledWatermark(to: tempVideoURL, text: watermarkText, opacity: finalOpacity)
        
        // 保存到相册
        try await WatermarkConverter.shared.saveToPhotos(url: resultURL)
        print("AddTiledWatermarkIntent: 视频已成功添加45度平铺水印并保存到相册")
        
        // 清理临时文件
        if tempVideoURL.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: tempVideoURL)
        }
        if resultURL.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: resultURL)
        }
        
        return .result()
    }
}

// MARK: - 添加右上角水印的意图

struct AddCornerWatermarkIntent: AppIntent {
    static var title: LocalizedStringResource = "添加右上角水印"
    static var description: LocalizedStringResource = "为视频添加右上角自定义水印。"
    
    @Parameter(title: "输入视频", description: "选择一个视频文件或从快捷指令传入媒体变量。", default: nil)
    var inputFile: IntentFile?
    
    @Parameter(title: "水印内容", description: "水印的文字内容。", default: "版权所有")
    var watermarkText: String
    
    @Parameter(title: "透明度", description: "水印的透明度，范围0.1-1.0。", default: 0.7)
    var opacity: Double
    
    func perform() async throws -> some IntentResult {
        print("AddCornerWatermarkIntent: perform() called")

        // 验证输入文件
        guard let inputFile = inputFile else {
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择文件或文件不可用。"])
        }

        // 限制透明度范围
        let finalOpacity = min(max(Float(opacity), 0.1), 1.0)
        
        // 准备临时文件
        var tempVideoURL: URL!
        var finalFileExtension: String!

        do {
            // 从输入获取视频数据
            var dataToProcess: Data?
            var tentativeExtension: String? = inputFile.fileURL?.pathExtension.lowercased()

            if let fileData = try? inputFile.data {
                dataToProcess = fileData
                finalFileExtension = tentativeExtension?.isEmpty ?? true ? "mp4" : tentativeExtension
                print("AddCornerWatermarkIntent: 直接处理输入文件数据。大小: \(dataToProcess?.count ?? 0) bytes")
            }
            else if let fileURL = inputFile.fileURL {
                let (data, response) = try await URLSession.shared.data(from: fileURL)
                dataToProcess = data
                finalFileExtension = fileURL.pathExtension.lowercased().isEmpty ? "mp4" : fileURL.pathExtension.lowercased()
                print("AddCornerWatermarkIntent: 已从原始URL下载视频数据。大小: \(dataToProcess?.count ?? 0) bytes")
            }
            else {
                throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取文件数据或URL。"])
            }

            // 确保有数据可写入
            guard let data = dataToProcess else {
                throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "处理后没有可用的视频数据。"])
            }

            // 写入临时文件
            let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            let tempFileName = UUID().uuidString + "." + (finalFileExtension ?? "mp4")
            tempVideoURL = tempDirectory.appendingPathComponent(tempFileName)

            try data.write(to: tempVideoURL)
            print("AddCornerWatermarkIntent: 成功将处理后的数据写入临时URL: \(tempVideoURL.path)")

        } catch {
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "准备输入文件失败: \(error.localizedDescription)"])
        }

        // 验证文件
        if !FileManager.default.fileExists(atPath: tempVideoURL.path) {
            print("AddCornerWatermarkIntent Error: 本地文件不存在: \(tempVideoURL.path)")
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "本地文件不存在: \(tempVideoURL.path)"])
        }
        
        let supportedExtensions = ["mp4", "mov", "m4v"]
        guard supportedExtensions.contains(finalFileExtension) else {
            print("AddCornerWatermarkIntent Error: 不支持的文件类型: \(finalFileExtension ?? "unknown")")
            throw NSError(domain: "Watermark", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的文件类型: \(finalFileExtension ?? "unknown")"])
        }
        
        // 添加水印
        print("AddCornerWatermarkIntent: 开始添加右上角水印到视频: \(tempVideoURL.lastPathComponent)")
        let resultURL = try await WatermarkConverter.shared.addCornerWatermark(to: tempVideoURL, text: watermarkText, opacity: finalOpacity)
        
        // 保存到相册
        try await WatermarkConverter.shared.saveToPhotos(url: resultURL)
        print("AddCornerWatermarkIntent: 视频已成功添加右上角水印并保存到相册")
        
        // 清理临时文件
        if tempVideoURL.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: tempVideoURL)
        }
        if resultURL.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: resultURL)
        }
        
        return .result()
    }
} 