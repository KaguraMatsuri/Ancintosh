import AncintoshCore
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class PasteboardBridge: NSObject, ClipboardAccess {
    public var changed: ((URL?, String?, String?) -> Void)?
    private let pasteboard = NSPasteboard.general
    private var count = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var original: URL?
    private var mime: String?

    public var permitted: Bool { pasteboard.accessBehavior == .alwaysAllow }
    public func start() {
        stop()
        count = pasteboard.changeCount
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    public func stop() { timer?.invalidate(); timer = nil }
    private func poll() {
        guard permitted, pasteboard.changeCount != count else { return }
        count = pasteboard.changeCount
        do {
            let payload = try current()
            changed?(payload.0, payload.1, payload.2)
        } catch { changed?(nil, nil, nil) }
    }
    public func current() throws -> (URL?, String?, String?) {
        guard permitted else { throw ProtocolFailure.permissionDenied }
        if let value = pasteboard.string(forType: .fileURL), let file = URL(string: value), file.isFileURL {
            if file == original, let mime { return (file, nil, mime) }
            let resource = try file.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
            if resource.isRegularFile == true, let type = resource.contentType, type.conforms(to: .image) {
                return (file, nil, type.preferredMIMEType ?? "application/octet-stream")
            }
        }
        if pasteboard.types?.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true }) == true {
            throw ProtocolFailure.originalUnavailable
        }
        if let text = pasteboard.string(forType: .string) { return (nil, text, "text/plain;charset=utf-8") }
        throw ProtocolFailure.sourceUnavailable
    }
    public func apply(_ manifest: TransferManifest, file: URL) throws {
        if manifest.kind == .text {
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard let text = String(data: bytes, encoding: .utf8) else { throw ProtocolFailure.invalidFrame }
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else { throw ProtocolFailure.permissionDenied }
        } else if manifest.kind == .image {
            original = file
            mime = manifest.mime
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            if let type = UTType(mimeType: manifest.mime) {
                item.setDataProvider(OriginalFileProvider(file), forTypes: [NSPasteboard.PasteboardType(type.identifier)])
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { throw ProtocolFailure.permissionDenied }
        }
        count = pasteboard.changeCount
    }
}

private final class OriginalFileProvider: NSObject, NSPasteboardItemDataProvider {
    private let original: URL
    init(_ original: URL) { self.original = original }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = try? Data(contentsOf: original, options: .mappedIfSafe) else { return }
        item.setData(data, forType: type)
    }
}
