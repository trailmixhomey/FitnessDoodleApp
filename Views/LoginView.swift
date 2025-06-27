import SwiftUI

struct LoginView: View {
    var onLogin: () -> Void

    var body: some View {
        VStack {
            Spacer()
            Text("🖋️")
                .font(.system(size: 80))
            Text("Fitness Doodle")
                .font(.custom("Noteworthy", size: 40))
                .padding(.bottom, 60)
            Button {
                // Real implementation would use Sign in with Apple / Firebase, etc.
                onLogin()
            } label: {
                Text("Sign In")
                    .font(.headline)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.black, lineWidth: 2)
                    )
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}

#Preview {
    LoginView(onLogin: {})
} 