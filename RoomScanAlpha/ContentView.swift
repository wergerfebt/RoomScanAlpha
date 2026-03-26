import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "camera.viewfinder")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .font(.system(size: 60))
            Text("Hello World")
                .font(.largeTitle)
                .padding(.top)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
