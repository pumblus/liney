import UIKit

/// How photo detail lays out the photo and its Photo Info and actions.
enum PhotoDetailLayout: Equatable {
    /// The 1.0 layout: the photo above a footnote, with actions in the Photo Actions menu.
    case stacked
    /// The photo leading, Photo Info and action buttons trailing.
    case sideBySide
    /// The photo above a fold across the window, Photo Info and action buttons below it.
    case aroundFold

    /// Side by side needs regular width: the system split shows only the photo in compact width.
    /// `divisions` are the window's fold regions; only an active one across the window places the photo above it.
    init(size: CGSize, horizontalSizeClass: UIUserInterfaceSizeClass, divisions: [EditorFoldRule.Division]) {
        if divisions.contains(where: \.isActiveHorizontal) {
            self = .aroundFold
        } else if horizontalSizeClass == .regular, size.width > size.height {
            self = .sideBySide
        } else {
            self = .stacked
        }
    }
}

/// One photo detail action, shown as a menu item when stacked and as a button otherwise.
struct PhotoDetailAction {
    let title: String
    let isDestructive: Bool
    let perform: () -> Void

    var menuAction: UIAction {
        UIAction(title: title, attributes: isDestructive ? .destructive : []) { _ in perform() }
    }

    var button: UIButton {
        let button = actionButton(title, action: perform)
        if isDestructive {
            button.configuration?.baseForegroundColor = .systemRed
            button.configuration?.baseBackgroundColor = .systemRed
        }
        return button
    }
}

/// The photo as the primary view and its Photo Info and actions as the secondary view.
@available(iOS 27.1, *)
func makePhotoArrangement(photo: EntryPhoto, storage: PhotoStorage, info: String,
                          actions: [PhotoDetailAction]) -> UIArrangementViewController {
    let photoPane = UIViewController()
    let image = StoredPhotoView(); image.contentMode = .scaleAspectFit
    image.load(photo.fileName, storage: storage, pixels: PhotoStorage.targetLongEdge)
    image.translatesAutoresizingMaskIntoConstraints = false
    photoPane.view.addSubview(image)
    let safeArea = photoPane.view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
        image.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 24),
        image.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -24),
        image.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 24),
        image.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -24)
    ])
    let infoPane = UIViewController()
    infoPane.installStack([bodyLabel(info)] + actions.map(\.button))

    let arrangement = UIArrangementViewController()
    arrangement.setViewController(photoPane, for: .primary)
    arrangement.setViewController(infoPane, for: .secondary)
    return arrangement
}

@available(iOS 27.1, *)
extension UIArrangementViewController {
    /// Splits along the layout's axis; around a fold, the system places the split at the fold.
    func arrangePhoto(_ layout: PhotoDetailLayout) {
        var split = UISplitArrangement().axes(layout == .aroundFold ? .vertical : .horizontal)
        var info = split.defaultViewProperties
        if layout == .sideBySide {
            info.width.minimum = .absolute(260)
            info.width.preferred = .fractional(0.35)
        }
        split.setViewProperties(info, for: .secondary)
        updateArrangement(split)
    }
}
