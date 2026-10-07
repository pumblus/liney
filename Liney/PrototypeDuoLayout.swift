// PROTOTYPE — throwaway, branch `prototype/duo-layout` only. Never merge.
//
// Question: on iPhone Duo (and any wide window), should the editor clamp text and photos to the
// readable width (wayfinder Q2), and does a size-driven split arrangement for photo detail plus
// "no hinge handling elsewhere" hold up against the fold (Q4)?
//
// Root is always a UISplitViewController (Q1 recommendation). Data is an in-memory store seeded
// with generated sample entries and photos; nothing touches a real journal.
// The floating bar cycles the width variant (A/B/C) and the photo detail variant (Split/Today).
// The overlay prints size classes, window size, split collapse state and the fold region.

import SwiftData
import UIKit

enum PrototypeWidth: String, CaseIterable {
    case a = "A text+photos readable, photo ≤70% height"
    case b = "B text readable, photos full width"
    case c = "C today (no clamp)"
    static let key = "prototype.width"
    static var current: PrototypeWidth {
        get { PrototypeWidth(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .a }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum PrototypeDetail: String, CaseIterable {
    case split = "Split arrangement"
    case today = "Today"
    static let key = "prototype.detail"
    static var current: PrototypeDetail {
        get { PrototypeDetail(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .split }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

extension Notification.Name {
    static let prototypeVariantDidChange = Notification.Name("prototypeVariantDidChange")
}

// MARK: - Sample data

enum PrototypeSeed {
    static func container() -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self, configurations: configuration)
        let context = ModelContext(container)
        let storage = PhotoStorage()
        let paragraph = "Sample paragraph for layout. The quick brown fox jumps over the lazy dog, then keeps running across the meadow until the line wraps several times and shows how long a line of body text becomes on a wide display. "
        // (photo sizes per group), title, days ago
        let plans: [([CGSize], String, Int)] = [
            ([CGSize(width: 1200, height: 900)], "Single landscape photo", 0),
            ([CGSize(width: 900, height: 1600)], "Single tall photo", 1),
            ([CGSize(width: 1000, height: 1000), CGSize(width: 1200, height: 800)], "Two photos", 2),
            ([CGSize(width: 800, height: 800), CGSize(width: 800, height: 1000), CGSize(width: 1000, height: 800)], "Three photos", 3),
            (Array(repeating: CGSize(width: 900, height: 900), count: 5), "Five photos", 5),
            ([], "Text only, long", 8)
        ]
        let colors: [UIColor] = [.systemTeal, .systemOrange, .systemIndigo, .systemPink, .systemGreen]
        for (index, plan) in plans.enumerated() {
            let entry = JournalEntry(title: plan.1, entryDate: Calendar.current.date(byAdding: .day, value: -plan.2, to: .now)!,
                                     locationName: "Sample Place")
            context.insert(entry)
            _ = entry.insertTextBlock(String(repeating: paragraph, count: 2), in: context)
            if !plan.0.isEmpty {
                let items = plan.0.enumerated().compactMap { offset, size -> PhotoGroupItem? in
                    guard let saved = try? storage.saveJPEG(from: image(size: size, color: colors[(index + offset) % colors.count],
                                                                        label: "\(plan.1) #\(offset + 1)")) else { return nil }
                    return PhotoGroupItem(fileName: saved.fileName, capturedAt: entry.entryDate, placeName: "Sample Place")
                }
                entry.insertPhotoGroup(photos: items, in: context)
            }
            _ = entry.insertTextBlock(String(repeating: paragraph, count: index == 5 ? 8 : 3), after: entry.orderedBlocks.last, in: context)
        }
        try! context.save()
        return container
    }

    private static func image(size: CGSize, color: UIColor, label: String) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.35).setStroke()
            let path = UIBezierPath(); path.lineWidth = 8
            path.move(to: .zero); path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.move(to: CGPoint(x: size.width, y: 0)); path.addLine(to: CGPoint(x: 0, y: size.height)); path.stroke()
            let text = "\(label)\n\(Int(size.width))×\(Int(size.height))" as NSString
            text.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.white])
        }
    }
}

