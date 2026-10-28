//  FirstRunHint.swift — Thermik (MIT). OWNER: Unit 7. First-run hint (SPEC §4.4 B6): a small popover anchored to the
//  status item, "Thermik lives here. Click for temperatures and fans.", shown once (then `menuBar.hintShown = true`).
//  Shown only while the item is actually visible, after onboarding (or 60 s after launch if onboarding is still open).
import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "app.thermik.Thermik", category: "menubar")

@MainActor final class FirstRunHint: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var dismissWork: DispatchWorkItem?
    private let launchDate = Date()
    var isShown: Bool { popover?.isShown ?? false }

    /// Cheap check, called on every tick and visibility change.
    func showIfNeeded(settings: SettingsStore, status: StatusItemController, itemVisible: Bool) {
        guard !settings.menuBarHintShown, popover == nil, itemVisible, !status.isOpen else { return }
        guard settings.onboardingCompleted || Date().timeIntervalSince(launchDate) > 60 else { return }
        guard let button = status.item.button, button.window != nil else { return }
        settings.menuBarHintShown = true
        show(relativeTo: button)
    }

    func show(relativeTo button: NSStatusBarButton) {
        close()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.delegate = self
        let host = NSHostingController(rootView: FirstRunHintView { [weak self] in self?.close() })
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = p
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        log.info("first-run hint shown")
    }

    func close() {
        dismissWork?.cancel(); dismissWork = nil
        popover?.performClose(nil)
        popover = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            dismissWork?.cancel(); dismissWork = nil
            popover = nil
        }
    }
}

struct FirstRunHintView: View {
    var onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Thermik lives here.").font(.system(size: 13, weight: .semibold))
                Text("Click for temperatures and fans.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { onDismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .accessibilityLabel(Text("Close"))
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}
