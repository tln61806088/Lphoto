import SwiftUI

class AppState: ObservableObject {
    @Published var showSuccess = false
    @Published var successMessage = ""
    @Published var showError = false
    @Published var errorMessage = ""
    
    func createNewProject() {
        // 重置所有状态
        showSuccess = false
        successMessage = ""
        showError = false
        errorMessage = ""
    }
}

struct Project {
    var id = UUID()
    var name: String = "新项目"
    var createdAt = Date()
} 