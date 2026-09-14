import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One photo taken on a walk.
///
/// This is the part that lives in the doodle: an identifier, when the shutter was pressed, and
/// where the walker was standing. The pixels live in their own file, keyed by `id`.
struct WalkPhoto: Identifiable, Codable, Hashable {
    let id: String
    let takenAt: Date
    /// Where on the route the photo was taken, when a fix was available at the time.
    let coordinate: Coordinate?

    init(id: String = UUID().uuidString, takenAt: Date = Date(), coordinate: Coordinate? = nil) {
        self.id = id
        self.takenAt = takenAt
        self.coordinate = coordinate
    }
}

/// Keeps the photos taken on a walk as ordinary files on disk.
///
/// Photos deliberately do *not* live inside the doodle. `DoodleStore` holds every doodle in one
/// JSON file and rewrites the whole file on every add, update and delete, so a photo kept inline
/// would be re-encoded and re-written every time any doodle anywhere changed — and JSON has no
/// way to carry bytes, so each one would be inflated by a third into base64 first. Ten photos
/// across a few walks is enough to turn deleting a doodle into a visible stall, and to hold every
/// photo the user has ever taken in memory for as long as the gallery is on screen.
///
/// Safe to use from any thread, and deliberately not confined to the main actor: decoding a JPEG
/// is the one thing here that takes long enough to drop a frame, and a photo strip has to be able
/// to do it somewhere else. Everything mutable inside is either immutable after `init` or already
/// thread-safe (`NSCache`, `UserDefaults`, a serial queue).
final class PhotoStore: @unchecked Sendable {
    static let shared = PhotoStore()

    /// Longest edge kept on disk. A full-resolution capture is several times more than the
    /// largest thing the app ever draws with it (a 1080x1920 share image), and costs disk,
    /// decode time and memory on every single view.
    private static let maxPixelSize: CGFloat = 2048
    private static let compressionQuality: CGFloat = 0.85
    /// Longest edge of a cached thumbnail — comfortably more than the strip's 80pt at 3x.
    private static let thumbnailPixelSize: CGFloat = 320

    /// Photos captured during a walk that has not been saved as a doodle yet.
    ///
    /// Held outside the view so a session recovered after a crash or a force-quit comes back with
    /// the photos it had already taken, and so `prune` can tell an in-progress photo apart from
    /// one belonging to a doodle the user discarded.
    private static let inProgressKey = "walkPhotosInProgress"

    private let directory: URL
    private let defaults: UserDefaults

    /// All file work happens here, in order, so pressing the shutter never stalls a frame and a
    /// read can never overtake the write that produced it.
    private let ioQueue = DispatchQueue(label: "Trail-Mix.Doodle.PhotoStore")

    private let thumbnailCache = NSCache<NSString, UIImage>()

