//
//  LPhotoApp.swift
//  LPhoto
//
//  Created by 孙凡 on 2025/6/10.
//

import SwiftUI
import AppIntents
import AVFoundation
import Photos

// 定义快捷指令类型
enum Shortcut {
    case convertVideo(URL)
    case convertImage(URL)
}

@main
struct LPhotoApp: App {
    @StateObject private var appState = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)
        appDelegate.appState = appState
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建项目") {
                    appState.createNewProject()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    var appState: AppState!
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.OpenURLOptionsKey: Any]? = nil) -> Bool {
        // 请求照片库权限
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            switch status {
            case .authorized, .limited:
                print("Photo Library access granted: \(status)")
            case .denied, .restricted:
                print("Photo Library access denied: \(status)")
            case .notDetermined:
                print("Photo Library access not determined.")
            @unknown default:
                print("Unknown Photo Library authorization status.")
            }
        }
        return true
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        Task {
            do {
                try await handleIncomingURL(url)
            } catch {
                appState.showError = true
                appState.errorMessage = "处理失败: \(error.localizedDescription)"
            }
        }
        return true
    }
    
    private func handleShortcut(_ shortcut: Shortcut) {
        Task {
            do {
                switch shortcut {
                case .convertVideo(let videoURL):
                    print("开始处理视频转换: \(videoURL)")
                    let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: videoURL)
                    try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                    print("视频转换完成: \(videoURL.lastPathComponent)")
                    appState.showSuccess = true
                    appState.successMessage = "视频转换成功"
                case .convertImage(let imageURL):
                    print("开始处理图片转换: \(imageURL)")
                    let result = try await ImageConverter.shared.convertImageToHEIF(from: imageURL)
                    try await ImageConverter.shared.saveToPhotos(url: result)
                    print("图片转换完成: \(result)")
                    appState.showSuccess = true
                    appState.successMessage = "图片转换成功"
                }
            } catch {
                print("处理快捷指令时出错: \(error)")
                appState.showError = true
                appState.errorMessage = "处理失败: \(error.localizedDescription)"
            }
        }
    }
    
    private func handleIncomingURL(_ url: URL) async throws {
        appState.createNewProject()
        
        if url.pathExtension.lowercased() == "mp4" {
            let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: url)
            try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
            appState.showSuccess = true
            appState.successMessage = "视频转换成功"
        } else if ["jpg", "jpeg", "png", "gif"].contains(url.pathExtension.lowercased()) {
            let convertedURL: URL = try await ImageConverter.shared.convertImageToHEIF(from: url)
            try await ImageConverter.shared.saveToPhotos(url: convertedURL)
            appState.showSuccess = true
            appState.successMessage = "图片转换成功"
        } else if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            // 尝试下载网页内容并提取视频URL
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                appState.showError = true
                appState.errorMessage = "无法访问网页"
                throw NSError(domain: "LPhoto", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法访问网页"])
            }
            
            if let htmlString = String(data: data, encoding: .utf8), let videoURLString = VideoConverter.shared.extractVideoURL(from: htmlString), let videoURL = URL(string: videoURLString) {
                // 找到视频URL，尝试转换
                let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: videoURL)
                try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                appState.showSuccess = true
                appState.successMessage = "视频转换成功"
            } else if let mimeType = httpResponse.mimeType?.lowercased(), mimeType.contains("video") {
                // 直接是视频文件，尝试转换
                let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: url)
                try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                appState.showSuccess = true
                appState.successMessage = "视频转换成功"
            } else {
                appState.showError = true
                appState.errorMessage = "不支持的网页内容类型或未找到视频"
                throw NSError(domain: "LPhoto", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的网页内容类型或未找到视频"])
            }
        } else {
            appState.showError = true
            appState.errorMessage = "无法处理的URL类型"
            throw NSError(domain: "LPhoto", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法处理的URL类型"])
        }
    }
}

extension URLSession {
    // 移除了同步方法，因为现在允许await了，优先使用原生async方法
    // func synchronousDataTask(with request: URLRequest) throws -> (Data, URLResponse) { ... }
}

extension URL {
    var queryParameters: [String: String]? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else { return nil }
        
        var parameters = [String: String]()
        for item in queryItems {
            parameters[item.name] = item.value
        }
        
        return parameters
    }
}
