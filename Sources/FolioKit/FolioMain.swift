import AppKit

/// Process entry point. Keeps `main.swift` to a single call so the executable target
/// needs almost no `public` surface from FolioKit.
public enum FolioMain {

    public static func run() -> Never {
        if let code = runDebugFlag() { exit(code) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // Retain the delegate: NSApplication holds it weakly.
        retainedDelegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        exit(0)
    }

    private static var retainedDelegate: AppDelegate?

    /// Headless rendering flags used by `make snapshot` and by tests.
    /// Returns an exit code when a flag was handled, `nil` to continue launching normally.
    private static func runDebugFlag() -> Int32? {
        let args = CommandLine.arguments
        guard args.count >= 3 else { return nil }

        switch args[1] {
        case "--render-txt":
            let url = URL(fileURLWithPath: args[2])
            do {
                let doc = try MarkdownDocument(url: url)
                print(DocumentDump.dump(document: doc))
                return 0
            } catch {
                FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8))
                return 1
            }

        case "--render-png":
            guard args.count >= 4 else {
                FileHandle.standardError.write(Data(
                    ("usage: Folio --render-png <file.md> <out.png> [--width N] "
                        + "[--height N] [--page N]\n").utf8
                ))
                return 2
            }
            var options = SnapshotRenderer.Options()
            if let i = args.firstIndex(of: "--width"), args.count > i + 1,
               let width = Double(args[i + 1]) {
                options.width = CGFloat(width)
            }
            if let i = args.firstIndex(of: "--height"), args.count > i + 1,
               let height = Double(args[i + 1]) {
                options.viewportHeight = CGFloat(height)
            }
            if let i = args.firstIndex(of: "--page"), args.count > i + 1,
               let page = Int(args[i + 1]) {
                options.page = page
            }
            do {
                try SnapshotRenderer.render(
                    markdown: URL(fileURLWithPath: args[2]),
                    to: URL(fileURLWithPath: args[3]),
                    options: options
                )
                return 0
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                return 1
            }

        default:
            return nil
        }
    }
}
