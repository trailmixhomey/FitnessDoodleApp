import SwiftUI

struct LoginView: View {
    var onLogin: () -> Void

    var body: some View {
        VStack {
            Spacer()
            Image("doodle-logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
                .padding(.bottom, 20)
            Text("Fitness Doodle")
                .font(.messyLarge(.title))
                .padding(.bottom, 60)
            Button {
                // Real implementation would use Sign in with Apple / Firebase, etc.
                onLogin()
            } label: {
                Text("Sign In")
                    .font(.messyLarge(.headline))
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