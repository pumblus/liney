import UIKit

/// Go to Month: year and month wheels over the calendar's month range, with This Month and Done.
/// Reports a month only on Done or This Month; dismissing any other way chooses nothing.
final class GoToMonthViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
    /// The system year and month wheels, on iOS 17.4 and later.
    private(set) var datePicker: UIDatePicker?
    /// Liney's own year and month wheels, before iOS 17.4.
    private(set) var picker: UIPickerView?
    private let usesSystemWheels: Bool
    private let calendar: Calendar
    /// The first moment of each month the wheels offer, oldest first; the last is the current month.
    private let months: [Date]
    private let years: [Int]
    private var selectedYear: Int
    private var selectedMonth: Int
    private let onChoose: (Date) -> Void

    /// `usesSystemWheels` false shows Liney's own wheels where the system ones exist, for tests.
    init(months: [Date], selected: Date, calendar: Calendar = .current, usesSystemWheels: Bool = true,
         onChoose: @escaping (Date) -> Void) {
        self.calendar = calendar
        self.usesSystemWheels = usesSystemWheels
        self.months = months
        var years: [Int] = []
        for month in months where years.last != calendar.component(.year, from: month) {
            years.append(calendar.component(.year, from: month))
        }
        self.years = years
        selectedYear = calendar.component(.year, from: selected)
        selectedMonth = calendar.component(.month, from: selected)
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        navigationItem.title = String(localized: "Go to Month")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "This Month"), primaryAction: UIAction { [weak self] _ in
            guard let self, let current = self.months.last else { return }
            self.choose(current)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self, let month = self.month(year: self.selectedYear, month: self.selectedMonth) else { return }
            self.choose(month)
        })
        let wheels: UIView
        if #available(iOS 17.4, *), usesSystemWheels {
            wheels = makeDatePicker()
        } else {
            let picker = UIPickerView()
            picker.dataSource = self
            picker.delegate = self
            self.picker = picker
            wheels = picker
            selectCurrentRows()
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: GoToMonthViewController, _: UITraitCollection) in
                controller.picker?.reloadAllComponents()
                controller.selectCurrentRows()
            }
        }
        wheels.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wheels)
        NSLayoutConstraint.activate([
            wheels.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            wheels.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            wheels.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            wheels.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    /// The system wheels run from the first month to the current month and dim the months outside it.
    @available(iOS 17.4, *)
    private func makeDatePicker() -> UIDatePicker {
        let datePicker = UIDatePicker()
        datePicker.calendar = calendar
        datePicker.datePickerMode = .yearAndMonth
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.minimumDate = months.first
        datePicker.maximumDate = months.last
        datePicker.date = month(year: selectedYear, month: selectedMonth) ?? months.last ?? .now
        datePicker.addAction(UIAction { [unowned self, unowned datePicker] _ in
            self.selectedYear = self.calendar.component(.year, from: datePicker.date)
            self.selectedMonth = self.calendar.component(.month, from: datePicker.date)
        }, for: .valueChanged)
        self.datePicker = datePicker
        return datePicker
    }

    private func choose(_ month: Date) {
        dismiss(animated: true)
        onChoose(month)
    }

    private func selectCurrentRows() {
        guard let picker else { return }
        if let row = years.firstIndex(of: selectedYear) { picker.selectRow(row, inComponent: 0, animated: false) }
        if let row = monthNumbers(in: selectedYear).firstIndex(of: selectedMonth) { picker.selectRow(row, inComponent: 1, animated: false) }
    }

    private func month(year: Int, month: Int) -> Date? {
        months.first { calendar.component(.year, from: $0) == year && calendar.component(.month, from: $0) == month }
    }

    /// The month numbers the range covers in `year`, so the current year ends at the current month.
    private func monthNumbers(in year: Int) -> [Int] {
        months.filter { calendar.component(.year, from: $0) == year }.map { calendar.component(.month, from: $0) }
    }

    /// The text a wheel row shows: a year in the locale's year format, or a standalone month name.
    func title(forRow row: Int, inComponent component: Int) -> String {
        if component == 0 {
            return month(year: years[row], month: monthNumbers(in: years[row])[0])?.formatted(.dateTime.year()) ?? ""
        }
        return calendar.standaloneMonthSymbols[monthNumbers(in: selectedYear)[row] - 1]
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        component == 0 ? years.count : monthNumbers(in: selectedYear).count
    }
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        if component == 0 {
            selectedYear = years[row]
            // Keep the month when the new year has it; otherwise take the nearest month the year has.
            let numbers = monthNumbers(in: selectedYear)
            selectedMonth = numbers.contains(selectedMonth) ? selectedMonth : selectedMonth < numbers[0] ? numbers[0] : numbers[numbers.count - 1]
            pickerView.reloadComponent(1)
            if let row = numbers.firstIndex(of: selectedMonth) { pickerView.selectRow(row, inComponent: 1, animated: false) }
        } else {
            selectedMonth = monthNumbers(in: selectedYear)[row]
        }
    }
    func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
        UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traitCollection).lineHeight + 12
    }
    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
        let label = view as? UILabel ?? UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traitCollection)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.textAlignment = .center
        label.text = title(forRow: row, inComponent: component)
        return label
    }
}
