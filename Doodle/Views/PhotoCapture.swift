import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// What the camera can actually do right now, asked before anything is presented.
///
/// `UIImagePickerController` does not refuse a camera it cannot show: on a device with the
/// permission denied, and in the simulator, it presents a black screen with a shutter button that
/// does nothing. Checking first is what turns both of those into something the user can act on.
enum CameraAccess {
    /// False in the simulator and on any device without a usable camera.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    enum Result { case authorized, denied, unavailable }

    static func request() async -> Result {
        guard isAvailable else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        default:
            return .denied
        }
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The system camera, as a SwiftUI view.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    /// Called for both a capture and a cancel.
    ///
    /// The picker is embedded as a child of the cover's hosting controller rather than presented
    /// by it, so it has no `presentingViewController` to dismiss itself through: closing it means
    /// telling SwiftUI to take the cover down.
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onFinish()
        }
    }
}

/// A button that adds photos to a walk, from the camera or the photo library.
///
/// Both places that collect photos — the walk in progress and the summary afterwards — want the
/// same behaviour behind very different chrome, so the label is supplied by the caller and only
/// the sources, the permissions and the loading live here.
struct AddPhotoButton<Label: View>: View {
    var maxSelection: Int = 5
    var identifier: String = "addPhotoButton"
    let onPicked: ([UIImage]) -> Void
    @ViewBuilder var label: () -> Label

    @State private var isChoosingSource = false
    @State private var isShowingCamera = false
    @State private var isShowingLibrary = false
    @State private var isShowingPermissionAlert = false
    @State private var libraryItems: [PhotosPickerItem] = []

    var body: some View {
        Button { isChoosingSource = true } label: { label() }
            .accessibilityIdentifier(identifier)
            .confirmationDialog("Add a photo", isPresented: $isChoosingSource, titleVisibility: .visible) {
                // Offered only when there is a camera to open, so the simulator and a device with
                // the camera restricted show the library rather than a button that goes nowhere.
                if CameraAccess.isAvailable {
                    Button("Take Photo") { requestCamera() }
                }
                Button("Choose from Library") { isShowingLibrary = true }
                Button("Cancel", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker(onCapture: { onPicked([$0]) }, onFinish: { isShowingCamera = false })
                    .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $isShowingLibrary,
                selection: $libraryItems,
                maxSelectionCount: maxSelection,
                matching: .images
            )
            .onChange(of: libraryItems) { _, items in
                guard !items.isEmpty else { return }
                libraryItems = []
                Task { await load(items) }
            }
            .alert("Camera Access Is Off", isPresented: $isShowingPermissionAlert) {
                Button("Open Settings") { CameraAccess.openSettings() }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Turn on the camera for Fitness Doodle in Settings to take photos on your walk.")
            }
    }

    private func requestCamera() {
        Task {
            switch await CameraAccess.request() {
            case .authorized: isShowingCamera = true
            case .denied: isShowingPermissionAlert = true
            case .unavailable: isShowingLibrary = true
            }
        }
    }

    /// Loads the picked items in the order they were selected.
    ///
    /// `loadTransferable` finishes out of order, so the results are gathered by index rather than
    /// appended as they arrive — otherwise a large photo picked first lands after a small one
    /// picked second, and the strip is in an order the user did not choose.
    private func load(_ items: [PhotosPickerItem]) async {
        var images = [UIImage?](repeating: nil, count: items.count)
        for (index, item) in items.enumerated() {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    images[index] = UIImage(data: data)
                }
            } catch {
                Log.general.error("Could not load a picked photo: \(error.localizedDescription, privacy: .public)")
            }
        }
        let picked = images.compactMap { $0 }
        guard !picked.isEmpty else { return }
        onPicked(picked)
    }
}

/// A photo from the store, loaded off the main thread and swapped in when it arrives.
///
/// Decoding even a downscaled JPEG takes long enough to drop frames if it happens while a strip
/// is being scrolled, and `Image(uiImage:)` gives no way to do it anywhere else.
struct StoredPhotoView: View {
    let id: String
    var thumbnail = true
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                // The file can be genuinely missing — a write that failed, or a photo taken by a
                // build before the walk was saved — so this is a resting state, not just a delay.
                ZStack {
                    Color(white: 0.93)
                    Image(systemName: "photo")
                        .foregroundStyle(Color(white: 0.6))
                }
            }
        }
        .task(id: id) {
            let store = PhotoStore.shared
            let id = self.id
            let wantsThumbnail = thumbnail
            image = await Task.detached(priority: .userInitiated) {
                wantsThumbnail ? store.thumbnail(for: id) : store.image(for: id)
            }.value
        }
    }
}

/// The row of photos taken on a walk, with a tile for adding more.
///
/// Shared by the summary shown when a walk ends and the detail view for a saved one, so a photo
/// can be added, opened or removed in the same way wherever the walk is being looked at.
struct WalkPhotoStrip: View {
    let photos: [WalkPhoto]
    var tileSize: CGFloat = 76
    let onTap: (WalkPhoto) -> Void
    let onAdd: ([UIImage]) -> Void
    let onDelete: (WalkPhoto) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(photos.isEmpty ? "Add a photo from your walk" : "Photos from your walk")
                .font(.messyLarge(.caption))
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(photos) { photo in
                        Button { onTap(photo) } label: {
                            StoredPhotoView(id: photo.id)
                                .frame(width: tileSize, height: tileSize)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Add Route Overlay", systemImage: "scribble") { onTap(photo) }
                            Button("Remove Photo", systemImage: "trash", role: .destructive) { onDelete(photo) }
                        }
                    }

                    AddPhotoButton(identifier: "stripAddPhotoButton", onPicked: onAdd) {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.fill").font(.title3)
                            Text("Add").font(.messyLarge(.caption2))
                        }
                        .foregroundStyle(.black)
                        .frame(width: tileSize, height: tileSize)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.96))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.black, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }
}
