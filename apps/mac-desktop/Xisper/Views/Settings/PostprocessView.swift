import SwiftUI

struct PostprocessView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: NSLocalizedString("AI Post-processing", comment: ""))

            HStack(alignment: .top) {
                SettingRow(NSLocalizedString("Automatic Refinement", comment: ""), description: NSLocalizedString("After recognition, text is automatically refined by Xisper's AI. No API key needed.", comment: ""))
                Spacer()
            }
            .padding(.vertical, DesignSpacing.xxxs)
        }
        .sectionStyle()
    }
}
