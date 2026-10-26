import SwiftUI
import AppKit
import AVKit
import FreeTheICloudCore

// Disambiguate the property wrapper from the same-named macro in the macOS 27 SDK.
typealias ViewState<Value> = SwiftUI.State<Value>

private let ink = Color(red: 0.13, green: 0.22, blue: 0.22)
private let accent = Color(red: 0.16, green: 0.43, blue: 0.38)
private let paper = Color(red: 0.97, green: 0.97, blue: 0.95)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var moreFilters = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let activity = model.exportActivity {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Label(activity.running ? "Exporting copies" : "Export result", systemImage: activity.running ? "square.and.arrow.up" : "info.circle")
                                    .font(.headline)
                                Spacer()
                                if activity.running {
                                    Text("\(activity.saved) of \(activity.total) saved").font(.caption)
                                    Button(activity.cancelling ? "Cancelling…" : "Cancel", action: model.cancel).disabled(activity.cancelling)
                                } else {
                                    Button("Show output folder") { NSWorkspace.shared.open(activity.destination) }
                                    Button("Dismiss") { model.exportActivity = nil }
                                }
                            }
                            Text(activity.detail).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if activity.running {
                                if let fraction = activity.fraction {
                                    HStack {
                                        ProgressView(value: fraction).progressViewStyle(.linear)
                                        Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).frame(width: 40)
                                    }
                                } else { ProgressView().controlSize(.small) }
                                Text("Copies appear in the output folder after validation.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(14).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 28).padding(.bottom, 12)
                    }
                    Divider().padding(.horizontal, 28)
                    switch model.section {
                    case .overview: overview
                    case .media, .videos: mediaBrowser
                    case .similar: similarBrowser
                    case .plan: reviewPlan
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
            }
            Divider()
            HStack(spacing: 9) {
                if model.busy { if let fraction = model.progressFraction { ProgressView(value: fraction).frame(width: 90) } else { ProgressView().controlSize(.small) } }
                else { Image(systemName: "lock.shield").foregroundStyle(accent) }
                Text(model.status).lineLimit(1).font(.system(size: 11))
                Spacer()
                if !model.busy && !model.exportFailures.isEmpty && model.section != .plan { Button("Export details") { model.section = .plan }.controlSize(.small) }
                if model.busy && model.canCancel { Button("Cancel", action: model.cancel).controlSize(.small) }
                Text("ON THIS MAC").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).frame(height: 34).background(.white)
        }
        .tint(accent).foregroundStyle(ink).preferredColorScheme(.light)
        .frame(minWidth: 1060, minHeight: 720)
        .alert("Couldn’t complete the operation", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: $model.inspected, onDismiss: model.finishInspection) { item in InspectorView(item: item, model: model) }
        .sheet(item: $model.comparing) { group in ComparisonView(group: group, model: model).id(group.id) }
        .sheet(item: $model.viewingExport) { result in ExportComparisonView(result: result, original: model.items.first { $0.id == result.sourceID }) }
        .sheet(item: $model.pendingLibraryAction) { draft in LibraryActionView(draft: draft, model: model) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cloud.sun.fill").font(.system(size: 27)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("free the icloud").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Photo & video cleanup").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 34).padding(.top, 12)
            Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary).padding(.bottom, 10)
            ForEach(Section.allCases) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.symbol).frame(width: 18)
                        Text(section.rawValue).font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                        Spacer()
                        if section == .plan && model.plan.selectedIDs.count + model.plan.videoIDs.count > 0 {
                            Text("\(model.plan.selectedIDs.union(model.plan.videoIDs).count)").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3).background(accent.opacity(0.12), in: Capsule())
                        }
                    }.padding(.horizontal, 12).frame(height: 40)
                        .background(model.section == section ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label(model.isDemo ? "Demo workspace" : "Approved source", systemImage: model.isDemo ? "sparkles" : "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.isDemo ? "16 images · 2 clips" : model.sourceName)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Menu {
                    if !model.savedSources.isEmpty {
                        Menu("Saved scans") {
                            ForEach(model.savedSources) { source in
                                Button(source.name) { model.openSavedSource(source) }
                            }
                        }
                        Divider()
                    }
                    Button("Generated demo", action: model.startDemo)
                    Button("Choose a folder…", action: model.chooseFolder)
                    Button("Connect Photos…", action: model.connectPhotos)
                    if model.savedSources.contains(where: { $0.id == "photos:system" }) { Button("Photos access…", action: model.authorizePhotos) }
                } label: { Text("Change source").frame(maxWidth: .infinity) }.disabled(model.busy)
            }.padding(14).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text("Local processing").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.top, 16)
        }.padding(18).frame(width: 225).background(Color(red: 0.93, green: 0.95, blue: 0.92))
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.sourceName.uppercased()).tracking(1.5)
                    if model.showingSavedScan { Text("SAVED SCAN").help(model.lastCompletedScan.map { "Last completed scan: " + $0.formatted() } ?? "Saved results. Refresh to check for changes; the original files have not been rescanned.") }
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(model.section.rawValue).font(.system(size: 27, weight: .semibold, design: .rounded))
            }
            Spacer()
            Button(action: model.toggleDryRun) {
                Label(model.dryRun ? "Dry run" : "Actions enabled", systemImage: model.dryRun ? "shield.lefthalf.filled" : "checkmark.shield")
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 8)
                    .background(model.dryRun ? accent.opacity(0.08) : Color.orange.opacity(0.15), in: Capsule())
            }.buttonStyle(.plain).disabled(model.busy)
                .help("Dry run blocks media exports and Photos changes. Reports can still be saved.")
            Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.help("Update scan; reuse unchanged analysis").accessibilityLabel("Rescan approved source").disabled(model.busy || model.sourceID.isEmpty)
        }.padding(.horizontal, 28).padding(.vertical, 23)
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your library,\na little lighter.")
                            .font(.system(size: 32, weight: .medium, design: .serif)).lineSpacing(2)
                        Text("Review photos. Make smaller video copies.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                        Button { model.section = .similar } label: {
                            Label("Explore similar photos", systemImage: "arrow.right").padding(.horizontal, 8).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).padding(.top, 5)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ZStack(alignment: .bottomLeading) {
                        if let image = model.items.first(where: { $0.kind == .photo }) {
                            Thumbnail(item: image).frame(width: 270, height: 225).clipped()
                        } else { Rectangle().fill(accent.opacity(0.18)).frame(width: 270, height: 225) }
                        Text(model.isDemo ? "GENERATED ON YOUR MAC" : "YOUR APPROVED SOURCE")
                            .font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.white)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.3))
                    }.frame(width: 270).clipShape(RoundedRectangle(cornerRadius: 12)).rotationEffect(.degrees(2))
                }.padding(25).background(.white, in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 14) {
                    stat("Indexed media", value: "\(model.items.count)", foot: "\(model.items.filter { $0.kind == .photo }.count) photos · \(model.items.filter { $0.kind == .video }.count) videos", icon: "photo.stack")
                    stat("Measured originals", value: Format.bytes(model.totalBytes), foot: "\(model.items.filter { $0.bytes == nil }.count) sizes still unknown", icon: "externaldrive")
                    stat("Groups to explore", value: "\(model.visibleGroups.count)", foot: "Ready to compare", icon: "square.on.square")
                }
                HStack { Text("Explore").font(.system(size: 17, weight: .semibold)); Spacer(); Text("ORIGINALS UNCHANGED").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary) }
                HStack(spacing: 14) {
                    destinationCard("Find the heavyweights", detail: "Browse by size, date, or type.", symbol: "externaldrive", destination: .media)
                    destinationCard("Compare your photos", detail: "Choose your keepers side by side.", symbol: "rectangle.on.rectangle", destination: .similar)
                    destinationCard("Try smaller video copies", detail: "Compare a sample before exporting.", symbol: "play.rectangle", destination: .videos)
                }
                Label("Original media sizes", systemImage: "info.circle").help("Measured resource bytes, not physical disk usage or your iCloud quota.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    private func stat(_ title: String, value: String, foot: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(accent) }
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded))
            Text(foot).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
    private func destinationCard(_ title: String, detail: String, symbol: String, destination: Section) -> some View {
        Button { model.section = destination } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(accent).frame(height: 25)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).frame(maxWidth: .infinity, minHeight: 45, alignment: .topLeading)
                Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(accent)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search filenames", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 230)
                if model.section != .videos {
                    Picker("Type", selection: $model.category) { ForEach(["Everything", "Photos", "Videos", "Screenshots"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 145)
                }
                Spacer()
                Picker("Sort", selection: $model.sort) { ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue) } }.labelsHidden().frame(width: 130)
                Picker("Layout", selection: $model.useTable) {
                    Image(systemName: "square.grid.2x2").tag(false)
                    Image(systemName: "list.bullet").tag(true)
                }.pickerStyle(.segmented).frame(width: 64).help("Grid or table")
            }
            HStack(spacing: 9) {
                Text("Size").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Min MB", text: $model.minMB).frame(width: 78)
                Text("–").foregroundStyle(.secondary)
                TextField("Max MB", text: $model.maxMB).frame(width: 78)
                if model.section == .videos { TextField("Min seconds", text: $model.minSeconds).frame(width: 100) }
                Button { moreFilters.toggle() } label: { Label(model.dateRange != "Any date" || model.minPixels > 0 || model.availableOnly ? "More filters •" : "More filters", systemImage: moreFilters ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Reset", action: model.resetFilters).buttonStyle(.link).font(.system(size: 11))
            }.textFieldStyle(.roundedBorder).font(.system(size: 11))
            if moreFilters {
                HStack {
                    Picker("Date", selection: $model.dateRange) { ForEach(["Any date", "Last 30 days", "Last year"], id: \.self) { Text($0) } }.frame(width: 170)
                    Picker("Resolution", selection: $model.minPixels) {
                        Text("Any").tag(0); Text("2+ MP").tag(2_000_000); Text("12+ MP").tag(12_000_000)
                    }.frame(width: 180)
                    Toggle("Available locally", isOn: $model.availableOnly)
                }.font(.system(size: 11))
            }
            if !model.filtersValid { Text("Check the size and duration filters.").font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 28).padding(.vertical, 16)
    }
    private var mediaBrowser: some View {
        VStack(spacing: 0) {
            filters
            if model.section == .videos {
                HStack {
                    Label("Export smaller copies. Keep your originals.", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(); Button("Queue visible", action: model.queueVisible).disabled(model.busy || model.filtered.isEmpty)
                    Button("Export queue (\(model.plan.videoIDs.count))") { model.section = .plan }
                }.padding(.horizontal, 28).padding(.bottom, 15)
            }
            if model.filtered.isEmpty || !model.filtersValid {
                empty("No media matches", detail: "Try clearing filters or choosing another source.", symbol: "line.3.horizontal.decrease.circle")
            } else if model.useTable {
                Table(model.filtered, selection: $model.highlightedIDs) {
                    TableColumn("Name") { item in Button(item.name) { model.inspected = item }.buttonStyle(.link) }.width(min: 170, ideal: 240)
                    TableColumn("Kind") { Text($0.kind.rawValue) }.width(55)
                    TableColumn("Original size") { Text(Format.bytes($0.bytes)).monospacedDigit() }.width(100)
                    TableColumn("Dimensions") { Text("\($0.width) × \($0.height)") }.width(110)
                    TableColumn("Date") { Text($0.date?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown") }.width(95)
                    TableColumn("Review") { item in
                        Button(model.plan.selectedIDs.contains(item.id) ? "Unmark" : "Mark") { model.toggleSelection(item) }
                    }.width(65)
                    TableColumn("Video copy") { item in
                        if item.kind == .video { Button(model.plan.videoIDs.contains(item.id) ? "Unqueue export" : "Queue export") { model.toggleVideo(item) }.disabled(model.busy || !item.canQueueVideo) }
                    }.width(75)
                }.contextMenu(forSelectionType: String.self) { ids in
                    Button("Mark for review") { model.mutatePlan { plan in for item in model.items where ids.contains(item.id) { plan.mark(item) } } }
                } primaryAction: { ids in model.inspected = model.items.first { ids.contains($0.id) } }
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205, maximum: 320), spacing: 16)], spacing: 18) {
                        ForEach(model.filtered) { item in MediaCard(item: item, model: model) }
                    }.padding(.horizontal, 28).padding(.bottom, 28)
                }
            }
            HStack { Text("\(model.filtered.count) items"); Spacer(); Text("\(model.filtered.compactMap(\.bytes).reduce(0,+).formatted(.byteCount(style: .file)))") }
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 9)
        }
    }
    private var similarBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Similarity").font(.system(size: 11))
                Slider(value: $model.hashRadius, in: 2...16, step: 2) { editing in if !editing { model.regroup() } }.frame(width: 130)
                Text(model.hashRadius <= 4 ? "Strict" : model.hashRadius <= 10 ? "Balanced" : "Loose").font(.system(size: 11, design: .monospaced)).frame(width: 65)
                Toggle("Search across all dates", isOn: $model.allDates).font(.system(size: 11)).onChange(of: model.allDates) { _, _ in model.regroup() }
                Spacer()
                if !model.plan.dismissedGroupIDs.isEmpty { Button("Restore dismissed") { model.mutatePlan { $0.dismissedGroupIDs = [] } } }
            }.padding(.horizontal, 28).padding(.vertical, 18)
            Text(model.findingGroups ? "Finding matches…" : "\(model.visibleGroups.count) groups")
                .help("Identical originals match across all dates. Similarity normally uses a 48-hour window. Enable all dates for missing capture dates.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.bottom, 16)
            if model.visibleGroups.isEmpty { empty(model.findingGroups ? "Finding matches…" : "No groups to review", detail: model.findingGroups ? "You can keep browsing while this runs." : "Try a looser match or search all dates.", symbol: "square.on.square") }
            else {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(model.visibleGroups) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.match.rawValue).font(.system(size: 14, weight: .semibold))
                                        Text("\(group.items.count) items · Suggested keeper: \(group.items[0].name)").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Dismiss") { model.mutatePlan { $0.dismissedGroupIDs.insert(group.id) } }
                                    Button("Compare") { model.comparing = group }.buttonStyle(.borderedProminent)
                                }
                                ScrollView(.horizontal) {
                                    HStack(spacing: 12) {
                                        ForEach(group.items) { item in
                                            VStack(alignment: .leading, spacing: 5) {
                                                Button { model.comparing = group } label: {
                                                    Thumbnail(item: item).frame(width: 165, height: 112).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                                                }.buttonStyle(.plain)
                                                Text(item.name).font(.system(size: 10)).lineLimit(1)
                                                PhotoReviewStatus(item: item, suggested: item.id == group.referenceID, plan: model.plan)
                                                Text(Format.bytes(item.bytes)).font(.system(size: 10)).foregroundStyle(.secondary)
                                            }.frame(width: 165, alignment: .leading)
                                        }
                                    }
                                }
                            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 28)
                }
            }
        }
    }
    private var reviewPlan: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ready for review").font(.system(size: 22, weight: .medium, design: .serif))
                        Text("Marked: \(Format.mediaCounts(model.selected)) · \(model.queuedVideos.count) queued for export").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Undo", action: model.undo).disabled(model.undoHistory.isEmpty)
                    Menu("Export report") {
                        Button("JSON", action: { model.exportReport() })
                        Button("CSV", action: { model.exportReport(csv: true) })
                    }.fixedSize()
                }
                if let reason = model.libraryFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Photos action did not complete", systemImage: "exclamationmark.circle").font(.headline)
                        Text(reason).font(.callout).textSelection(.enabled)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                if !model.exportFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Not exported (\(model.exportFailures.count))", systemImage: "exclamationmark.circle").font(.headline)
                        ForEach(model.exportFailures) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.name).font(.system(size: 12, weight: .semibold))
                                Text(issue.reason).font(.callout).textSelection(.enabled)
                                Text("\(issue.preset.title) · \(issue.sample ? "Sample" : "Full copy") · \(issue.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.dryRun {
                    Label("Dry run · Library changes and media exports are blocked.", systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 12)).padding(15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Marked for review · \(model.selected.count)").font(.headline); Spacer()
                        Button("Unmark all", action: model.clearReview).disabled(model.busy || model.selected.isEmpty)
                        Button("Create album", action: model.createAlbum)
                            .disabled(model.dryRun || model.busy || model.selected.isEmpty || model.sourceID != "photos:system")
                        Button("Delete marked items…", role: .destructive, action: model.prepareDeletion)
                            .disabled(model.busy || model.selected.isEmpty || model.sourceID != "photos:system")
                    }
                    Text("\(Format.mediaCounts(model.selected)) · \(Format.bytes(model.selected.compactMap(\.bytes).reduce(0, +)))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Delete marked items applies to every photo and video in this list.").font(.caption).foregroundStyle(.secondary)
                    if model.selected.isEmpty { Text("Mark photos or videos from the library.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12) }
                    ForEach(model.selected) { item in planRow(item, video: false) }
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Export queue · \(model.queuedVideos.count) videos").font(.headline)
                        Spacer()
                        Picker("Preset", selection: Binding(get: { model.plan.preset }, set: { value in model.mutatePlan { $0.preset = value } })) {
                            ForEach(CompressionPreset.allCases, id: \.self) { Text($0.title) }
                        }.frame(width: 250)
                    }
                    Text(model.plan.preset.explanation).font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Compare presets") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(CompressionPreset.allCases, id: \.self) { preset in
                                Text("\(preset.title): ").bold() + Text(preset.explanation)
                            }
                            Text("All preserve supported HDR and frame rate. Try samples to judge detail; savings depend on the video.")
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }
                    Label("HDR preserved · Exporting creates copies", systemImage: "info.circle").help("SDR, HLG, PQ and iPhone Dolby Vision 8.4. Spatial and specialty formats are skipped. Originals stay unchanged. Smaller file also compresses large mono/stereo audio to AAC; multichannel audio passes through.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.queuedVideos.contains(where: { model.plan.selectedIDs.contains($0.id) }) {
                        Label("Videos labeled ‘Also marked’ are included in Delete marked items above.", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if model.queuedVideos.isEmpty { Text("Queue a clip from Videos to compare and export.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12) }
                    ForEach(model.queuedVideos) { item in planRow(item, video: true) }
                    HStack {
                        Button("Clear queue", action: model.clearQueue).disabled(model.busy || model.queuedVideos.isEmpty)
                        Spacer()
                        Button("Try samples") { model.exportVideos(sample: true) }.disabled(model.dryRun || model.busy || model.queuedVideos.isEmpty)
                        Button("Export copies") { model.exportVideos(sample: false) }.buttonStyle(.borderedProminent).disabled(model.dryRun || model.busy || model.queuedVideos.isEmpty)
                    }
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                if !model.exports.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Export history").font(.headline)
                        ForEach(Array(model.exports.enumerated()), id: \.offset) { _, result in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.output.lastPathComponent).font(.system(size: 12, weight: .medium))
                                    Text(result.preset.title + (result.preset == .balanced && result.encodingVersion == nil ? " · Previous settings" : "") + (result.sample ? " · Sample" : " · Full copy"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let color = result.colorProfile { Text(color.label + (color.isHDR ? " · 10-bit" : "")).font(.caption).foregroundStyle(.secondary) }
                                    Text(result.sample ? "Sample: \(Format.bytes(result.outputBytes)) · Approximate full size: \(Format.bytes(Int64(Double(result.outputBytes) * result.sourceDuration / result.sampleDuration)))" : "Original: \(Format.bytes(result.originalBytes)) · Copy: \(Format.bytes(result.outputBytes)) · \(result.savings > 0 ? "Smaller by " + Format.bytes(result.savings) : "No size saving")")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Compare") { model.viewingExport = result }
                                if !result.sample {
                                    Button("Replace original…") { model.prepareReplacement(result) }
                                        .disabled(model.busy || !model.canReplace(result))
                                        .help("Requires a new full export of an unchanged Photos video. Keepers cannot be replaced.")
                                }
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([result.output]) }
                            }
                        }
                    }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                if !model.photoExports.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Resized photo copies").font(.headline)
                        ForEach(model.photoExports) { result in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.output.lastPathComponent).font(.callout)
                                    Text("\(result.width) × \(result.height) · \(result.hdr ? "10-bit HDR" : "SDR") · \(Format.bytes(result.outputBytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(result.savings > 0 ? "Smaller by " + Format.bytes(result.savings) : "No size saving")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open copy") { NSWorkspace.shared.open(result.output) }
                                Button("Replace original…") { model.prepareReplacement(result) }
                                    .disabled(model.busy || !model.canReplace(result))
                                    .help("Review the exported photo first. Requires a smaller copy of an unchanged Photos still. Keepers cannot be replaced.")
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([result.output]) }
                            }
                        }
                    }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                if let report = model.lastReport { Button("Reveal saved report") { NSWorkspace.shared.activateFileViewerSelecting([report]) } }
            }.padding(28)
        }
    }
    private func planRow(_ item: MediaItem, video: Bool) -> some View {
        HStack(spacing: 12) {
            Thumbnail(item: item).frame(width: 60, height: 42).clipped().clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12, weight: .medium))
                Text("\(item.kind == .video ? "Video" : "Photo") · \(Format.bytes(item.bytes)) · \(item.width) × \(item.height)\(item.protected ? " · Protected" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if video && model.plan.selectedIDs.contains(item.id) {
                    Label("Also marked · included in deletion", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Inspect") { model.inspected = item }
            if item.sourceID == "photos:system" {
                Button("Delete…", role: .destructive) { model.prepareSingleDeletion(item) }
                    .disabled(model.busy || model.plan.keeperIDs.contains(item.id))
                    .help("Delete only this item after confirmation. Keepers cannot be deleted.")
            }
            Button(video ? "Unqueue" : "Unmark") {
                if video { model.toggleVideo(item) } else { model.toggleSelection(item) }
                model.status = video ? "Removed from export queue · Original unchanged" : "Unmarked from review · Photo unchanged"
            }.disabled(model.busy)
                .help(video ? "Remove from the export queue. Does not change the original." : "Remove the review mark. Does not delete this photo.")
        }.padding(.vertical, 4)
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(accent.opacity(0.6))
            Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Thumbnail: View {
    let item: MediaItem
    var fit = false
    @ViewState private var image: NSImage? = nil
    private static let cache: NSCache<NSURL, NSImage> = { let cache = NSCache<NSURL, NSImage>(); cache.countLimit = 80; cache.totalCostLimit = 96_000_000; return cache }()
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.gray.opacity(0.1)
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill).frame(width: geometry.size.width, height: geometry.size.height) }
                else { Image(systemName: item.available ? "photo" : "icloud.slash").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.clipped().accessibilityLabel("Preview of \(item.name)")
            .task(id: item.thumbnailURL) {
                guard let url = item.thumbnailURL else { image = nil; return }
                if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                let loaded = data.flatMap { NSImage(data: $0) }
                if let loaded { Self.cache.setObject(loaded, forKey: url as NSURL, cost: Int(loaded.size.width * loaded.size.height * 4)) }
                image = loaded
            }
    }
}

