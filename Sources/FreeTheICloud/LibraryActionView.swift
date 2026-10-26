import SwiftUI
import AppKit
import FreeTheICloudCore

struct LibraryActionDraft: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let export: ExportResult?
    var photoExport: PhotoExportResult? = nil
    var singleItemDeletion = false
    var replacing: Bool { export != nil || photoExport != nil }
}

struct LibraryActionView: View {
    let draft: LibraryActionDraft
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var reviewed = false
    @ViewState private var includeProtected = false
    private var protectedCount: Int { draft.items.filter(\.protected).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.replacing ? (draft.photoExport == nil ? "Replace original video?" : "Replace original photo?") : (draft.items.count == 1 ? "Delete this \(draft.items.first?.kind == .video ? "video" : "photo") from Photos?" : "Delete \(draft.items.count) items from Photos?"))
                .font(.title2)
            if !draft.replacing {
                Text(Format.mediaCounts(draft.items)).font(.headline)
                Text(draft.singleItemDeletion ? "Only this item will be deleted. Other marked items stay unchanged." : "Only the items listed below will be deleted. Queuing a video for export does not select it for deletion.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(draft.items) { item in
                        HStack {
                            Thumbnail(item: item, fit: true).frame(width: 72, height: 50)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).lineLimit(2)
                                Text("\(item.kind == .video ? "Video" : "Photo") · \(Format.bytes(item.bytes))\(item.protected ? " · Protected" : "")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }.frame(height: min(260, CGFloat(draft.items.count) * 64))
            if let export = draft.export {
                Text("Compressed copy: \(Format.bytes(export.outputBytes)) · \(Format.bytes(export.savings)) smaller").font(.headline)
            }
            if let photo = draft.photoExport {
                HStack {
                    Text("\(photo.width) × \(photo.height) · \(Format.bytes(photo.savings)) smaller").font(.headline)
                    Spacer()
                    Button("Open copy to review") { NSWorkspace.shared.open(photo.output) }
                }
                Text("The full-resolution original will be deleted. Depth data\(photo.hdr ? " and the original HDR gain-map representation" : "") are not preserved.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if draft.replacing {
                Text("The copy becomes a new Photos item. Capture date, location, favorite status and regular albums are carried over. Captions and other Photos-only metadata may be lost.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(draft.photoExport == nil ? "I visually reviewed the full compressed video" : "I visually reviewed this resized photo", isOn: $reviewed)
            } else if protectedCount > 0 {
                Toggle(protectedCount == 1 ? "Include the protected item" : "Include \(protectedCount) protected items", isOn: $includeProtected)
                    .help("These include favorites, edited assets, RAW, or Live Photos. Deleting a Live Photo removes its still and motion together.")
            }
            Text("Deletion syncs across iCloud devices. Photos normally allows recovery for 30 days, but may delete immediately if iCloud is over its storage limit. Undo here only changes review selections.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if model.dryRun { Text("Dry run is on. Close this dialog and enable actions to delete.").font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.replacing ? "Replace original" : "Delete from Photos", role: .destructive) {
                    model.commitLibraryAction(draft, reviewed: reviewed, includeProtected: includeProtected)
                }
                .disabled(model.dryRun || model.busy || (draft.replacing ? !reviewed : protectedCount > 0 && !includeProtected))
            }
        }
        .padding(24).frame(width: 620)
        .background(Color(red: 0.97, green: 0.97, blue: 0.95)).preferredColorScheme(.light)
    }
}
