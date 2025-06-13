//
//  ContentView.swift
//  LPhoto
//
//  Created by Sun Fan on 2025/6/10.
//

import SwiftUI
import Photos
import Network

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var networkStatus = "Checking..."
    @State private var photosStatus = "Checking..."
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack {
                Spacer()
                
                Image("LPhotoIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .padding(.bottom, 20)
                
                Text("A powerful Shortcuts companion app that extends functionality and provides secure encryption for sensitive data.")
                    .foregroundColor(.white)
                    .font(.system(size: 20, weight: .light))
                    .multilineTextAlignment(.center)
                    .padding()
                
                Spacer()
                
                // Permission status display
                VStack(spacing: 10) {
                    HStack(alignment: .center) {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .foregroundColor(.white)
                                .frame(width: 20)
                            Text("Network")
                                .foregroundColor(.white)
                        }
                        .frame(width: 100, alignment: .leading)
                        
                        Text("  \(networkStatus)")
                            .foregroundColor(networkStatus == "●" ? .green : .red)
                    }
                    .frame(width: 200)
                    
                    HStack(alignment: .center) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .foregroundColor(.white)
                                .frame(width: 20)
                            Text("Photos")
                                .foregroundColor(.white)
                        }
                        .frame(width: 100, alignment: .leading)
                        
                        Text("  \(photosStatus)")
                            .foregroundColor(photosStatus == "●" ? .green : .red)
                    }
                    .frame(width: 200)
                }
                .padding(.bottom, 20)
            }
        }
        .alert("Success", isPresented: $appState.showSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.successMessage)
        }
        .alert("Error", isPresented: $appState.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.errorMessage)
        }
        .onAppear {
            checkPermissions()
        }
    }
    
    private func checkPermissions() {
        // Check network permission
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                if path.status == .satisfied {
                    networkStatus = "●" // Green circle
                } else {
                    networkStatus = "●" // Red circle
                }
            }
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
        
        // Check photo permission
        PHPhotoLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    photosStatus = "●" // Green circle
                case .denied, .restricted:
                    photosStatus = "●" // Red circle
                case .notDetermined:
                    photosStatus = "●" // Red circle
                case .limited:
                    photosStatus = "●" // Red circle
                @unknown default:
                    photosStatus = "●" // Red circle
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
