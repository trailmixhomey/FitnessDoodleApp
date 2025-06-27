import SwiftUI

struct CompleteDoodleView: View {
    @EnvironmentObject private var store: DoodleStore
    @Environment(\.dismiss) private var dismiss

    let result: (doodle: Doodle, image: UIImage)
    @State private var isSharePresented = false

    var body: some View {
        VStack {
            Image(uiImage: result.image)
                .resizable()
                .scaledToFit()
                .padding()
            Text(String(format: "%.2f km", result.doodle.distance/1000))
                .font(.headline)
            Spacer()
            HStack {
                Button("Discard") {
                    dismiss()
                }
                .buttonStyle(SketchyButton())

                Button("Save") {
                    store.add(result.doodle)
                    dismiss()
                }
                .buttonStyle(SketchyButton())

                Button("Share") {
                    isSharePresented = true
                }
                .buttonStyle(SketchyButton())
            }
            .padding()
        }
        .sheet(isPresented: $isSharePresented) {
            ActivityView(activityItems: [result.image])
        }
        // White background across entire screen
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .ignoresSafeArea()
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