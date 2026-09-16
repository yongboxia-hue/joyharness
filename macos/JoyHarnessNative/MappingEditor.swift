import AppKit
import SwiftUI

enum MappingGesture: String, CaseIterable, Identifiable {
    case single
    case double
    case long

    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return "单击"
        case .double: return "双击"
        case .long: return "长按"
        }
    }
}

enum MappingActionDraft: Equatable {
    case disabled
    /// The user added this gesture but has not chosen a shortcut for it yet.
    /// The row is visible; nothing is written until it is filled in.
    case pending
    case shortcut(ShortcutDefinition)
    case appSwitch
    case windowSwitch
    case focusInput
    /// A mapping this editor does not know how to edit (a macro, say). Kept
    /// byte-for-byte so opening a button never quietly rewrites it.
    case preserved(Data, String)

    /// The draft for one built-in, named the way ActionCatalog names it.
    static func builtIn(_ action: String) -> MappingActionDraft {
        switch action {
        case "app_switch_mode": return .appSwitch
        case "window_switch": return .windowSwitch
        case "focus_input": return .focusInput
        default: return .disabled
        }
    }

    static func shortcutKeys(_ keys: String...) -> MappingActionDraft {
        guard let shortcut = ShortcutDefinition(keys: keys) else { return .disabled }
        return .shortcut(shortcut)
    }

    static func from(_ mapping: [String: Any]?) -> MappingActionDraft {
        guard let mapping else { return .disabled }

        // A gesture slot is just a set of keys -- it names no action.
        if let keys = mapping["keys"] as? [String], mapping["action"] == nil {
            guard let shortcut = ShortcutDefinition(keys: keys) else { return preserve(mapping) }
            return .shortcut(shortcut)
        }

        switch mapping["action"] as? String ?? "disabled" {
        case "disabled": return .disabled
        case "passthrough":
            guard let keys = mapping["keys"] as? [String],
                  let shortcut = ShortcutDefinition(keys: keys) else { return preserve(mapping) }
            return .shortcut(shortcut)
        case "app_switch_mode": return .appSwitch
        case "window_switch": return .windowSwitch
        case "focus_input": return .focusInput
        default: return preserve(mapping)
        }
    }

    /// Whether this gesture has a row in the editor at all.
    var isSet: Bool { self != .disabled }

    /// The action identifier this draft writes, for the built-ins.
    var actionName: String? {
        switch self {
        case .appSwitch: return "app_switch_mode"
        case .windowSwitch: return "window_switch"
        case .focusInput: return "focus_input"
        case .disabled: return "disabled"
        default: return nil
        }
    }

    var displayLabel: String {
        switch self {
        case .pending: return "未设置"
        case .shortcut(let shortcut): return shortcut.displayLabel
        case .preserved(_, let label): return label
        default: return ActionCatalog.name(of: actionName)
        }
    }

