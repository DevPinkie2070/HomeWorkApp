import SwiftUI

struct ContentView: View {
    @AppStorage("memberID") private var memberID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HomeWorkApp")
                .font(.title)
                .bold()

            if memberID.isEmpty {
                Text("Keine Member-ID gesetzt. Bitte in den Einstellungen hinterlegen.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Aktive Member-ID: \(memberID)")
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
