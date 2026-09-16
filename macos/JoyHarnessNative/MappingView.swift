import SwiftUI

struct MappingView: View {
    @EnvironmentObject private var state: AppState
    @State private var hoveredID: String?
    private let hotspots = ControllerHotspotReader.load()

    var body: some View {
        VStack(spacing: 0) {
            PageTitle(
                "按键",
                subtitle: "点任意一个按键，修改它发出的快捷键。",
                trailing: AnyView(
                    Picker("手柄", selection: $state.mappingSide) {
                        ForEach(ControllerSide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 176)
                )
            )
            .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 10)

            if !state.permissionsSatisfied { permissionNotice }
            if let error = state.mappingConfigError { configError(error) }

            ScrollView {
                mappingBoard(height: naturalBoardHeight)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 8)
            }
        }
        .sheet(item: $state.mappingDraft) { draft in
            MappingEditorSheet(draft: draft)
                .environmentObject(state)
                .interactiveDismissDisabled(state.isSavingMapping)
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JoyTheme.orange)
            Text("还没有授权，这些配置暂时不会生效。").font(.system(size: 12))
            Spacer()
            Button("前往关于页面") { state.selectedPage = .about }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(JoyTheme.orange.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 30).padding(.bottom, 8)
    }

    private func configError(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error); Spacer()
            Button("重新读取") { state.reloadMappingConfiguration() }.buttonStyle(SecondaryButtonStyle())
        }
        .font(.system(size: 12)).padding(.horizontal, 30).padding(.bottom, 12)
    }

    private func mappingBoard(height: CGFloat) -> some View {
        GeometryReader { geometry in
            let metrics = BoardMetrics(size: geometry.size, side: side)
            let layout = boardLayout(metrics: metrics)
            ZStack(alignment: .topLeading) {
                controllerVisual
                    .frame(width: metrics.controllerFrame.width, height: metrics.controllerFrame.height)
                    .position(x: metrics.controllerFrame.midX, y: metrics.controllerFrame.midY)

                Canvas { context, _ in
                    for item in layout {
                        var path = Path()
                        path.move(to: item.start)
                        let direction: CGFloat = item.column == .left ? 1 : -1
                        let curve = max(52, min(104, abs(item.end.x - item.start.x) * 0.46))
                        path.addCurve(
                            to: item.end,
                            control1: CGPoint(x: item.start.x + curve * direction, y: item.start.y),
                            control2: CGPoint(x: item.end.x - curve * direction, y: item.end.y)
                        )
                        let highlighted = hoveredID == item.card.id
                        context.stroke(path, with: .color(highlighted ? JoyTheme.blue : JoyTheme.blue.opacity(0.24)), lineWidth: highlighted ? 3 : 1.2)
                        let radius: CGFloat = highlighted ? 6 : 4
                        context.fill(Path(ellipseIn: CGRect(x: item.end.x - radius, y: item.end.y - radius, width: radius * 2, height: radius * 2)), with: .color(highlighted ? JoyTheme.blue : JoyTheme.blue.opacity(0.62)))
                    }
                }
                .allowsHitTesting(false)

                ForEach(layout) { item in
                    mappingCard(item.card)
                        .frame(width: LayoutItem.cardWidth, height: item.height)
                        .position(
                            x: item.cardOrigin.x + LayoutItem.cardWidth / 2,
                            y: item.cardOrigin.y + item.height / 2
                        )
                }
            }
        }
        .frame(height: height)
    }

    /// The board is as tall as what it holds, never as tall as the window.
    /// It used to take `max(570, window - 8)`, and since both the controller
    /// and each column are centred inside that height, a taller window pushed
    /// them apart and opened a band of nothing under the page title: the
    /// page's weight sat low while its top was blank. Sized to its content,
    /// the slack falls below the board, where a top-anchored page expects it.
    private var naturalBoardHeight: CGFloat {
        let points = hotspots[side] ?? [:]
        let cards = state.mappingCards(for: side)
        func columnHeight(_ group: [MappingCardModel]) -> CGFloat {
            let stacked = group.map(LayoutItem.height(for:)).reduce(0, +)
            return stacked + LayoutItem.gap * CGFloat(max(group.count - 1, 0))
        }
        let left = cards.filter { (points[$0.hotspotKey]?.x ?? 0.5) < 0.5 }
        let right = cards.filter { (points[$0.hotspotKey]?.x ?? 0.5) >= 0.5 }
        return max(
            BoardMetrics.controllerSize.height,
            columnHeight(left),
            columnHeight(right)
        ) + 28
    }

    private enum Column { case left, right }
    private struct LayoutItem: Identifiable {
        static let cardWidth: CGFloat = 190
        /// Gap between cards. Capped, because a column spread over the full
        /// board height stops reading as a list and starts floating.
        static let gap: CGFloat = 14

        /// Cards are as tall as what they hold. A fixed height meant a button
        /// that does one thing was drawn in a box sized for two, which is why
        /// half the board looked unfinished next to the other half.
        static func height(for card: MappingCardModel) -> CGFloat {
            switch card.rows.count {
            case 1: return 48
            case 2: return 62
            default: return 78
            }
        }

        var height: CGFloat { LayoutItem.height(for: card) }
        let card: MappingCardModel
        let column: Column
        let cardOrigin: CGPoint
        let start: CGPoint
        let end: CGPoint
        var id: String { card.id }
    }

    private struct BoardMetrics {
        static let controllerSize = CGSize(width: 310, height: 505)
        static let imageSize = CGSize(width: 310, height: 410)

        let size: CGSize
        let side: ControllerSide

        var controllerFrame: CGRect {
            CGRect(
                x: (size.width - Self.controllerSize.width) / 2,
                y: max(0, (size.height - Self.controllerSize.height) / 2),
                width: Self.controllerSize.width,
                height: Self.controllerSize.height
            )
        }

        var imageFrame: CGRect {
            CGRect(
                x: controllerFrame.minX,
                y: controllerFrame.minY + 62,
                width: Self.imageSize.width,
                height: Self.imageSize.height
            )
        }

        // The two source PNGs have slightly different optical bounds. This
        // correction keeps calibrated right-side dots centered on the keys.
        var hotspotYOffset: CGFloat { side == .right ? 8 : 0 }

        func hotspotPoint(_ hotspot: ControllerHotspot) -> CGPoint {
            CGPoint(
                x: imageFrame.minX + hotspot.x * imageFrame.width,
                y: imageFrame.minY + hotspot.y * imageFrame.height + hotspotYOffset
            )
        }
    }

    private func boardLayout(metrics: BoardMetrics) -> [LayoutItem] {
        let points = hotspots[side] ?? [:]
        let cards = state.mappingCards(for: side)
        let left = cards.filter { (points[$0.hotspotKey]?.x ?? 0.5) < 0.5 }
            .sorted { (points[$0.hotspotKey]?.y ?? 0) < (points[$1.hotspotKey]?.y ?? 0) }
        let right = cards.filter { (points[$0.hotspotKey]?.x ?? 0.5) >= 0.5 }
            .sorted { (points[$0.hotspotKey]?.y ?? 0) < (points[$1.hotspotKey]?.y ?? 0) }
        return [(Column.left, left), (.right, right)].flatMap { column, columnCards -> [LayoutItem] in
            let top: CGFloat = 14
            // Both columns cap their gap at the same LayoutItem.gap, which is
            // what keeps them reading as one board however many cards each
            // holds. (A `maxColumnCount` used to be computed here and never
            // read; the CI contract asserted that dead line by name.)
            let heights = columnCards.map(LayoutItem.height(for:))
            let stacked = heights.reduce(0, +)
            let usableHeight = max(stacked, metrics.size.height - top * 2)
            let spread = columnCards.count > 1
                ? min((usableHeight - stacked) / CGFloat(columnCards.count - 1), LayoutItem.gap)
                : 0
            let columnHeight = stacked + spread * CGFloat(max(columnCards.count - 1, 0))
            var y = top + (usableHeight - columnHeight) / 2

            return columnCards.enumerated().map { index, card in
                let origin = CGPoint(
                    x: column == .left ? 0 : metrics.size.width - LayoutItem.cardWidth,
                    y: y
                )
                let hotspot = points[card.hotspotKey] ?? ControllerHotspot(x: 0.5, y: 0.5)
                let start = CGPoint(
                    x: column == .left ? origin.x + LayoutItem.cardWidth : origin.x,
                    y: origin.y + heights[index] / 2
                )
                y += heights[index] + spread
                return LayoutItem(
                    card: card,
                    column: column,
                    cardOrigin: origin,
                    start: start,
                    end: metrics.hotspotPoint(hotspot)
                )
            }
        }
    }

    private func mappingCard(_ card: MappingCardModel) -> some View {
        Button {
            state.beginEditing(side: side, button: card.id, displayKey: card.key)
        } label: {
            HStack(spacing: 10) {
                ButtonGlyph(button: card.key).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.rows) { row in
                        mappingLine(row.gesture, row.value, isOnly: card.rows.count == 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(hoveredID == card.id ? JoyTheme.blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hoveredID == card.id ? JoyTheme.blue : Color.primary.opacity(0.08), lineWidth: hoveredID == card.id ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(hoveredID == card.id ? 1.015 : 1)
            .animation(JoyMotion.hover, value: hoveredID)
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? card.id : nil }
        .accessibilityLabel("\(card.key) 按键配置")
        .accessibilityIdentifier("mapping-card-\(side.rawValue)-\(card.id)")
    }

    /// A nil gesture means the button does one thing, so the line carries no
    /// label -- and the value gets the larger type, because on that card it
    /// *is* the content rather than one of several alternatives.
    private func mappingLine(_ gesture: String?, _ action: String, isOnly: Bool) -> some View {
        let unset = action == "未设置"
        return HStack(spacing: 8) {
            if let gesture {
                Text(gesture)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
            }
            Text(action)
                .font(.system(size: isOnly ? 15 : 12, weight: isOnly ? .semibold : .medium))
                .foregroundStyle(unset ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var controllerVisual: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isSelectedControllerConnected ? JoyTheme.green
                          : (selectedControllerStatus.asleep ? JoyTheme.blue : Color.secondary))
                    .frame(width: 8, height: 8)
                Text(selectedControllerStatus.statusText).font(.system(size: 11, weight: .semibold))
                if let level = selectedControllerStatus.batteryLevel {
                    Text(selectedControllerStatus.charging ? "· 电量 \(level)/4 · 充电中" : "· 电量 \(level)/4")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 36).background(JoyTheme.cardSurface).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(JoyTheme.cardBorder, lineWidth: 1) }
            .fixedSize(horizontal: true, vertical: false)
            .position(x: 155, y: 19)

            if let image = state.imageResource(named: side.imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 310, height: 410)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 7)
                    .position(x: 155, y: 267)
            }

            Text(side == .left ? "左 Joy-Con" : "右 Joy-Con")
                .font(.system(size: 11))
                .foregroundStyle(JoyTheme.detail)
                .position(x: 155, y: 493)
        }
    }

    private var selectedControllerStatus: ControllerStatus { side == .left ? state.leftController : state.rightController }
    private var isSelectedControllerConnected: Bool { selectedControllerStatus.connected }
    private var side: ControllerSide { state.mappingSide }
}

