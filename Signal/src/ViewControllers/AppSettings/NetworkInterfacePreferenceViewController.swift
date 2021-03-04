//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

class NetworkInterfacePreferenceViewController: OWSTableViewController {
    private var selectedOption: NetworkInterfaceSet?
    private let availableOptions: [NetworkInterfaceSet]
    private let updateHandler: (NetworkInterfaceSet) -> Void

    public required init(
        selectedOption: NetworkInterfaceSet?,
        availableOptions: [NetworkInterfaceSet],
        updateHandler: @escaping (NetworkInterfaceSet) -> Void) {

        self.selectedOption = selectedOption
        self.availableOptions = availableOptions
        self.updateHandler = updateHandler
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.useThemeBackgroundColors = true
        updateTableContents()
    }

    func updateTableContents() {
        self.contents = OWSTableContents(sections: [
            OWSTableSection(header: nil, items: availableOptions.compactMap { option in
                guard let name = Self.name(forInterfaceSet: option) else { return nil }

                return OWSTableItem(
                    text: name,
                    actionBlock: { [weak self] in
                        self?.selectedOption = option
                        self?.updateHandler(option)
                        self?.navigationController?.popViewController(animated: true)
                    },
                    accessoryType: option == selectedOption ? .checkmark : .none)
            })
        ])
    }

    static func name(forInterfaceSet interfaceSet: NetworkInterfaceSet) -> String? {
        switch interfaceSet {
        case .none: return NSLocalizedString(
            "NETWORK_INTERFACE_SET_NEVER",
            comment: "String representing the 'never' condition of having no supported network interfaces")
        case .cellular: return NSLocalizedString(
            "NETWORK_INTERFACE_SET_CELLULAR",
            comment: "String representing only the cellular interface")
        case .wifi: return NSLocalizedString(
            "NETWORK_INTERFACE_SET_WIFI",
            comment: "String representing only the wifi interface")
        case .wifiAndCellular: return NSLocalizedString(
            "NETWORK_INTERFACE_SET_WIFI_CELLULAR",
            comment: "String representing both wifi and cellular interfaces")
        default: return nil
        }
    }
}