    /// This draft as a whole button -- the button *is* this key.
    var passthroughMapping: [String: Any]? {
        switch self {
        case .disabled, .pending: return nil
        case .shortcut(let shortcut): return shortcut.passthroughMapping
        case .appSwitch: return ["action": "app_switch_mode"]
        case .windowSwitch: return ["action": "window_switch"]
        case .focusInput: return ["action": "focus_input"]
        case .preserved(let data, _): return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// This draft as one slot of a gesture split -- sent once when that
    /// gesture happens, so it carries keys rather than an action.
    var slotMapping: [String: Any]? {
        switch self {
        case .disabled, .pending: return nil
        case .shortcut(let shortcut): return shortcut.slotMapping
        case .appSwitch: return ["action": "app_switch_mode"]
        case .windowSwitch: return ["action": "window_switch"]
        case .focusInput: return ["action": "focus_input"]
        case .preserved(let data, _): return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    private static func preserve(_ mapping: [String: Any]) -> MappingActionDraft {
        let data = (try? JSONSerialization.data(withJSONObject: mapping, options: [.sortedKeys])) ?? Data()
        return .preserved(data, MappingConfigReader.formatAction(mapping))
    }
}

struct MappingEditDraft: Identifiable {
    let side: ControllerSide
    let button: String
    let displayKey: String
    var single: MappingActionDraft
    var double: MappingActionDraft
    var long: MappingActionDraft

    var id: String { "\(side.rawValue)-\(button)" }

    subscript(gesture: MappingGesture) -> MappingActionDraft {
        get {
            switch gesture {
            case .single: return single
            case .double: return double
            case .long: return long
            }
        }
        set {
            switch gesture {
            case .single: single = newValue
            case .double: double = newValue
            case .long: long = newValue
            }
        }
    }
}

struct MappingEditorSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var draft: MappingEditDraft
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    /// True once the button does more than one thing, which is exactly when
    /// the gesture names are worth showing.
    private var isSplit: Bool { draft.long.isSet || draft.double.isSet }

    /// Built-ins own both of their levels, so the "add" affordances and the
    /// gesture rows below them would be promising something they cannot do.
    private var isBuiltInDraft: Bool {
        guard let action = draft.single.actionName else { return false }
        return ActionCatalog.twoLevelActions.contains(action)
    }

    init(draft: MappingEditDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("配置 \(draft.displayKey)")
                    .font(.system(size: 17, weight: .semibold))
                Text(draft.side.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if isBuiltInDraft {
                Label("内置动作，单击和长按不能分开设置。", systemImage: "lock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            // Only the first gesture is ever shown up front. A button that
            // does one thing is just a key, and asking the user to pick a
            // "type" before configuring it would make them learn the model
            // first -- the type is a consequence of what they fill in.
            VStack(alignment: .leading, spacing: 12) {
                ShortcutActionEditorRow(
                    gesture: .single,
                    showGestureTitle: isSplit,
                    action: binding(for: .single)
                )
                if draft.long.isSet {
                    ShortcutActionEditorRow(
                        gesture: .long,
                        showGestureTitle: true,
                        action: binding(for: .long),
                        onRemove: { draft.long = .disabled }
                    )
                }
                if draft.double.isSet {
                    ShortcutActionEditorRow(
                        gesture: .double,
                        showGestureTitle: true,
                        action: binding(for: .double),
                        onRemove: { draft.double = .disabled }
                    )
                }
            }

            // Two ways to add a gesture, so two of the same thing. 添加双击
            // used to hide inside a menu of its own with one item in it,
            // next to 添加长按 as a plain link -- two shapes for one job, and
            // a menu called 更多 sitting a few points below another menu
            // called 更多 that offered something else entirely.
            if !isBuiltInDraft && (!draft.long.isSet || !draft.double.isSet) {
                HStack(spacing: 18) {
                    if !draft.long.isSet {
                        addGestureButton("添加长按") { draft.long = .pending }
                            .accessibilityIdentifier("mapping-add-long")
                    }
                    if !draft.double.isSet {
                        addGestureButton("添加双击") { draft.double = .pending }
                            .accessibilityIdentifier("mapping-add-double")
                    }
                    Spacer(minLength: 0)
                }
            }

            // The cost of a double click, where it can be read. It was a
            // tooltip on a menu, which is to say invisible: nothing told you
            // that adding this slows every single press down.
            if draft.double.isSet {
                Text("加了双击之后，单击会延迟 0.35 秒才触发。")
                    .font(.system(size: 11))
                    .foregroundStyle(JoyTheme.detail)
            }

            // Only says the thing that cannot be guessed from looking at it.
            // "点击方框录制快捷键" is visible from the field's own placeholder
            // and from trying it once; that the short press moves to release
            // is not.
            if isSplit {
                Text("单击会在松手时触发。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(JoyTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("恢复推荐") {
                    draft = state.recommendedDraft(side: draft.side, button: draft.button, displayKey: draft.displayKey)
                    saveError = nil
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("mapping-editor-reset")
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("mapping-editor-cancel")
                Button(state.isSavingMapping ? "保存中…" : "保存") {
                    saveError = nil
                    state.saveMapping(draft) { failure in
                        saveError = failure
                        if failure == nil { dismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isSavingMapping)
                // How verify-native-hit-targets knows the editor opened. It
                // looked for an identifier on the sheet itself, which nothing
                // carried and which SwiftUI does not surface here anyway --
                // the sheet's own container is not in the accessibility tree,
                // only the controls inside it. 保存 is the one control that is
                // always there, whatever the button is configured to do.
                .accessibilityIdentifier("mapping-editor-save")
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func binding(for gesture: MappingGesture) -> Binding<MappingActionDraft> {
        Binding(get: { draft[gesture] }, set: { draft[gesture] = $0 })
    }

    private func addGestureButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(JoyTheme.blue)
    }
}

private struct ShortcutActionEditorRow: View {
    let gesture: MappingGesture
    /// A button that does one thing needs no gesture name -- it is just
    /// that key. The names only earn their space once there are several.
    var showGestureTitle: Bool = true
    @Binding var action: MappingActionDraft
    var onRemove: (() -> Void)? = nil
    @State private var manualInput = ""
    @State private var showManualInput = false
    @State private var validationMessage: String?
    @State private var isRecording = false
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The gesture's name belongs above the field it names, the way
            // every section on every page of this app is labelled. Beside it
            // -- 12pt grey floating next to a tall block -- it read as a stray
            // caption, and because it only appears once a button does two
            // things, the field's left edge used to jump 50 points sideways
            // the moment a second gesture was added.
            HStack(spacing: 10) {
                if showGestureTitle {
                    Text(gesture.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(JoyTheme.detail)
                }
                Spacer(minLength: 8)
                // Small icons, on the line with the small text. Beside the
                // field they were two bare glyphs next to a solid block, at a
                // weight that matched nothing else in the row.
                rowMenu
                if let onRemove {
                    Button {
                        validationMessage = nil
                        onRemove()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("移除这个动作")
                    .accessibilityLabel("移除\(gesture.title)")
                }
            }
            .frame(height: 16)

            if isBuiltInAction {
                Label(action.displayLabel, systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 16)
                    .background(JoyTheme.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(JoyTheme.cardBorder, lineWidth: 1)
                    }
                    .help("这是内置动作，请从上面的菜单选择")
            } else {
                shortcutField
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        // `action` can change out from under this row without going through
        // one of the handlers below -- e.g. the sheet's "恢复推荐" button
        // replaces the whole draft at once. Without this, a stale manual
        // TextField entry or validation error from before the reset would
        // keep showing next to the now-current action.
        .onChange(of: action) { _ in
            if !showManualInput { manualInput = "" }
            validationMessage = nil
        }
        // Half-typed text is not a mistake yet. The complaint waits until the
        // field is left, by which point the text is as finished as it is going
        // to get.
        .onChange(of: isTyping) { focused in
            if !focused { validateTypedText() }
        }
    }

    private var rowMenu: some View {
        // One kind of thing: what this button sends. How you enter a shortcut
        // -- record it or type it -- is a different axis, and it lives in the
        // field itself; mixing the two in here is what made manual entry hard
        // to find and odd to come across.
        Menu {
            specialButton("fn", .shortcutKeys("fn"))
            specialButton("Return", .shortcutKeys("enter"))
            specialButton("Escape", .shortcutKeys("escape"))
            specialButton("Tab", .shortcutKeys("tab"))
            specialButton("Space", .shortcutKeys("space"))
            specialButton("Delete", .shortcutKeys("backspace"))
            Divider()
            // No "连续 Delete" or "按住 Command" entries any more: a modifier
            // is held and everything else repeats, the same way it does on the
            // keyboard, so plain Delete and plain Command already are those.
            specialButton("Command", .shortcutKeys("cmd"))
            specialButton("Option", .shortcutKeys("alt_r"))
            specialButton("Control", .shortcutKeys("ctrl"))
            specialButton("Shift", .shortcutKeys("shift"))
            Divider()
            // Built-ins come from ActionCatalog, so the menu cannot offer a
            // name the rest of the app calls something else, nor an action the
            // shipped runtime cannot carry out.
            ForEach(ActionCatalog.editableActions, id: \.self) { action in
                specialButton(ActionCatalog.name(of: action), .builtIn(action))
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择特殊按键或行为")
    }

    private var isBuiltInAction: Bool {
        guard let name = action.actionName else { return false }
        return ActionCatalog.twoLevelActions.contains(name)
    }

    /// The shortcut, and both ways of putting one there, inside a single
    /// field-shaped control.
    ///
    /// The shortcut is the one value this whole sheet exists to set, so it is
    /// drawn at a size that says so rather than squeezed into a 30pt button.
    /// Recording and typing take the same slot -- never both at once -- and
    /// the way into the other one sits at the trailing edge behind a hairline,
    /// so it reads as part of the field without becoming a second place to
    /// click when you meant to start recording.
    private var shortcutField: some View {
        HStack(spacing: 0) {
            Group {
                if showManualInput {
                    TextField("如 ⌘V 或 Command+V", text: $manualInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .focused($isTyping)
                        .onSubmit { isTyping = false }
                        .onChange(of: manualInput) { _ in parseWhileTyping() }
                        .accessibilityLabel("\(gesture.title)快捷键手动输入")
                        .accessibilityIdentifier("manual-shortcut-field")
                } else {
                    ShortcutRecorderControl(
                        label: action.displayLabel,
                        onRecord: { shortcut in
                            action = .shortcut(shortcut)
                            manualInput = ""
                            validationMessage = nil
                        },
                        onRecordingChanged: { isRecording = $0 }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)

            // Left of the hairline is about the value itself, right of it is
            // how you enter one -- so clearing belongs here, and the hairline
            // belongs to the clear button: with nothing to clear there is only
            // one control on this side and nothing to separate it from.
            if canClear {
                Button(action: clearValue) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(JoyTheme.detail)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .help("清空")
                .accessibilityLabel("清空\(gesture.title)")
                .accessibilityIdentifier("shortcut-clear")

                Divider()
                    .frame(height: 24)
            }

            // Recording is what this field is for -- you press the keys you
            // want. Typing is for the keys you cannot press, so it is named
            // and always in the same place, but never given equal weight.
            Button(showManualInput ? "改用录制" : "手动输入") {
                showManualInput.toggle()
                manualInput = showManualInput ? editableText : ""
                validationMessage = nil
                isTyping = showManualInput
            }
            .buttonStyle(JoyLinkButtonStyle())
            .padding(.horizontal, 14)
            .accessibilityIdentifier("manual-shortcut-toggle")
        }
        .frame(height: 48)
        .background(JoyTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isRecording ? JoyTheme.blue : JoyTheme.cardBorder,
                        lineWidth: isRecording ? 2 : 1)
        }
        .animation(JoyMotion.hover, value: isRecording)
        .animation(JoyMotion.hover, value: showManualInput)
        .animation(JoyMotion.hover, value: canClear)
    }

    /// Whether there is anything in the field to empty out.
    private var canClear: Bool {
        showManualInput ? !manualInput.isEmpty : action.isSet
    }

    /// The current shortcut as text the parser will accept back, so switching
    /// to typing starts from what is already set rather than from nothing.
    /// Empty when the value cannot survive the round trip -- better to start
    /// blank than to hand back something that will not parse.
    private var editableText: String {
        guard case .shortcut = action else { return "" }
        let label = action.displayLabel
        return (try? ShortcutDefinition.parse(label)) != nil ? label : ""
    }

    /// Emptying the field is the same act as clearing the mapping: an empty
    /// field means this gesture does nothing, which is what the outer 清除
    /// button used to say separately. Removing the row is a different thing
    /// and still lives on the row's own line -- and never on the first row,
    /// which cannot be removed at all.
    private func clearValue() {
        manualInput = ""
        action = .disabled
        validationMessage = nil
        if showManualInput { isTyping = true }
    }

    /// Typed text becomes the value as it is typed, so there is no second
    /// word for "commit" anywhere near 保存. Half-typed text is not an error
    /// yet, so nothing is said about it until the field is left or Enter is
    /// pressed; until then the last thing that did parse stands.
    private func parseWhileTyping() {
        validationMessage = nil
        let trimmed = manualInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            action = .disabled
            return
        }
        if let parsed = try? ShortcutDefinition.parse(trimmed) {
            action = .shortcut(parsed)
        }
    }

    private func validateTypedText() {
        let trimmed = manualInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = nil
            return
        }
        do {
            action = .shortcut(try ShortcutDefinition.parse(trimmed))
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func specialButton(_ title: String, _ value: MappingActionDraft) -> some View {
        Button(title) {
            action = value
            manualInput = ""
            validationMessage = nil
        }
    }
}

private struct ShortcutRecorderControl: NSViewRepresentable {
    let label: String
    let onRecord: (ShortcutDefinition) -> Void
    /// Reported upward so the field drawn around this button can show that it
    /// is listening. The button has no bezel of its own any more, so without
    /// this there would be nothing to see but the title changing.
    var onRecordingChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.currentLabel = label
        button.onRecord = onRecord
        button.onRecordingChanged = onRecordingChanged
        button.toolTip = "点击后按下快捷键，Esc 取消"
        // Named so the editor's own test can click it and then send keys at
        // it; there is no other way to prove recording still records.
        button.setAccessibilityIdentifier("shortcut-recorder")
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.currentLabel = label
        button.onRecord = onRecord
        button.onRecordingChanged = onRecordingChanged
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onRecord: ((ShortcutDefinition) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var currentLabel = "未设置" {
        didSet { if !isRecording { title = displayTitle } }
    }
    private var isRecording = false
    /// The largest set of modifiers seen so far in the current recording.
    ///
    /// A modifier-only shortcut cannot be committed when it is pressed,
    /// because at that moment there is no way to tell ⌃ from the start of
    /// ⌃fn or ⌃C. So the peak is remembered while keys go down and
    /// committed once everything is released.
    private var peakModifiers: [String] = []

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        peakModifiers = []
        title = "请按快捷键"
        onRecordingChanged?(true)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        guard let shortcut = KeyboardKeyCatalog.shortcut(from: event) else {
            NSSound.beep()
            return
        }
        // A regular key ends the gesture, so the modifier-release path below
        // must not fire a second time for the same press.
        peakModifiers = []
        onRecord?(shortcut)
        stopRecording()
    }

    /// Records shortcuts made only of modifiers -- ⌃fn, ⇧⌥, fn on its own.
    ///
    /// The fn key never sends a key-down event (it is a modifier, so macOS
    /// reports it only through flags-changed), which is why ⌃C recorded
    /// fine while ⌃fn did nothing at all: keyDown was the sole handler.
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }

        let held = KeyboardKeyCatalog.modifiers(from: event)
        if held.count > peakModifiers.count {
            peakModifiers = held
        }

        guard held.isEmpty else { return }
        defer { peakModifiers = [] }
        guard let shortcut = ShortcutDefinition(keys: peakModifiers) else { return }
        onRecord?(shortcut)
        stopRecording()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    private var displayTitle: String {
        currentLabel == "未设置" ? "点击录制" : currentLabel
    }

    private func stopRecording() {
        let wasRecording = isRecording
        isRecording = false
        peakModifiers = []
        title = displayTitle
        if wasRecording { onRecordingChanged?(false) }
    }
}
