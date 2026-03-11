import SwiftUI

// Legacy shim — all tokens now live in DesignSystem.swift (DS enum).
// This file only exists to keep the single remaining call-site compiling
// until every view has been migrated to the DS button styles.

extension View {
    func styleMateSecondaryButton() -> some View {
        self.buttonStyle(DSSecondaryButton())
    }
}
