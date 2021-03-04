//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import UIKit

@objc
public class OWSNavigationBar: UINavigationBar {

    @objc
    public let navbarWithoutStatusHeight: CGFloat = 44

    @objc
    public var statusBarHeight: CGFloat {
        return CurrentAppContext().statusBarHeight
    }

    @objc
    public var fullWidth: CGFloat {
        return superview?.frame.width ?? .zero
    }

    public required init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    @objc
    public static let backgroundBlurMutingFactor: CGFloat = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)

        applyTheme()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(themeDidChange),
                                               name: .ThemeDidChange,
                                               object: nil)
    }

    // MARK: Theme

    private func applyTheme() {
        guard respectsTheme else {
            return
        }

        let color = Theme.navbarBackgroundColor
        let backgroundImage = UIImage(color: color)
        
        self.barTintColor = Theme.navbarBackgroundColor
        self.setBackgroundImage(backgroundImage, for: .default)
        self.titleTextAttributes = [NSAttributedString.Key.foregroundColor: Theme.primaryTextColor]
        self.tintColor = Theme.orangeBackground()
        
        
        
        isTranslucent = false
    }

    @objc
    public func themeDidChange() {
        Logger.debug("")
        applyTheme()
    }

    @objc
    public var respectsTheme: Bool = true {
        didSet {
            themeDidChange()
        }
    }

    // MARK: Override Theme

    @objc
    public enum NavigationBarStyle: Int {
        case clear, alwaysDark, `default`, secondaryBar
    }

    private var currentStyle: NavigationBarStyle?

    @objc
    public func switchToStyle(_ style: NavigationBarStyle) {
        let applyDarkThemeOverride = {
            self.barStyle = .default
            self.titleTextAttributes = [NSAttributedString.Key.foregroundColor: Theme.primaryTextColor]
            self.barTintColor = Theme.navbarBackgroundColor
            self.tintColor =  Theme.orangeBackground()
        }

        let removeDarkThemeOverride = {
            self.barStyle = .default
            self.titleTextAttributes = [NSAttributedString.Key.foregroundColor: Theme.primaryTextColor]
            self.barTintColor = Theme.navbarBackgroundColor
            self.tintColor = Theme.orangeBackground()
        }

        let applyTransparentBarOverride = {
            self.clipsToBounds = true

            // Making a toolbar transparent requires setting an empty uiimage
            self.setBackgroundImage(UIImage(), for: .default)
            self.shadowImage = UIImage()
        }

        let removeTransparentBarOverride = {
            self.clipsToBounds = false

            self.setBackgroundImage(nil, for: .default)
            self.shadowImage = nil
        }

        let applySecondaryBarOverride = {
            self.shadowImage = UIImage()
        }

        let removeSecondaryBarOverride = {
            self.shadowImage = nil
        }

        currentStyle = style

        switch style {
        case .clear:
            respectsTheme = false
            removeSecondaryBarOverride()
            applyDarkThemeOverride()
            applyTransparentBarOverride()
        case .alwaysDark:
            respectsTheme = false
            removeSecondaryBarOverride()
            removeTransparentBarOverride()
            applyDarkThemeOverride()
        case .default:
            respectsTheme = true
            removeDarkThemeOverride()
            removeTransparentBarOverride()
            removeSecondaryBarOverride()
            applyTheme()
        case .secondaryBar:
            respectsTheme = true
            removeDarkThemeOverride()
            removeTransparentBarOverride()
            applySecondaryBarOverride()
            applyTheme()
        }
    }
}
