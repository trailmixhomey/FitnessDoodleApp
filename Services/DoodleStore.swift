import Foundation

@MainActor
final class DoodleStore: ObservableObject {
    @Published private(set) var doodles: [Doodle] = []

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("doodles.json")
    }()

    init(preloaded: [Doodle] = []) {
        if preloaded.isEmpty {
            load()
        } else {
            self.doodles = preloaded
        }
    }

    func add(_ doodle: Doodle) {
        doodles.insert(doodle, at: 0)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        do {
            doodles = try JSONDecoder().decode([Doodle].self, from: data)
        } catch {
            print("Failed to decode doodles: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(doodles)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            print("Failed to save doodles: \(error)")
        }
    }
} 