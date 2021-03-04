//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
class ExperienceUpgradeManager: NSObject {
    private static var databaseStorage: SDSDatabaseStorage {
        return .shared
    }

    private static weak var lastPresented: ExperienceUpgradeView?

    // The first day is day 0, so this gives the user 1 week of megaphone
    // before we display the splash.
    static let splashStartDay = 7

    private static func dismissLastPresented() {
        lastPresented?.dismiss(animated: false, completion: nil)
        lastPresented = nil
    }

    @objc
    static func presentNext(fromViewController: UIViewController) -> Bool {
        let optionalNext = databaseStorage.read(block: { transaction in
            return ExperienceUpgradeFinder.next(transaction: transaction.unwrapGrdbRead)
        })

        // If we already have presented this experience upgrade, do nothing.
        guard let next = optionalNext, lastPresented?.experienceUpgrade.uniqueId != next.uniqueId else {
            if optionalNext == nil {
                dismissLastPresented()
                return false
            } else {
                return true
            }
        }

        // Otherwise, dismiss any currently present experience upgrade. It's
        // no longer next and may have been completed.
        dismissLastPresented()

        let hasMegaphone = self.hasMegaphone(forExperienceUpgrade: next)
        let hasSplash = self.hasSplash(forExperienceUpgrade: next)

        // If we have a megaphone and a splash, we only show the megaphone for
        // 7 days after the user first viewed the megaphone. After this point
        // we will display the splash. If there is only a megaphone we will
        // render it for as long as the upgrade is active. We don't show the
        // splash if the user currently has a selected thread, as we don't
        // ever want to block access to messaging (e.g. via tapping a notification).
        let didPresentView: Bool
        if (hasMegaphone && !hasSplash) || (hasMegaphone && next.daysSinceFirstViewed < splashStartDay) {
            let megaphone = self.megaphone(forExperienceUpgrade: next, fromViewController: fromViewController)
            megaphone?.present(fromViewController: fromViewController)
            lastPresented = megaphone
            didPresentView = true
        } else if hasSplash, !SignalApp.shared().hasSelectedThread, let splash = splash(forExperienceUpgrade: next) {
            fromViewController.presentFormSheet(OWSNavigationController(rootViewController: splash), animated: true)
            lastPresented = splash
            didPresentView = true
        } else {
            Logger.info("no megaphone or splash needed for experience upgrade: \(next.id as Optional)")
            didPresentView = false
        }

        // Track that we've successfully presented this experience upgrade once, or that it was not
        // needed to be presented.
        // If it was already marked as viewed, this will do nothing.
        databaseStorage.asyncWrite { transaction in
            ExperienceUpgradeFinder.markAsViewed(experienceUpgrade: next, transaction: transaction.unwrapGrdbWrite)
        }

        return didPresentView
    }

    // MARK: - Experience Specific Helpers

    @objc
    static func dismissSplashWithoutCompletingIfNecessary() {
        guard let lastPresented = lastPresented as? SplashViewController else { return }
        lastPresented.dismissWithoutCompleting(animated: false, completion: nil)
    }

    @objc
    static func dismissPINReminderIfNecessary() {
        guard lastPresented?.experienceUpgrade.id == .pinReminder else { return }
        lastPresented?.dismiss(animated: false, completion: nil)
    }

    static func clearExperienceUpgradeWithSneakyTransaction(_ experienceUpgradeId: ExperienceUpgradeId) {
        // Check if we need to do a write, we'll skip opening a write
        // transaction if we're able.
        let hasIncomplete = databaseStorage.read { transaction in
            ExperienceUpgradeFinder.hasIncomplete(
                experienceUpgradeId: experienceUpgradeId,
                transaction: transaction.unwrapGrdbRead
            )
        }

        guard hasIncomplete else {
            // If it's currently being presented, dismiss it.
            guard lastPresented?.experienceUpgrade.id == experienceUpgradeId else { return }
            lastPresented?.dismiss(animated: false, completion: nil)
            return
        }

        databaseStorage.asyncWrite { clearExperienceUpgrade(experienceUpgradeId, transaction: $0.unwrapGrdbWrite) }
    }

    @objc(clearExperienceUpgrade:transaction:)
    static func clearExperienceUpgrade(objcId experienceUpgradeId: ObjcExperienceUpgradeId,
                                       transaction: GRDBWriteTransaction) {
        clearExperienceUpgrade(experienceUpgradeId.swiftRepresentation, transaction: transaction)
    }

