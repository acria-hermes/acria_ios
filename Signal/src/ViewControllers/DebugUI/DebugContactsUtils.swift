//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

#if DEBUG

@objc
public extension DebugContactsUtils {

    // MARK: - Dependencies

    private static var databaseStorage: SDSDatabaseStorage {
        return .shared
    }

    // MARK: -

    static func reindexAllContacts() {
        databaseStorage.write { transaction in
            SignalAccount.anyEnumerate(transaction: transaction, batched: true) { (account: SignalAccount, _) in
                account.anyUpsert(transaction: transaction)
            }
            SignalRecipient.anyEnumerate(transaction: transaction, batched: true) { (signalRecipient: SignalRecipient, _) in
                signalRecipient.anyUpsert(transaction: transaction)
            }
            TSThread.anyEnumerate(transaction: transaction, batched: true) { (thread: TSThread, _) in
                thread.anyUpsert(transaction: transaction)
            }
        }
    }

    static func logSignalAccounts() {
        databaseStorage.read { transaction in
            SignalAccount.anyEnumerate(transaction: transaction, batched: true) { (account: SignalAccount, _) in
                Logger.verbose("---- \(account.uniqueId),  \(account.recipientAddress),  \(account.contactFirstName()),  \(account.contactLastName()),  \(account.contactNicknameIfAvailable()), ")
            }
        }
    }
}

#endif
