//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import SafariServices
import PromiseKit

@objc
public class ProfileSettingsViewController: OWSTableViewController {

    private let avatarViewHelper = AvatarViewHelper()

    private lazy var givenNameTextField = OWSTextField()

    private lazy var familyNameTextField = OWSTextField()

    private let profileNamePreviewLabel = UILabel()

    private let usernameLabel = UILabel()

    private let avatarView = AvatarImageView()

    private var saveButton: OWSFlatButton?

    private var username: String?
    private var profileBio: String?
    private var profileBioEmoji: String?
    private var avatarData: Data?

    private var hasUnsavedChanges = false {
        didSet {
            updateNavigationItem()
        }
    }

    private let completionHandler: (ProfileSettingsViewController) -> Void

    @objc
    public required init(completionHandler: @escaping (ProfileSettingsViewController) -> Void) {
        self.completionHandler = completionHandler

        super.init()

        self.shouldAvoidKeyboard = true
    }

    // MARK: -

    public override func loadView() {
        super.loadView()

        self.useThemeBackgroundColors = true

        self.title = NSLocalizedString("PROFILE_VIEW_TITLE", comment: "Title for the profile view.")

        avatarViewHelper.delegate = self

        let profileSnapshot = profileManager.localProfileSnapshot(shouldIncludeAvatar: true)
        givenNameTextField.text = profileSnapshot.givenName
        familyNameTextField.text = profileSnapshot.familyName
        self.profileBio = profileSnapshot.bio
        self.profileBioEmoji = profileSnapshot.bioEmoji
        self.username = profileSnapshot.username
        self.avatarData = profileSnapshot.avatarData

        createViews()
        updateNavigationItem()
        updateTableContents()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateNavigationItem()
        updateUsername()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateNavigationItem()
    }

    private func createViews() {
        avatarView.autoSetDimensions(to: CGSize.square(96))
        avatarView.accessibilityIdentifier = "avatar_view"

        givenNameTextField.returnKeyType = .next
        givenNameTextField.autocorrectionType = .no
        givenNameTextField.spellCheckingType = .no
        givenNameTextField.placeholder = NSLocalizedString("PROFILE_VIEW_GIVEN_NAME_DEFAULT_TEXT",
                                                           comment: "Default text for the given name field of the profile view.")
        givenNameTextField.delegate = self
        givenNameTextField.textAlignment = .right
        givenNameTextField.accessibilityIdentifier = "given_name_textfield"
        givenNameTextField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)