    /// Marks the specified type up of upgrade as complete and dismisses it if it is currently presented.
    static func clearExperienceUpgrade(_ experienceUpgradeId: ExperienceUpgradeId, transaction: GRDBWriteTransaction) {
        ExperienceUpgradeFinder.markAsComplete(experienceUpgradeId: experienceUpgradeId, transaction: transaction)
        transaction.addAsyncCompletion(queue: .main) {
            // If it's currently being presented, dismiss it.
            guard lastPresented?.experienceUpgrade.id == experienceUpgradeId else { return }
            lastPresented?.dismiss(animated: false, completion: nil)
        }
    }

    // MARK: - Splash

    private static func hasSplash(forExperienceUpgrade experienceUpgrade: ExperienceUpgrade) -> Bool {
        switch experienceUpgrade.id {
        case .introducingPins:
            return true
        case .groupsV2AndMentionsSplash2:
            return true
        default:
            return false
        }
    }

    fileprivate static func splash(forExperienceUpgrade experienceUpgrade: ExperienceUpgrade) -> SplashViewController? {
        switch experienceUpgrade.id {
        case .introducingPins:
            return IntroducingPinsSplash(experienceUpgrade: experienceUpgrade)
        case .groupsV2AndMentionsSplash2:
            return GroupsV2AndMentionsSplash(experienceUpgrade: experienceUpgrade)
        default:
            return nil
        }
    }

    // MARK: - Megaphone

    private static func hasMegaphone(forExperienceUpgrade experienceUpgrade: ExperienceUpgrade) -> Bool {
        switch experienceUpgrade.id {
        case .introducingPins,
             .pinReminder,
             .notificationPermissionReminder,
             .contactPermissionReminder,
             .linkPreviews,
             .researchMegaphone1,
             .groupCallsMegaphone,
             .sharingSuggestions:
            return true
        case .groupsV2AndMentionsSplash2:
            return false
        default:
            return false
        }
    }

    fileprivate static func megaphone(forExperienceUpgrade experienceUpgrade: ExperienceUpgrade, fromViewController: UIViewController) -> MegaphoneView? {
        switch experienceUpgrade.id {
        case .introducingPins:
            return IntroducingPinsMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        case .pinReminder:
            return PinReminderMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        case .notificationPermissionReminder:
            return NotificationPermissionReminderMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        case .contactPermissionReminder:
            return ContactPermissionReminderMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        case .linkPreviews:
            return LinkPreviewsMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        case .researchMegaphone1:
            return ResearchMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        case .groupCallsMegaphone:
            return GroupCallsMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        case .sharingSuggestions:
            return SharingSuggestionsMegaphone(experienceUpgrade: experienceUpgrade, fromViewController: fromViewController)
        default:
            return nil
        }
    }
}

// MARK: -

protocol ExperienceUpgradeView: class {
    var experienceUpgrade: ExperienceUpgrade { get }
    var isPresented: Bool { get }
    func dismiss(animated: Bool, completion: (() -> Void)?)
}

extension ExperienceUpgradeView {
    var databaseStorage: SDSDatabaseStorage {
        return .shared
    }

    func presentToast(text: String, fromViewController: UIViewController) {
        let toastController = ToastController(text: text)

        let bottomInset = fromViewController.bottomLayoutGuide.length + 8
        toastController.presentToastView(fromBottomOfView: fromViewController.view, inset: bottomInset)
    }

    /// - Parameter transaction: An optional transaction to write the completion in.
    /// If nil is provided for `transaction` then the write will be performed under a synchronous write transaction
    func markAsSnoozed(transaction: SDSAnyWriteTransaction? = nil) {
        let performUpdate: (SDSAnyWriteTransaction) -> Void = { transaction in
            ExperienceUpgradeFinder.markAsSnoozed(
                experienceUpgrade: self.experienceUpgrade,
                transaction: transaction.unwrapGrdbWrite
            )
        }
        if let transaction = transaction {
            performUpdate(transaction)
        } else {
            databaseStorage.write(block: performUpdate)
        }
    }

    /// - Parameter transaction: An optional transaction to write the completion in.
    /// If nil is provided for `transaction` then the write will be performed under a synchronous write transaction
    func markAsComplete(transaction: SDSAnyWriteTransaction? = nil) {
        let performUpdate: (SDSAnyWriteTransaction) -> Void = { transaction in
            ExperienceUpgradeFinder.markAsComplete(
                experienceUpgrade: self.experienceUpgrade,
                transaction: transaction.unwrapGrdbWrite
            )
        }
        if let transaction = transaction {
            performUpdate(transaction)
        } else {
            databaseStorage.write(block: performUpdate)
        }
    }
}