    /// - Parameter directory: where the photo files live. Defaults to Application Support, which
    ///   is included in backups — a photo of a walk cannot be regenerated from anything.
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WalkPhotos", isDirectory: true)
        self.directory = base
        self.defaults = defaults
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            Log.general.error("Could not create the photo directory: \(error.localizedDescription, privacy: .public)")
        }
        thumbnailCache.countLimit = 120
    }

    func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).jpg")
    }

    // MARK: - Writing

    /// Files `image` under a fresh identifier and returns the record to hang on the doodle.
    ///
    /// Returns as soon as the identifier exists; the downscale, the encode and the write happen
    /// on `ioQueue`. A thumbnail is made here so the photo strip can show the capture at once
    /// rather than waiting on the disk it was just written to.
    @discardableResult
    func save(_ image: UIImage, takenAt: Date = Date(), at coordinate: Coordinate? = nil) -> WalkPhoto {
        let photo = WalkPhoto(takenAt: takenAt, coordinate: coordinate)
        let destination = url(for: photo.id)

        if let thumbnail = Self.downscale(image, maxPixelSize: Self.thumbnailPixelSize) {
            thumbnailCache.setObject(thumbnail, forKey: photo.id as NSString)
        }

        // A camera capture carries its rotation in `imageOrientation` rather than in its pixels.
        // Redrawing it here bakes the rotation in, so everything downstream that works in pixels
        // — the overlay composition, the share renderer — does not have to know about it.
        let normalized = Self.downscale(image, maxPixelSize: Self.maxPixelSize) ?? image
        let quality = Self.compressionQuality
        ioQueue.async {
            guard let data = normalized.jpegData(compressionQuality: quality) else {
                Log.general.error("Could not encode a captured photo")
                return
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                Log.general.error("Could not write a captured photo: \(error.localizedDescription, privacy: .public)")
            }
        }
        return photo
    }

    /// Blocks until every queued write has landed. Tests only.
    func waitForPendingWrites() {
        ioQueue.sync {}
    }

    // MARK: - Reading

    /// The full stored photo, decoded from disk. Nil if the file is missing or unreadable.
    func image(for id: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: id).path)
    }

    /// A small version of the photo, for strips and grids.
    ///
    /// Decoding a 2048px JPEG to fill an 80pt square costs about forty times the pixels the
    /// screen will use, and a scrolling strip would pay it per photo per appearance. ImageIO
    /// decodes straight to the size asked for.
    func thumbnail(for id: String) -> UIImage? {
        if let cached = thumbnailCache.object(forKey: id as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(url(for: id) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: cgImage)
        thumbnailCache.setObject(thumbnail, forKey: id as NSString)
        return thumbnail
    }

    // MARK: - Deleting

    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { thumbnailCache.removeObject(forKey: id as NSString) }
        let urls = ids.map(url(for:))
        ioQueue.async {
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // Already gone — a prune got there first, or the write never landed.
                } catch {
                    Log.general.error("Could not delete a photo: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Deletes every photo file that nothing refers to any more.
    ///
    /// Photos are written the moment the shutter is pressed, which is long before anyone knows
    /// whether the walk will be saved. Discarding a doodle deletes its photos directly, but a
    /// crash, a force-quit or a battery death between the shutter and the save leaves files
    /// behind that no doodle will ever mention. Run at launch, this is what stops those
    /// accumulating for the life of the install.
    func prune(keeping doodles: [Doodle]) {
        var live = Set(inProgressPhotos.map(\.id))
        for doodle in doodles {
            live.formUnion(doodle.photos.map(\.id))
            if let overlay = doodle.overlayPhotoID { live.insert(overlay) }
        }

        let directory = self.directory
        ioQueue.async {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { return }
            var removed = 0
            for file in files where file.pathExtension == "jpg" {
                guard !live.contains(file.deletingPathExtension().lastPathComponent) else { continue }
                if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
            if removed > 0 {
                Log.general.notice("Pruned \(removed) orphaned photo file(s)")
            }
        }
    }

    // MARK: - The walk in progress

    var inProgressPhotos: [WalkPhoto] {
        get {
            guard let data = defaults.data(forKey: Self.inProgressKey) else { return [] }
            return (try? JSONDecoder().decode([WalkPhoto].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.inProgressKey)
        }
    }

    func clearInProgressPhotos() {
        defaults.removeObject(forKey: Self.inProgressKey)
    }

    // MARK: - Migration

    /// Moves photos that an earlier build stored inline in the doodle into their own files.
    ///
    /// The June 2025 camera build wrote JPEG data straight into `Doodle.photos`, and so into
    /// `doodles.json`. Returns the migrated doodle, or nil if it had nothing inline to move.
    func migrateInlinePhotos(in doodle: Doodle) -> Doodle? {
        let legacyPhotos = doodle.legacyPhotoData ?? []
        let legacyOverlay = doodle.legacyOverlayData
        guard !legacyPhotos.isEmpty || legacyOverlay != nil else { return nil }

        var migrated = doodle
        migrated.photos = legacyPhotos.enumerated().compactMap { index, data in
            guard let image = UIImage(data: data) else { return nil }
            // The old format recorded neither a time nor a place, so date the photos to the walk
            // they belong to and leave the coordinate unknown.
            return save(image, takenAt: doodle.date.addingTimeInterval(Double(index)), at: nil)
        }
        if let legacyOverlay, let image = UIImage(data: legacyOverlay) {
            migrated.overlayPhotoID = save(image, takenAt: doodle.date).id
        }
        migrated.legacyPhotoData = nil
        migrated.legacyOverlayData = nil
        Log.general.notice("Migrated \(migrated.photos.count) inline photo(s) out of a doodle")
        return migrated
    }

    // MARK: - Helpers

    /// Redraws `image` no larger than `maxPixelSize` on its longest edge, with any orientation
    /// baked into the pixels. Returns nil only if the image has no size to work from.
    private static func downscale(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage? {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > 0 else { return nil }
        let scale = min(1, maxPixelSize / longestEdge)
        let size = CGSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