        familyNameTextField.returnKeyType = .done
        familyNameTextField.autocorrectionType = .no
        familyNameTextField.spellCheckingType = .no
        familyNameTextField.placeholder = NSLocalizedString("PROFILE_VIEW_FAMILY_NAME_DEFAULT_TEXT",
                                                            comment: "Default text for the family name field of the profile view.")
        familyNameTextField.delegate = self
        familyNameTextField.textAlignment = .right
        familyNameTextField.accessibilityIdentifier = "family_name_textfield"
        familyNameTextField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)

        profileNamePreviewLabel.textAlignment = .center
        profileNamePreviewLabel.textColor = Theme.secondaryTextAndIconColor
        profileNamePreviewLabel.font = .ows_dynamicTypeSubheadlineClamped
    }

    func updateTableContents() {
        let contents = OWSTableContents()

        let givenNameTextField = self.givenNameTextField
        let familyNameTextField = self.familyNameTextField
        let avatarView = self.avatarView
        let profileNamePreviewLabel = self.profileNamePreviewLabel

        updateAvatarView()
        updateProfileNamePreview()

        let avatarSection = OWSTableSection()
        avatarSection.add(OWSTableItem(customCellBlock: { () -> UITableViewCell in
            let cell = OWSTableItem.newCell()

            let stackView = UIStackView(arrangedSubviews: [avatarView, profileNamePreviewLabel])
            stackView.axis = .vertical
            stackView.alignment = .center
            stackView.spacing = 16
            stackView.layoutMargins = UIEdgeInsets(top: 24, leading: 0, bottom: 32, trailing: 0)
            stackView.isLayoutMarginsRelativeArrangement = true
            cell.contentView.addSubview(stackView)
            stackView.autoPinEdgesToSuperviewMargins()

            let cameraImageView = UIImageView.withTemplateImageName("camera-outline-24", tintColor: Theme.secondaryTextAndIconColor)
            cameraImageView.autoSetDimensions(to: CGSize.square(32))
            cameraImageView.contentMode = .center
            cameraImageView.backgroundColor = Theme.backgroundColor
            cameraImageView.layer.cornerRadius = 16
            cameraImageView.layer.shadowColor = (Theme.isDarkThemeEnabled ? Theme.darkThemeWashColor : Theme.primaryTextColor).cgColor
            cameraImageView.layer.shadowOffset = CGSize.square(1)
            cameraImageView.layer.shadowOpacity = 0.5
            cameraImageView.layer.shadowRadius = 4
            stackView.addSubview(cameraImageView)
            cameraImageView.autoPinTrailing(toEdgeOf: avatarView)
            cameraImageView.autoPinEdge(.bottom, to: .bottom, of: avatarView)

            return cell
        },
        actionBlock: { [weak self] in
            self?.didTapAvatar()
        }))
        contents.addSection(avatarSection)

        let namesSection = OWSTableSection()
        func addGivenNameRow() {
            namesSection.add(OWSTableItem(customCellBlock: { () -> UITableViewCell in

                givenNameTextField.font = .ows_dynamicTypeBodyClamped
                givenNameTextField.textColor = Theme.primaryTextColor

                return Self.buildNameCell(title: NSLocalizedString("PROFILE_VIEW_GIVEN_NAME_FIELD",
                                                                   comment: "Label for the given name field of the profile view."),
                                          valueView: givenNameTextField,
                                          accessibilityIdentifier: "given_name")
            },
            actionBlock: {
                givenNameTextField.becomeFirstResponder()
            }))
        }
        func addFamilyNameRow() {
            namesSection.add(OWSTableItem(customCellBlock: { () -> UITableViewCell in

                familyNameTextField.font = .ows_dynamicTypeBodyClamped
                familyNameTextField.textColor = Theme.primaryTextColor

                return Self.buildNameCell(title: NSLocalizedString("PROFILE_VIEW_FAMILY_NAME_FIELD",
                                                                   comment: "Label for the family name field of the profile view."),
                                          valueView: familyNameTextField,
                                          accessibilityIdentifier: "given_name")
            },
            actionBlock: {
                familyNameTextField.becomeFirstResponder()
            }))
        }
        // For CJKV locales, display family name field first.
        if NSLocale.current.isCJKV {
            addFamilyNameRow()
            addGivenNameRow()

            // Otherwise, display given name field first.
        } else {
            addGivenNameRow()
            addFamilyNameRow()
        }
        if RemoteConfig.usernames {
            namesSection.add(buildUsernameItem())
        }
        contents.addSection(namesSection)

        let aboutSection = OWSTableSection()
        aboutSection.headerTitle = NSLocalizedString("PROFILE_VIEW_BIO_SECTION_HEADER",
                                                     comment: "Header for the 'bio' section of the profile view.")
        let profileBio = self.normalizedProfileBio
        let profileBioEmoji = self.normalizedProfileBioEmoji
        if let bioForDisplay = OWSUserProfile.bioForDisplay(bio: profileBio, bioEmoji: profileBioEmoji) {
            aboutSection.add(OWSTableItem(customCellBlock: { () -> UITableViewCell in
                let cell = OWSTableItem.newCell()

                let label = UILabel()
                label.text = bioForDisplay
                label.textColor = Theme.primaryTextColor
                label.font = .ows_dynamicTypeBodyClamped
                label.numberOfLines = 0
                label.lineBreakMode = .byWordWrapping
                cell.contentView.addSubview(label)
                label.autoPinEdgesToSuperviewMargins()

                cell.accessoryType = .disclosureIndicator

                cell.accessibilityIdentifier = "profile_bio"

                return cell
            },
            actionBlock: { [weak self] in
                self?.didTapBio()
            }))
        } else {
            aboutSection.add(OWSTableItem.item(name: NSLocalizedString("PROFILE_VIEW_ADD_BIO_TO_PROFILE",
                                                                       comment: "Button to add a 'bio' to the user's profile in the profile view."),
                                               textColor: Theme.accentBlueColor,
                                               accessoryType: .disclosureIndicator,
                                               accessibilityIdentifier: "profile_bio") { [weak self] in
                self?.didTapBio()
            })
        }
        contents.addSection(aboutSection)

        // Information Footer

        let infoGestureRecognizer = UITapGestureRecognizer(target: self,
                                                           action: #selector(didTapInfo))
        aboutSection.customFooterView = { () -> UIView in

            let label = UILabel()
            label.textColor = Theme.secondaryTextAndIconColor
            label.font = .ows_dynamicTypeCaption1Clamped
            let attributedText = NSMutableAttributedString()
            attributedText.append(NSLocalizedString("PROFILE_VIEW_PROFILE_DESCRIPTION",
                                                    comment: "Description of the user profile."))
            attributedText.append(" ")
            attributedText.append(NSAttributedString(string: CommonStrings.learnMore,
                                                     attributes: [
                                                        NSAttributedString.Key.foregroundColor: Theme.accentBlueColor,
                                                        NSAttributedString.Key.underlineStyle: 0
                                                     ]))
            label.attributedText = attributedText
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping

            label.backgroundColor = Theme.tableViewBackgroundColor

            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(infoGestureRecognizer)

            let footer = UIView()
            footer.layoutMargins = UIEdgeInsets(hMargin: 20, vMargin: 12)
            footer.addSubview(label)
            label.autoPinEdgesToSuperviewMargins()

            return footer
        }()

        self.contents = contents
    }

    private func buildUsernameItem() -> OWSTableItem {
        updateUsername()

        let usernameLabel = self.usernameLabel
        return OWSTableItem(customCellBlock: { () -> UITableViewCell in
            let title = NSLocalizedString("PROFILE_VIEW_USERNAME_FIELD",
                                          comment: "Label for the username field of the profile view.")

            usernameLabel.font = .ows_dynamicTypeBodyClamped
            usernameLabel.textAlignment = .right

            let cell = Self.buildNameCell(title: title,
                                          valueView: usernameLabel,
                                          accessibilityIdentifier: "username")

            cell.accessoryType = .disclosureIndicator

            return cell
        },
        actionBlock: { [weak self] in
            self?.didTapUsername()
        })
    }

    private static func buildNameLabel(title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.textColor = Theme.primaryTextColor
        label.font = UIFont.ows_dynamicTypeBodyClamped.ows_semibold
        label.setCompressionResistanceHorizontalHigh()
        label.setContentHuggingHorizontalHigh()
        return label
    }

    private static func buildNameCell(title: String,
                                      valueView: UIView,
                                      accessibilityIdentifier: String,
                                      accessoryView: UIView? = nil) -> UITableViewCell {
        let cell = OWSTableItem.newCell()

        let titleLabel = buildNameLabel(title: title)

        valueView.setCompressionResistanceHorizontalLow()
        valueView.setContentHuggingHorizontalLow()

        var subviews = [titleLabel, valueView]
        if let accessoryView = accessoryView {
            accessoryView.setCompressionResistanceHorizontalHigh()
            accessoryView.setContentHuggingHorizontalHigh()
            subviews.append(accessoryView)
        }
        let stackView = UIStackView(arrangedSubviews: subviews)
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 10
        cell.contentView.addSubview(stackView)
        stackView.autoPinEdgesToSuperviewMargins()

        cell.accessibilityIdentifier = accessibilityIdentifier

        return cell
    }

    // MARK: - Event Handling

    private func leaveViewCheckingForUnsavedChanges() {
        familyNameTextField.resignFirstResponder()
        givenNameTextField.resignFirstResponder()

        if !hasUnsavedChanges {
            // If user made no changes, return to conversation settings view.
            profileCompleted()
            return
        }

        OWSActionSheets.showPendingChangesActionSheet(discardAction: { [weak self] in
            self?.profileCompleted()
        })
    }

    private func updateNavigationItem() {
        if hasUnsavedChanges {
            // If we have a unsaved changes, right item should be a "save" button.
            let saveButton = UIBarButtonItem(barButtonSystemItem: .save,
                                             target: self,
                                             action: #selector(updateProfile),
                                             accessibilityIdentifier: "save_button")
            navigationItem.rightBarButtonItem = saveButton
        } else {
            navigationItem.rightBarButtonItem = nil
        }
    }

    @objc
    func updateProfile() {

        let normalizedGivenName = self.normalizedGivenName
        let normalizedFamilyName = self.normalizedFamilyName
        let normalizedProfileBio = self.normalizedProfileBio
        let normalizedProfileBioEmoji = self.normalizedProfileBioEmoji

        if normalizedGivenName.isEmpty {
            OWSActionSheets.showErrorAlert(message: NSLocalizedString("PROFILE_VIEW_ERROR_GIVEN_NAME_REQUIRED",
                                                                      comment: "Error message shown when user tries to update profile without a given name"))
            return
        }

        if profileManager.isProfileNameTooLong(normalizedGivenName) {
            OWSActionSheets.showErrorAlert(message: NSLocalizedString("PROFILE_VIEW_ERROR_GIVEN_NAME_TOO_LONG",
                                                                      comment: "Error message shown when user tries to update profile with a given name that is too long."))
            return
        }

        if profileManager.isProfileNameTooLong(normalizedFamilyName) {
            OWSActionSheets.showErrorAlert(message: NSLocalizedString("PROFILE_VIEW_ERROR_FAMILY_NAME_TOO_LONG",
                                                                      comment: "Error message shown when user tries to update profile with a family name that is too long."))
            return
        }

        if !self.reachabilityManager.isReachable {
            OWSActionSheets.showErrorAlert(message: NSLocalizedString("PROFILE_VIEW_NO_CONNECTION",
                                                                      comment: "Error shown when the user tries to update their profile when the app is not connected to the internet."))
            return
        }

        // Show an activity indicator to block the UI during the profile upload.
        let avatarData = self.avatarData
        ModalActivityIndicatorViewController.present(fromViewController: self,
                                                     canCancel: false) { modalActivityIndicator in
            firstly(on: .global()) { () -> Promise<Void> in
                OWSProfileManager.updateLocalProfilePromise(profileGivenName: normalizedGivenName,
                                                            profileFamilyName: normalizedFamilyName,
                                                            profileBio: normalizedProfileBio,
                                                            profileBioEmoji: normalizedProfileBioEmoji,
                                                            profileAvatarData: avatarData)
            }.done { _ in
                modalActivityIndicator.dismiss { [weak self] in
                    AssertIsOnMainThread()
                    self?.profileCompleted()
                }
            }.catch { error in
                owsFailDebug("Error: \(error)")
                modalActivityIndicator.dismiss { [weak self] in
                    AssertIsOnMainThread()
                    self?.profileCompleted()
                }
            }
        }
    }

    private var normalizedGivenName: String {
        (givenNameTextField.text ?? "").ows_stripped()
    }

    private var normalizedFamilyName: String {
        (familyNameTextField.text ?? "").ows_stripped()
    }

    private var normalizedProfileBio: String? {
        profileBio?.ows_stripped()
    }

    private var normalizedProfileBioEmoji: String? {
        profileBioEmoji?.ows_stripped()
    }

    private func profileCompleted() {
        AssertIsOnMainThread()
        Logger.verbose("")

        completionHandler(self)
    }

    // MARK: - Avatar

    private func setAvatarImage(_ avatarImage: UIImage?) {
        AssertIsOnMainThread()

        var avatarData: Data?
        if let avatarImage = avatarImage {
            avatarData = OWSProfileManager.avatarData(forAvatarImage: avatarImage)
        }
        hasUnsavedChanges = hasUnsavedChanges || avatarData != self.avatarData
        self.avatarData = avatarData

        updateAvatarView()
    }

    private let avatarSize: UInt = 96

    private func updateAvatarView() {
        if let avatarData = avatarData {
            avatarView.image = UIImage(data: avatarData)
        } else {
            avatarView.image = OWSContactAvatarBuilder(forLocalUserWithDiameter: avatarSize).buildDefaultImage()
        }
    }

    private func updateProfileNamePreview() {
        var components = PersonNameComponents()
        components.givenName = normalizedGivenName
        components.familyName = normalizedFamilyName

        let previewText = PersonNameComponentsFormatter.localizedString(from: components,
                                                                        style: .`default`)
        if previewText.isEmpty {
            profileNamePreviewLabel.text = " "
        } else {
            profileNamePreviewLabel.text = previewText
        }
    }

    private func updateUsername() {
        if let username = username {
            usernameLabel.text = CommonFormats.formatUsername(username)
            usernameLabel.textColor = Theme.primaryTextColor
        } else {
            usernameLabel.text = NSLocalizedString("PROFILE_VIEW_CREATE_USERNAME",
                                                   comment: "A string indicating that the user can create a username on the profile view.")
            usernameLabel.textColor = Theme.accentBlueColor
        }
    }

    private func didTapUsername() {
        navigationController?.pushViewController(UsernameViewController(), animated: true)
    }

    private func didTapBio() {
        let view = ProfileBioViewController(bio: profileBio,
                                            bioEmoji: profileBioEmoji,
                                            profileDelegate: self)
        navigationController?.pushViewController(view, animated: true)
    }

    private func didTapAvatar() {
        avatarViewHelper.showChangeAvatarUI()
    }

    @objc
    private func didTapInfo() {
        let vc = SFSafariViewController(url: URL(string: "https://support.signal.org/hc/articles/360007459591")!)
        present(vc, animated: true, completion: nil)
    }
}

