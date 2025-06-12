//
//  LPhotoShortcuts.swift
//  LPhotoShortcuts
//
//  Created by 孙凡 on 2025/6/11.
//

import AppIntents

struct LPhotoShortcuts: AppIntent {
    static var title: LocalizedStringResource { "LPhotoShortcuts" }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}
