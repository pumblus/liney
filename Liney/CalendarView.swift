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
        let bottom = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height
        collectionView.setContentOffset(CGPoint(x: 0, y: max(bottom, -collectionView.adjustedContentInset.top)), animated: false)
    }

    private func day(at indexPath: IndexPath) -> CalendarDay? {
        guard case .day(let date) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return days[date]
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        day(at: indexPath)?.state == .hasEntries
    }
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        day(at: indexPath)?.state == .hasEntries
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let day = day(at: indexPath), day.state == .hasEntries else { return }
        onSelectDay?(day.date)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Date, Item> {
        let cells = UICollectionView.CellRegistration<CalendarDayCell, Item> { [unowned self] cell, _, item in
            guard case .day(let date) = item else { cell.configure(nil, storage: self.storage); return }
            cell.configure(self.days[date], storage: self.storage)
        }
        let headers = UICollectionView.SupplementaryRegistration<CalendarMonthHeader>(
            elementKind: UICollectionView.elementKindSectionHeader) { [unowned self] header, _, indexPath in
            header.configure(month: self.dataSource.sectionIdentifier(for: indexPath.section))
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

/// A month's name above the weekday names, in the system calendar's order.
private final class CalendarMonthHeader: UICollectionReusableView {
    private let title = bodyLabel("", style: .title2)
    private let weekdays = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        title.accessibilityTraits = .header
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

    func configure(month: Date?) {
        title.text = month?.formatted(.dateTime.month(.wide).year())
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
        let style: UIFont.Weight = day.state == .hasEntries ? .semibold : .regular
        number.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: style))
        styleNumber()
        isAccessibilityElement = true
        accessibilityLabel = day.date.formatted(.dateTime.month(.wide).day())
        accessibilityValue = switch day.state {
        case .hasEntries where day.photoFileName != nil: String(localized: "\(day.entryCount) entries, with photos")
        case .hasEntries: String(localized: "\(day.entryCount) entries")
        case .noEntries, .future: String(localized: "No entries")
        }
        accessibilityTraits = day.state == .hasEntries ? .button : .none
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