// MARK: - Floating switcher + state overlay

final class PrototypeOverlay: UIView {
    private let info = UILabel()
    private let widthButton = UIButton(configuration: .filled())
    private let detailButton = UIButton(configuration: .filled())
    private let foldLayer = CAShapeLayer()
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        foldLayer.fillColor = UIColor.systemRed.withAlphaComponent(0.25).cgColor
        foldLayer.strokeColor = UIColor.systemRed.cgColor
        layer.addSublayer(foldLayer)
        info.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        info.numberOfLines = 0; info.textColor = .white
        for button in [widthButton, detailButton] {
            button.configuration?.baseBackgroundColor = .black
            button.configuration?.cornerStyle = .capsule
            button.configuration?.buttonSize = .mini
        }
        widthButton.addAction(UIAction { [weak self] _ in
            let all = PrototypeWidth.allCases
            PrototypeWidth.current = all[(all.firstIndex(of: PrototypeWidth.current)! + 1) % all.count]
            self?.refresh(); NotificationCenter.default.post(name: .prototypeVariantDidChange, object: nil)
        }, for: .touchUpInside)
        detailButton.addAction(UIAction { [weak self] _ in
            PrototypeDetail.current = PrototypeDetail.current == .split ? .today : .split
            self?.refresh(); NotificationCenter.default.post(name: .prototypeVariantDidChange, object: nil)
        }, for: .touchUpInside)
        let pill = UIStackView(arrangedSubviews: [info, widthButton, detailButton])
        pill.axis = .vertical; pill.alignment = .leading; pill.spacing = 4
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        pill.layer.cornerRadius = 12
        pill.isLayoutMarginsRelativeArrangement = true
        pill.directionalLayoutMargins = .init(top: 8, leading: 10, bottom: 8, trailing: 10)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4),
            pill.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, constant: -16)
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Touches pass through except on the pill.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() { super.layoutSubviews(); refresh() }

    func refresh() {
        widthButton.configuration?.title = "Width: \(PrototypeWidth.current.rawValue)"
        detailButton.configuration?.title = "Photo detail: \(PrototypeDetail.current.rawValue)"
        guard let window else { return }
        let traits = window.traitCollection
        func name(_ s: UIUserInterfaceSizeClass) -> String { s == .regular ? "R" : s == .compact ? "C" : "?" }
        var lines = ["size \(Int(window.bounds.width))×\(Int(window.bounds.height))  h:\(name(traits.horizontalSizeClass)) v:\(name(traits.verticalSizeClass))"]
        if let split = window.rootViewController as? UISplitViewController {
            lines.append("split \(split.isCollapsed ? "collapsed" : "expanded")")
        }
        let path = UIBezierPath()
        if #available(iOS 27.1, *) {
            let regions = reservedRegions(kind: .division, options: .includeInactive)
            lines.append(regions.isEmpty ? "fold: none" : regions.map {
                "fold \($0.isActive ? "ACTIVE" : "inactive") \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))"
            }.joined(separator: "\n"))
            for region in regions where region.isActive {
                path.append(UIBezierPath(rect: region.frame.width < 1 ? region.frame.insetBy(dx: -2, dy: 0) :
                                            region.frame.height < 1 ? region.frame.insetBy(dx: 0, dy: -2) : region.frame))
            }
            let cameras = reservedRegions(kind: .occlusion)
            if !cameras.isEmpty { lines.append("occlusion: \(cameras.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: "; "))") }
            if let axis = PrototypeOverlay.detailAxis { lines.append("photo detail split axis: \(axis)") }
        }
        foldLayer.path = path.cgPath
        info.text = lines.joined(separator: "\n")
    }
    static var detailAxis: String?
}

// MARK: - Photo detail as a split arrangement

