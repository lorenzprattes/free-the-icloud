import SwiftUI
import AppKit
import AVKit
import Photos
import FreeTheICloudCore

// Use AppKit's player directly; the SwiftUI VideoPlayer overlay crashes on this macOS build.
private struct LocalVideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline; view.videoGravity = .resizeAspect
        view.player = player; player.allowsExternalPlayback = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player; player.allowsExternalPlayback = false }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

private final class PreviewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID?
    private var cancelled = false
    func install(_ value: PHImageRequestID) {
        lock.lock(); id = value; let cancel = cancelled; lock.unlock()
        if cancel { PHImageManager.default().cancelImageRequest(value) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = id; lock.unlock()
        if let value { PHImageManager.default().cancelImageRequest(value) }
    }
}

@MainActor private func localPlayer(for item: MediaItem) async -> AVPlayer? {
    if let file = item.fileURL {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return AVPlayer(url: file)
    }
    guard item.sourceID == "photos:system", item.id.hasPrefix("photos:system:"),
          [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)),
          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [String(item.id.dropFirst("photos:system:".count))], options: nil).firstObject else { return nil }
    let request = PreviewRequest()
    let playerItem: AVPlayerItem? = await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false; options.deliveryMode = .highQualityFormat
            request.install(PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                continuation.resume(returning: playerItem)
            })
        }
    }, onCancel: { request.cancel() })
    guard !Task.isCancelled, let playerItem else { return nil }
    return AVPlayer(playerItem: playerItem)
}

struct DetailPreview: View {
    let item: MediaItem
    @ViewState private var image: NSImage?
    @ViewState private var player: AVPlayer?
    @ViewState private var unavailable = false
    @ViewState private var previewError: String?
    @ViewState private var cachedPreview: NSImage?
    @ViewState private var retry = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if let player { LocalVideoView(player: player) }
            else if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if let cachedPreview { Image(nsImage: cachedPreview).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            if unavailable {
                HStack {
                    Text(cachedPreview == nil ? "No local preview" : "Saved preview")
                        .help(previewError ?? "Local playback is unavailable. Downloads are off.")
                    if let previewError {
                        Image(systemName: "info.circle").help(previewError).accessibilityLabel(previewError)
                    }
                    Button("Retry") { retry += 1 }.buttonStyle(.borderless)
                }.font(.caption).padding(8).background(.regularMaterial, in: Capsule()).padding(8)
            }
        }
        .task(id: "\(item.id):\(retry)") {
            image = nil; player?.pause(); player = nil; unavailable = false; previewError = nil; cachedPreview = nil
            let thumbnail = item.thumbnailURL
            let cachedData = await Task.detached(priority: .userInitiated) { thumbnail.flatMap { try? Data(contentsOf: $0) } }.value
            guard !Task.isCancelled else { return }
            cachedPreview = cachedData.flatMap(NSImage.init(data:))
            if item.kind == .video {
                let loaded = await localPlayer(for: item)
                guard !Task.isCancelled else { return }
                player = loaded
                unavailable = player == nil
                return
            }
            let media = item
            let request = Task.detached(priority: .userInitiated) { () throws -> Data in
                if let file = media.fileURL {
                    return try ImageAnalyzer.jpegData(ImageAnalyzer.thumbnail(file, maxSize: 4096))
                }
                return try PhotosSource.previewJPEG(for: media)
            }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
                guard !Task.isCancelled else { return }
                image = NSImage(data: data); unavailable = image == nil
                if unavailable { previewError = "The local preview could not be decoded." }
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as NSError
                previewError = "\(failure.localizedDescription) [\(failure.domain) \(failure.code)]"
                unavailable = true
            }
        }
        .onDisappear { player?.pause() }
    }
}

struct ExportComparisonView: View {
    let result: ExportResult
    let original: MediaItem?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var originalPlayer: AVPlayer?
    @ViewState private var copyPlayer: AVPlayer?
    @ViewState private var visible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(result.sample ? "Compare sample" : "Compare copy").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(result.preset.title + (result.preset == .balanced && result.encodingVersion == nil ? " · Previous settings" : ""))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Original · \(Format.bytes(result.originalBytes))").font(.headline)
                    if let originalPlayer { LocalVideoView(player: originalPlayer) }
                    else if let original {
                        Thumbnail(item: original, fit: true)
                            .overlay(alignment: .bottom) { Text("Original playback unavailable").font(.caption).padding(8).background(.regularMaterial) }
                    } else { Text("Original unavailable").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                VStack(alignment: .leading) {
                    Text("\(result.sample ? "Sample" : "Copy") · \(Format.bytes(result.outputBytes))").font(.headline)
                    if let copyPlayer { LocalVideoView(player: copyPlayer) }
                    else { Text("Exported file unavailable").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }.frame(height: 310)
            HStack {
                Button("Play together") { restart() }.disabled(copyPlayer == nil)
                Button("Pause") { originalPlayer?.pause(); copyPlayer?.pause() }
                Spacer()
                Text(result.sample ? "\(Format.duration(result.sampleDuration)) sample · size estimates vary" : result.savings > 0 ? "\(Format.bytes(result.savings)) smaller" : "No size saving")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.output]) }
            }
        }
        .padding(24).frame(width: 950)
        .background(Color(red: 0.97, green: 0.97, blue: 0.95))
        .foregroundStyle(Color(red: 0.13, green: 0.22, blue: 0.22)).preferredColorScheme(.light)
        .task {
            visible = true
            if let original { originalPlayer = await localPlayer(for: original) }
            guard !Task.isCancelled else { return }
            if FileManager.default.fileExists(atPath: result.output.path) { copyPlayer = AVPlayer(url: result.output) }
            copyPlayer?.isMuted = originalPlayer != nil
            if result.sample { originalPlayer?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: offset+result.sampleDuration, preferredTimescale: 600) }
            await originalPlayer?.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
        }
        .onDisappear { visible = false; originalPlayer?.pause(); copyPlayer?.pause() }
    }
    private var offset: Double { result.sample ? max(0, (result.sourceDuration-result.sampleDuration)/2) : 0 }
    private func restart() {
        let source = originalPlayer, copy = copyPlayer
        Task { @MainActor in
            source?.pause(); copy?.pause()
            if let source { await source.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            if let copy { await copy.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
            guard visible else { return }
            source?.play(); copy?.play()
        }
    }
}
