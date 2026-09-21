import UIKit

final class SettingsViewController: UITableViewController {
    let appLock: AppLockModel
    init(appLock: AppLockModel) { self.appLock = appLock; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = String(localized: "Settings") }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : 2 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? String(localized: "Use Face ID, Touch ID, or your device passcode to protect Liney.") : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = String(localized: "App Lock"); content.image = UIImage(systemName: "lock")
            let toggle = UISwitch()
            toggle.isOn = UserDefaults.standard.bool(forKey: "liney.requiresAppLock")
            toggle.accessibilityLabel = content.text
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                if !toggle.isOn {
                    UserDefaults.standard.set(false, forKey: "liney.requiresAppLock")
                    self.appLock.disableLock()
                } else {
                    toggle.isEnabled = false
                    Task {
                        let success = await self.appLock.authenticateToEnable()
                        UserDefaults.standard.set(success, forKey: "liney.requiresAppLock")
                        toggle.isOn = success; toggle.isEnabled = true
                        if !success {
                            self.showError(String(localized: "Could Not Enable App Lock"), message: String(localized: "Device authentication was not completed."))
                        }
                    }
                }
            }, for: .valueChanged)
            cell.accessoryView = toggle
        } else {
            content.text = indexPath.row == 0 ? String(localized: "Privacy") : String(localized: "About")
            content.image = UIImage(systemName: indexPath.row == 0 ? "hand.raised" : "info.circle")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        let controller: MessageController
        if indexPath.row == 0 {
            controller = MessageController(title: String(localized: "Privacy"), message: [
                String(localized: "Your journal is stored on this device."),
                String(localized: "Liney does not require an account."),
                String(localized: "Liney does not collect analytics or advertising data."),
                String(localized: "Photos you add are copied into Liney so entries keep working."),
                String(localized: "Imports and exports happen only when you choose them.")
            ].joined(separator: "\n\n"))
        } else {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            controller = MessageController(title: String(localized: "About"), message: "Liney\n\n" + String(localized: "A light journal for words and photos.") + "\n\n" + String(localized: "Version") + " \(version) (\(build))")
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}
