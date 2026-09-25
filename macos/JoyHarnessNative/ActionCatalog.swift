import Foundation

/// The one place an action's name and meaning are written down.
///
/// These strings used to live in three files at once -- `MappingConfigReader
/// .formatAction`, `MappingActionDraft.displayLabel` and the mapping editor's
/// "⋯" menu -- so the same action could be called one thing on the card, a
/// second thing in the editor, and a third thing in the menu that set it. That
/// is the shape of most of v0.1's bugs: a fact restated until the copies drift.
///
/// Adding an action means adding one row here. Anything that needs to *show*
/// it reads `name(of:)`; anything that needs to explain a rendered label reads
/// `meaning(of:)`.
enum ActionCatalog {
    /// Actions whose two levels are part of the action itself, so the editor
    /// shows them locked rather than offering to split them.
    ///
    /// `window_switch` is deliberately NOT here. Its second level needed an
    /// overlay window the shipped runtime cannot build (the bundled Python has
    /// tkinter excluded and nothing ever calls `set_tk_root`), so the card used
    /// to promise "长按 → 选择窗口" for a long press that did nothing at all --
    /// not even the buzz every other long press gives you.
    static let twoLevelActions: Set<String> = ["app_switch_mode"]

    /// action identifier → what it is called everywhere it appears.
    static let names: [String: String] = [
        "disabled": String(localized: "未设置"),
        "app_switch_mode": String(localized: "切换应用"),
        "window_switch": String(localized: "切换窗口"),
        "focus_input": String(localized: "聚焦输入框"),
        "screenshot": String(localized: "截图"),
        "window_picker": String(localized: "选择窗口"),
        "macro": String(localized: "执行宏"),
        "exec": String(localized: "运行命令")
    ]

    /// Actions the mapping editor offers, in menu order. Anything configurable
    /// by hand but not offered here simply keeps working and is preserved
    /// byte-for-byte when its button is opened.
    ///
    /// `window_switch` is not offered: besides the dead second level above, its
    /// first level cycles one hard-coded app's windows (`WindowCycler`'s
    /// default) and nothing in the UI can change which. Offering a button
    /// labelled 聚焦窗口 that only ever reaches VS Code is worse than not
    /// offering it.
    static let editableActions: [String] = ["focus_input", "app_switch_mode"]

    static func name(of action: String?) -> String {
        guard let action else { return names["disabled"]! }
        return names[action] ?? action
    }

    /// What a rendered label is *for*, in the words a user would use.
    ///
    /// Keyed on the label rather than on the button, so it cannot disagree with
    /// the button it is printed next to -- the summary once carried its own
    /// button table and went on calling left X "删除" long after ⌫ had moved to
    /// B. Action names come from `names` above, so those half can never drift.
    static func meaning(of label: String) -> String {
        if let known = shortcutMeanings[label] { return known }
        if let action = names.first(where: { $0.value == label })?.key,
           let explained = actionMeanings[action] {
            return explained
        }
        // Nothing to say about a shortcut this app has no opinion on. It used
        // to answer 常用操作, which says nothing while looking like it does --
        // ⌘⇧5 is not a "common action", it is whatever the user bound it to.
        return ""
    }

    private static let shortcutMeanings: [String: String] = [
        "fn": String(localized: "语音输入"),
        "⌘V": String(localized: "粘贴"),
        "⌥A": String(localized: "连续听写"),
        "⌥": String(localized: "修饰键"),
        "↩": String(localized: "回车"),
        "⇧↩": String(localized: "换行"),
        "⌫": String(localized: "删除"),
        "Esc": String(localized: "取消"),
        "⎋": String(localized: "取消"),
        "⌘Space": String(localized: "聚焦搜索"),
        "⌘L": String(localized: "定位"),
        "⌘K": String(localized: "清除"),
        "⌘Tab": String(localized: "切换应用")
    ]

    private static let actionMeanings: [String: String] = [
        // A meaning explains, it does not restate the name -- 切换应用 /
        // 在应用之间切换 was the same sentence twice -- and it says so in two
        // to four characters, because it is printed on one line beside the
        // name and anything longer is simply cut off.
        "app_switch_mode": String(localized: "选应用"),
        "window_switch": String(localized: "选窗口"),
        "window_picker": String(localized: "选窗口"),
        "focus_input": String(localized: "定位光标"),
        "screenshot": String(localized: "存成图片"),
        "macro": String(localized: "一串操作"),
        "exec": String(localized: "跑命令")
    ]
}
