import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: ClipperSettings
    @State private var showFolderPicker = false
    @State private var resolvedPath: String = "Not set"

    var body: some View {
        NavigationStack {
            Form {
                // MARK: – Vault Configuration
                Section {
                    HStack {
                        Label("Vault Name", systemImage: "book.closed")
                        Spacer()
                        TextField("e.g. omniscient", text: $settings.vaultName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Label("Target Folder", systemImage: "folder")
                        Spacer()
                        TextField("e.g. Inbox", text: $settings.targetFolder)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Select Vault Folder", systemImage: "folder.badge.plus")
                    }

                    HStack {
                        Text("Vault Location")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(resolvedPath)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Vault")
                } footer: {
                    Text("Select the root folder of your Obsidian vault in iCloud Drive or On My iPhone. The target folder is created inside the vault if it doesn't exist.")
                }

                // MARK: – Clipping Options
                Section {
                    Toggle(isOn: $settings.includeFrontmatter) {
                        Label("YAML Frontmatter", systemImage: "doc.text")
                    }

                    Toggle(isOn: $settings.saveImages) {
                        Label("Save Images", systemImage: "photo.on.rectangle")
                    }

                    Toggle(isOn: $settings.enableOCR) {
                        Label("OCR on Images", systemImage: "text.viewfinder")
                    }
                } header: {
                    Text("Clipping Options")
                } footer: {
                    Text("When enabled, images found in the page are downloaded to an images/ subfolder. OCR extracts text from images and includes it in the note as a blockquote.")
                }

                // MARK: – How to Use
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        step(number: 1, text: "Open any webpage in Safari (or any app with Share)")
                        step(number: 2, text: "Tap the Share button")
                        step(number: 3, text: "Select \"Clip to Obsidian\"")
                        step(number: 4, text: "The article is converted to Markdown and saved to your vault")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("How to Use")
                }

                // MARK: – About
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Obsidian Clipper")
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { url in
                    settings.saveVaultBookmark(for: url)
                    refreshResolvedPath()
                }
            }
            .onAppear {
                refreshResolvedPath()
            }
        }
    }

    private func refreshResolvedPath() {
        if let resolved = settings.resolveVaultURL() {
            resolvedPath = resolved.url.lastPathComponent
        } else {
            resolvedPath = "Not set"
        }
    }

    @ViewBuilder
    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ClipperSettings())
}
