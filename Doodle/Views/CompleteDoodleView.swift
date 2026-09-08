import SwiftUI

struct CompleteDoodleView: View {
    @EnvironmentObject private var store: DoodleStore
    @Environment(\.dismiss) private var dismiss

    let result: (doodle: Doodle, image: UIImage)
    @State private var isSharePresented = false
    @State private var shareImageForSheet: UIImage?
    @State private var currentDoodle: Doodle
    @State private var showingDiscardAlert = false
    
    // Callback to dismiss all the way to home
    var onSaveAndDismissToHome: (() -> Void)?
    
    init(result: (doodle: Doodle, image: UIImage), onSaveAndDismissToHome: (() -> Void)? = nil) {
        self.result = result
        self.onSaveAndDismissToHome = onSaveAndDismissToHome
        self._currentDoodle = State(initialValue: result.doodle)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Doodle Image
            Image(uiImage: result.image)
                .resizable()
                .scaledToFit()
                .padding()
                .background(Color.white)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            
            // Stats
            VStack(spacing: 8) {
                Text(String(format: "%.2f mi", result.doodle.distance/1609.34))
                    .font(.messyLarge(.title2))
                    .foregroundColor(.primary)
                
                Text(formatDuration(result.doodle.duration))
                    .font(.messyLarge(.subheadline))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Action Buttons
            VStack(spacing: 24) {
                // Primary actions: Save and Share
                HStack(spacing: 16) {
                    Button {
                        store.add(currentDoodle)
                        if let onSaveAndDismissToHome = onSaveAndDismissToHome {
                            onSaveAndDismissToHome()
                        } else {
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                            Text("Save Doodle")
                        }
                        .font(.messyLarge(.headline))
                    }
                    .buttonStyle(PrimarySketchyButton())
                    
                    Button {
                        shareDoodle()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .font(.messyLarge(.headline))
                    }
                    .buttonStyle(ShareSketchyButton())
                }
                
                // Discard button
                Button {
                    showingDiscardAlert = true
                } label: {
                    Text("Discard Doodle")
                        .font(.messyLarge(.subheadline))
                        .foregroundColor(Color(red: 0.6, green: 0.0, blue: 0.0)) // Dark red
                }
                .padding(.top, 16)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .padding()

        .sheet(isPresented: $isSharePresented) {
            if let shareImage = shareImageForSheet {
                ActivityView(activityItems: [shareImage])
            }
        }
        .alert("Discard Doodle", isPresented: $showingDiscardAlert) {
            Button("Discard", role: .destructive) {
                discardDoodle()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to discard this doodle? This action cannot be undone.")
        }
        // White background across entire screen
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .ignoresSafeArea()
    }
    
    private func discardDoodle() {
        if let onSaveAndDismissToHome = onSaveAndDismissToHome {
            onSaveAndDismissToHome()
        } else {
            dismiss()
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
    
    private func shareDoodle() {
        let shareImage = generateBlankDoodleShareImageWithTime()
        shareImageForSheet = shareImage
        isSharePresented = true
    }
    
    private func resizeImageForSharing(_ image: UIImage) -> UIImage {
        // Social media optimized dimensions: 1080x1920 (9:16 aspect ratio)
        let shareSize = CGSize(width: 1080, height: 1920)
        
        return UIGraphicsImageRenderer(size: shareSize).image { context in
            // Calculate aspect-fit scaling
            let imageAspect = image.size.width / image.size.height
            let targetAspect = shareSize.width / shareSize.height
            
            var drawRect: CGRect
            if imageAspect > targetAspect {
                // Image is wider, fit to width
                let newHeight = shareSize.width / imageAspect
                drawRect = CGRect(x: 0, y: (shareSize.height - newHeight) / 2, width: shareSize.width, height: newHeight)
            } else {
                // Image is taller, fit to height  
                let newWidth = shareSize.height * imageAspect
                drawRect = CGRect(x: (shareSize.width - newWidth) / 2, y: 0, width: newWidth, height: shareSize.height)
            }
            
            // Fill background with white
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: shareSize))
            
            // Draw the image
            image.draw(in: drawRect)
        }
    }
    
    private func generateBlankDoodleShareImageWithTime() -> UIImage {
        // Social media optimized dimensions: 1080x1920 (9:16 aspect ratio)
        let shareSize = CGSize(width: 1080, height: 1920)
        
        // First resize the white background doodle image to share dimensions
        let baseImage = resizeImageForSharing(result.image)
        
        // Create a new image with the time elapsed overlay
        let finalImage = UIGraphicsImageRenderer(size: shareSize).image { context in
            // Draw the base doodle image
            baseImage.draw(at: .zero)
            
            let timeText = formatDuration(currentDoodle.duration)

            let fontSize: CGFloat = 120
            let font = UIFont(name: "MessyHandwritten-Bold", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)

            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black
            ]

            let textSize = timeText.size(withAttributes: textAttributes)

            let textOrigin = CGPoint(
                x: shareSize.width * 0.65 - textSize.width / 2,
                y: shareSize.height * 0.25
            )

            timeText.draw(at: textOrigin, withAttributes: textAttributes)
            
        }
        
        return finalImage
    }
}

private struct PrimarySketchyButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primaryColor)
            )
            .foregroundColor(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

private struct ShareSketchyButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor)
            )
            .foregroundColor(.white)
            .overlay(
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
