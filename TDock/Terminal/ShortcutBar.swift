import SwiftTerm
import TDockCore
import UIKit

/// 键盘上方的自定义快捷栏（替换 SwiftTerm 默认的 inputAccessoryView）。
///
/// - 多页按键，左右滑动切换；按键内容来自设置中的 `ShortcutLayout`。
/// - Ctrl / Alt 为单次锁定修饰键（作用于下一次按键，由 SwiftTerm 的 controlModifier / metaModifier 实现）。
/// - **长按 Ctrl** 弹出常用组合键菜单（Ctrl+C/D/Z/L/R/A/E/K/U）。
/// - 方向键交给 SwiftTerm 按当前光标模式（普通/应用）发送，按住自动重复。
/// - 右侧 Agent 按钮展开 Agent 快捷抽屉（Esc、Tab 补全、Ctrl+C 中断、↑/↓ 历史）。
/// - 所有功能都是按键，不使用手势代替按键。
@MainActor
final class ShortcutBar: UIInputView, UIInputViewAudioFeedback {
    private static let rowHeight: CGFloat = 44
    private static let drawerHeight: CGFloat = 50

    private weak var terminalView: TerminalView?
    private var layout: ShortcutLayout
    private var drawerVisible = false

    private let scrollView = UIScrollView()
    private let pageControl = UIPageControl()
    private let pagesStack = UIStackView()
    private let drawer = UIStackView()
    private let agentButton = UIButton(type: .system)
    private var modifierButtons: [ShortcutKey: UIButton] = [:]
    private var repeatTimer: Timer?
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    var enableInputClicksWhenVisible: Bool { true }

