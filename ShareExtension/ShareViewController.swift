import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Adds the shared recording to Transcribe and opens the app on it. No processing here.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.close = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.openApp = { [weak self] url in self?.openApp(url) ?? false }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { await model.run(providers.first) }
    }

    /// Share extensions have no official way to open their app. Walking the responder chain
    /// to UIApplication and calling open(_:options:completionHandler:) works in practice; it's
    /// called through the runtime because the method is marked unavailable in extensions.
    /// Returns false if it can't be reached, and the sheet then offers a button instead.
    private func openApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(app.method(for: selector), to: Open.self)
                open(app, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}

@MainActor @Observable
final class ShareModel {
    enum Phase { case adding, added, failed }

    var phase = Phase.adding
    var name = ""
    var error = ""
    var link: URL?
    var close: () -> Void = {}
    var openApp: (URL) -> Bool = { _ in false }

    func run(_ provider: NSItemProvider?) async {
        guard let provider,
              let type = provider.registeredTypeIdentifiers.first(where: {
                  UTType($0)?.conforms(to: .audiovisualContent) == true
              })
        else { return fail("Nothing to add.") }

        do {
            let t = try await Self.copyIntoInbox(provider, type: type)
            name = t.sourceName
            link = URL(string: "transcribe://open?id=\(t.id.uuidString)")
        } catch {
            return fail(error.localizedDescription)
        }
        phase = .added
        open()
    }

    func open() {
        if let link, openApp(link) { close() }
    }

    private func fail(_ message: String) {
        error = message
        phase = .failed
    }

    /// The provider's temporary file is deleted once the handler returns, so copy it there.
    private static func copyIntoInbox(_ provider: NSItemProvider, type: String) async throws -> Transcript {
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    return cont.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
                cont.resume(with: Result {
                    let display = name.map { $0 + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)") }
                    return try Store.importMedia(from: url, name: display)
                })
            }
        }
    }
}