struct MediaCard: View {
    let item: MediaItem
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.inspected = item } label: {
                ZStack(alignment: .bottomTrailing) {
                    Thumbnail(item: item).frame(height: 150)
                    if item.kind == .video {
                        Label(Format.duration(item.duration), systemImage: "play.fill").font(.system(size: 10, weight: .medium))
                            .padding(6).background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(8)
                    }
                }
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if item.favorite { Image(systemName: "heart.fill").foregroundStyle(.orange).font(.caption) }
                    if item.protected { Image(systemName: "shield").font(.caption).help("Favorite, edited, Live Photo, or RAW") }
                }
                HStack { Text(Format.bytes(item.bytes)); Spacer(); Text("\(item.width) × \(item.height)") }.font(.system(size: 10)).foregroundStyle(.secondary)
                if item.issue != nil { Label("Needs attention", systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.orange) }
                HStack {
                    Button { model.toggleSelection(item) } label: {
                        Label(model.plan.selectedIDs.contains(item.id) ? "Marked" : "Review", systemImage: model.plan.selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                    Spacer()
                    if item.kind == .video {
                        Button(model.plan.videoIDs.contains(item.id) ? "Queued" : "Queue copy") { model.toggleVideo(item) }.font(.system(size: 10)).disabled(model.busy || !item.canQueueVideo)
                    }
                }
            }.padding(12)
        }.background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.plan.selectedIDs.contains(item.id) ? accent : .clear, lineWidth: 2))
    }
}

