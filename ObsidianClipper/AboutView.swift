import SwiftUI

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.system(size: 48))
                        .foregroundStyle(.accent)
                    Text("Obsidian Clipper")
                        .font(.title2.bold())
                    Text("v1.0")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("About") {
                Text("Clip any webpage to your Obsidian vault as a clean Markdown note. Images are extracted, OCR is performed using Apple Vision, and everything is saved to your chosen vault folder.")
                    .font(.subheadline)
            }

            Section("Credits") {
                LabeledContent("HTML → Markdown") {
                    Text("NSAttributedString + native Swift")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("OCR") {
                    Text("Apple Vision Framework")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("File Access") {
                    Text("Security-Scoped Bookmarks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com")!) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
