# Free the iCloud

A native macOS app for reviewing large media, comparing similar photos, and exporting smaller video copies. All analysis runs on the Mac using Swift, Apple Vision, SQLite, and AVFoundation. There are no third-party dependencies, accounts, analytics, model downloads, or cloud AI calls.

> **Disclaimer.** This software is provided as is, with no warranty and no responsibility taken by the author for any loss. It can delete and replace photos and videos in your Photos library, which may sync to iCloud and all your devices. Back up your library first, and use it at your own risk. See [LICENSE](LICENSE) (MIT).

The first launch starts in a **generated demo**. Later launches reopen the last **saved scan**, with **dry-run enabled**. Startup reads the app's catalog without requesting Photos permission or rescanning original media.

## Download

Prebuilt Apple Silicon builds are on the [Releases page](../../releases). The app is not notarized, so macOS will block the first launch: right-click the app, choose **Open**, then confirm, or run `xattr -dr com.apple.quarantine "Free the iCloud.app"`.

## Build and open

Requires macOS 14 or newer and Apple's Swift command-line tools (Xcode is not required). Built with Swift 6.4 in Swift 5 language mode and tested on Apple Silicon; other Mac and macOS combinations have not been validated.

```sh
bash scripts/build.sh
open 'dist/Free the iCloud.app'
```

The build produces a locally ad-hoc-signed app. It is not notarized. The build script passes `--disable-sandbox` to SwiftPM so the build also works inside restricted environments; the package has no external dependencies or build plugins.

## Use the app

1. Start in **All media**; **Overview** shows totals. The 16 generated image files and two short clips are real files with measured sizes, not a mock catalog.
2. Use size, type, date, resolution, duration, and availability filters. Switch between grid and table. Click a filename or thumbnail to inspect it.
3. Open **Similar photos**, then **Compare**. The left image is a suggested reference. Use **Keep** to protect a choice from bulk marking, mark alternatives for review, or dismiss the group. Decisions change only the saved review plan.
4. Queue a clip in **Videos**. **Review plan** contains selected items, a compression preset, and report export actions.
5. JSON/CSV reports work in dry-run. To test actual encoding on the generated clips, disable dry-run deliberately, then export samples or full copies to a chosen folder. Each batch requires confirmation. Use **Compare** in export history to inspect the original and encoded copy side by side.

The source menu contains **Choose a folder** and **Connect Photos**. These are opt-in actions for when you want to grant access. Folder selection approves local reading of the selected root. Connecting Photos presents an explanation before the macOS permission request. Development and automated checks use generated fixtures only.

**Saved scans** reopens cached sources, including their review decisions, video queues and export history. **Refresh** checks for changes and reuses unchanged analysis; interrupted scans retain completed work. Existing catalogs from earlier versions are recognized automatically. If no previous source selection was recorded, a cached Photos scan takes priority over the demo.

Failed exports appear under **Not exported** at the top of Review plan, with the filename and error reason. Errors are saved locally and remain visible after restarting, until the next export batch. Errors from versions before v0.4 were not saved.

## Delete and replace in Photos

For one Photos item, use **Inspect → Delete this item…**, or **Delete…** beside its Review plan row. The confirmation contains only that item; other review marks stay unchanged. You do not need to mark the item first. Keepers remain protected.

For batch deletion, connect Photos, scan, and review the selected items. In **Review plan**, **Delete marked items…** shows the exact list and asks for confirmation. Dry run leaves the final action disabled. Protected selections need a separate acknowledgement.

Replacement is optional and never runs as part of export. Export a **full** video copy, compare it, then choose **Replace original…** in export history. Confirm that you reviewed the full video and approve replacement. The external compressed file stays in its output folder. Rescan after replacement to index the new Photos item. Exports created before v0.3 must be recreated because they lack the source and output integrity hashes.

The compression choices are:

| Preset | Resolution | Tradeoff |
| --- | --- | --- |
| Smaller file | Original | Stronger compression; fine detail may soften. Large mono/stereo audio also becomes AAC. |
| High quality | Original | Apple’s highest-quality HEVC preset. Prioritizes detail; size can increase. |
| Fit within 1080p | At most 1920 × 1080, keeping aspect ratio | High-quality HEVC at a reduced resolution. Uses High quality unchanged for inputs already within 1080p. |

