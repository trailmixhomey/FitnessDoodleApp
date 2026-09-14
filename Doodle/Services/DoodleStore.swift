import Foundation

@MainActor
final class DoodleStore: ObservableObject {
    @Published private(set) var doodles: [Doodle] = []

    /// Set when the saved doodles could not be read and could not be safely set aside either.
    ///
    /// Saving is refused while this is true. The old behaviour — start empty, then write the
    /// empty list back on the next change — turned a single unreadable byte into the silent loss
    /// of every doodle the user had ever saved.
    @Published private(set) var isReadOnly = false

    private static let fileName = "doodles.json"

    private let saveURL: URL

    /// Encoding and writing happen here, off the main actor: the file holds every doodle the
    /// user has, and it is rewritten in full on every add, update and delete.
    private let ioQueue = DispatchQueue(label: "Trail-Mix.Doodle.DoodleStore")

    private let photoStore: PhotoStore

    /// - Parameter directory: where `doodles.json` lives. Defaults to Documents; tests pass a
    ///   temporary directory so they can exercise the recovery paths against real files.
    init(preloaded: [Doodle] = [], directory: URL? = nil, photoStore: PhotoStore = .shared) {
        let dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        saveURL = dir.appendingPathComponent(Self.fileName)
        self.photoStore = photoStore
        if preloaded.isEmpty {
            load()
        } else {
            self.doodles = preloaded
        }
    }

    /// Blocks until every queued write has landed. Tests only.
    func waitForPendingWrites() {
        ioQueue.sync {}
    }

    func add(_ doodle: Doodle) {
        doodles.insert(doodle, at: 0)
        save()
    }

    func update(_ doodle: Doodle) {
        if let index = doodles.firstIndex(where: { $0.id == doodle.id }) {
            doodles[index] = doodle
            save()
        }
    }

    func delete(_ doodle: Doodle) {
        if let index = doodles.firstIndex(where: { $0.id == doodle.id }) {
            doodles.remove(at: index)
            save()
            // The photos are files of their own now, so removing the doodle that named them is
            // what makes them unreachable rather than what frees them.
            photoStore.delete(ids: doodle.photos.map(\.id) + [doodle.overlayPhotoID].compactMap { $0 })
        }
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: saveURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // First run. An empty store is the truth here, and saving is safe.
            return
        } catch {
            // The file is there but unreadable. Do not touch it, and do not let a save overwrite
            // whatever it holds.
            Log.general.error("Could not read saved doodles: \(error.localizedDescription, privacy: .public)")
            isReadOnly = true
            return
        }

        do {
            doodles = try JSONDecoder().decode([Doodle].self, from: data)
        } catch {
            Log.general.error("Failed to decode doodles: \(error.localizedDescription, privacy: .public)")
            quarantineUnreadableFile()
            return
        }

        migrateInlinePhotos()
        // Photo files are written when the shutter is pressed, which is before anyone knows
        // whether the walk will be kept. Anything no doodle refers to by now never will be.
        photoStore.prune(keeping: doodles)
    }

    /// Moves any photo an earlier build stored inside the doodle into its own file.
    ///
    /// Runs once: after the first successful pass nothing has inline data left, so the loop
    /// finds nothing to do and no write happens.
    private func migrateInlinePhotos() {
        var migratedAny = false
        for (index, doodle) in doodles.enumerated() {
            if let migrated = photoStore.migrateInlinePhotos(in: doodle) {
                doodles[index] = migrated
                migratedAny = true
            }
        }
        if migratedAny { save() }
    }

    /// Moves a file we cannot decode out of the way, keeping it under a dated name.
    ///
    /// Once it is safely aside the store can start fresh and accept saves again. If it cannot be
    /// moved, the store stays read-only rather than writing over data that might be salvageable.
    private func quarantineUnreadableFile() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantineURL = saveURL
            .deletingLastPathComponent()
            .appendingPathComponent("doodles-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: saveURL, to: quarantineURL)
            Log.general.error("Moved unreadable doodles file aside to \(quarantineURL.lastPathComponent, privacy: .public)")
            doodles = []
        } catch {
            Log.general.error("Could not set aside unreadable doodles file: \(error.localizedDescription, privacy: .public)")
            isReadOnly = true
        }
    }

    private func save() {
        guard !isReadOnly else {
            Log.general.error("Refusing to save: the doodles on disk could not be read")
            return
        }
        let snapshot = doodles
        let url = saveURL
        ioQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.general.error("Failed to save doodles: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
