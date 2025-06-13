import SwiftUI

class AppState: ObservableObject {
    @Published var showSuccess = false
    @Published var successMessage = ""
    @Published var showError = false
    @Published var errorMessage = ""
    
    func createNewProject() {
        // Reset all states
        showSuccess = false
        successMessage = ""
        showError = false
        errorMessage = ""
    }
}

struct Project {
    var id = UUID()
    var name: String = "New Project"
    var createdAt = Date()
} 