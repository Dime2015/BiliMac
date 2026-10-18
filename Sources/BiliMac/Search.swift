import AppKit
import SwiftUI

/// Search box state: history, bilibili 热搜, and live suggestions.
@MainActor
final class SearchModel: ObservableObject {
    @Published var hot: [BiliAPI.HotWord] = []
    @Published var suggestions: [String] = []
    @Published private(set) var history: [String]
    @Published var placeholder = L("想看什么？")
    /// Keyboard-highlighted row in `items(for:)`.
    @Published var highlighted: Int?
    private var defaultWord: String?
    private var hotLoaded = Date.distantPast
    private var suggestTask: Task<Void, Never>?
    private var lastQuery = ""

    init() { history = Env.demo ? [] : UserDefaults.standard.stringArray(forKey: "searchHistory") ?? [] }

    func loadIfNeeded() async {
        guard Date().timeIntervalSince(hotLoaded) > 300 else { return }
        hotLoaded = Date()
        async let h = try? BiliAPI.shared.hotSearch()
        async let d = BiliAPI.shared.defaultSearchWord()
        if let list = await h { hot = list }
        if let w = await d, !w.isEmpty { defaultWord = w; placeholder = w }
    }

    func textChanged(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q != lastQuery else { return }
        lastQuery = q
        highlighted = nil
        suggestTask?.cancel()
        guard !q.isEmpty else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let r = (try? await BiliAPI.shared.searchSuggest(q)) ?? []
            if !Task.isCancelled { suggestions = r }
        }
    }

    /// Rows the arrow keys move through.
    func items(for text: String) -> [String] {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? history + hot.map(\.keyword) : suggestions
    }

    func move(_ delta: Int, text: String) {
        let n = items(for: text).count
        guard n > 0 else { return }
        if let h = highlighted { highlighted = (h + delta + n) % n } else { highlighted = delta > 0 ? 0 : n - 1 }
    }

    /// What Enter searches for: the highlighted row, else the text, else the site's suggested word.
    func query(for text: String) -> String? {
        let list = items(for: text)
        if let h = highlighted, list.indices.contains(h) { return list[h] }
        let q = text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return q }
        return defaultWord
    }

    func record(_ q: String) {
        guard !Env.demo else { return }
        history.removeAll { $0 == q }
        history.insert(q, at: 0)
        if history.count > 12 { history.removeLast(history.count - 12) }
        UserDefaults.standard.set(history, forKey: "searchHistory")
    }

    func clearHistory() {
        history = []
        highlighted = nil
        UserDefaults.standard.removeObject(forKey: "searchHistory")
    }
}

// MARK: - Text field without the system completion / AutoFill panel

final class SearchNSTextField: NSTextField {
    var onFocus: ((Bool) -> Void)?

    /// Only take focus from a click (or ⌘F), never as the window's automatic first key view —
    /// that is what popped a panel under the field right after launch.
    static var focusRequested = false
    override var acceptsFirstResponder: Bool {
        if Self.focusRequested { return true }
        if let e = NSApp.currentEvent, e.type == .leftMouseDown, let w = window,
           frame.insetBy(dx: -20, dy: -14).contains(superview?.convert(e.locationInWindow, from: nil) ?? .zero), e.window === w {
            return true
        }
        return false
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        Self.focusRequested = false
        if ok {
            if let editor = currentEditor() as? NSTextView { Self.quiet(editor) }
            onFocus?(true)
        }
        return ok
    }

    /// Turns off everything that pops system UI under the field.
    static func quiet(_ tv: NSTextView) {
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.inlinePredictionType = .no
        tv.insertionPointColor = .themeText
    }
}

struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onFocus: (Bool) -> Void
    /// Called only for edits the user typed (not for text set from code).
    var onEdit: () -> Void = {}
    var onSubmit: () -> Void
    var onMove: (Int) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchNSTextField {
        let f = SearchNSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 14.5)
        f.textColor = .themeText
        f.isAutomaticTextCompletionEnabled = false
        f.contentType = nil
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.cell?.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        f.onFocus = { context.coordinator.parent.onFocus($0) }
        return f
    }

    func updateNSView(_ f: SearchNSTextField, context: Context) {
        context.coordinator.parent = self
        // While editing, only push text that changed from code (the clear button). SwiftUI also calls this with a
        // stale value while a keystroke is still on its way; writing that back and then the new value selected
        // all the text, so the next key replaced it — and any write while an input method (pinyin, kana) is
        // composing throws the composition away. Both cut off Chinese input.
        let c = context.coordinator
        defer { c.lastText = text }
        if let editor = f.currentEditor() as? NSTextView {
            if text != c.lastText, text != c.typed, editor.string != text, !editor.hasMarkedText() {
                f.stringValue = text
                c.typed = text
            }
        } else if f.stringValue != text {
            f.stringValue = text
        }
        // Touch the cell only when the placeholder really changes, not on every keystroke.
        guard context.coordinator.placeholder != placeholder else { return }
        context.coordinator.placeholder = placeholder
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.42) : NSColor(hex: 0x9499A0)
            }, .font: NSFont.systemFont(ofSize: 14.5),
        ])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        /// The last text that came from the user's typing.
        var typed = ""
        var placeholder: String?
        /// The bound value at the previous update, to tell a real change from a stale repeat.
        var lastText = ""
        init(_ p: SearchTextField) { parent = p }

        func controlTextDidBeginEditing(_ n: Notification) {
            if let tv = (n.object as? NSTextField)?.currentEditor() as? NSTextView { SearchNSTextField.quiet(tv) }
        }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            // Pinyin still being composed: wait for the committed characters.
            if let editor = f.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            // A pasted or injected newline means "search", never part of the query.
            if f.stringValue.contains(where: \.isNewline) {
                f.stringValue = f.stringValue.filter { !$0.isNewline }
                typed = f.stringValue
                parent.text = f.stringValue
                parent.onSubmit()
                return
            }
            typed = f.stringValue
            parent.text = f.stringValue
            parent.onEdit()
        }

        func controlTextDidEndEditing(_ n: Notification) { parent.onFocus(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

// MARK: - Search box + dropdown

struct SearchBox: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var search: SearchModel
    @State private var focused = false
    @State private var open = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                .foregroundStyle(focused ? Theme.text : Theme.text2)
            SearchTextField(text: $app.searchText, placeholder: search.placeholder,
                            onFocus: { f in
                                focused = f
                                if f { withAnimation(Motion.pop) { open = true } }
                            },
                            onEdit: { if !open { withAnimation(Motion.pop) { open = true } } },
                            onSubmit: submit,
                            onMove: { search.move($0, text: app.searchText) },
                            onCancel: { withAnimation(Motion.exit) { open = false } })
                .frame(height: 22)
            if !app.searchText.isEmpty {
                Button { app.searchText = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 14)) }
                    .buttonStyle(.pressable).foregroundStyle(Theme.text2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 420, height: 44)
        .background(focused ? Color.dyn(0x2A2A2A, 0xFFFFFF) : Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Color.dyn(0xFFFFFF, 0xFB7299) : .clear, lineWidth: 1.5))
        .animation(Motion.press, value: focused)
        .animation(Motion.pop, value: app.searchText.isEmpty)
        .floatingPanel(id: "search", isPresented: $open, placement: .below(.leading)) {
            SearchPanel(search: search, text: app.searchText) { pick($0) }
        }
        .onChange(of: app.searchText) { _, t in search.textChanged(t) }
        .task { await search.loadIfNeeded() }
    }

    private func submit() {
        guard let q = search.query(for: app.searchText) else { return }
        pick(q)
    }

    private func pick(_ q: String) {
        withAnimation(Motion.exit) { open = false }
        app.submitSearch(q)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct SearchPanel: View {
    @ObservedObject var search: SearchModel
    let text: String
    let pick: (String) -> Void

    var body: some View {
        let q = text.trimmingCharacters(in: .whitespaces)
        MenuSurface(width: 460) {
            if q.isEmpty {
                if !search.history.isEmpty {
                    HStack {
                        MenuHeader(text: L("搜索历史"))
                        Spacer()
                        Button(L("清空")) { withAnimation(Motion.slide) { search.clearHistory() } }
                            .buttonStyle(.pressable)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Theme.text3)
                            .padding(.trailing, 10)
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(Array(search.history.enumerated()), id: \.element) { i, h in
                            HistoryChip(text: h, highlighted: search.highlighted == i) { pick(h) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    MenuDivider()
                }
                MenuHeader(text: L("bilibili 热搜"))
                if search.hot.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(14)
                }
                ForEach(Array(search.hot.enumerated()), id: \.element) { i, w in
                    HotRow(rank: i + 1, word: w, highlighted: search.highlighted == search.history.count + i) { pick(w.keyword) }
                }
            } else {
                SuggestRow(text: Lf("搜索「%@」", "\(q)"), query: "", icon: "magnifyingglass", highlighted: false) { pick(q) }
                if !search.suggestions.isEmpty { MenuDivider() }
                ForEach(Array(search.suggestions.enumerated()), id: \.element) { i, s in
                    SuggestRow(text: s, query: q, icon: "arrow.up.right", highlighted: search.highlighted == i) { pick(s) }
                }
            }
        }
    }
}

private struct HistoryChip: View {
    let text: String
    let highlighted: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12.5)).lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(hover || highlighted ? Color.dyn(0x4A4A4A, 0xF8DCE6) : Color.dyn(0x3A3A3A, 0xFCEBF1), in: Capsule())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }
}

private struct HotRow: View {
    let rank: Int
    let word: BiliAPI.HotWord
    let highlighted: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(rank)").font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(rank <= 3 ? Theme.pink : Theme.text3)
                    .frame(width: 18)
                Text(word.keyword).font(.system(size: 13.5)).lineLimit(1)
                if let icon = word.icon {
                    RemoteImage(url: icon, contentMode: .fit).frame(height: 14).frame(maxWidth: 30)
                        .background(.clear)
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(hover || highlighted ? Theme.menuHover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }
}

private struct SuggestRow: View {
    let text: String
    let query: String
    let icon: String
    let highlighted: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3).frame(width: 18)
                highlightedText.lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(hover || highlighted ? Theme.menuHover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }

    /// The typed part in white, the completion dimmer.
    private var highlightedText: Text {
        guard !query.isEmpty, let r = text.range(of: query, options: .caseInsensitive) else {
            return Text(text).font(.system(size: 13.5))
        }
        return Text(text[..<r.lowerBound]).font(.system(size: 13.5)).foregroundColor(Theme.text2)
            + Text(text[r]).font(.system(size: 13.5, weight: .bold)).foregroundColor(Theme.text)

            + Text(text[r.upperBound...]).font(.system(size: 13.5)).foregroundColor(Theme.text2)
    }
}