// MARK: -

extension ProfileSettingsViewController: AvatarViewHelperDelegate {

    public func avatarActionSheetTitle() -> String? {
        NSLocalizedString("PROFILE_VIEW_AVATAR_ACTIONSHEET_TITLE", comment: "Action Sheet title prompting the user for a profile avatar")
    }

    public func avatarDidChange(_ image: UIImage) {
        AssertIsOnMainThread()

        setAvatarImage(image.resizedImage(toFillPixelSize: .square(CGFloat(kOWSProfileManager_MaxAvatarDiameter))))
    }

    public func fromViewController() -> UIViewController {
        self
    }

    public func hasClearAvatarAction() -> Bool {
        avatarData != nil
    }

    public func clearAvatar() {
        setAvatarImage(nil)
    }

    public func clearAvatarActionLabel() -> String {
        return NSLocalizedString("PROFILE_VIEW_CLEAR_AVATAR", comment: "Label for action that clear's the user's profile avatar")
    }
}

// MARK: -

extension ProfileSettingsViewController: UITextFieldDelegate {

    private var firstTextField: UITextField {
        NSLocale.current.isCJKV ? familyNameTextField : givenNameTextField
    }

    private var secondTextField: UITextField {
        NSLocale.current.isCJKV ? givenNameTextField : familyNameTextField
    }

