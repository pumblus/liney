import UIKit

/// The Calendar View: the journal's months as grids of days, shown in the timeline column.
final class CalendarViewController: UICollectionViewController {
    private enum Item: Hashable {
        case leading(month: Date, index: Int)
        case day(Date)
    }
    private var days: [Date: CalendarDay] = [:]
    private var months: [CalendarMonth] = []
    private var needsScrollToCurrentMonth = true
    private let storage: PhotoStorage
    /// Runs with the start of a tapped day that has entries.
    var onSelectDay: ((Date) -> Void)?
    private lazy var dataSource = makeDataSource()
    /// Runs with the start of a month and its Month Header when the header is tapped.
    var onSelectMonthHeader: ((Date, UIView) -> Void)?
    /// The first moment of each month the calendar shows, oldest first.
    var monthStarts: [Date] { months.map(\.start) }

    init(storage: PhotoStorage) {
        self.storage = storage
        super.init(collectionViewLayout: Self.layout())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The timeline column's background shows through, as behind the list.
        collectionView.backgroundColor = .clear
        collectionView.dataSource = dataSource
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollToCurrentMonthIfNeeded()
    }

    func apply(_ calendar: MonthCalendar) {
        let previous = days
        months = calendar.months
        days = Dictionary(uniqueKeysWithValues: calendar.months.flatMap(\.days).map { ($0.date, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Date, Item>()
        for month in calendar.months {
            snapshot.appendSections([month.start])
            snapshot.appendItems((0..<month.leadingEmptyDays).map { .leading(month: month.start, index: $0) }, toSection: month.start)
            snapshot.appendItems(month.days.map { .day($0.date) }, toSection: month.start)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            guard case .day(let date) = $0, let old = previous[date] else { return false }
            return old != days[date]
        })
        dataSource.apply(snapshot, animatingDifferences: false)
        scrollToCurrentMonthIfNeeded()
    }

    /// Where the day starting at `date` is in the grid, or nil outside the calendar's range.
    func indexPath(for date: Date) -> IndexPath? { dataSource.indexPath(for: .day(date)) }

    /// The calendar opens at the current month, the last one.
    private func scrollToCurrentMonthIfNeeded() {
        guard needsScrollToCurrentMonth, !months.isEmpty, collectionView.bounds.height > 0 else { return }
        needsScrollToCurrentMonth = false
        collectionView.layoutIfNeeded()
        scroll(to: collectionView.bottomContentOffsetY)
    }

    /// Scrolls `month`'s header to the top, as far as the content allows.
    func scroll(toMonth month: Date) {
        guard let section = dataSource.index(for: month) else { return }
        collectionView.layoutIfNeeded()
        guard let header = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) else { return }
        let top = collectionView.adjustedContentInset.top
        scroll(to: max(min(header.frame.minY - top, collectionView.bottomContentOffsetY), -top))
    }

    /// Scrolls to `y`, unless that leaves the expanded large title over the first month: a scroll from the top
    /// shorter than the title does not collapse it, so the calendar stays at the top instead.
    private func scroll(to y: CGFloat) {
        let top = collectionView.adjustedContentInset.top
        let fromTop = collectionView.contentOffset.y <= -top + 0.5
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        // Only a collapsed split view, one stack as on iPhone, shows the timeline's large title.
        guard fromTop, y > -top, splitViewController?.isCollapsed ?? true else { return }
        // The navigation bar collapses its large title in this layout pass when the scroll is long enough.
        view.window?.layoutIfNeeded()
        if collectionView.adjustedContentInset.top >= top { collectionView.setContentOffset(CGPoint(x: 0, y: -top), animated: false) }
    }

    private func day(at indexPath: IndexPath) -> CalendarDay? {
        guard case .day(let date) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return days[date]
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        day(at: indexPath)?.isTappable ?? false
    }
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        day(at: indexPath)?.isTappable ?? false
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let day = day(at: indexPath), day.isTappable else { return }
        onSelectDay?(day.date)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Date, Item> {
        let cells = UICollectionView.CellRegistration<CalendarDayCell, Item> { [unowned self] cell, _, item in
            guard case .day(let date) = item else { cell.configure(nil, storage: self.storage); return }
            cell.configure(self.days[date], storage: self.storage)
        }
        let headers = UICollectionView.SupplementaryRegistration<CalendarMonthHeader>(
            elementKind: UICollectionView.elementKindSectionHeader) { [unowned self] header, _, indexPath in
            guard let month = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            header.configure(month: month)
            header.onTap = { [unowned self] source in self.onSelectMonthHeader?(month, source) }
        }
        let dataSource = UICollectionViewDiffableDataSource<Date, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cells, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headers, for: indexPath)
        }
        return dataSource
    }

    /// Seven square columns per week; each month is a section under its own header.
    private static func layout() -> UICollectionViewCompositionalLayout {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / 7),
                                                                             heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                                                          heightDimension: .fractionalWidth(1.0 / 7)),
                                                       repeatingSubitem: item, count: 7)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .readableContent
        section.supplementaryContentInsetsReference = .readableContent
        section.contentInsets.bottom = 24
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        section.boundarySupplementaryItems = [header]
        return UICollectionViewCompositionalLayout(section: section)
    }
}

