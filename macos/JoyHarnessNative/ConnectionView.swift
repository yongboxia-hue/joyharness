import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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

                // The states that need an action this page does not otherwise
                // offer. Being paused is not one of them: the response row
                // below both says it and undoes it, so a banner there would be
                // the same sentence twice on one screen.
                if showsRecoveryCard {
                    recoveryCard
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Cards, not full-width rows: a row this wide spends nine
                // hundred points saying 未连接. Nothing on this page is a
                // card inside another card any more, which is what used to
                // put two nearly identical greys on top of each other.
                VStack(alignment: .leading, spacing: 10) {
                    JoySectionHeader("设备")
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
                }

                VStack(alignment: .leading, spacing: 10) {
                    JoySectionHeader(
                        "常用按键",
                        trailing: AnyView(
                            Button("全部配置") { state.selectedPage = .mapping }
                                .buttonStyle(JoyLinkButtonStyle())
                        )
                    )

                    if previewMappings.isEmpty {
                        JoyCard(padding: 14) {
                            Text("还没有可显示的按键。")
                                .font(.system(size: 12))
                                .foregroundStyle(JoyTheme.detail)
                        }
                    } else {
                        // Six previews in three columns: two full rows, no
                        // empty cell. The count is what left a hole in the
                        // old three-column grid, not the three columns.
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                            spacing: 12
                        ) {
                            ForEach(previewMappings) { item in
                                mappingCard(item)
                            }
                        }
                    }
                }

                // Hidden while the banner is up: in those two states this row
                // says the banner's sentence again in weaker words, and the
                // only control it carries is disabled anyway. Exactly one
                // place on the page explains why a press does nothing.
                if !showsRecoveryCard {
                    VStack(alignment: .leading, spacing: 10) {
                        JoySectionHeader("按键响应")
                        // Keyed off availability, not just `paused`: without the
                        // Accessibility grant no key can be sent at all, and this
                        // row still read 正在响应 · 按键正在发出快捷键 on the same
                        // screen as the red 还需要完成系统授权 banner.
                        JoyCard(padding: 14) {
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
                    .transition(.opacity)
                }
            }
            .animation(JoyMotion.stateChange, value: state.availability)
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    /// The states the page cannot fix from the sections below: the grant lives
    /// on another page, a stopped service has to be restarted, and with no
    /// controller connected the device cards can state the fact but not offer
    /// the way out. `disconnected` means neither controller is connected --
    /// one is enough for this product, so a single card reading 未连接 next to
    /// a connected one raises no banner.
    private var showsRecoveryCard: Bool {
        state.availability == .permissionRequired
            || state.availability == .serviceStopped
            || state.availability == .disconnected
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
                    .foregroundStyle(JoyTheme.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            recoveryAction(for: availability)
        }
        .padding(18)
        .background(Color(nsColor: availability.tint).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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

    /// One mapping, on one line: the key cap, what it sends, what that means.
    /// The cap is drawn the way the 按键 page draws it, so a button has one
    /// appearance in this app rather than one per page.
    private func mappingCard(_ item: MappingPreviewItem) -> some View {
        JoyCard(padding: 12, cornerRadius: 10) {
            HStack(spacing: 11) {
                Text(item.key)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 26)
                    .background(JoyTheme.keyCapOnRow)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                // A floor, not a fixed width: short shortcuts line their
                // meanings up down the column, long ones still get the room.
                Text(item.shortcut)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(minWidth: 56, alignment: .leading)
                Text(item.semantic)
                    .font(.system(size: 12))
                    .foregroundStyle(JoyTheme.detail)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
            }
        }
    }

    /// The controller, its name, and one line saying only what the pill does
    /// not: the battery when it is connected, how to get it back when it is
    /// not. A 未连接 line under a 未连接 pill is the same word twice.
    private func controllerCard(name: String, imageName: String, status: ControllerStatus) -> some View {
        JoyCard {
            HStack(spacing: 14) {
                Group {
                    if let image = state.imageResource(named: imageName) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .opacity(status.connected ? 1 : 0.45)
                    }
                }
                .frame(width: 42, height: 70)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(status.connected ? JoyTheme.green : Color.secondary.opacity(0.6))
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if status.connected {
                        BatteryLevelView(level: status.batteryLevel, charging: status.charging)
                    } else {
                        Text(status.asleep ? "按任意键唤醒" : "长按侧边同步键配对")
                            .font(.system(size: 12))
                            .foregroundStyle(JoyTheme.detail)
                    }
                }

                Spacer(minLength: 12)
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
    /// Six, so the two columns come out even.
    private static let previewOrder: [ControllerSide: [String]] = [
        .right: ["ZR", "Plus", "A", "B", "X", "Y"],
        .left: ["ZL", "Minus", "A", "B", "X", "Y"],
    ]

    private var previewMappings: [MappingPreviewItem] {
        let side: ControllerSide = state.leftController.connected && !state.rightController.connected ? .left : .right
        let cards = state.mappingCards(for: side)
        var result: [MappingPreviewItem] = []

        func append(_ card: MappingCardModel, _ row: MappingRow) {
            guard result.count < 6, row.value != "未设置" else { return }
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
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(1...4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fillColor(for: index))
                        .frame(width: 8, height: 12)
                }
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(JoyTheme.detail)
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
