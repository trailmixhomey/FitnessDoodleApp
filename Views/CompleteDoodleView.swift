import SwiftUI
import Photos

struct CompleteDoodleView: View {
    @EnvironmentObject private var store: DoodleStore
    @Environment(\.dismiss) private var dismiss

    let result: (doodle: Doodle, image: UIImage)
    @State private var isSharePresented = false
    @State private var selectedPhotoIndex: Int?
    @State private var showingPhotoOverlay = false
    @State private var currentDoodle: Doodle
    
    init(result: (doodle: Doodle, image: UIImage)) {
        self.result = result
        self._currentDoodle = State(initialValue: result.doodle)
    }
    
    private var photos: [UIImage] {
        // Use display-optimized photos for UI (much smaller memory footprint)
        currentDoodle.photos.compactMap { data in
            guard let fullImage = UIImage(data: data) else { return nil }
            return resizePhotoForDisplay(fullImage)
        }
    }
    
    /// Resize photo for display in UI to reduce memory usage
    private func resizePhotoForDisplay(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 400 // Much smaller for carousel thumbnails
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
    
    private func updateDoodleWithPhotoOverlay(_ overlayImage: UIImage) {
        if let overlayData = overlayImage.jpegData(compressionQuality: 0.9) {
            currentDoodle.savedPhotoOverlay = overlayData
        }
        showingPhotoOverlay = false
    }

    var body: some View {
        VStack {
            Image(uiImage: result.image)
                .resizable()
                .scaledToFit()
                .padding()
            Text(String(format: "%.2f km", result.doodle.distance/1000))
                .font(.headline)
            
            // Photo carousel
            if !photos.isEmpty {
                VStack(spacing: 12) {
                    Text("Photos from your walk")
                        .font(.headline)
                        .padding(.top)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(photos.indices, id: \.self) { index in
                                Button {
                                    selectedPhotoIndex = index
                                    showingPhotoOverlay = true
                                } label: {
                                    Image(uiImage: photos[index])
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.black, lineWidth: 2)
                                        )
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom)
            }
            
            Spacer()
            HStack {
                Button("Discard") {
                    dismiss()
                }
                .buttonStyle(SketchyButton())

                Button("Save") {
                    store.add(currentDoodle)
                    dismiss()
                }
                .buttonStyle(SketchyButton())

                Button("Share") {
                    shareToInstagram()
                }
                .buttonStyle(SketchyButton())
            }
            .padding()
        }
        .sheet(isPresented: $isSharePresented) {
            // Only include the image for Instagram Stories compatibility
            ActivityView(activityItems: [result.image])
        }
        .fullScreenCover(isPresented: $showingPhotoOverlay) {
            if let index = selectedPhotoIndex {
                PhotoOverlayEditor(
                    photo: photos[index],
                    doodle: currentDoodle
                ) { overlayImage in
                    // Handle saved overlay
                    updateDoodleWithPhotoOverlay(overlayImage)
                }
            }
        }
        // White background across entire screen
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .ignoresSafeArea()
    }
    
    private func shareToInstagram() {
        // Use standard iOS share sheet (includes Instagram as an option)
        print("📤 Sharing image with size: \(result.image.size)")
        isSharePresented = true
    }
}

private struct SketchyButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

import UIKit
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview {
    CompleteDoodleView(result: (Doodle(points: [], distance: 1200, duration: 500), UIImage()))
        .environmentObject(DoodleStore())
} 