@available(iOS 27.1, *)
final class PrototypePhotoDetailSplit: UIViewController {
    let photo: EntryPhoto
    let storage: PhotoStorage
    let actions: [UIAction]
    private let arrangement = UIArrangementViewController()
    init(photo: EntryPhoto, storage: PhotoStorage, actions: [UIAction]) {
        self.photo = photo; self.storage = storage; self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let imageController = UIViewController()
        let image = StoredPhotoView(); image.contentMode = .scaleAspectFit
        image.load(photo.fileName, storage: storage, pixels: PhotoStorage.targetLongEdge)
        image.translatesAutoresizingMaskIntoConstraints = false
        imageController.view.addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: imageController.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            image.trailingAnchor.constraint(equalTo: imageController.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            image.topAnchor.constraint(equalTo: imageController.view.safeAreaLayoutGuide.topAnchor, constant: 16),
            image.bottomAnchor.constraint(equalTo: imageController.view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        let infoController = UIViewController()
        let info = [photo.capturedAt?.formatted(date: .long, time: .shortened), photo.placeDisplayText].compactMap { $0 }.joined(separator: "\n")
        let buttons = actions.map { action -> UIButton in
            let button = actionButton(action.title) { action.performWithSender(nil, target: nil) }
            if action.attributes.contains(.destructive) { button.configuration?.baseForegroundColor = .systemRed }
            return button
        }
        infoController.installStack([bodyLabel(String(localized: "Photo Info"), style: .headline), bodyLabel(info, style: .body)] + buttons)

        addChild(arrangement)
        arrangement.view.frame = view.bounds
        arrangement.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arrangement.view)
        arrangement.didMove(toParent: self)
        arrangement.setViewController(imageController, for: .primary)
        arrangement.setViewController(infoController, for: .secondary)
        var split = UISplitArrangement().axes([.horizontal, .vertical])
        var photoProperties = split.defaultViewProperties
        photoProperties.layoutPriority = 2
        split.setViewProperties(photoProperties, for: .primary)
        var infoProperties = split.defaultViewProperties
        infoProperties.width.minimum = .absolute(260)
        infoProperties.width.preferred = .fractional(0.35)
        split.setViewProperties(infoProperties, for: .secondary)
        arrangement.updateArrangement(split)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let state = arrangement.state(for: .secondary) {
            PrototypeOverlay.detailAxis = state.splitAxis == .horizontal ? "horizontal (side by side)" :
                state.splitAxis == .vertical ? "vertical (stacked)" : "\(state.splitAxis.rawValue)"
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); PrototypeOverlay.detailAxis = nil }
}

// MARK: - Collapse target and auto-open (PROTOTYPE)

/// Collapsing shows the editor when one is open, otherwise the timeline (the default showed the placeholder).
final class PrototypeSplitDelegate: NSObject, UISplitViewControllerDelegate {
    static let shared = PrototypeSplitDelegate()
    func splitViewController(_ svc: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        let secondary = (svc.viewController(for: .secondary) as? UINavigationController)?.topViewController
        return secondary is EntryEditorViewController ? .secondary : .primary
    }
}

/// `SIMCTL_CHILD_PROTO_OPEN=entry|photo` opens the first entry (and its first photo) after launch.
enum PrototypeAutoOpen {
    static func run(in window: UIWindow?) {
        guard let mode = ProcessInfo.processInfo.environment["PROTO_OPEN"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let split = window?.rootViewController as? UISplitViewController,
                  let timeline = (split.viewController(for: .primary) as? UINavigationController)?.viewControllers.first as? TimelineViewController
            else { return }
            timeline.tableView(timeline.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
            if ProcessInfo.processInfo.environment["PROTO_SIDEBAR"] == "hidden" { split.preferredDisplayMode = .secondaryOnly }
            guard mode == "photo" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let editor = (split.viewController(for: .secondary) as? UINavigationController)?.topViewController as? EntryEditorViewController
                    ?? (split.viewController(for: .primary) as? UINavigationController)?.topViewController as? EntryEditorViewController
                    ?? (split.viewController(for: .compact) as? UINavigationController)?.topViewController as? EntryEditorViewController
                    ?? (timeline.navigationController?.topViewController as? EntryEditorViewController)
                guard let editor, let photo = editor.entry.orderedBlocks.first(where: { $0.kind == .photoGroup })?.orderedPhotos.first else { return }
                editor.openPhoto(photo)
            }
        }
    }
}