    init(terminalView: TerminalView, layout: ShortcutLayout) {
        self.terminalView = terminalView
        self.layout = layout.normalized()
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.rowHeight), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleHeight
        allowsSelfSizing = true
        buildViews()
        rebuildPages()
        NotificationCenter.default.addObserver(self, selector: #selector(modifiersReset),
                                               name: .terminalViewControlModifierReset, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(modifiersReset),
                                               name: .terminalViewMetaModifierReset, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.rowHeight + (drawerVisible ? Self.drawerHeight : 0))
    }

    func update(layout newLayout: ShortcutLayout) {
        let normalized = newLayout.normalized()
        guard normalized != layout else { return }
        layout = normalized
        rebuildPages()
    }

    // MARK: - Layout

    private func buildViews() {
        // Agent 抽屉（默认隐藏）
        drawer.axis = .horizontal
        drawer.distribution = .fillEqually
        drawer.spacing = 6
        drawer.isHidden = true
        let drawerTitles: [ShortcutKey: String] = [.esc: "Esc", .tab: "Tab 补全", .ctrlC: "^C 中断", .up: "↑ 历史", .down: "↓ 历史"]
        for key in ShortcutKey.agentDrawer {
            drawer.addArrangedSubview(makeButton(for: key, title: drawerTitles[key] ?? key.label, prominent: true))
        }

        // 分页按键区
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        pagesStack.axis = .horizontal
        pagesStack.distribution = .fillEqually
        pagesStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(pagesStack)

        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = false
        pageControl.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .tertiaryLabel

        agentButton.setImage(UIImage(systemName: "sparkles"), for: .normal)
        agentButton.accessibilityLabel = "Agent 快捷抽屉"
        agentButton.addTarget(self, action: #selector(toggleDrawer), for: .touchUpInside)
        let hideKeyboard = UIButton(type: .system)
        hideKeyboard.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hideKeyboard.accessibilityLabel = "收起键盘"
        hideKeyboard.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)

        let mainRow = UIStackView(arrangedSubviews: [scrollView, agentButton, hideKeyboard])
        mainRow.axis = .horizontal
        mainRow.spacing = 4
        let column = UIStackView(arrangedSubviews: [drawer, mainRow])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        addSubview(pageControl)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            mainRow.heightAnchor.constraint(equalToConstant: Self.rowHeight - 8),
            drawer.heightAnchor.constraint(equalToConstant: Self.drawerHeight - 6),
            agentButton.widthAnchor.constraint(equalToConstant: 36),
            hideKeyboard.widthAnchor.constraint(equalToConstant: 36),
            pagesStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            pagesStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            pagesStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            pagesStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            pagesStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            pageControl.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 6),
        ])
    }

    private func rebuildPages() {
        pagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        modifierButtons = [:]
        for keys in layout.pages {
            let page = UIStackView()
            page.axis = .horizontal
            page.distribution = .fillEqually
            page.spacing = 5
            for key in keys { page.addArrangedSubview(makeButton(for: key, title: key.label, prominent: false)) }
            pagesStack.addArrangedSubview(page)
            // 每页宽度 = 可视宽度，实现整页滑动。
            page.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
        }
        pageControl.numberOfPages = layout.pages.count
        pageControl.currentPage = 0
        scrollView.contentOffset = .zero
        modifiersReset()
    }

    private func makeButton(for key: ShortcutKey, title: String, prominent: Bool) -> UIButton {
        var config = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.monospacedSystemFont(ofSize: prominent ? 14 : 15, weight: .medium)
            return attributes
        }
        config.titleLineBreakMode = .byClipping
        let button = UIButton(configuration: config)
        button.accessibilityLabel = key.title
        button.tag = ShortcutKey.allCases.firstIndex(of: key) ?? 0

        switch key.kind {
        case .cursor:
            // 按下即发送，按住重复。
            button.addTarget(self, action: #selector(cursorDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(stopRepeat), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        case .modifier:
            button.addTarget(self, action: #selector(modifierTapped(_:)), for: .touchUpInside)
            button.changesSelectionAsPrimaryAction = false
            modifierButtons[key] = button
            if key == .ctrl {
                // 长按 Ctrl：常用组合键菜单（点按仍是锁定 Ctrl）。
                button.menu = UIMenu(title: "组合键", children: ShortcutKey.controlCombos.map { combo in
                    UIAction(title: combo.title) { [weak self] _ in self?.press(combo) }
                })
                button.showsMenuAsPrimaryAction = false
            }
        case .bytes:
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        }
        return button
    }

    // MARK: - Actions

    private func key(for sender: UIButton) -> ShortcutKey {
        ShortcutKey.allCases[sender.tag]
    }

    @objc private func keyTapped(_ sender: UIButton) {
        press(key(for: sender))
    }

    @objc private func modifierTapped(_ sender: UIButton) {
        guard let terminalView else { return }
        feedback()
        switch key(for: sender) {
        case .ctrl: terminalView.controlModifier.toggle()
        case .alt: terminalView.metaModifier.toggle()
        default: break
        }
        modifiersReset()
    }

    @objc private func cursorDown(_ sender: UIButton) {
        let key = key(for: sender)
        press(key)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                    Task { @MainActor in self?.sendCursor(key) }
                }
            }
        }
    }

    @objc private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    /// 发送一个按键。按键立即写出，不攒批。
    func press(_ key: ShortcutKey) {
        guard let terminalView else { return }
        feedback()
        switch key.kind {
        case .modifier:
            break
        case .cursor:
            sendCursor(key)
        case .bytes(var bytes):
            // 锁定的 Alt 作用于快捷栏按键：加 ESC 前缀（Meta）。
            if terminalView.metaModifier {
                bytes.insert(0x1B, at: 0)
                terminalView.metaModifier = false
            }
            terminalView.controlModifier = false
            terminalView.send(bytes)
        }
        modifiersReset()
    }

    private func sendCursor(_ key: ShortcutKey) {
        guard let terminalView else { return }
        switch key {
        case .up: terminalView.sendKeyUp()
        case .down: terminalView.sendKeyDown()
        case .left: terminalView.sendKeyLeft()
        case .right: terminalView.sendKeyRight()
        case .home: terminalView.sendKeyHome()
        case .end: terminalView.sendKeyEnd()
        default: break
        }
    }

    @objc private func modifiersReset() {
        modifierButtons[.ctrl]?.isSelected = terminalView?.controlModifier ?? false
        modifierButtons[.alt]?.isSelected = terminalView?.metaModifier ?? false
        for (key, button) in modifierButtons {
            var config = button.configuration
            let active = key == .ctrl ? terminalView?.controlModifier == true : terminalView?.metaModifier == true
            config?.baseBackgroundColor = active ? .tintColor : nil
            config?.baseForegroundColor = active ? .white : nil
            button.configuration = config
        }
    }

    @objc private func toggleDrawer() {
        feedback()
        drawerVisible.toggle()
        drawer.isHidden = !drawerVisible
        agentButton.tintColor = drawerVisible ? .tintColor : nil
        agentButton.isSelected = drawerVisible
        invalidateIntrinsicContentSize()
        terminalView?.reloadInputViews()
    }

    @objc private func dismissKeyboard() {
        _ = terminalView?.resignFirstResponder()
    }

    private func feedback() {
        UIDevice.current.playInputClick()
        haptics.impactOccurred()
    }
}

extension ShortcutBar: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        pageControl.currentPage = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
    }
}
