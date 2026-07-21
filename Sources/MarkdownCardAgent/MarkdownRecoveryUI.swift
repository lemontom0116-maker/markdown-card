import AppKit
import Foundation
import MarkdownCardCore

@MainActor
final class VersionHistoryPickerController: NSObject {
    let view: NSView
    private let popUpButton = NSPopUpButton()
    private let textView = NSTextView()
    private let snapshots: [CardVersionSnapshot]
    private let currentMarkdown: String
    private let formatter: DateFormatter

    init(snapshots: [CardVersionSnapshot], currentMarkdown: String) {
        self.snapshots = snapshots
        self.currentMarkdown = currentMarkdown
        formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 390))
        super.init()

        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        for snapshot in snapshots {
            popUpButton.addItem(
                withTitle: "\(formatter.string(from: snapshot.capturedAt)) — \(snapshot.title)"
            )
        }
        popUpButton.target = self
        popUpButton.action = #selector(selectionChanged(_:))
        popUpButton.setAccessibilityLabel("Card version")

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.setAccessibilityLabel("Version comparison")
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        view.addSubview(popUpButton)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            popUpButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            popUpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            popUpButton.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: popUpButton.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateComparison()
    }

    var selectedSnapshot: CardVersionSnapshot? {
        guard snapshots.indices.contains(popUpButton.indexOfSelectedItem) else { return nil }
        return snapshots[popUpButton.indexOfSelectedItem]
    }

    @objc private func selectionChanged(_ sender: Any?) {
        updateComparison()
    }

    private func updateComparison() {
        guard let snapshot = selectedSnapshot else {
            textView.string = "No version selected."
            return
        }
        textView.string = MarkdownComparison.render(
            original: snapshot.markdown,
            modified: currentMarkdown,
            originalLabel: "Selected Version",
            modifiedLabel: "Current Card"
        )
        textView.scrollToBeginningOfDocument(nil)
    }
}

@MainActor
func makeMarkdownComparisonAccessory(
    original: String,
    modified: String,
    originalLabel: String,
    modifiedLabel: String
) -> NSView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    textView.string = MarkdownComparison.render(
        original: original,
        modified: modified,
        originalLabel: originalLabel,
        modifiedLabel: modifiedLabel
    )
    textView.textContainerInset = NSSize(width: 10, height: 10)
    textView.setAccessibilityLabel("Markdown comparison")
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    return scrollView
}

enum MarkdownRendererRecoveryReason: Equatable, Sendable {
    case rendererUnavailable
    case navigationFailed
    case renderFailed
    case renderTimedOut
    case webContentTerminated

    var title: String {
        switch self {
        case .rendererUnavailable:
            "Preview is unavailable"
        case .navigationFailed, .renderFailed:
            "Preview could not be loaded"
        case .renderTimedOut:
            "Preview stopped responding"
        case .webContentTerminated:
            "Preview closed unexpectedly"
        }
    }

    var guidance: String {
        switch self {
        case .rendererUnavailable:
            "The renderer could not be found. Your Markdown is still available."
        case .navigationFailed, .renderFailed:
            "The Rich editor could not show this card. Your Markdown is still available."
        case .renderTimedOut:
            "Rendering took too long. Retry Rich view or continue safely in Source."
        case .webContentTerminated:
            "The web renderer exited. Retry Rich view or continue safely in Source."
        }
    }
}