/// A Month Header: the month's name as a button that opens Go to Month, above the weekday names in the system calendar's order.
private final class CalendarMonthHeader: UICollectionReusableView {
    private let title: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        configuration.image = UIImage(systemName: "chevron.down",
                                      withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .tintColor }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.accessibilityHint = String(localized: "Changes the month shown in the calendar.")
        // The VoiceOver rotor still moves month by month.
        button.accessibilityTraits.insert(.header)
        return button
    }()
    var onTap: ((UIView) -> Void)?
    private let weekdays = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.addAction(UIAction { [unowned self] _ in self.onTap?(self.title) }, for: .primaryActionTriggered)
        weekdays.distribution = .fillEqually
        let calendar = Calendar.current
        let shift = calendar.firstWeekday - 1
        let rotate = { (symbols: [String]) in Array(symbols[shift...] + symbols[..<shift]) }
        for (short, full) in zip(rotate(calendar.veryShortStandaloneWeekdaySymbols), rotate(calendar.standaloneWeekdaySymbols)) {
            let label = bodyLabel(short, style: .footnote)
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.numberOfLines = 1
            label.accessibilityLabel = full
            weekdays.addArrangedSubview(label)
        }
        let stack = UIStackView(arrangedSubviews: [title, weekdays])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(month: Date) {
        let name = month.formatted(.dateTime.month(.wide).year())
        title.configuration?.title = name
        title.accessibilityLabel = name
    }
}

/// One day's date number, over the day's representative photo when it has one and it loads;
/// a leading cell before day 1 shows nothing.
private final class CalendarDayCell: UICollectionViewCell {
    private let number = bodyLabel("")
    private let photo = StoredPhotoView()
    private var day: CalendarDay?
    /// The photo file shown or loading, so reconfiguring the same day keeps it instead of reloading.
    private var photoFileName: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        photo.isAccessibilityElement = false
        photo.isHidden = true
        photo.layer.cornerRadius = 6
        photo.translatesAutoresizingMaskIntoConstraints = false
        photo.onAvailabilityChange = { [unowned self] available in
            self.photo.isHidden = !available
            self.styleNumber()
        }
        contentView.addSubview(photo)
        number.layer.shadowColor = UIColor.black.cgColor
        number.layer.shadowOffset = .zero
        number.layer.shadowRadius = 2
        number.textAlignment = .center
        number.numberOfLines = 1
        number.adjustsFontSizeToFitWidth = true
        number.minimumScaleFactor = 0.5
        number.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(number)
        NSLayoutConstraint.activate([
            photo.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            photo.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            photo.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            photo.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            number.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            number.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            number.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ day: CalendarDay?, storage: PhotoStorage) {
        self.day = day
        showPhoto(day?.photoFileName, storage: storage)
        guard let day else {
            number.text = nil
            isAccessibilityElement = false
            return
        }
        number.text = day.number.formatted()
        let style: UIFont.Weight = day.isTappable ? .semibold : .regular
        number.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: style))
        styleNumber()
        isAccessibilityElement = true
        accessibilityLabel = day.date.formatted(.dateTime.month(.wide).day())
        accessibilityValue = switch day.state {
        case .hasEntries where day.photoFileName != nil: String(localized: "\(day.entryCount) entries, with photos")
        case .hasEntries: String(localized: "\(day.entryCount) entries")
        case .noEntries, .future: String(localized: "No entries")
        }
        accessibilityTraits = day.isTappable ? .button : .none
    }

    /// Loads off the main actor; a file that cannot be loaded hides the photo, leaving the date number.
    private func showPhoto(_ fileName: String?, storage: PhotoStorage) {
        guard fileName != photoFileName else { return }
        photoFileName = fileName
        photo.cancel()
        photo.isHidden = true
        if let fileName { photo.load(fileName, storage: storage, pixels: 300) }
    }

    /// The date number reads in white over a photo; today keeps Liney Aqua.
    private func styleNumber() {
        guard let day else { return }
        let onPhoto = !photo.isHidden
        number.layer.shadowOpacity = onPhoto ? 0.6 : 0
        number.textColor = switch day.state {
        case .future: .tertiaryLabel
        case _ where day.isToday: UIColor(named: "LineyAqua") ?? .tintColor
        case _ where onPhoto: .white
        case .hasEntries: .label
        case .noEntries: .secondaryLabel
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        photo.cancel()
        photo.isHidden = true
        photoFileName = nil
    }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? .systemFill : nil }
    }
}
