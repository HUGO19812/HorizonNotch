import AppKit
import Combine
import SwiftUI

/// A pocket calculator page. Works with the mouse and, while the page is
/// open, with the keyboard (digits, + − × ÷, Enter, Esc, Backspace).
final class CalculatorModule: NotchModule {
    let id = "calculator"
    var title: String { L("Rechner", "Calculator") }
    let symbol = "plus.forwardslash.minus"
    let priority = ModulePriority.media - 30
    let hasExpandedContent = true

    let engine = CalculatorEngine()
    private var subscription: AnyCancellable?

    init() {
        subscription = engine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var isActive: Bool { false }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(CalculatorView(engine: engine)) }
}

/// Immediate-execution logic like a desk calculator.
final class CalculatorEngine: ObservableObject {
    enum Operation: String {
        case add = "+", subtract = "−", multiply = "×", divide = "÷"

        func apply(_ a: Double, _ b: Double) -> Double {
            switch self {
            case .add: return a + b
            case .subtract: return a - b
            case .multiply: return a * b
            case .divide: return b == 0 ? .nan : a / b
            }
        }
    }

    @Published private(set) var display = "0"
    /// Small line above the result, e.g. "12 ×".
    @Published private(set) var expression = ""
    @Published private(set) var pending: Operation?

    private var accumulator: Double?
    private var typing = false

    private var value: Double { Double(display.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    func digit(_ d: String) {
        if !typing || display == "0" {
            display = d
            typing = true
        } else if display.count < 15 {
            display += d
        }
    }

    func decimal() {
        if !typing {
            display = "0,"
            typing = true
        } else if !display.contains(",") {
            display += ","
        }
    }

    func operation(_ op: Operation) {
        if let accumulator, let pending, typing {
            setResult(pending.apply(accumulator, value))
        }
        accumulator = value
        pending = op
        expression = "\(format(value)) \(op.rawValue)"
        typing = false
    }

    func equals() {
        guard let accumulator, let pending else { return }
        let operand = value
        expression = "\(format(accumulator)) \(pending.rawValue) \(format(operand)) ="
        let result = pending.apply(accumulator, operand)
        setResult(result)
        if result.isFinite { remember("\(expression) \(display)") }
        self.accumulator = nil
        self.pending = nil
        typing = false
    }

    // MARK: History

    static let historyLimit = 30

    /// Stored as "12 × 3 = 36", newest first, in the settings.
    private func remember(_ entry: String) {
        var history = AppSettings.shared.calculatorHistory
        history.removeAll { $0 == entry }
        history.insert(entry, at: 0)
        AppSettings.shared.calculatorHistory = Array(history.prefix(Self.historyLimit))
    }

    /// The result part of a history entry ("36" from "12 × 3 = 36").
    static func result(of entry: String) -> String {
        entry.components(separatedBy: "= ").last ?? entry
    }

    /// Takes a result from the history as the number being typed, so it
    /// can continue a calculation.
    func recall(_ entry: String) {
        display = Self.result(of: entry)
        typing = true
    }

    func clearHistory() {
        AppSettings.shared.calculatorHistory = []
    }

    func clear() {
        if typing && display != "0" {
            display = "0"
            typing = false
        } else {
            display = "0"
            expression = ""
            accumulator = nil
            pending = nil
            typing = false
        }
    }

    var clearTitle: String { typing && display != "0" ? "C" : "AC" }

    func toggleSign() {
        guard display != "0" else { return }
        display = display.hasPrefix("-") ? String(display.dropFirst()) : "-" + display
    }

    func percent() {
        setResult(value / 100)
        typing = false
    }

    func backspace() {
        guard typing else { return }
        display = String(display.dropLast())
        if display.isEmpty || display == "-" { display = "0" }
    }

    private func setResult(_ result: Double) {
        display = result.isFinite ? format(result) : L("Fehler", "Error")
    }

    private func format(_ number: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        if abs(number) >= 1e15 || (abs(number) < 1e-9 && number != 0) {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 6
        }
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

// MARK: - View

extension Notification.Name {
    /// Asks the island panel to take keyboard focus without activating the app.
    static let islandWantsKeyboard = Notification.Name("horizon.islandWantsKeyboard")
}

private struct CalculatorView: View {
    @ObservedObject var engine: CalculatorEngine
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.islandTheme) private var theme
    @FocusState private var focused: Bool
    @State private var copied = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .trailing, spacing: 2) {
                HistoryTape(entries: settings.calculatorHistory, accent: theme.accent,
                            onPick: { engine.recall($0) }, onClear: { engine.clearHistory() })
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                Text(copied ? L("Kopiert", "Copied") : engine.expression)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(copied ? theme.accent : .white.opacity(0.45))
                    .lineLimit(1)
                    .frame(height: 14)
                Text(engine.display)
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: engine.display)
                    .onTapGesture { copy() }
                    .help(L("Klicken zum Kopieren", "Click to copy"))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Keypad(engine: engine)
                .frame(width: 236)
        }
        .padding(.bottom, 2)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear {
            NotificationCenter.default.post(name: .islandWantsKeyboard, object: nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.display, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return: engine.equals(); return .handled
        case .escape: engine.clear(); return .handled
        case .delete, .deleteForward: engine.backspace(); return .handled
        default: break
        }
        if press.modifiers.contains(.command), press.characters == "c" {
            copy()
            return .handled
        }
        switch press.characters {
        case let c where c.count == 1 && "0123456789".contains(c): engine.digit(c)
        case ",", ".": engine.decimal()
        case "+": engine.operation(.add)
        case "-": engine.operation(.subtract)
        case "*", "x", "X": engine.operation(.multiply)
        case "/", ":": engine.operation(.divide)
        case "=": engine.equals()
        case "%": engine.percent()
        case "c", "C": engine.clear()
        default: return .ignored
        }
        return .handled
    }
}

/// Past calculations like a paper tape: oldest at the top, newest just
/// above the display. A click takes the result into the calculator.
private struct HistoryTape: View {
    let entries: [String]
    let accent: Color
    let onPick: (String) -> Void
    let onClear: () -> Void
    @State private var hovering = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 1) {
                    ForEach(Array(entries.reversed().enumerated()), id: \.offset) { index, entry in
                        HistoryRow(entry: entry, accent: accent) { onPick(entry) }
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 10)
            }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                               startPoint: .top, endPoint: .bottom)
            }
            .onAppear { proxy.scrollTo(entries.count - 1, anchor: .bottom) }
            .onChange(of: entries) { _, new in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new.count - 1, anchor: .bottom) }
            }
        }
        .overlay(alignment: .topLeading) {
            if !entries.isEmpty && hovering {
                Button(action: onClear) {
                    Label(L("Verlauf löschen", "Clear history"), systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Verlauf löschen", "Clear history"))
                .transition(.opacity)
            }
        }
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }
}

