// SettingsPage.swift — Thermik (MIT). The Settings page of the main window: a strip of the ten tabs (icon over title,
// like the toolbar of the former Settings window) above the selected tab's content (SettingsRoot). The popover's gear,
// ⌘, and thermik://settings links open this page.
import SwiftUI

struct SettingsPage: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabStrip(selection: $model.settingsTab)
            Divider()
            SettingsRoot(tab: model.settingsTab)
        }
    }
}

/// The tabs centred in one row; scrolls sideways when the window is too narrow for all of them.
private struct SettingsTabStrip: View {
    @Binding var selection: SettingsTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs.frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) { tabs }
        }
        .padding(.vertical, 6)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .regular))
                            .frame(height: 22)
                        Text(verbatim: tab.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .background(selected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: tab.title))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.horizontal, 8)
    }
}

extension SettingsTab {
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .sensors: "thermometer.medium"
        case .fans: "fan"
        case .alerts: "bell.badge"
        case .logging: "list.bullet.rectangle"
        case .appearance: "sparkles"
        case .helper: "lock.shield"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}