    public func textField(_ textField: UITextField,
                          shouldChangeCharactersIn range: NSRange,
                          replacementString string: String) -> Bool {
        TextFieldHelper.textField(
            textField,
            shouldChangeCharactersInRange: range,
            replacementString: string.withoutBidiControlCharacters,
            maxByteCount: OWSUserProfile.maxNameLengthBytes
        )
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == firstTextField {
            secondTextField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return false
    }

    @objc
    func textFieldDidChange(_ textField: UITextField) {
        hasUnsavedChanges = true

        updateProfileNamePreview()

        // TODO: Update length warning.
    }
}

// MARK: -

extension ProfileSettingsViewController: OWSNavigationView {

    @available(iOS 13, *)
    override public var isModalInPresentation: Bool {
        get { hasUnsavedChanges }
        set { /* noop superclass requirement */ }
    }

    public func shouldCancelNavigationBack() -> Bool {
        let result = hasUnsavedChanges
        if result {
            leaveViewCheckingForUnsavedChanges()
        }
        return result
    }
}

// MARK: -

extension ProfileSettingsViewController: ProfileBioViewControllerDelegate {

    public func profileBioViewDidComplete(bio: String?,
                                          bioEmoji: String?) {
        profileBio = bio
        profileBioEmoji = bioEmoji
        hasUnsavedChanges = true
        updateTableContents()
    }
}