@MainActor
final class MarkdownPreviewRecoveryView: NSView {
    var onRetry: (() -> Void)?
    var onOpenSource: (() -> Void)?
    var onCopyMarkdown: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let guidanceLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let sourceButton = NSButton(title: "Open Source", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private var resolvedAppearance: ResolvedAppearance

    init(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        super.init(frame: .zero)
        configure()
        apply(resolvedAppearance: resolvedAppearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(reason: MarkdownRendererRecoveryReason, diagnostic: String? = nil) {
        titleLabel.stringValue = reason.title
        guidanceLabel.stringValue = reason.guidance
        guidanceLabel.toolTip = diagnostic
        statusLabel.stringValue = ""
        setAccessibilityLabel("\(reason.title). \(reason.guidance)")
    }

    func showCopyResult(success: Bool) {
        statusLabel.stringValue = success ? "Markdown copied" : "Unable to copy Markdown"
        statusLabel.textColor = success
            ? MonochromePalette.secondaryText(for: resolvedAppearance)
            : NSColor.systemRed
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [.announcement: statusLabel.stringValue]
        )
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        wantsLayer = true
        layer?.backgroundColor = MonochromePalette.windowBackground(
            for: resolvedAppearance
        ).cgColor
        iconView.contentTintColor = MonochromePalette.secondaryText(for: resolvedAppearance)
        titleLabel.textColor = MonochromePalette.primaryText(for: resolvedAppearance)
        guidanceLabel.textColor = MonochromePalette.secondaryText(for: resolvedAppearance)
        statusLabel.textColor = MonochromePalette.secondaryText(for: resolvedAppearance)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("markdownPreview.recovery")

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.arrow.triangle.2.circlepath",
            accessibilityDescription: "Preview recovery"
        )
        iconView.symbolConfiguration = .init(pointSize: 23, weight: .regular)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2

        guidanceLabel.translatesAutoresizingMaskIntoConstraints = false
        guidanceLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        guidanceLabel.alignment = .center
        guidanceLabel.maximumNumberOfLines = 3

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.setAccessibilityLabel("Recovery status")

        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.bezelStyle = .rounded
        retryButton.keyEquivalent = "\r"
        retryButton.identifier = NSUserInterfaceItemIdentifier("markdownPreview.recovery.retry")
        retryButton.setAccessibilityLabel("Retry Rich View")
        retryButton.setAccessibilityHelp("Reload the Rich Markdown editor")

        sourceButton.target = self
        sourceButton.action = #selector(openSource(_:))
        sourceButton.bezelStyle = .rounded
        sourceButton.identifier = NSUserInterfaceItemIdentifier("markdownPreview.recovery.source")
        sourceButton.setAccessibilityHelp("Continue editing with the native Markdown source editor")

        copyButton.target = self
        copyButton.action = #selector(copyMarkdown(_:))
        copyButton.bezelStyle = .rounded
        copyButton.identifier = NSUserInterfaceItemIdentifier("markdownPreview.recovery.copy")
        copyButton.setAccessibilityLabel("Copy Markdown")

        let buttonRow = NSStackView(views: [retryButton, sourceButton, copyButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillProportionally
        buttonRow.spacing = 8

        let content = NSStackView(views: [iconView, titleLabel, guidanceLabel, buttonRow, statusLabel])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 9
        addSubview(content)

        let horizontalContainment = [
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
        ]
        horizontalContainment.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(horizontalContainment)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            guidanceLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])
    }

    @objc private func retry(_ sender: Any?) {
        onRetry?()
    }

    @objc private func openSource(_ sender: Any?) {
        onOpenSource?()
    }

    @objc private func copyMarkdown(_ sender: Any?) {
        onCopyMarkdown?()
    }
}

@MainActor
final class MarkdownNativeSourceRecoveryView: NSView, NSTextViewDelegate {
    var onRetry: (() -> Void)?
    var onCopyMarkdown: (() -> Void)?
    var onMarkdownChange: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Markdown Source")
    private let noteLabel = NSTextField(labelWithString: "Rich preview unavailable — edits are still saved")
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let scrollView = NSScrollView()
    let textView = NSTextView()
    private var isApplyingMarkdown = false
    private var resolvedAppearance: ResolvedAppearance