private struct HistoryRow: View {
    let entry: String
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let result = CalculatorEngine.result(of: entry)
        let calculation = String(entry.dropLast(result.count)).trimmingCharacters(in: .whitespaces)
        Button(action: action) {
            HStack(spacing: 4) {
                Text(calculation)
                    .foregroundStyle(.white.opacity(0.4))
                Text(result)
                    .foregroundStyle(hovering ? accent : .white.opacity(0.75))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Ergebnis übernehmen", "Use result"))
    }
}

private struct Keypad: View {
    @ObservedObject var engine: CalculatorEngine

    var body: some View {
        Grid(horizontalSpacing: 5, verticalSpacing: 4) {
            GridRow {
                Key(engine.clearTitle, kind: .function) { engine.clear() }
                Key("±", kind: .function) { engine.toggleSign() }
                Key("%", kind: .function) { engine.percent() }
                Key("÷", kind: .operation, active: engine.pending == .divide) { engine.operation(.divide) }
            }
            GridRow {
                ForEach(["7", "8", "9"], id: \.self) { d in Key(d) { engine.digit(d) } }
                Key("×", kind: .operation, active: engine.pending == .multiply) { engine.operation(.multiply) }
            }
            GridRow {
                ForEach(["4", "5", "6"], id: \.self) { d in Key(d) { engine.digit(d) } }
                Key("−", kind: .operation, active: engine.pending == .subtract) { engine.operation(.subtract) }
            }
            GridRow {
                ForEach(["1", "2", "3"], id: \.self) { d in Key(d) { engine.digit(d) } }
                Key("+", kind: .operation, active: engine.pending == .add) { engine.operation(.add) }
            }
            GridRow {
                Key("0") { engine.digit("0") }
                    .gridCellColumns(2)
                Key(",") { engine.decimal() }
                Key("=", kind: .equals) { engine.equals() }
            }
        }
    }
}

/// One key: digits dark glass, functions a step lighter, operators in
/// the island's accent colour (white while chosen), "=" solid accent.
private struct Key: View {
    enum Kind { case digit, function, operation, equals }

    let title: String
    let kind: Kind
    let active: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.islandTheme) private var theme

    init(_ title: String, kind: Kind = .digit, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: kind == .digit ? 13 : 14, weight: kind == .digit ? .medium : .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                        .brightness(hovering ? 0.08 : 0)
                }
                .overlay {
                    if kind == .operation && !active {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(theme.accent.opacity(0.5), lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .animation(.easeOut(duration: 0.15), value: active)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .digit, .function, .equals: return .white
        case .operation: return theme.accent
        }
    }

    private var fill: Color {
        switch kind {
        case .digit: return Color.white.opacity(0.1)
        case .function: return Color.white.opacity(0.2)
        case .operation: return active ? .white : theme.accent.opacity(0.16)
        case .equals: return theme.accent
        }
    }
}
