//
//  LPhotoApp.swift
//  LPhoto
//
//  Created by Sun Fan on 2025/6/10.
//

import SwiftUI
import AppIntents
import AVFoundation
import Photos

// Define shortcut types
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
                Button("New Project") {
                    appState.createNewProject()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    var appState: AppState!
    
    private func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.OpenURLOptionsKey: Any]? = nil) -> Bool {
        // Request photo library permission
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
                appState.errorMessage = "Processing failed: \(error.localizedDescription)"
            }
        }
        return true
    }
    
    private func handleShortcut(_ shortcut: Shortcut) {
        Task {
            do {
                switch shortcut {
                case .convertVideo(let videoURL):
                    print("Starting video conversion: \(videoURL)")
                    let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: videoURL)
                    try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                    print("Video conversion completed: \(videoURL.lastPathComponent)")
                    appState.showSuccess = true
                    appState.successMessage = "Video conversion successful"
                case .convertImage(let imageURL):
                    print("Starting image conversion: \(imageURL)")
                    let result = try await ImageConverter.shared.convertImageToHEIF(from: imageURL)
                    try await ImageConverter.shared.saveToPhotos(url: result)
                    print("Image conversion completed: \(result)")
                    appState.showSuccess = true
                    appState.successMessage = "Image conversion successful"
                }
            } catch {
                print("Error processing shortcut: \(error)")
                appState.showError = true
                appState.errorMessage = "Processing failed: \(error.localizedDescription)"
            }
        }
    }
    
    private func handleIncomingURL(_ url: URL) async throws {
        appState.createNewProject()
        
        if url.pathExtension.lowercased() == "mp4" {
            let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: url)
            try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
            appState.showSuccess = true
            appState.successMessage = "Video conversion successful"
        } else if ["jpg", "jpeg", "png", "gif"].contains(url.pathExtension.lowercased()) {
            let convertedURL: URL = try await ImageConverter.shared.convertImageToHEIF(from: url)
            try await ImageConverter.shared.saveToPhotos(url: convertedURL)
            appState.showSuccess = true
            appState.successMessage = "Image conversion successful"
        } else if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            // Try to download webpage content and extract video URL
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                appState.showError = true
                appState.errorMessage = "Unable to access webpage"
                throw NSError(domain: "LPhoto", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to access webpage"])
            }
            
            if let htmlString = String(data: data, encoding: .utf8), let videoURLString = VideoConverter.shared.extractVideoURL(from: htmlString), let videoURL = URL(string: videoURLString) {
                // Found video URL, try to convert
                let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: videoURL)
                try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                appState.showSuccess = true
                appState.successMessage = "Video conversion successful"
            } else if let mimeType = httpResponse.mimeType?.lowercased(), mimeType.contains("video") {
                // Direct video file, try to convert
                let (photoData, videoURL) = try await VideoConverter.shared.convertVideoToHEIF(from: url)
                try await VideoConverter.shared.saveLivePhoto(photoData: photoData, videoURL: videoURL)
                appState.showSuccess = true
                appState.successMessage = "Video conversion successful"
            } else {
                appState.showError = true
                appState.errorMessage = "Unsupported webpage content type or video not found"
                throw NSError(domain: "LPhoto", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported webpage content type or video not found"])
            }
        } else {
            appState.showError = true
            appState.errorMessage = "Unable to process URL type"
            throw NSError(domain: "LPhoto", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to process URL type"])
        }
    }
}

extension URLSession {
    // Removed synchronous method, because async/await is now allowed, prefer using native async methods
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
