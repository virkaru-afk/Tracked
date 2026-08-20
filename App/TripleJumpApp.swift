import SwiftUI

/// The app entry point.
///
/// Deliberately the only file in the app target that contains logic, and it
/// contains almost none. A library cannot carry `@main`, which is the whole
/// reason this file exists separately.
///
/// There is no `import TJApp`. The app target compiles `Sources/TJApp/*.swift`
/// directly rather than consuming the Swift package, and that is a deliberate
/// requirement rather than a shortcut: CocoaPods integrates MediaPipe into the
/// *app target*, and a SwiftPM package target cannot see pod-installed
/// frameworks. Were these files compiled as a package, every
/// `#if canImport(MediaPipeTasksVision)` in `PoseEstimator.swift` and
/// `PoseModelBundle.frameworkAvailable` would evaluate false even on a build
/// where MediaPipe was linked and working — pose extraction would silently
/// compile to the throwing stub, and the hardware check would report the
/// framework missing while it sat right there in the binary.
///
/// `Package.swift` still exists, and still builds the same sources, so the
/// numerical core can be tested without Xcode or pods. It is a second way to
/// build these files, not the way the app is built.
@main
struct TripleJumpAppMain: App {
    var body: some Scene {
        TripleJumpScene().body
    }
}
