import SwiftTerm
import UIKit
import XCTest
@testable import TDock

final class CompositionInputTests: XCTestCase {
    @MainActor
    func testPreeditIsVisibleAndDoesNotReachServer() {
        let (view, recorder) = makeView()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(view.compositionPreviewText, "nihao")
        XCTAssertTrue(recorder.bytes.isEmpty)
    }

    @MainActor
    func testBackspaceEditsAtCompositionCaretWithoutRemoteBackspace() {
        let (view, recorder) = makeView()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 2, length: 0))
        view.deleteBackward()
        XCTAssertEqual(view.compositionPreviewText, "nhao")
        XCTAssertTrue(recorder.bytes.isEmpty)
        let marked = view.markedTextRange!
        XCTAssertEqual(view.offset(from: marked.start, to: view.selectedTextRange!.start), 1)
    }

    @MainActor
    func testSelectedPreeditDeletionAndCancellationStayLocal() {
        let (view, recorder) = makeView()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 1, length: 3))
        view.deleteBackward()
        XCTAssertEqual(view.compositionPreviewText, "no")
        view.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNil(view.compositionPreviewText)
        XCTAssertTrue(recorder.bytes.isEmpty)
    }

    @MainActor
    func testDeletingLastPreeditCharacterDoesNotDeleteRemoteText() {
        let (view, recorder) = makeView()
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        view.deleteBackward()
        XCTAssertNil(view.markedTextRange)
        XCTAssertNil(view.compositionPreviewText)
        XCTAssertTrue(recorder.bytes.isEmpty)
        view.deleteBackward()
        XCTAssertEqual(recorder.bytes, [0x7f])
    }

    @MainActor
    func testCommittingChineseSendsExactlyOnceAndHidesPreview() {
        let (view, recorder) = makeView()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        view.insertText("你好")
        XCTAssertNil(view.compositionPreviewText)
        XCTAssertEqual(recorder.bytes, Array("你好".utf8))
        view.unmarkText()
        XCTAssertEqual(recorder.bytes, Array("你好".utf8))
    }

    @MainActor
    func testUnicodePreeditDeletionUsesCharacterBoundaries() {
        let (view, recorder) = makeView()
        let text = "n👩🏽‍💻"
        view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        view.deleteBackward()
        XCTAssertEqual(view.compositionPreviewText, "n")
        XCTAssertTrue(recorder.bytes.isEmpty)
    }

    @MainActor
    func testUnmarkedEnglishAndBackspaceKeepWorking() {
        let (view, recorder) = makeView()
        view.insertText("abc")
        view.deleteBackward()
        XCTAssertEqual(recorder.bytes, Array("abc".utf8) + [0x7f])
        XCTAssertNil(view.compositionPreviewText)
    }

    @MainActor
    func testCompositionWithSystemKeyboardDelegateAndResponderLifecycle() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let (view, recorder) = makeView()
        controller.view = view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        XCTAssertTrue(view.becomeFirstResponder())
        view.feed(text: "Local input preview\r\n$ ")
        view.setMarkedText("nihao", selectedRange: NSRange(location: 3, length: 0))
        view.deleteBackward()
        XCTAssertEqual(view.compositionPreviewText, "niao")
        XCTAssertTrue(recorder.bytes.isEmpty)
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { context in view.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Pinyin composition preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        view.insertText("你好")
        XCTAssertEqual(recorder.bytes, Array("你好".utf8))
        XCTAssertNil(view.compositionPreviewText)
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertTrue(view.becomeFirstResponder())
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(view.compositionPreviewText, "zhong")
    }

    @MainActor
    func testPreeditSurvivesTabletAndNarrowWindowResizing() throws {
        let (view, recorder) = makeView()
        view.setMarkedText("zhongwen", selectedRange: NSRange(location: 3, length: 0))
        for size in [CGSize(width: 1194, height: 650), CGSize(width: 834, height: 850),
                     CGSize(width: 320, height: 250)] {
            view.frame.size = size
            view.setNeedsLayout()
            view.layoutIfNeeded()
            // Off-window views have no active keyboard; reattach the observer explicitly.
            view.observeComposition()
            XCTAssertEqual(view.compositionPreviewText, "zhongwen")
            XCTAssertTrue(view.bounds.contains(try XCTUnwrap(view.compositionPreviewFrame)))
            XCTAssertEqual(view.offset(from: view.markedTextRange!.start, to: view.selectedTextRange!.start), 3)
            XCTAssertTrue(recorder.bytes.isEmpty)
        }
        view.insertText("中文")
        XCTAssertEqual(recorder.bytes, Array("中文".utf8))
    }

    @MainActor
    private func makeView() -> (ComposingTerminalView, OutputRecorder) {
        let recorder = OutputRecorder()
        let view = ComposingTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        view.terminalDelegate = recorder
        view.observeComposition()
        return (view, recorder)
    }
}

@MainActor
private final class OutputRecorder: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
