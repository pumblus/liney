import UIKit

extension Notification.Name {
    static let journalDidChange = Notification.Name("Liney.journalDidChange")
}

extension Error {
    /// Foundation reports a full disk as `NSFileWriteOutOfSpaceError`, often wrapping `ENOSPC`;
    /// ZIPFoundation throws `ENOSPC` directly.
    var isOutOfSpace: Bool {
        var error: NSError? = self as NSError
        while let current = error {
            if current.domain == NSCocoaErrorDomain && current.code == NSFileWriteOutOfSpaceError { return true }
            if current.domain == NSPOSIXErrorDomain && current.code == Int(ENOSPC) { return true }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

var outOfSpaceMessage: String {
    String(localized: "There isn’t enough storage on this device. Free up space and try again.")
}

/// Alert text for a failed write. Raw error text is never shown: it can name private file paths.
func writeFailureMessage(for error: any Error, otherwise fallback: String) -> String {
    error.isOutOfSpace ? outOfSpaceMessage : fallback
}

func bodyLabel(_ text: String, style: UIFont.TextStyle = .body) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: style)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    return label
}

func actionButton(_ title: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(configuration: .tinted(), primaryAction: UIAction(title: title) { _ in action() })
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.titleLabel?.numberOfLines = 0
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    return button
}

extension UIViewController {
    func installStack(_ children: [UIView], centered: Bool = false) {
        view.backgroundColor = .systemBackground
        let scroll = UIScrollView()
        let stack = UIStackView(arrangedSubviews: children)
        stack.axis = .vertical; stack.spacing = 20
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        if centered {
            let content = UIView()
            content.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(content)
            content.addSubview(stack)
            let compactHeight = content.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 48)
            compactHeight.priority = .defaultLow
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 24),
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
                stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48), compactHeight
            ])
            let width = stack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48)
            width.priority = .defaultHigh; width.isActive = true
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
                stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
            ])
        }
    }

    func showError(_ title: String, message: String, onDismiss: (() -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in onDismiss?() })
        present(alert, animated: true)
    }

    func confirmDeletion(title: String, message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in action() })
        present(alert, animated: true)
    }
}

final class MessageController: UIViewController {
    let message: String
    init(title: String, message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); installStack([bodyLabel(message)]) }
}

/// Native, non-interactive status for work that must finish before its surrounding UI can resume.
final class ProcessingViewController: UIViewController {
    private let message: String

    init(title: String, message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
        self.title = title
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let heading = bodyLabel(title ?? "", style: .title2)
        heading.accessibilityTraits.insert(.header)
        let status = bodyLabel(message)
        heading.textAlignment = .center
        status.textAlignment = .center
        let activity = UIActivityIndicatorView(style: .large)
        activity.isAccessibilityElement = false
        activity.startAnimating()
        installStack([heading, activity, status], centered: true)
        view.accessibilityViewIsModal = true
    }
}

/// Bounded serial decoding keeps scrolling work off the main thread and limits peak image memory.
final class StoredPhotoView: UIImageView {
    var onImageSize: ((CGSize) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var deferredSource: (file: String, storage: PhotoStorage, pixels: Int)?
    private var isVisible = false
    private var requestID = UUID()
    private var operation: Operation?
    init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill; clipsToBounds = true
        layer.cornerRadius = 8
        backgroundColor = .secondarySystemBackground
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Photo")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func deferLoading(_ fileName: String, storage: PhotoStorage, pixels: Int) {
        cancel()
        deferredSource = (fileName, storage, pixels)
        isVisible = false
    }
    func updateVisibility(_ visible: Bool) {
        guard let source = deferredSource, visible != isVisible else { return }
        isVisible = visible
        if visible { load(source.file, storage: source.storage, pixels: source.pixels) }
        else { cancel() }
    }
    func load(_ fileName: String, storage: PhotoStorage = PhotoStorage(), pixels: Int = 600) {
        operation?.cancel(); operation = nil; requestID = UUID()
        // A cached image appears in the same frame, so reloads and reuse do not flash empty.
        if let cached = storage.cachedThumbnail(for: fileName, maxPixelSize: pixels) {
            display(cached)
            return
        }
        image = nil
        let id = requestID
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let image = autoreleasepool { storage.thumbnail(for: fileName, maxPixelSize: pixels) }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requestID == id else { return }
                self.display(image)
            }
        }
        self.operation = operation
        Self.queue.addOperation(operation)
    }
    private func display(_ image: UIImage?) {
        self.image = image ?? UIImage(systemName: "photo")
        if let image { onImageSize?(image.size) }
        accessibilityLabel = image == nil ? String(localized: "Photo unavailable") : String(localized: "Photo")
        onAvailabilityChange?(image != nil)
    }
    func cancel() { operation?.cancel(); operation = nil; requestID = UUID(); image = nil }
    deinit { operation?.cancel() }
}
