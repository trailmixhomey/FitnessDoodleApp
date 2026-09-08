import Foundation
import CoreLocation

/// An append-only record, written to disk as the walk happens, of the session in progress.
///
/// Everything the tracker holds — the raw fixes, the colour splits, the clock — used to live only
/// in memory until the user tapped Done. A crash, an out-of-memory kill, a reboot or a force-quit
/// mid-walk therefore threw the whole session away with nothing left to recover from. Each
/// accepted fix is now appended here first, so a session survives the process that recorded it.
///
/// The file is newline-delimited JSON rather than one re-encoded document: appending a line is a
/// single small write regardless of how long the walk has run, and a torn final line — the write
/// that was in flight when the process died — costs one fix instead of the entire file.
final class SessionJournal {

    /// A session found on disk that was never finished.
    struct Recovered: Identifiable {
        var startDate: Date
        var startColorHex: String
        var fixes: [GPSFix]
        /// Each colour change: when it happened, and the colour started at that moment.
        var colorChanges: [(date: Date, colorHex: String)]

        var id: Date { startDate }
    }

    /// A journal with fewer fixes than this is not worth offering back — it is a session that was
    /// opened and abandoned before it recorded anything.
    private static let minimumRecoverableFixes = 5

    private static let fileURL: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            Log.general.error("Could not create Application Support directory: \(error.localizedDescription)")
            return nil
        }
        return base.appendingPathComponent("session-journal.ndjson")
    }()

    /// All file I/O happens here, in order, so a fix can never overtake the header or the delete.
    private let queue = DispatchQueue(label: "Trail-Mix.Doodle.SessionJournal")
    private var handle: FileHandle?

    // MARK: - Recording

    /// Starts a fresh journal, discarding any previous one.
    func begin(startDate: Date, startColorHex: String) {
        queue.async { [weak self] in
            guard let self, let url = Self.fileURL else { return }
            self.closeHandle()
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.openHandle(at: url, seekingToEnd: false)
            self.write(Record(kind: .start, t: startDate.timeIntervalSince1970, color: startColorHex))
        }
    }

    /// Reopens an existing journal to keep appending to a session being resumed.
    func resume() {
        queue.async { [weak self] in
            guard let self, let url = Self.fileURL else { return }
            self.closeHandle()
            self.openHandle(at: url, seekingToEnd: true)
        }
    }

    func record(_ fix: GPSFix) {
        queue.async { [weak self] in
            self?.write(Record(fix))
        }
    }

    func recordColorChange(at date: Date, colorHex: String) {
        queue.async { [weak self] in
            self?.write(Record(kind: .color, t: date.timeIntervalSince1970, color: colorHex))
        }
    }

    /// Blocks until everything queued has actually reached the file.
    ///
    /// Writes are queued rather than synchronous so a fix never stalls the location callback, so
    /// anything that reads the journal back straight after writing it has to wait for the queue.
    func flush() {
        queue.sync {}
    }

    /// Ends the session: the journal has served its purpose once the doodle exists.
    func finish() {
        queue.async { [weak self] in
            self?.closeHandle()
            Self.deleteFile()
        }
    }

    // MARK: - Recovery

    /// The unfinished session on disk, if there is one worth offering back.
    ///
    /// A journal that cannot be parsed, or that holds too little to be a real walk, is deleted
    /// here rather than left to prompt on every launch.
    static func pending() -> Recovered? {
        guard let url = fileURL, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }

        var startDate: Date?
        var startColorHex = "#006693"
        var fixes: [GPSFix] = []
        var colorChanges: [(date: Date, colorHex: String)] = []

        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // A torn last line is expected after a crash; skip it rather than failing the session.
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else { continue }
            switch record.kind {
            case .start:
                startDate = Date(timeIntervalSince1970: record.t)
                if let color = record.color { startColorHex = color }
            case .color:
                if let color = record.color {
                    colorChanges.append((Date(timeIntervalSince1970: record.t), color))
                }
            case .fix:
                if let fix = record.gpsFix { fixes.append(fix) }
            }
        }

        guard let startDate, fixes.count >= minimumRecoverableFixes else {
            Log.general.info("Discarding journal with \(fixes.count) fixes; nothing worth recovering")
            deleteFile()
            return nil
        }

        Log.general.info("Recovered unfinished session from \(startDate) with \(fixes.count) fixes")
        return Recovered(startDate: startDate,
                         startColorHex: startColorHex,
                         fixes: fixes,
                         colorChanges: colorChanges)
    }

    /// Throws away the unfinished session without recovering it.
    static func discard() {
        deleteFile()
    }

    private static func deleteFile() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - File handling

    /// Must only be called on `queue`.
    private func openHandle(at url: URL, seekingToEnd: Bool) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Log.general.error("Could not open session journal for writing")
            return
        }
        if seekingToEnd { _ = try? handle.seekToEnd() }
        self.handle = handle
    }

    /// Must only be called on `queue`.
    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// Must only be called on `queue`.
    private func write(_ record: Record) {
        guard let handle, var data = try? JSONEncoder().encode(record) else { return }
        data.append(UInt8(ascii: "\n"))
        do {
            try handle.write(contentsOf: data)
        } catch {
            Log.general.error("Failed to append to session journal: \(error.localizedDescription)")
        }
    }

    // MARK: - Wire format

    /// One line of the journal. Short keys because this is written once per second for hours.
    private struct Record: Codable {
        enum Kind: String, Codable {
            case start = "s"
            case fix = "f"
            case color = "c"
        }

        var kind: Kind
        /// Seconds since 1970.
        var t: Double
        var color: String?
        var lat: Double?
        var lon: Double?
        var acc: Double?
        var spd: Double?
        var sacc: Double?
        var crs: Double?
        var cacc: Double?

        enum CodingKeys: String, CodingKey {
            case kind = "k", t, color = "c", lat, lon, acc, spd, sacc, crs, cacc
        }

        init(kind: Kind, t: Double, color: String? = nil) {
            self.kind = kind
            self.t = t
            self.color = color
        }

        init(_ fix: GPSFix) {
            kind = .fix
            t = fix.timestamp.timeIntervalSince1970
            lat = fix.coordinate.latitude
            lon = fix.coordinate.longitude
            acc = fix.horizontalAccuracy
            spd = fix.speed
            sacc = fix.speedAccuracy
            crs = fix.course
            cacc = fix.courseAccuracy
        }

        var gpsFix: GPSFix? {
            guard let lat, let lon else { return nil }
            return GPSFix(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                timestamp: Date(timeIntervalSince1970: t),
                horizontalAccuracy: acc ?? 10,
                speed: spd ?? -1,
                speedAccuracy: sacc ?? -1,
                course: crs ?? -1,
                courseAccuracy: cacc ?? -1
            )
        }
    }
}
