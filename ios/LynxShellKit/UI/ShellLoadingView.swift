import UIKit

/** OTA 缺包/修复/回滚期间的原生 Loading，不创建空 LynxView 掩盖真实状态。 */
final class ShellLoadingView: UIView {
    var onCancel: (() -> Void)?

    private let indicator = UIActivityIndicatorView(style: .large)
    private let detailLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func show(message: String, canCancel: Bool = true) {
        detailLabel.text = message
        cancelButton.isHidden = !canCancel
        isHidden = false
        indicator.startAnimating()
        superview?.bringSubviewToFront(self)
    }

    func hide() {
        indicator.stopAnimating()
        isHidden = true
    }

    private func configure() {
        backgroundColor = .systemBackground
        isHidden = true
        indicator.hidesWhenStopped = true

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [indicator, detailLabel, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
