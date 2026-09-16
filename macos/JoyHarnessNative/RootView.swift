import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var hoveredPage: SidebarPage?

    var body: some View {
        Group {
            if state.isShowingOnboarding {
                OnboardingView()
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    Group {
                        switch state.selectedPage {
                        case .connection: ConnectionView()
                        case .mapping: MappingView()
                        case .about: AboutView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .background(.ultraThinMaterial)
            }
        }
        .alert(
            "操作没有完成",
            isPresented: Binding(
                get: { state.lastError != nil },
                set: { if !$0 { state.dismissError() } }
            )
        ) {
            Button("知道了", role: .cancel) { state.dismissError() }
        } message: {
            Text(state.lastError ?? "请稍后重试。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let icon = state.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("JoyHarness")
                        .font(.system(size: 14, weight: .bold))
                    Text("Joy-Con 快捷键")
                        .font(.system(size: 11))
                        .foregroundStyle(JoyTheme.detail)
                }
            }
            .padding(.horizontal, 17)
            .padding(.top, 24)
            .padding(.bottom, 22)

            VStack(spacing: 5) {
                ForEach(SidebarPage.allCases) { page in
                    Button {
                        state.selectedPage = page
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 22)
                            Text(page.title)
                                .font(.system(size: 13, weight: state.selectedPage == page ? .semibold : .medium))
                            Spacer()
                        }
                        .foregroundStyle(state.selectedPage == page ? JoyTheme.blue : Color.primary.opacity(0.72))
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                        .background(state.selectedPage == page ? JoyTheme.blue.opacity(0.12) : (hoveredPage == page ? Color.primary.opacity(0.055) : Color.clear))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(hoveredPage == page && state.selectedPage != page ? 1.01 : 1)
                    .onHover { isHovering in hoveredPage = isHovering ? page : nil }
                    .animation(.easeOut(duration: 0.15), value: hoveredPage)
                    .accessibilityLabel(page.title)
                    .accessibilityIdentifier("sidebar-\(page.rawValue)")
                    .accessibilityValue(state.selectedPage == page ? "已选择" : "未选择")
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            HStack(spacing: 9) {
                Circle()
                    .fill(Color(nsColor: state.availability.tint))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.availability.badge)
                        .font(.system(size: 12, weight: .semibold))
                    Text(state.controllerSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(JoyTheme.detail)
                        .lineLimit(1)
                }
            }
            .padding(16)
        }
        .frame(width: JoyTheme.sidebarWidth)
        .background(.thinMaterial)
    }
}
