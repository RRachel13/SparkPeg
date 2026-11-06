import AppKit

/// Receives only the selection supplied by macOS Services, never the global
/// clipboard, accessibility tree, OCR or a simulated copy shortcut.
@MainActor
final class TextPinService: NSObject {
    var onPin: ((String) throws -> Void)?

    @objc func pinSelectedText(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        error.pointee = nil
        do {
            let text = try Self.selectedText(from: pasteboard)
            guard let onPin else { throw CocoaError(.featureUnsupported) }
            try onPin(text)
        } catch let failure {
            error.pointee = "\(L("Could not pin selected text"))\n\(failure.localizedDescription)" as NSString
        }
    }

    static func selectedText(from pasteboard: NSPasteboard) throws -> String {
        let text: String?
        if let plain = pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")) {
            text = plain
        } else if let rtf = pasteboard.data(forType: .rtf) {
            text = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil).string
        } else {
            text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "SideLine.TextPin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("Select some text first.")])
        }
        return text
    }
}
