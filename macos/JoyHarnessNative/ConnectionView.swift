import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(
                    "连接",
                    subtitle: "手柄连上了没有，常用按键现在发出什么。",
                    // No status badge here. The banner below states the three
                    // states this page cannot act on, the 按键响应 card states
                    // the other two, and the sidebar states all five all the
                    // time -- a badge beside the title was the same fact a
                    // fourth time. Refresh stays: it is an action on the
                    // page's status, and it is most wanted in exactly the
                    // states that raise no banner.
                    trailing: AnyView(
                        RefreshButton(isRefreshing: state.isRefreshingStatus) {
                            state.refreshStatusWithFeedback()
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
                            name: "左手柄",
                            imageName: ControllerSide.left.imageName,
                            status: state.leftController
                        )
                        controllerCard(
                            name: "右手柄",
                            imageName: ControllerSide.right.imageName,
                            status: state.rightController
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    // Which controller this is about. Both pages read the
                    // same config, but they can be showing different halves of
                    // it, and a summary that does not say which hand it means
                    // looks like a summary that did not update.
                    JoySectionHeader(
                        "常用按键 · \(state.previewSide == .left ? "左手柄" : "右手柄")",
                        trailing: AnyView(
                            Button("全部配置") { state.selectedPage = .mapping }
                                .buttonStyle(JoyLinkButtonStyle())
                        )
                    )

                    if previewMappings.isEmpty {
                        JoyCard(padding: 14) {
                            Text("还没有配置任何按键。")
                                .font(.system(size: 12))
                                .foregroundStyle(JoyTheme.detail)
                        }
                    } else {
                        // Two columns, the same split the device cards use, so
                        // the page has exactly one interior edge and everything
                        // lines up against it. Three columns divided at 33% and
                        // 66% and matched nothing above them.
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
                                    Button {
                                        state.togglePaused()
                                    } label: {
                                        SteadyTitle(
                                            state.isChangingPauseState ? "处理中…" : (state.paused ? "继续响应" : "暂停响应"),
                                            of: ["暂停响应", "继续响应", "处理中…"]
                                        )
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
        case .ready: return "可以用了"
        case .paused: return "已暂停"
        case .permissionRequired: return "等待授权"
        case .serviceStopped: return "没有在运行"
        case .disconnected: return "还没连上手柄"
        }
    }

    private var responseDetail: String {
        switch state.availability {
        case .ready: return "现在按手柄，Mac 就有反应。"
        case .paused: return "手柄还连着，只是暂时不动作。"
        case .permissionRequired: return "先去「设置」里授权。"
        case .serviceStopped: return "JoyHarness 没在运行。"
        case .disconnected: return "连上任意一只手柄就能用。"
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
                Text(bannerDetail(for: availability))
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

    /// Always a neutral button. The banner's own tint carries the severity;
    /// a blue button on a red surface is two accent colours competing inside
    /// one box, and a red one would read as destructive -- which 重新启动 is
    /// not.
    /// The banner is the only place the pairing gesture is written down now
    /// that the cards have stopped carrying it, so the disconnected banner
    /// says it. Not in `AvailabilityState.detail`: that string is also a
    /// menu-bar item, and a second sentence would stretch that menu across
    /// the screen.
    private func bannerDetail(for availability: AvailabilityState) -> String {
        guard availability == .disconnected else { return availability.detail }
        return availability.detail + "第一次配对要长按手柄侧边的同步键，直到指示灯来回跑动。"
    }

    @ViewBuilder
    private func recoveryAction(for availability: AvailabilityState) -> some View {
        switch availability {
        case .serviceStopped:
            Button { state.startService() } label: {
                SteadyTitle(state.isPerformingServiceAction ? "正在启动…" : "重新启动",
                            of: ["重新启动", "正在启动…"])
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.isPerformingServiceAction)
        case .permissionRequired:
            Button("前往授权") { state.selectedPage = .settings }
                .buttonStyle(SecondaryButtonStyle())
        case .disconnected:
            Button("打开蓝牙设置") { state.openBluetoothSettings() }
                .buttonStyle(SecondaryButtonStyle())
        case .paused:
            Button { state.togglePaused() } label: {
                SteadyTitle(state.isChangingPauseState ? "处理中…" : "继续响应",
                            of: ["继续响应", "处理中…"])
            }
            .buttonStyle(SecondaryButtonStyle())
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
                    .font(.system(size: capFontSize(for: item.key), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 26)
                    .background(JoyTheme.keyCapOnRow)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(item.shortcut)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                // Pinned to the trailing edge, which is what gives the card's
                // width a job: what the button sends on the left, what that
                // means on the right, both aligned down the column.
                Text(item.semantic)
                    .font(.system(size: 12))
                    .foregroundStyle(JoyTheme.detail)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
        // Named and valued for the same reason the mapping cards are: this
        // summary is supposed to follow the config, and a test should be able
        // to see that rather than a person noticing it did not.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("preview-\(item.key)")
        .accessibilityValue(item.shortcut)
    }

    /// The controller, its name, and a second line only when there is one
    /// worth having: the battery, or the one gesture that wakes a sleeping
    /// controller. Not 未连接 -- the pill says that -- and not the pairing
    /// instruction either. Most people use one Joy-Con, so on the other card
    /// that instruction would sit there forever as a chore they never meant
    /// to do; it belongs in the banner, which is the only place that also
    /// offers the Bluetooth settings to finish it in.
    /// + and - sit on the maths axis, which is roughly x-height, so at the
    /// size that suits ZR they look a size smaller than the letters beside
    /// them. Symbols get the larger size, letters the middle one, and the
    /// two-character caps stay where they were.
    private func capFontSize(for key: String) -> CGFloat {
        guard key.count == 1, let character = key.first else { return 11 }
        return character.isLetter || character.isNumber ? 12 : 14
    }

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
                    } else if status.asleep {
                        Text("按一下手柄就醒")
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
    /// The order a sentence gets said in, not the order the buttons sit in:
    /// put the cursor somewhere, talk, send it, paste what you copied, delete
    /// what came out wrong, move to the next app. Six, so the columns come out
    /// even. What each one *means* is still read from the mapping itself.
    private static let previewOrder: [ControllerSide: [String]] = [
        .right: ["X", "ZR", "A", "Plus", "B", "Y"],
        .left: ["X", "ZL", "A", "Minus", "B", "Y"],
    ]

    private var previewMappings: [MappingPreviewItem] {
        let side = state.previewSide
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
