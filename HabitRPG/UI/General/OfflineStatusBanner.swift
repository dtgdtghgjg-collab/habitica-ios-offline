//
//  OfflineStatusBanner.swift
//  Habitica
//
//  Small pill above the tab bar that tells the player whether their changes
//  are saved locally, syncing, or already on the server.
//

import UIKit
import ReactiveSwift
import Habitica_Database

final class OfflineStatusBanner: UIView, Themeable {

    private let label = UILabel()
    private let iconView = UIImageView()
    private let disposable = ScopedDisposable(CompositeDisposable())
    private var hideWorkItem: DispatchWorkItem?
    private var lastKnownPendingCount = 0

    static func install(in tabBarController: UITabBarController) -> OfflineStatusBanner {
        let banner = OfflineStatusBanner()
        banner.translatesAutoresizingMaskIntoConstraints = false
        tabBarController.view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: tabBarController.view.centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: tabBarController.tabBar.topAnchor, constant: -8),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: tabBarController.view.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: tabBarController.view.trailingAnchor, constant: -16)
        ])
        banner.setup()
        ThemeService.shared.addThemeable(themable: banner)
        return banner
    }

    private func setup() {
        backgroundColor = .systemGray
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true

        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .white
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        isHidden = true
        alpha = 0

        disposable.inner.add(OfflineState.shared.isOnline.producer
            .skipRepeats()
            .startWithValues { [weak self] _ in
                self?.refresh()
            })
        disposable.inner.add(OfflineState.shared.pendingCount.producer
            .skipRepeats()
            .startWithValues { [weak self] _ in
                self?.refresh()
            })
        disposable.inner.add(OfflineState.shared.isSyncing.producer
            .skipRepeats()
            .startWithValues { [weak self] _ in
                self?.refresh()
            })

        refresh()
    }

    // MARK: - State

    private func refresh() {
        let state = OfflineState.shared
        let pending = state.pendingCount.value

        hideWorkItem?.cancel()
        hideWorkItem = nil

        if state.isOffline {
            show(text: pending == 0
                 ? "Offline — changes are saved on this device"
                 : "Offline — \(pending) change\(pending == 1 ? "" : "s") to sync",
                 symbolName: "wifi.slash",
                 background: .systemOrange)
        } else if state.isSyncing.value || pending > 0 {
            show(text: pending > 0 ? "Syncing \(pending) change\(pending == 1 ? "" : "s")…" : "Syncing…",
                 symbolName: "arrow.triangle.2.circlepath",
                 background: .systemBlue)
        } else if lastKnownPendingCount > 0 {
            show(text: "All changes synced", symbolName: "checkmark.circle.fill", background: .systemGreen)
            let workItem = DispatchWorkItem { [weak self] in
                self?.hide(animated: true)
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
        } else {
            hide(animated: false)
        }

        lastKnownPendingCount = pending
    }

    private func show(text: String, symbolName: String, background: UIColor) {
        label.text = text
        iconView.image = UIImage(systemName: symbolName)
        backgroundColor = background
        guard isHidden else {
            return
        }
        isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.alpha = 1
        }
    }

    private func hide(animated: Bool) {
        guard !isHidden else {
            return
        }
        let finish = {
            self.isHidden = true
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 0
            }, completion: { _ in finish() })
        } else {
            alpha = 0
            finish()
        }
    }

    // MARK: - Themeable

    func applyTheme(theme: Theme) {
        // The pill is always filled with a saturated status colour, so white
        // text keeps the contrast in both themes.
        label.textColor = .white
        iconView.tintColor = .white
    }
}
