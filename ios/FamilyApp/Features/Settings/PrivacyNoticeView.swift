import SwiftUI

/// The privacy notice (GDPR art. 13), shown at sign-up and in Settings. Keep it in step with docs/10-gdpr.md.
struct PrivacyNoticeView: View {
    private static let sections = ["who", "what", "access", "where", "sharing", "rights", "keep", "children"]

    var body: some View {
        List {
            ForEach(Self.sections, id: \.self) { id in
                Section(LocalizedStringKey("privacy.notice." + id + ".title")) {
                    Text(LocalizedStringKey("privacy.notice." + id + ".body"))
                }
            }
            Section { Text("privacy.notice.updated").foregroundStyle(.secondary) }
        }
        .navigationTitle("privacy.notice.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}