struct InspectorView: View {
    let item: MediaItem
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState private var zoom: Double = 1.0
    private var resizeBlockers: [String] {
        var reasons: [String] = []
        if model.dryRun { reasons.append("dry run is on") }
        if model.busy { reasons.append("another operation is running") }
        if !item.available { reasons.append("original unavailable at last scan; make it local, then Refresh") }
        if item.livePhoto { reasons.append("Live Photos aren't supported") }
        if item.raw { reasons.append("RAW photos aren't supported") }
        if item.edited { reasons.append("edited photos aren't supported") }
        return reasons
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(item.name).font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView([.horizontal, .vertical]) {
                DetailPreview(item: item).frame(width: 810 * zoom, height: 420 * zoom)
            }.frame(height: 420).background(.black.opacity(0.04))
            HStack { Text("Zoom"); Slider(value: $zoom, in: 1...4).frame(width: 180); Text("\(Int(zoom*100))%").monospacedDigit(); Spacer(); Text("Local preview · up to 4096 px").foregroundStyle(.secondary) }.font(.caption)
            HStack(spacing: 30) {
                Label(Format.bytes(item.bytes), systemImage: "externaldrive")
                Text("\(item.width) × \(item.height)")
                Text(item.date?.formatted(date: .abbreviated, time: .shortened) ?? "Capture date unknown")
                if item.kind == .video { Text(Format.duration(item.duration)) }
            }.font(.system(size: 12))
            if let issue = item.issue {
                if item.sourceID == "photos:system" && !item.available {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Original could not be read at last scan · previews may still be available", systemImage: "info.circle")
                        DisclosureGroup("Scan details") { Text(issue).textSelection(.enabled) }
                    }.font(.caption).foregroundStyle(.secondary)
                } else { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            if item.protected { Text("Protected characteristics: \([item.favorite ? "favorite" : nil, item.edited ? "edited" : nil, item.livePhoto ? "Live Photo" : nil, item.raw ? "RAW" : nil].compactMap { $0 }.joined(separator: ", ")).").font(.caption) }
            HStack {
                Button(model.plan.selectedIDs.contains(item.id) ? "Unmark" : "Mark for review") { model.toggleSelection(item) }
                    .help("Change the review selection. Does not delete the original.")
                if item.kind == .video { Button(model.plan.videoIDs.contains(item.id) ? "Remove from video queue" : "Queue video copy") { model.toggleVideo(item) }.disabled(model.busy || !item.canQueueVideo) }
                if item.kind == .photo {
                    Menu("Resize copy…") {
                        ForEach([4096, 2560, 1920, 1280], id: \.self) { size in
                            Button("Longest edge: \(size) px") { model.exportPhoto(item, maxDimension: size) }
                        }
                    }.disabled(!resizeBlockers.isEmpty)
                        .help("Export a smaller HEIC copy; preserve HDR when present. Original stays unchanged.")
                }
                Spacer()
                Button("Review plan…") { model.section = .plan; dismiss() }
                    .help("Delete marked items from Review plan. Each deletion requires confirmation.")
                if item.sourceID == "photos:system" {
                    Button("Delete this item…", role: .destructive) { model.prepareSingleDeletion(item) }
                        .disabled(model.busy || model.plan.keeperIDs.contains(item.id))
                        .help(model.plan.keeperIDs.contains(item.id) ? "Remove the Keep decision first." : "Confirm deletion of only this photo or video.")
                }
                if let file = item.fileURL { Button("Open original") { NSWorkspace.shared.open(file) } }
            }
            if item.kind == .photo && !resizeBlockers.isEmpty {
                HStack(alignment: .top) {
                    Label("Resize unavailable: " + resizeBlockers.joined(separator: " · ") + ".", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.dryRun {
                        Button("Enable actions…", action: model.toggleDryRun).disabled(model.busy)
                    }
                }
            }
        }.padding(24).frame(width: 860).background(paper).foregroundStyle(ink).preferredColorScheme(.light).tint(accent)
    }
}

private struct PhotoReviewStatus: View {
    let item: MediaItem
    let suggested: Bool
    let plan: ReviewPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if suggested {
                Label("Suggested keeper", systemImage: "star")
                    .help("Suggested by favorite status, edits, resolution, then file size. This is not an explicit Keep decision.")
            }
            if plan.keeperIDs.contains(item.id) {
                Label("Kept", systemImage: "checkmark.shield.fill").foregroundStyle(accent)
            } else if plan.selectedIDs.contains(item.id) {
                Label("Marked for review", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
            } else if item.protected {
                Label("Protected", systemImage: "shield")
                    .help("Skipped by Mark alternatives: favorite, edited photo, RAW, or Live Photo.")
            } else if !suggested {
                Text("Not marked").foregroundStyle(.secondary)
            }
        }.font(.system(size: 10, weight: .medium))
    }
}

