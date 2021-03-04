//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

public enum MessageRecipient: Equatable {
    case contact(_ address: SignalServiceAddress)
    case group(_ groupThreadId: String)
}

public protocol ConversationItem {
    var messageRecipient: MessageRecipient { get }
    var title: String { get }
    var image: UIImage? { get }
    var isBlocked: Bool { get }
    var disappearingMessagesConfig: OWSDisappearingMessagesConfiguration? { get }

    func thread(transaction: SDSAnyWriteTransaction) -> TSThread?
}

struct RecentConversationItem {
    enum ItemType {
        case contact(_ item: ContactConversationItem)
        case group(_ item: GroupConversationItem)
    }

    let backingItem: ItemType
    var unwrapped: ConversationItem {
        switch backingItem {
        case .contact(let contactItem):
            return contactItem
        case .group(let groupItem):
            return groupItem
        }
    }
}

extension RecentConversationItem: ConversationItem {
    var messageRecipient: MessageRecipient {
        return unwrapped.messageRecipient
    }

    var title: String {
        return unwrapped.title
    }

    var image: UIImage? {
        return unwrapped.image
    }

    var isBlocked: Bool {
        return unwrapped.isBlocked
    }

    var disappearingMessagesConfig: OWSDisappearingMessagesConfiguration? {
        return unwrapped.disappearingMessagesConfig
    }

    func thread(transaction: SDSAnyWriteTransaction) -> TSThread? {
        return unwrapped.thread(transaction: transaction)
    }
}

struct ContactConversationItem {
    let address: SignalServiceAddress
    let isBlocked: Bool
    let disappearingMessagesConfig: OWSDisappearingMessagesConfiguration?
    let contactName: String
    let comparableName: String
}

extension ContactConversationItem: Comparable {
    static var contactsManager: OWSContactsManager {
        return Environment.shared.contactsManager
    }

    public static func < (lhs: ContactConversationItem, rhs: ContactConversationItem) -> Bool {
        return lhs.comparableName < rhs.comparableName
    }
}

extension ContactConversationItem: ConversationItem {

    // MARK: - Dependencies

    var contactsManager: OWSContactsManager {
        return Environment.shared.contactsManager
    }

    var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    // MARK: -

    var messageRecipient: MessageRecipient {
        return .contact(address)
    }

    var title: String {
        guard !address.isLocalAddress else {
            return MessageStrings.noteToSelf
        }

        return contactName
    }

    var image: UIImage? {
        return databaseStorage.uiRead { transaction in
            return self.contactsManager.image(for: self.address, transaction: transaction)
        }
    }

    func thread(transaction: SDSAnyWriteTransaction) -> TSThread? {
        return TSContactThread.getOrCreateThread(withContactAddress: address, transaction: transaction)
    }
}

struct GroupConversationItem {
    let groupThreadId: String
    let isBlocked: Bool
    let disappearingMessagesConfig: OWSDisappearingMessagesConfiguration?

    var databaseStorage: SDSDatabaseStorage { .shared }

    func thread(transaction: SDSAnyWriteTransaction) -> TSThread? {
        return TSGroupThread.anyFetchGroupThread(uniqueId: groupThreadId, transaction: transaction)
    }

    // We don't want to keep this in memory, because the group model
    // can be very large.
    var groupThread: TSGroupThread? {
        return databaseStorage.uiRead { transaction in
            return TSGroupThread.anyFetchGroupThread(uniqueId: groupThreadId, transaction: transaction)
        }
    }

    var groupModel: TSGroupModel? {
        return groupThread?.groupModel
    }
}

extension GroupConversationItem: ConversationItem {
    var messageRecipient: MessageRecipient {
        return .group(groupThreadId)
    }

    var title: String {
        guard let groupThread = groupThread else { return TSGroupThread.defaultGroupName }
        return groupThread.groupNameOrDefault
    }

    var image: UIImage? {
        guard let groupThread = groupThread else { return nil }
        return OWSAvatarBuilder.buildImage(thread: groupThread, diameter: kStandardAvatarSize)
    }
}