The revised Smaller file encoder targets 25% of the source video bitrate, capped at 0.025 bits per pixel per frame for SDR or 0.035 for HDR, with a 64 kbps floor. The [average bitrate setting](https://developer.apple.com/documentation/avfoundation/avvideoaveragebitratekey) is an encoding target, not a file-size guarantee. Audio, container overhead and scene complexity affect the result. Try samples before a full export; replacement remains optional after visual review. Export history labels the preset and marks older Smaller file outputs as **Previous settings**. Existing copies do not change.

HDR videos use the same export controls. HLG, PQ and iPhone Dolby Vision 8.4 retain HDR through a 10-bit HEVC path; export history shows the resulting format. **Fit within 1080p** also preserves HDR. Exports are rejected if validation detects lost HDR color tags, insufficient bit depth or a lost Dolby Vision profile.

For still photos, open **Inspect → Resize copy…** and choose a maximum long edge (4096, 2560, 1920 or 1280 pixels). Enable actions first. The app exports a separate HEIC copy and a manifest; no upscaling is performed. HDR and gain-map inputs become 10-bit PQ HEIC, preserving HDR pixel values while changing the source representation. Results appear under **Resized photo copies** in Review plan. File size can increase despite smaller dimensions. RAW, Live Photos, edited Photos assets and multi-image files are excluded. Adaptive gain maps require macOS 15 or later. After opening and visually reviewing a copy, you can choose **Replace original…** beside it. The confirmation requires a fresh review acknowledgement. Replacement is available only when the copy saves space and the original and export are unchanged. Exporting alone leaves the original untouched; automatic batch replacement is not enabled.

Library actions are recorded before submission and marked completed or failed afterward. A pending record after a crash means the outcome is unknown; rescan Photos before retrying. The app does not promise recovery of deleted originals.

## What works

- Measured original-resource sizes, with unknown sizes retained as unknown. Unknown values are excluded by active size filters and sorted after known sizes.
- Recursive folder indexing with cancellation and cached analysis. Symbolic links, Photos library bundles, hidden files, packages, and undownloaded cloud placeholders are excluded.
- A PhotoKit source adapter for the System Photo Library. Original-resource requests and thumbnail requests disable iCloud downloads. Metadata, favorites, edits, RAW indicators, Live Photo pairing, and screenshot subtype are represented where available.
- SHA-256 exact matching over complete original-resource inventories. Capture dates do not restrict exact matches.
- A 64-bit DCT perceptual hash, a BK-tree candidate index, and local Vision revision-2 feature prints for ordering comparisons. If Vision is unavailable, perceptual hashing still works.
- Reference-based groups: every similar item must match the reference, avoiding unrestricted transitive clustering. Default radius is eight bits with a 48-hour window; both controls are exposed. Missing dates require all-dates mode.
- Persistent review decisions, explicit keepers, and undo. Bulk alternatives exclude keepers, favorites, edited assets, RAW, and Live Photos. Decisions are cleared if the scanned content changes; old plans without content versions require review again.
- HEVC video samples and full copies using AVFoundation, with progress and cancellation. **Smaller file** targets a lower bitrate at the original dimensions, preserves supported color tags and compresses large mono/stereo audio to AAC (96/128 kbps). Already economical AAC and multichannel audio pass through. Full exports that save no space are discarded. **High quality** and **Fit within 1080p** remain available; they may produce larger copies. Outputs have unique filenames and JSON manifests.
- Live scan results, resumable indexing, larger photo inspection previews, video playback, side-by-side copy comparison, and persistent export history. Additional date/resolution/availability filters expand when needed.
- Output validation for readability, a decoded frame, duration, dimensions/aspect ratio, frame rate, and audio track count. Actual byte differences are reported; a larger copy is not counted as a saving.
- Confirmed deletion of marked Photos items, with a separate acknowledgement for protected assets. Explicit keepers cannot be deleted. The current Photos item is checked again before submission.
- Confirmed replacement of a Photos video with a reviewed, smaller full export, or an unedited still photo with a reviewed, smaller resized copy. Samples, changed originals, changed copies, keepers and exports without integrity information are excluded. A private verified copy is imported and the original is deleted in a single PhotoKit transaction. Capture date, location, favorite status and regular album membership are copied; other Photos-only metadata may be lost.
- A confirmed Photos review-album action remains available. Folder files are never deleted or replaced by the app.

## Privacy and storage

The application has no networking client. It never uploads photos to an external service or permits PhotoKit resource downloads. Apple's Photos app synchronizes approved album, deletion and replacement operations through the user's existing iCloud configuration. Replacement imports the reviewed copy into Photos, which may upload it to iCloud. These operations change the library across synced devices.

App-owned data lives in:

```text
~/Library/Application Support/FreeTheICloud/
  catalog.sqlite       Saved scans, fingerprints, review plans and export results/errors
  Demo-v2/             Generated demo media
  Thumbnails/          Locally generated analysis previews
  LibraryActions/      Pending/completed/failed mutation receipts
```

The catalog and reports can contain filenames, local paths, and media metadata. They stay local unless you choose a synced output folder or share them yourself. The prototype does not encrypt its local catalog. Thumbnail files remain on disk until the app data is removed; the in-memory thumbnail cache is bounded.

Every launch resets dry-run to on. Reopening a saved scan loads cached metadata and previews; refresh and original-media access remain explicit actions. **Photos access…** is available in the source menu if permission needs to be granted again. The OS PhotoKit permission is read/write because there is no separate read-only authorization mode for this workflow; the app's execution policy independently blocks mutations during dry-run. Changing dry-run mode does not grant access to a source.

Cancellation and failure cleanup removes only app-created temporary files. Deleting a Photos item or replacing a video requires an explicit confirmation; those actions delete originals through PhotoKit. The app never edits Photos database files or empties Recently Deleted. Reports and video exports are rejected inside Photos library bundles.

## Limitations

- **Real-library testing is limited.** The author tested the app by hand on one personal Mac and Photos library. The automated checks use generated fixtures and a simulated library only, and the PhotoKit mutation adapter is not covered by them. Your library, macOS version and iCloud setup may behave differently, so back up first and try a few items before anything larger.
- System Photo Library only. Other libraries, Shared Library edge cases, and shared-album behavior are not validated. Hidden assets are excluded.
- Size measurement may stream every locally available original once. It can be I/O-heavy on a large library. Cached results reduce later work. These totals are not physical disk usage or authoritative iCloud storage totals.
- Photo inspection requests a local preview up to 4096 pixels; grid thumbnails are up to 1200 pixels. Zoom beyond the preview resolution enlarges it. Cached previews are labelled when a larger local preview is unavailable. Groups are suggestions, not safe-to-delete judgments. Perceptual indexing can miss large crops or strongly changed viewpoints; it is not semantic clustering.
- Live Photo resource pairing is supported by the Photos adapter. Files in ordinary folders are treated individually; the prototype does not reconstruct Live Photo pairs from filenames.
- Video compression supports SDR H.264/HEVC, HLG, PQ and iPhone Dolby Vision 8.4. Other Dolby Vision profiles, high-frame-rate, stereo/spatial and recognized specialty formats are excluded. Edited, cinematic, and slow-motion Photos videos are rejected. HDR validation checks color primaries, transfer function, matrix, 10-bit depth and Dolby profile, not every proprietary metadata field or perceptual fidelity. Specialty metadata in arbitrary standalone files is not exhaustively classified, so copies must be visually reviewed.
- The Smaller file preset keeps full exports only when they are smaller. Lower bitrate also means some quality loss, so inspect a sample first. The High quality and 1080p presets do not guarantee savings. Sample projections are approximate and can be misleading for clips with changing complexity.
- Supported container metadata is copied, but export does not preserve Photos asset identity, edit history, album membership, or every proprietary metadata field. The JSON manifest records source identity and limitations; it is not a Photos restoration archive.
- Exporting copies and creating review albums do not free iCloud storage. Use the separate Delete or Replace original action to change the library. Replacement creates a new asset identity; captions, recognition data, sharing state and custom album ordering are not guaranteed to carry over. Unsupported album memberships stop replacement.
- Photos normally provides 30-day recovery, but deleted items may be removed immediately when iCloud is over its storage limit. Recently Deleted does not count toward iCloud storage, according to [Apple’s current storage guidance](https://support.apple.com/en-my/108922). Review-plan Undo cannot reverse a library mutation.
- Screenshot filtering uses PhotoKit metadata. There is no inferred screenshot classifier for folders or screen-recording filter; the installed SDK does not expose that subtype.
- No semantic search, face recognition, automatic batch replacement, background watcher, App Store sandbox, or public-release infrastructure yet. Photo resize exports do not preserve depth data, original gain-map representation or Photos editing history. App inspection thumbnails are SDR previews; open the exported file in an HDR-capable viewer to assess HDR appearance.

## Checks

The package builds with only the command-line tools, which do not include XCTest, so a dependency-free executable provides the core checks:

```sh
swift run --disable-sandbox -c release CoreChecks
```

The checks generate their own images, video, and test audio in temporary directories, then remove those fixtures. They cover dry-run barriers (including stopping before PhotoKit calls), exact and perceptual grouping, date handling, index recall, SQLite persistence, folder boundaries, source changes, corrupt images, actual HEVC encoding, audio preservation, cancellation, unique outputs, and high-frame-rate exclusion. Deletion and replacement use an in-memory library simulator to test policy barriers, selection validation, integrity checks, transaction failure, success receipts and preservation of external export files. The real PhotoKit mutation adapter is compiled but never invoked by these checks. No real photo library is used.

AppKit bitmap captures omit hardware video layers, so player readiness and playback are checked separately.

These runtime checks need ordinary access to macOS media services. A restricted sandbox (for example an agent or CI sandbox) can deny Uniform Type Identifier services and video encoders; run them in a normal local terminal.

The core checks currently cover 41 cases and all pass. They exercise the Smaller file preset on generated SDR, HLG/Dolby Vision and PQ clips (copies were 61–89% smaller than High quality; a fixture measurement, not a guarantee for camera footage), audio channel retention and PCM-to-AAC conversion, loading of older export histories, single-item deletion, Photo replacement barriers (review acknowledgement, dry run, unsupported originals, failed imports, altered copies, stale sources, simulated success), HDR video exports through all presets (downscaling, ten-bit depth, color tags, bright luma, portrait orientation, rejecting an SDR result), and still-photo resizing of PQ HDR, adaptive gain-map HDR, SDR and rotated inputs. A 10,000-record grouping benchmark runs in about 1.3 seconds. Real-camera HDR edge cases and comprehensive keyboard/accessibility behavior are not systematically tested.

To capture only the app's generated-demo windows and exercise basic UI state transitions:

```sh
open -W -n 'dist/Free the iCloud.app' --args \
  --snapshot-dir "$PWD/artifacts/demo-check"
```

This mode uses a separate catalog and generated media under the supplied directory. It tests filters, keepers, undo, persistence, dry-run blocking, actual demo sample/full exports, export history, navigation, a small-window table, photo/video comparison presentation, deletion/replacement confirmation sheets, and dry-run submission barriers. It also checks that both native players become ready for display and advance during playback, and that startup restores the saved workspace without its originals being available. It writes PNGs plus `smoke.txt`, or `smoke-error.txt` on failure, then quits. It does not grant real-source access or perform album changes. It is not a substitute for accessibility, keyboard, or manual interaction testing.

## Layout

`FreeTheICloudCore` owns sources, image analysis, the SQLite actor, execution policy, fixture generation, and video export. `FreeTheICloud` owns the SwiftUI views and the main-actor application model. Expensive analysis runs outside the main actor. Scans save each completed item so cancellation or interruption can reuse completed work. Removed catalog entries are pruned only after a successful scan.

No API keys, Python runtime, FFmpeg, osxphotos, or downloaded ML weights are needed. The app is deliberately based on the supported [PhotoKit APIs](https://developer.apple.com/documentation/PhotoKit), [local Vision feature prints](https://developer.apple.com/documentation/vision/analyzing-image-similarity-with-feature-print), and [AVFoundation export presets](https://developer.apple.com/documentation/avfoundation/export-presets).

PhotoKit replacement uses a single change block, as described in [Apple’s atomic-update documentation](https://developer.apple.com/documentation/photokit/requesting-changes-to-the-photo-library?changes=_9). Behavior with other libraries, album setups and system confirmation dialogs is not guaranteed.


## License

MIT. See [LICENSE](LICENSE). No warranty; use at your own risk.
