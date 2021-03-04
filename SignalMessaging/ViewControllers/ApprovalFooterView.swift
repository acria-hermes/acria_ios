//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

// Outgoing message approval can be a multi-step process.
@objc
public enum ApprovalMode: UInt {
    // This is the final step of approval; continuing will send.
    case send
    // This is not the final step of approval; continuing will not send.
    case next
    // This step is not yet ready to proceed.
    case loading
}

// MARK: -

public protocol ApprovalFooterDelegate: AnyObject {
    func approvalFooterDelegateDidRequestProceed(_ approvalFooterView: ApprovalFooterView)

    func approvalMode(_ approvalFooterView: ApprovalFooterView) -> ApprovalMode
}

// MARK: -

public class ApprovalFooterView: UIView {
    public weak var delegate: ApprovalFooterDelegate? {
        didSet {
            updateContents()
        }
    }

    private var approvalMode: ApprovalMode {
        guard let delegate = delegate else {
            return .send
        }
        return delegate.approvalMode(self)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        autoresizingMask = .flexibleHeight
        translatesAutoresizingMaskIntoConstraints = false

        layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        // We extend our background view below the keyboard to avoid any gaps.
        let backgroundView = UIView()
        backgroundView.backgroundColor = Theme.keyboardBackgroundColor
        addSubview(backgroundView)
        backgroundView.autoPinWidthToSuperview()
        backgroundView.autoPinEdge(toSuperviewEdge: .top)
        backgroundView.autoPinEdge(toSuperviewEdge: .bottom, withInset: -30)

        let topStrokeView = UIView()
        topStrokeView.backgroundColor = Theme.hairlineColor
        addSubview(topStrokeView)
        topStrokeView.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .bottom)
        topStrokeView.autoSetDimension(.height, toSize: CGHairlineWidth())

        let stackView = UIStackView(arrangedSubviews: [labelScrollView, proceedButton])
        stackView.spacing = 12
        stackView.alignment = .center
        addSubview(stackView)
        stackView.autoPinEdgesToSuperviewMargins()

        updateContents()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: CGSize {
        return CGSize.zero
    }

    // MARK: public

    private var namesText: String? {
        get {
            return namesLabel.text
        }
    }

    public func setNamesText(_ newValue: String?, animated: Bool) {
        let changes = {
            self.namesLabel.text = newValue

            self.layoutIfNeeded()

            let offset = max(0, self.labelScrollView.contentSize.width - self.labelScrollView.bounds.width)
            let trailingEdge = CGPoint(x: offset, y: 0)

            self.labelScrollView.setContentOffset(trailingEdge, animated: false)
        }

        if animated {
            UIView.animate(withDuration: 0.1, animations: changes)
        } else {
            changes()
        }
    }

    // MARK: private subviews

    lazy var labelScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false

        scrollView.addSubview(namesLabel)
        namesLabel.autoPinEdgesToSuperviewEdges()
        namesLabel.autoMatch(.height, to: .height, of: scrollView)

        return scrollView
    }()

    lazy var namesLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.ows_dynamicTypeBody
        label.textColor = Theme.secondaryTextAndIconColor

        label.setContentHuggingLow()

        return label
    }()

    var proceedLoadingIndicator = UIActivityIndicatorView(style: .white)
    lazy var proceedButton: OWSButton = {
        let button = OWSButton.sendButton(imageName: proceedImageName) { [weak self] in
            guard let self = self else { return }
            self.delegate?.approvalFooterDelegateDidRequestProceed(self)
        }

        button.addSubview(proceedLoadingIndicator)
        proceedLoadingIndicator.autoCenterInSuperview()
        proceedLoadingIndicator.isHidden = true

        return button
    }()

    private var proceedImageName: String {
        return approvalMode == .send ? "send-solid-24" : "arrow-right-24"
    }

    func updateContents() {
        if approvalMode == .loading {
            proceedButton.setImage(imageName: nil)
            proceedLoadingIndicator.isHidden = false
            proceedLoadingIndicator.startAnimating()
        } else {
            proceedButton.setImage(imageName: proceedImageName)
            proceedLoadingIndicator.stopAnimating()
            proceedLoadingIndicator.isHidden = true
        }
    }
}
