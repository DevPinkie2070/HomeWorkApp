import SwiftUI

struct ContentView: View {
    @ObservedObject var store: HomeworkStore

    var body: some View {
        HomeworkComposerView(store: store)
    }
}
