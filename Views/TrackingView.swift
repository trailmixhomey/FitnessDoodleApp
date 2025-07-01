import SwiftUI
import CoreLocation

struct TrackingView: View {
    @StateObject private var tracker = LocationManager()
    @State private var isCompleted = false
    @State private var capturedPhotos: [UIImage] = []
    @State private var showingCamera = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Background and path drawing
            GeometryReader { proxy in
                let rect = proxy.frame(in: .local)
                let points = tracker.locations.map { Coordinate($0.coordinate) }
                let path = PathRenderer.makePath(from: points, in: rect, addJitter: true)
                path.stroke(Color.black, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 2]))
            }
            .background(Color.white)
            .onAppear { tracker.requestAuthorization(); tracker.start() }
            .ignoresSafeArea(.all, edges: .top) // Only ignore top safe area

            VStack {
                HStack {
                    Text(Date(), style: .time)
                        .font(.caption)
                        .padding(6)
                    Spacer()
                    // Photo count indicator
                    if !capturedPhotos.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                                .font(.caption)
                            Text("\(capturedPhotos.count)")
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.8))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(String(format: "%.2f km", tracker.distance / 1000))
                        .font(.headline)
                        .padding(6)
                }
            }
            .padding()

            // Bottom controls - respect safe area
            VStack {
                Spacer()
                
                // Camera button - positioned more prominently
                HStack {
                    Button {
                        showingCamera = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                                .font(.title)
                                .foregroundColor(.white)
                            Text("Photo")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                        .frame(width: 80, height: 80)
                        .background(Color.red) // Bright red for testing visibility
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    }
                    .padding(.leading, 30)
                    
                    Spacer()
                    
                    // Done button
                    Button {
                        // stop tracking
                        isCompleted = true
                    } label: {
                        Text("Done")
                            .font(.title2)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.black, lineWidth: 2)
                            )
                            .background(Color.white.opacity(0.9))
                    }
                    .padding(.trailing, 30)
                }
                .padding(.bottom, 30) // Reduced padding to ensure visibility
            }
            .ignoresSafeArea(.keyboard) // Only ignore keyboard safe area
        }
        .fullScreenCover(isPresented: $isCompleted) {
            if let result = completeSession() {
                CompleteDoodleView(result: result)
            } else {
                EmptyView()
                    .onAppear { dismiss() }
            }
        }
        .sheet(isPresented: $showingCamera) {
            ImagePicker { image in
                capturedPhotos.append(image)
            }
        }
    }

    private func completeSession() -> (Doodle, UIImage)? {
        let summary = tracker.stop()
        
        // Convert photos to Data for storage with optimized compression
        let photoData = capturedPhotos.compactMap { photo in
            let resizedPhoto = resizePhotoForStorage(photo)
            return resizedPhoto.jpegData(compressionQuality: 0.65)
        }
        
        // Create doodle with photos
        var doodle = Doodle(points: summary.points, distance: summary.distance, duration: summary.duration)
        doodle.photos = photoData

        // Render image snapshot
        let renderer = ImageRenderer(content: PathSnapshotView(doodle: doodle))
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else { return nil }
        return (doodle, uiImage)
    }
    
    /// Resize photo for storage to reduce memory usage while maintaining quality
    private func resizePhotoForStorage(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 1600
        let size = image.size
        
        // If image is already smaller than limit, return as-is
        if max(size.width, size.height) <= maxDimension {
            return image
        }
        
        // Calculate new size maintaining aspect ratio
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        // Resize the image
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

private struct PathSnapshotView: View {
    let doodle: Doodle
    var body: some View {
        GeometryReader { proxy in
            let path = PathRenderer.makePath(from: doodle.points, in: proxy.frame(in: .local))
            path.stroke(Color.black, lineWidth: 4)
                .background(Color.white)
        }
    }
}

// MARK: - ImagePicker
struct ImagePicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.allowsEditing = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#Preview {
    TrackingView()
} 