private struct ButtonGlyph: View {
    let button: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        glyph
            .frame(width: 38, height: 38)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.14 : 0.2), radius: 2, y: 1)
    }

    @ViewBuilder private var glyph: some View {
        if ["A", "B", "X", "Y"].contains(button) {
            keyCircle {
                Text(button).font(.system(size: 10, weight: .bold, design: .rounded))
            }
        } else if ["L", "R"].contains(button) {
            keyCapsule(width: 34, height: 23, radius: 10, text: button)
        } else if ["ZL", "ZR"].contains(button) {
            keyCapsule(width: 34, height: 26, radius: 7, text: button)
        } else if ["SL", "SR"].contains(button) {
            railKey
        } else if button == "摇杆" {
            stickKey
        } else if button == "+" || button == "−" {
            Image(systemName: button == "+" ? "plus" : "minus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(symbolColor)
                .frame(width: 32, height: 32)
        } else if button == "Home" {
            keyCircle {
                Image(systemName: "house.fill").font(.system(size: 13, weight: .semibold))
            }
        } else if button == "截图" {
            captureKey
        } else if ["↑", "↓", "←", "→"].contains(button) {
            keyCircle {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
            }
        } else {
            keyCapsule(width: 32, height: 28, radius: 7, text: button)
        }
    }

    private func keyCircle<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Circle().fill(keySurface)
            Circle().stroke(keyBorder, lineWidth: 1)
            Circle().stroke(keyHighlight, lineWidth: 1).padding(2)
            content().foregroundStyle(keyText)
        }
        .frame(width: 30, height: 30)
    }

    private func keyCapsule(width: CGFloat, height: CGFloat, radius: CGFloat, text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(keySurface)
            RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(keyBorder, lineWidth: 1)
            Text(text).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(keyText)
        }
        .frame(width: width, height: height)
    }

    private var railKey: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(keySurface)
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(keyBorder, lineWidth: 1)
            Capsule().fill(keyHighlight).frame(width: 2, height: 18).offset(x: -11)
            Text(button).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(keyText)
        }
        .frame(width: 31, height: 28)
    }

    private var stickKey: some View {
        ZStack {
            Circle().fill(keySurface)
            Circle().stroke(keyBorder, lineWidth: 2)
            Circle().stroke(keyHighlight, lineWidth: 1).padding(5)
            Circle().fill(keyHighlight.opacity(0.75)).frame(width: 5, height: 5)
        }
        .frame(width: 32, height: 32)
    }

    private var captureKey: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(keySurface)
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(keyBorder, lineWidth: 1)
            Circle().stroke(keyText.opacity(0.9), lineWidth: 2).frame(width: 14, height: 14)
            Circle().fill(keyText.opacity(0.9)).frame(width: 4, height: 4)
        }
        .frame(width: 30, height: 30)
    }

    // 键帽在深浅两个模式下都是深色的 —— 它画的是一颗实体按键，
    // 不是界面表面，跟着背景反相会让它不再像个按键。两种模式只差
    // 一点明度：浅色背景上压暗一档，深色背景上提亮一档，好让它
    // 在各自的底上都有边界。色值统一走 JoyTheme，不在这里另起一套。
    private var keySurface: Color {
        colorScheme == .dark ? JoyTheme.keyCapRaised : JoyTheme.keyCap
    }

    private var keyBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.38)
    }

    private var keyHighlight: Color { Color.white.opacity(colorScheme == .dark ? 0.16 : 0.12) }
    private var keyText: Color { Color.white.opacity(0.94) }
    private var symbolColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.9) : JoyTheme.keyCap
    }

    private var symbol: String {
        switch button {
        case "+": return "plus"
        case "−": return "minus"
        case "Home": return "house.fill"
        case "截图": return "camera.viewfinder"
        case "↑": return "arrow.up"
        case "↓": return "arrow.down"
        case "←": return "arrow.left"
        case "→": return "arrow.right"
        default: return "circle.fill"
        }
    }
}