struct ComparisonView: View {
    let group: MediaGroup
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState private var candidateID: String? = nil
    @ViewState private var zoom: Double = 1.0
    private var reference: MediaItem { group.items.first(where: { $0.id == group.referenceID }) ?? group.items[0] }
    private var candidate: MediaItem { group.items.first(where: { $0.id == candidateID && $0.id != reference.id }) ?? group.items.first(where: { $0.id != reference.id }) ?? reference }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(group.match.rawValue).font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack { Text("\(group.items.count) photos").font(.caption).foregroundStyle(.secondary); Image(systemName: "info.circle").help(group.explanation); Spacer(); Button("Previous") { model.compareNext(group, offset: -1) }; Button("Next group") { model.compareNext(group, offset: 1) } }
            Text("The first photo is the suggested keeper. Select another thumbnail to compare on the right.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 18) { comparePane(reference, reference: true); comparePane(candidate, reference: false) }
            HStack { Text("Zoom previews").font(.caption); Slider(value: $zoom, in: 1...3).frame(width: 150); Spacer()
                Text("Zoom up to 4096 px").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(group.items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Button { if item.id != reference.id { candidateID = item.id } } label: {
                                Thumbnail(item: item).frame(width: 135, height: 85).clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(item.id == candidate.id ? accent : .clear, lineWidth: 3))
                            }.buttonStyle(.plain)
                                .help(item.id == reference.id ? "Suggested keeper · shown on the left" : "Compare \(item.name) on the right")
                                .accessibilityLabel(item.id == reference.id ? "\(item.name), suggested keeper, shown on the left" : "Compare \(item.name)")
                            Text(item.id == reference.id ? "Left preview" : item.id == candidate.id ? "Right preview" : item.name)
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            PhotoReviewStatus(item: item, suggested: item.id == reference.id, plan: model.plan)
                        }.frame(width: 135, alignment: .topLeading)
                    }
                }.padding(3)
            }
            HStack {
                Text("\(group.items.filter { model.plan.keeperIDs.contains($0.id) }.count) kept · \(group.items.filter { model.plan.selectedIDs.contains($0.id) }.count) marked").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Undo", action: model.undo).disabled(model.busy || model.undoHistory.isEmpty)
                Button("Mark alternatives (\(model.unmarkedAlternatives(group).count))") { model.selectAlternatives(group) }
                    .disabled(model.busy || model.unmarkedAlternatives(group).isEmpty)
            }
            Text("Marks for review only. Skips the suggested keeper, your keepers, and protected photos.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 950).background(paper).foregroundStyle(ink).preferredColorScheme(.light).tint(accent)
    }
    private func comparePane(_ item: MediaItem, reference isReference: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(isReference ? "LEFT · SUGGESTED KEEPER" : "RIGHT · COMPARISON").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(accent)
                .help(isReference ? "Suggested by favorite status, edits, resolution, then file size. Choose Keep to protect it explicitly." : "Select a thumbnail below to change this preview.")
            ScrollView([.horizontal, .vertical]) { DetailPreview(item: item).frame(width: 430 * zoom, height: 310 * zoom) }
                .frame(width: 430, height: 310).background(.black.opacity(0.03))
            Text(item.name).font(.system(size: 13, weight: .medium))
            Text("\(Format.bytes(item.bytes)) · \(item.width) × \(item.height)\(item.protected ? " · Protected" : "")").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.plan.keeperIDs.contains(item.id) ? "Kept ✓" : "Keep") { model.keep(item) }
                Button(model.plan.selectedIDs.contains(item.id) ? "Marked ✓" : "Mark for review") { model.toggleSelection(item) }
            }.disabled(model.busy)
        }
    }
}
