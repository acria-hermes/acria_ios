//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public class CVComponentContactShare: CVComponentBase, CVComponent {

    private let contactShareState: CVComponentState.ContactShare

    private var contactShare: ContactShareViewModel {
        contactShareState.state.contactShare
    }

    init(itemModel: CVItemModel, contactShareState: CVComponentState.ContactShare) {
        self.contactShareState = contactShareState

        super.init(itemModel: itemModel)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewContactShare()
    }

    public func configureForRendering(componentView componentViewParam: CVComponentView,
                                      cellMeasurement: CVCellMeasurement,
                                      componentDelegate: CVComponentDelegate) {
        guard let componentView = componentViewParam as? CVComponentViewContactShare else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let contactShareView = CVContactShareView(state: contactShareState.state)
        let hostView = componentView.hostView
        hostView.addSubview(contactShareView)
        contactShareView.autoPinEdgesToSuperviewEdges()
    }

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let height = CVContactShareView.measureHeight(state: contactShareState.state)
        return CGSize(width: maxWidth, height: height).ceil
    }

    public override func handleTap(sender: UITapGestureRecognizer,
                                   componentDelegate: CVComponentDelegate,
                                   componentView: CVComponentView,
                                   renderItem: CVRenderItem) -> Bool {

        componentDelegate.cvc_didTapContactShare(contactShare)
        return true
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    @objc
    public class CVComponentViewContactShare: NSObject, CVComponentView {

        // For now we simply use this view to host ContactShareView.
        //
        // TODO: Reuse ContactShareView.
        fileprivate let hostView = UIView()

        public var isDedicatedCellView = false

        public var rootView: UIView {
            hostView
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            hostView.removeAllSubviews()
        }
    }
}

// MARK: -

extension CVComponentContactShare: CVAccessibilityComponent {
    public var accessibilityDescription: String {
        if let contactName = contactShare.displayName.filterForDisplay,
           !contactName.isEmpty {
            let format = NSLocalizedString("ACCESSIBILITY_LABEL_CONTACT_FORMAT",
                                           comment: "Accessibility label for contact. Embeds: {{ the contact name }}.")
            return String(format: format, contactName)
        } else {
            return NSLocalizedString("ACCESSIBILITY_LABEL_CONTACT",
                                     comment: "Accessibility label for contact.")
        }
    }
}
