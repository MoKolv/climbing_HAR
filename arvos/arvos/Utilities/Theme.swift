//
//  Theme.swift
//  arvos
//
//  App-wide theme - clean Apple design
//

import SwiftUI

struct Theme {
    // MARK: - Corner Radius

    static let cornerRadius: CGFloat = 8
    static let largeCornerRadius: CGFloat = 12
    static let buttonCornerRadius: CGFloat = 14 // For primary buttons

    // MARK: - Colors (Avoiding System Blue)

    static let accent = Color(red: 0.2, green: 0.2, blue: 0.2) // Neutral dark
    static let accentLight = Color(red: 0.4, green: 0.4, blue: 0.4)
    static let success = Color(red: 0.2, green: 0.78, blue: 0.35) // Green
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.23) // Red
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(isDestructive ? Theme.recording : Theme.accent)
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
