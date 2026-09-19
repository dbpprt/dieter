#if os(iOS)
    import SwiftUI
    import UIKit

    struct IOSAttachmentTextEditor: UIViewRepresentable {
        @Binding var text: String
        @Binding var isFocused: Bool
        let placeholder: String
        let minimumLines: Int
        let maximumLines: Int
        let accessibilityIdentifier: String
        var keyboardDoneAccessibilityIdentifier: String? = nil
        let pastedImages: ([IOSAttachmentPayload]) -> Void
        let pasteFailed: (Error) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> IOSPasteAwareTextView {
            let view = IOSPasteAwareTextView()
            view.delegate = context.coordinator
            view.backgroundColor = .clear
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.textContainerInset = UIEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
            view.textContainer.lineFragmentPadding = 0
            view.keyboardDismissMode = .interactive
            view.accessibilityIdentifier = accessibilityIdentifier
            view.accessibilityLabel = placeholder
            view.placeholder = placeholder
            view.pastedImages = pastedImages
            view.pasteFailed = pasteFailed
            if let keyboardDoneAccessibilityIdentifier {
                let toolbar = UIToolbar()
                let doneButton = UIButton(type: .system)
                doneButton.setTitle("Done", for: .normal)
                doneButton.titleLabel?.font = .boldSystemFont(ofSize: UIFont.buttonFontSize)
                doneButton.accessibilityIdentifier = keyboardDoneAccessibilityIdentifier
                doneButton.addTarget(
                    context.coordinator, action: #selector(Coordinator.dismissKeyboard), for: .touchUpInside)
                let spacer = UIBarButtonItem(
                    barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
                toolbar.items = [spacer, UIBarButtonItem(customView: doneButton)]
                toolbar.sizeToFit()
                view.inputAccessoryView = toolbar
                context.coordinator.textView = view
            }
            return view
        }

        func updateUIView(_ view: IOSPasteAwareTextView, context: Context) {
            context.coordinator.parent = self
            view.placeholder = placeholder
            view.pastedImages = pastedImages
            view.pasteFailed = pasteFailed
            let shouldApplyExternalText = !view.isFirstResponder || text.isEmpty
            if view.text != text, shouldApplyExternalText {
                view.text = text
                view.updatePlaceholder()
                view.invalidateIntrinsicContentSize()
            }
            if isFocused, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if isFocused {
                context.coordinator.focusBeganInUIKit = false
            } else if view.isFirstResponder, !context.coordinator.focusBeganInUIKit {
                view.resignFirstResponder()
            }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: IOSPasteAwareTextView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width else { return nil }
            let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let verticalInsets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
            let minimumHeight = lineHeight * CGFloat(max(minimumLines, 1)) + verticalInsets
            let maximumHeight = lineHeight * CGFloat(max(maximumLines, minimumLines)) + verticalInsets
            let fitting = uiView.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            let height = min(max(fitting.height, minimumHeight), maximumHeight)
            return CGSize(width: width, height: height)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: IOSAttachmentTextEditor
            var focusBeganInUIKit = false
            weak var textView: UITextView?

            init(_ parent: IOSAttachmentTextEditor) { self.parent = parent }

            @objc func dismissKeyboard() {
                textView?.resignFirstResponder()
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                (textView as? IOSPasteAwareTextView)?.updatePlaceholder()
                textView.invalidateIntrinsicContentSize()
            }

            func textViewDidBeginEditing(_ textView: UITextView) {
                focusBeganInUIKit = true
                parent.isFocused = true
            }

            func textViewDidEndEditing(_ textView: UITextView) {
                focusBeganInUIKit = false
                parent.isFocused = false
            }
        }
    }

    final class IOSPasteAwareTextView: UITextView {
        var pastedImages: ([IOSAttachmentPayload]) -> Void = { _ in }
        var pasteFailed: (Error) -> Void = { _ in }
        var placeholder = "" { didSet { updatePlaceholder() } }

        private lazy var placeholderLabel: UILabel = {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .placeholderText
            label.numberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
            ])
            return label
        }()

        override func paste(_ sender: Any?) {
            let pasteboard = UIPasteboard.general
            guard pasteboard.hasImages else {
                super.paste(sender)
                return
            }
            do {
                pastedImages(try Self.imagePayloads(from: pasteboard))
            } catch {
                pasteFailed(error)
            }
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        func updatePlaceholder() {
            placeholderLabel.text = placeholder
            placeholderLabel.isHidden = !text.isEmpty
        }

        @MainActor
        static func imagePayloads(from pasteboard: UIPasteboard) throws -> [IOSAttachmentPayload] {
            guard let images = pasteboard.images, !images.isEmpty else {
                throw IOSAttachmentError.invalidPaste
            }
            return try images.enumerated().map { index, image in
                guard let data = image.pngData(), !data.isEmpty else {
                    throw IOSAttachmentError.invalidPaste
                }
                let suffix = images.count == 1 ? "" : " \(index + 1)"
                return IOSAttachmentPayload(
                    data: data,
                    filename: "Pasted Screenshot\(suffix).png",
                    mediaType: "image/png")
            }
        }
    }
#endif
