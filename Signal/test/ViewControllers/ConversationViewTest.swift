//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import XCTest
@testable import Signal

class ConversationViewTest: SignalBaseTest {

    override func setUp() {
        super.setUp()
    }

    func testConversationStyleComparison() throws {
        let thread = ContactThreadFactory().create()

        Theme.setIsDarkThemeEnabledForTests(false)
        XCTAssertFalse(Theme.isDarkThemeEnabled)

        let style1 = ConversationStyle(type: .`default`, thread: thread, viewWidth: 100, hasWallpaper: false)
        let style2 = ConversationStyle(type: .`default`, thread: thread, viewWidth: 100, hasWallpaper: false)
        let style3 = ConversationStyle(type: .`default`, thread: thread, viewWidth: 101, hasWallpaper: false)

        XCTAssertFalse(style1.isDarkThemeEnabled)
        XCTAssertFalse(style2.isDarkThemeEnabled)
        XCTAssertFalse(style3.isDarkThemeEnabled)

        XCTAssertTrue(style1.isEqualForCellRendering(style2))
        XCTAssertFalse(style1.isEqualForCellRendering(style3))
        XCTAssertFalse(style2.isEqualForCellRendering(style3))

        Theme.setIsDarkThemeEnabledForTests(true)
        XCTAssertTrue(Theme.isDarkThemeEnabled)

        let style4 = ConversationStyle(type: .`default`, thread: thread, viewWidth: 100, hasWallpaper: false)

        XCTAssertFalse(style1.isDarkThemeEnabled)
        XCTAssertFalse(style2.isDarkThemeEnabled)
        XCTAssertFalse(style3.isDarkThemeEnabled)
        XCTAssertTrue(style4.isDarkThemeEnabled)

        XCTAssertTrue(style1.isEqualForCellRendering(style2))
        XCTAssertFalse(style1.isEqualForCellRendering(style3))
        XCTAssertFalse(style2.isEqualForCellRendering(style3))

        XCTAssertFalse(style4.isEqualForCellRendering(style1))
        XCTAssertFalse(style4.isEqualForCellRendering(style2))
        XCTAssertFalse(style4.isEqualForCellRendering(style3))
    }
}