    init(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        super.init(frame: .zero)
        configure()
        apply(resolvedAppearance: resolvedAppearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var markdown: String { textView.string }

    func setMarkdown(_ markdown: String) {
        guard textView.string != markdown else { return }
        let selection = textView.selectedRange()
        isApplyingMarkdown = true
        textView.string = markdown
        let upperBound = (markdown as NSString).length
        textView.setSelectedRange(NSRange(
            location: min(selection.location, upperBound),
            length: min(selection.length, max(0, upperBound - min(selection.location, upperBound)))
        ))
        isApplyingMarkdown = false
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    func showCopyResult(success: Bool) {
        statusLabel.stringValue = success ? "Markdown copied" : "Unable to copy Markdown"
        statusLabel.textColor = success
            ? MonochromePalette.secondaryText(for: resolvedAppearance)
            : NSColor.systemRed
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [.announcement: statusLabel.stringValue]
        )
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        wantsLayer = true
        layer?.backgroundColor = MonochromePalette.windowBackground(
            for: resolvedAppearance
        ).cgColor
        titleLabel.textColor = MonochromePalette.primaryText(for: resolvedAppearance)
        noteLabel.textColor = MonochromePalette.secondaryText(for: resolvedAppearance)
        statusLabel.textColor = MonochromePalette.secondaryText(for: resolvedAppearance)
        textView.textColor = MonochromePalette.primaryText(for: resolvedAppearance)
        textView.backgroundColor = MonochromePalette.controlFill(for: resolvedAppearance)
        scrollView.backgroundColor = MonochromePalette.controlFill(for: resolvedAppearance)
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingMarkdown else { return }
        onMarkdownChange?(textView.string)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("markdownPreview.nativeSource")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        noteLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        noteLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.setAccessibilityLabel("Source editor status")

        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.bezelStyle = .rounded
        retryButton.identifier = NSUserInterfaceItemIdentifier("markdownPreview.source.retry")
        retryButton.setAccessibilityLabel("Retry Rich View")
        retryButton.setAccessibilityHelp("Reload the Rich Markdown editor")
        copyButton.target = self
        copyButton.action = #selector(copyMarkdown(_:))
        copyButton.bezelStyle = .rounded
        copyButton.identifier = NSUserInterfaceItemIdentifier("markdownPreview.source.copy")
        copyButton.setAccessibilityLabel("Copy Markdown")

        let labels = NSStackView(views: [titleLabel, noteLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let controls = NSStackView(views: [statusLabel, copyButton, retryButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        let header = NSStackView(views: [labels, controls])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill

        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.setAccessibilityLabel("Markdown source editor")
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        addSubview(header)
        addSubview(scrollView)
        let containment = [
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ]
        // A Mini card intentionally collapses the entire preview to zero height.
        // Keep the fallback editor's internal layout from changing that window
        // contract while still satisfying these constraints whenever it is shown.
        containment.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(containment)
    }

    @objc private func retry(_ sender: Any?) {
        onRetry?()
    }

    @objc private func copyMarkdown(_ sender: Any?) {
        onCopyMarkdown?()
    }
}

@MainActor
final class MarkdownLinkNoticeView: NSView {
    var onSaveAs: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let saveAsButton = NSButton(title: "Save As…", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)

    init(resolvedAppearance: ResolvedAppearance) {
        super.init(frame: .zero)
        configure()
        apply(resolvedAppearance: resolvedAppearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(message: String) {
        messageLabel.stringValue = message
        setAccessibilityLabel(message)
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let fixedWidth = 12
            + 10
            + saveAsButton.fittingSize.width
            + 4
            + dismissButton.fittingSize.width
            + 8
        let messageWidth = max(72, width - fixedWidth)
        let messageHeight = messageLabel.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: messageWidth, height: 10_000)
        ).height ?? messageLabel.fittingSize.height
        let controlHeight = max(saveAsButton.fittingSize.height, dismissButton.fittingSize.height)
        return ceil(max(messageHeight, controlHeight) + 18)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        wantsLayer = true
        layer?.backgroundColor = MonochromePalette.controlFill(
            for: resolvedAppearance
        ).withAlphaComponent(0.98).cgColor
        layer?.borderColor = MonochromePalette.border(for: resolvedAppearance).cgColor
        messageLabel.textColor = MonochromePalette.primaryText(for: resolvedAppearance)
        saveAsButton.contentTintColor = MonochromePalette.primaryText(for: resolvedAppearance)
        dismissButton.contentTintColor = MonochromePalette.secondaryText(for: resolvedAppearance)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        identifier = NSUserInterfaceItemIdentifier("markdownPreview.linkNotice")

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        messageLabel.maximumNumberOfLines = 3
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        saveAsButton.translatesAutoresizingMaskIntoConstraints = false
        saveAsButton.target = self
        saveAsButton.action = #selector(saveAs(_:))
        saveAsButton.bezelStyle = .inline
        saveAsButton.font = .systemFont(ofSize: 12, weight: .semibold)
        saveAsButton.identifier = NSUserInterfaceItemIdentifier("markdownPreview.linkNotice.saveAs")
        saveAsButton.setAccessibilityHelp("Link this card to a Markdown file")

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.target = self
        dismissButton.action = #selector(dismiss(_:))
        dismissButton.bezelStyle = .inline
        dismissButton.font = .systemFont(ofSize: 12, weight: .regular)
        dismissButton.identifier = NSUserInterfaceItemIdentifier("markdownPreview.linkNotice.dismiss")

        addSubview(messageLabel)
        addSubview(saveAsButton)
        addSubview(dismissButton)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            saveAsButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: 10),
            saveAsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.leadingAnchor.constraint(equalTo: saveAsButton.trailingAnchor, constant: 4),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @objc private func saveAs(_ sender: Any?) {
        onSaveAs?()
    }

    @objc private func dismiss(_ sender: Any?) {
        onDismiss?()
    }
}
