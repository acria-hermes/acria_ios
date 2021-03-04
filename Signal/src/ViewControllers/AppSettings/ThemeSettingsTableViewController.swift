//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
class ThemeSettingsTableViewController: OWSTableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("SETTINGS_APPEARANCE_THEME_TITLE",
                                  comment: "The title for the theme section in the appearance settings.")

        self.useThemeBackgroundColors = true

        updateTableContents()
    }

    func updateTableContents() {
        let contents = OWSTableContents()

        let themeSection = OWSTableSection()
        themeSection.headerTitle = NSLocalizedString("SETTINGS_APPEARANCE_THEME_TITLE",
                                                     comment: "The title for the theme section in the appearance settings.")

        themeSection.add(appearanceItem(.system))
        themeSection.add(appearanceItem(.light))
        themeSection.add(appearanceItem(.dark))

        contents.addSection(themeSection)

        self.contents = contents
    }

    func appearanceItem(_ mode: ThemeMode) -> OWSTableItem {
        return OWSTableItem(
            text: Self.nameForTheme(mode),
            actionBlock: { [weak self] in
                self?.changeTheme(mode)
            },
            accessoryType: Theme.getOrFetchCurrentTheme() == mode ? .checkmark : .none
        )
    }

    func changeTheme(_ mode: ThemeMode) {
        Theme.setCurrent(mode)
        updateTableContents()
    }

    static var currentThemeName: String {
        return nameForTheme(Theme.getOrFetchCurrentTheme())
    }

    static func nameForTheme(_ mode: ThemeMode) -> String {
        switch mode {
        case .dark:
            return NSLocalizedString("APPEARANCE_SETTINGS_DARK_THEME_NAME",
                                     comment: "Name indicating that the dark theme is enabled.")
        case .light:
            return NSLocalizedString("APPEARANCE_SETTINGS_LIGHT_THEME_NAME",
                                     comment: "Name indicating that the light theme is enabled.")
        case .system:
            return NSLocalizedString("APPEARANCE_SETTINGS_SYSTEM_THEME_NAME",
                                     comment: "Name indicating that the system theme is enabled.")
        }
    }

    @objc func didToggleAvatarPreference(_ sender: UISwitch) {
        Logger.info("Avatar preference toggled: \(sender.isOn)")
        SDSDatabaseStorage.shared.asyncWrite { writeTx in
            SSKPreferences.setPreferContactAvatars(sender.isOn, transaction: writeTx)
        }
    }
}
