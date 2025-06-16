import Foundation
import UIKit
import Photos

class ImageConverter {
    static let shared = ImageConverter()
    
    private init() {}
    
    func convertImageToHEIF(from imageURL: URL) async throws -> URL {
        // 读取图片数据
        let imageData = try Data(contentsOf: imageURL)
        guard let image = UIImage(data: imageData) else {
            throw NSError(domain: "ImageConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to read image data"])
        }
        
        // 创建临时文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        
        // 转换图片为HEIF格式
        guard let heifData = image.heifData(compressionQuality: 0.8) else {
            throw NSError(domain: "ImageConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to convert image to HEIF format"])
        }
        
        // 保存到临时文件
        try heifData.write(to: tempURL)
        
        return tempURL
    }
    
    func saveToPhotos(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

extension UIImage {
    func heifData(compressionQuality: CGFloat) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0) else { return nil }
        
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        
        let options = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
            kCGImageDestinationOptimizeColorForSharing: true
        ] as CFDictionary
        
        guard let cgImage = self.cgImage else { return nil }
        CGImageDestinationAddImage(destination, cgImage, options)
        
        guard CGImageDestinationFinalize(destination) else { return nil }
        
        return mutableData as Data
    }
} 