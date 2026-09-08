import SwiftUI

struct StartDoodlingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showTracking = false
    @State private var chosenColor: Color = .primaryColor

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                GoButton {
                    showTracking = true
                }
                Spacer()

                HStack(spacing: 12) {
                    ForEach(palette, id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: chosenColor == color ? 50 : 36, height: chosenColor == color ? 50 : 36)
                            .scaleEffect(chosenColor == color ? 1.0 : 0.95)
                            .animation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0), value: chosenColor)
                            .onTapGesture { 
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0)) {
                                    chosenColor = color 
                                }
                            }
                    }
                }
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .navigationTitle("Start Doodling")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { 
                        dismiss() 
                    }
                    .font(.messyLarge(.body))
                }
            }
            .navigationDestination(isPresented: $showTracking) {
                // no-op
            }
            .fullScreenCover(isPresented: $showTracking) {
                TrackingView(strokeColor: chosenColor) {
                    // Dismiss both the tracking view and this start view to go back to home
                    showTracking = false
                    dismiss()
                }
            }
        }
        .background(Color.white.ignoresSafeArea())
    }

    private var palette: [Color] {
        [.fern, .coral, .cantaloupe, .cerulean, .primaryColor]
    }

    private struct GoButton: View {
        var action: () -> Void
        var body: some View {
            Button(action: action) {
                Text("GO")
                    .font(.custom("MessyHandwritten-Regular", size: 90))
                    .foregroundColor(.black)
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.black, lineWidth: 4))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    NavigationStack {
        StartDoodlingView()
    }
} 
