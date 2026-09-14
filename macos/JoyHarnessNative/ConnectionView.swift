import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(
                    "连接",
                    subtitle: "Joy-Con 连上之后，按键就会发出你配置的快捷键。",
                    trailing: AnyView(
                        HStack(spacing: 9) {
                            ConnectionStatusBadge(availability: state.availability)
                            RefreshButton(isRefreshing: state.isRefreshingStatus) {
                                state.refreshStatusWithFeedback()
                            }
                        }
                    )
                )

                // Only the two states that need an action the page does not
                // otherwise offer: authorization happens on another page, and a
                // stopped service has to be restarted. "Not connected" and
                // "paused" are said better by the sections below -- each of
                // which now reads its own state off `availability` -- so a
                // banner repeating them is the same sentence twice on a screen.
                if state.availability == .permissionRequired || state.availability == .serviceStopped {
                    recoveryCard
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Text("设备")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 14) {
                    controllerCard(
                        name: "左 Joy-Con",
                        imageName: ControllerSide.left.imageName,
                        status: state.leftController
                    )
                    controllerCard(
                        name: "右 Joy-Con",
                        imageName: ControllerSide.right.imageName,
                        status: state.rightController
                    )
                }

                HStack {
                    Text("常用按键")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("全部配置") { state.selectedPage = .mapping }
                        .buttonStyle(SecondaryButtonStyle())
                }

                JoyCard {
                    if previewMappings.isEmpty {
                        Text("还没有可显示的按键。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                            spacing: 10
                        ) {
                            ForEach(previewMappings) { item in
                                mappingPreview(item)
                            }
                        }
                    }
                }

                Text("按键响应")
                    .font(.system(size: 15, weight: .semibold))

                // Keyed off availability, not just `paused`: without the
                // Accessibility grant no key can be sent at all, and this row
                // still read 正在响应 · 按键正在发出快捷键 on the same screen as
                // the red 还需要完成系统授权 banner.
                JoyCard {
                    InfoRow(
                        symbol: responseSymbol,
                        title: responseTitle,
                        detail: responseDetail,
                        tint: responseTint,
                        trailing: AnyView(
                            Button(state.isChangingPauseState ? "处理中…" : (state.paused ? "继续响应" : "暂停响应")) {
                                state.togglePaused()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!state.serviceRunning || state.isChangingPauseState)
                        )
                    )
                }
            }
            .animation(JoyMotion.stateChange, value: state.availability)
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    /// What the 按键响应 row says. `paused` is only one of the reasons a press
    /// may do nothing, so it is read from the same availability the badge and
    /// the menu-bar icon use.
    private var responseTitle: String {
        switch state.availability {
        case .ready: return "正在响应"
        case .paused: return "已暂停"
        case .permissionRequired: return "等待授权"
        case .serviceStopped: return "没有在运行"
        case .disconnected: return "等待手柄"
        }
    }

    private var responseDetail: String {
        switch state.availability {
        case .ready: return "按键正在发出快捷键。"
        case .paused: return "手柄仍然连着，但按键不发出快捷键。"
        case .permissionRequired: return "完成辅助功能授权前，按键不会发出快捷键。"
        case .serviceStopped: return "服务没有运行，按键不会发出快捷键。"
        case .disconnected: return "连接任意一只 Joy-Con 后，按键就会发出快捷键。"
        }
    }

    private var responseSymbol: String {
        state.availability == .ready ? "keyboard" : state.availability.symbol
    }

    private var responseTint: Color {
        state.availability == .ready ? JoyTheme.green : Color(nsColor: state.availability.tint)
    }

    private var recoveryCard: some View {
        let availability = state.availability
        return HStack(spacing: 16) {
            Image(systemName: availability.symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(nsColor: availability.tint))
                .frame(width: 44, height: 44)
                .background(Color(nsColor: availability.tint).opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(availability.title)
                    .font(.system(size: 17, weight: .bold))
                Text(availability.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            recoveryAction(for: availability)
        }
        .padding(18)
        .background(Color(nsColor: availability.tint).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: availability.tint).opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func recoveryAction(for availability: AvailabilityState) -> some View {
        switch availability {
        case .serviceStopped:
            Button(state.isPerformingServiceAction ? "正在启动…" : "重新启动") { state.startService() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isPerformingServiceAction)
        case .permissionRequired:
            Button("前往授权") { state.selectedPage = .about }
                .buttonStyle(PrimaryButtonStyle())
        case .disconnected:
            Button("打开蓝牙设置") { state.openBluetoothSettings() }
                .buttonStyle(PrimaryButtonStyle())
        case .paused:
            Button(state.isChangingPauseState ? "处理中…" : "继续响应") { state.togglePaused() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isChangingPauseState)
        case .ready:
            EmptyView()
        }
    }

    private func mappingPreview(_ item: MappingPreviewItem) -> some View {
        HStack(spacing: 10) {
            Text(item.key)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.shortcut)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(item.semantic)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func controllerCard(name: String, imageName: String, status: ControllerStatus) -> some View {
        JoyCard {
            HStack(spacing: 14) {
                if let image = state.imageResource(named: imageName) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 70)
                        .opacity(status.connected ? 1 : 0.45)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(status.connected ? JoyTheme.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if status.connected {
                        BatteryLevelView(level: status.batteryLevel, charging: status.charging)
                    } else {
                        Text(status.asleep ? "按任意键唤醒" : "未连接")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                StatusPill(
                    text: status.statusText,
                    color: status.connected ? JoyTheme.green
                         : (status.asleep ? JoyTheme.blue : .secondary)
                )
            }
        }
    }

    /// Which buttons to surface first. Order only -- what each one *means* is
    /// read from the mapping itself, never from a table sitting beside it.
    /// The table that used to carry both drifted the moment the left
    /// controller began mirroring the right by position: it still called
    /// left X "删除" long after ⌫ had moved to B, so the summary confidently
    /// described the wrong button.
    private static let previewOrder: [ControllerSide: [String]] = [
        .right: ["ZR", "Plus", "A", "B", "X"],
        .left: ["ZL", "Minus", "A", "B", "X"],
    ]

    private var previewMappings: [MappingPreviewItem] {
        let side: ControllerSide = state.leftController.connected && !state.rightController.connected ? .left : .right
        let cards = state.mappingCards(for: side)
        var result: [MappingPreviewItem] = []

        func append(_ card: MappingCardModel, _ row: MappingRow) {
            guard result.count < 5, row.value != "未设置" else { return }
            let gesture = row.gesture ?? "单击"
            let id = "\(card.id)-\(gesture)"
            guard !result.contains(where: { $0.id == id }) else { return }
            result.append(MappingPreviewItem(
                id: id, key: card.key, gesture: gesture,
                shortcut: row.value, semantic: ActionCatalog.meaning(of: row.value)
            ))
        }

        for button in Self.previewOrder[side] ?? [] {
            guard let card = cards.first(where: { $0.id == button }),
                  let row = card.rows.first else { continue }
            append(card, row)
        }
        for card in cards {
            for row in card.rows { append(card, row) }
        }
        return result
    }

    private func action(for gesture: String, card: MappingCardModel) -> String {
        if let row = card.rows.first(where: { ($0.gesture ?? "单击") == gesture }) {
            return row.value
        }
        return "未设置"
    }
}


private struct MappingPreviewItem: Identifiable {
    let id: String
    let key: String
    let gesture: String
    let shortcut: String
    let semantic: String
}

struct BatteryLevelView: View {
    let level: Int?
    let charging: Bool

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 2) {
                ForEach(1...4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fillColor(for: index))
                        .frame(width: 9, height: 14)
                }
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(detail)
    }

    private func fillColor(for index: Int) -> Color {
        guard let level else { return Color.primary.opacity(0.1) }
        return index <= level ? JoyTheme.green : Color.primary.opacity(0.1)
    }

    private var detail: String {
        guard let level else { return "电量读取中" }
        return charging ? "电量 \(level)/4 · 充电中" : "电量 \(level)/4"
    }
}
