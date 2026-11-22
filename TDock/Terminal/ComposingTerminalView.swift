import SwiftTerm
import UIKit

/// Keeps pre-edit text local while preserving SwiftTerm's native keyboard handling.
final class ComposingTerminalView: TerminalView {
    private lazy var compositionObserver = CompositionObserver(owner: self)
    private let preview = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let previewScroll = UIScrollView()
    private let previewLabel = UILabel()
    private let previewCaret = UIView()

    /// Internal so input behavior can be exercised without presenting a keyboard.
    func observeComposition() {
        if inputDelegate !== compositionObserver {
            compositionObserver.downstream = inputDelegate
            inputDelegate = compositionObserver
        }
        refreshComposition()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { observeComposition() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            if inputDelegate === compositionObserver {
                inputDelegate = compositionObserver.downstream
            }
            preview.isHidden = true
        }
        return result
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isFirstResponder { observeComposition() }
    }

    override func deleteBackward() {
        guard let marked = markedTextRange, let composing = text(in: marked) else {
            super.deleteBackward()
            return
        }

        // A terminal backspace must never escape while the IME is editing pre-edit text.
        let string = composing as NSString
        let selection = selectedTextRange ?? marked
        let start = min(string.length, max(0, offset(from: marked.start, to: selection.start)))
        let end = min(string.length, max(start, offset(from: marked.start, to: selection.end)))
        let deletion: NSRange
        if start != end {
            deletion = NSRange(location: start, length: end - start)
        } else if start > 0 {
            deletion = string.rangeOfComposedCharacterSequence(at: start - 1)
        } else {
            return
        }
        let remaining = string.replacingCharacters(in: deletion, with: "")
        setMarkedText(remaining.isEmpty ? nil : remaining,
                      selectedRange: NSRange(location: deletion.location, length: 0))
        refreshComposition()
    }

    var compositionPreviewText: String? { preview.isHidden ? nil : previewLabel.text }
    var compositionPreviewFrame: CGRect? { preview.isHidden ? nil : preview.frame }

    fileprivate func refreshComposition() {
        guard let marked = markedTextRange, let composing = text(in: marked), !composing.isEmpty else {
            preview.isHidden = true
            return
        }
        if preview.superview == nil {
            preview.isUserInteractionEnabled = false
            preview.layer.cornerRadius = 8
            preview.clipsToBounds = true
            previewLabel.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
            previewLabel.textColor = .white
            previewCaret.backgroundColor = .systemTeal
            previewScroll.showsHorizontalScrollIndicator = false
            previewScroll.addSubview(previewLabel)
            previewScroll.addSubview(previewCaret)
            preview.contentView.addSubview(previewScroll)
            addSubview(preview)
        }
        let selection = selectedTextRange ?? marked
        let string = composing as NSString
        let start = min(string.length, max(0, offset(from: marked.start, to: selection.start)))
        let end = min(string.length, max(start, offset(from: marked.start, to: selection.end)))
        let attributes = NSMutableAttributedString(string: composing)
        attributes.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                range: NSRange(location: 0, length: string.length))
        if end > start {
            attributes.addAttribute(.backgroundColor, value: UIColor.systemTeal.withAlphaComponent(0.35),
                                    range: NSRange(location: start, length: end - start))
        }
        previewLabel.attributedText = attributes
        let font = previewLabel.font!
        let textWidth = ceil(string.size(withAttributes: [.font: font]).width)
        let width = min(max(64, textWidth + 24), max(1, bounds.width - 16))
        let height: CGFloat = 38
        // caretFrame and bounds are both in the scroll view's content coordinates.
        let cursor = caretFrame
        let x = max(bounds.minX + 8, min(cursor.minX, bounds.maxX - width - 8))
        let below = cursor.maxY + 4
        let y = max(bounds.minY + 4, min(below + height <= bounds.maxY - 4 ? below : cursor.minY - height - 4,
                                        bounds.maxY - height - 4))
        preview.frame = CGRect(x: x, y: y, width: width, height: height)
        previewScroll.frame = preview.contentView.bounds.insetBy(dx: 10, dy: 6)
        previewLabel.frame = CGRect(x: 0, y: 0, width: textWidth + 2, height: 26)
        let caretX = ceil((string.substring(to: start) as NSString).size(withAttributes: [.font: font]).width)
        previewCaret.frame = CGRect(x: caretX, y: 2, width: 2, height: 22)
        previewCaret.isHidden = end > start
        previewScroll.contentSize = CGSize(width: textWidth + 4, height: 26)
        previewScroll.scrollRectToVisible(CGRect(x: caretX, y: 0, width: 4, height: 26), animated: false)
        preview.isHidden = false
        bringSubviewToFront(preview)
    }
}

/// UIKit owns the input delegate. Forward every callback to it unchanged and
/// observe only completed edits; do not replace the IME or intercept its text.
private final class CompositionObserver: NSObject, UITextInputDelegate {
    weak var owner: ComposingTerminalView?
    weak var downstream: UITextInputDelegate?

    init(owner: ComposingTerminalView) { self.owner = owner }

    func selectionWillChange(_ textInput: UITextInput?) { downstream?.selectionWillChange(textInput) }
    func textWillChange(_ textInput: UITextInput?) { downstream?.textWillChange(textInput) }
    func selectionDidChange(_ textInput: UITextInput?) {
        downstream?.selectionDidChange(textInput)
        owner?.refreshComposition()
    }
    func textDidChange(_ textInput: UITextInput?) {
        downstream?.textDidChange(textInput)
        owner?.refreshComposition()
    }

    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: UITextInput?) {
        downstream?.conversationContext(context, didChange: textInput)
    }
}
