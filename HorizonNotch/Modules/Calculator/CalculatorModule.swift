import AppKit
import Combine
import SwiftUI

/// A scientific calculator page: three wide rows of keys (functions,
/// digits, operators) under the expression and its result, and a history
/// sidebar that slides in from the left. Works with the mouse and, while
/// the page is open, with the keyboard.
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

// MARK: - Engine

/// Builds an expression from key presses and evaluates it with a small
/// parser: + − × ÷ ^, brackets, unary minus, %, ², √, π, e and the
/// functions sin cos tan ln log. The result updates live while typing.
final class CalculatorEngine: ObservableObject {
    /// What was typed, e.g. "sin(30)×2".
    @Published private(set) var expression = ""
    /// The last finished calculation shown above, e.g. "sin(30)×2 =".
    @Published private(set) var lastExpression = ""
    /// The result just calculated (shown large until the next key).
    @Published private(set) var shownResult: String?
    @Published var degrees = true

    /// Live result of the expression typed so far, nil when incomplete.
    var preview: String? {
        guard !expression.isEmpty, let value = Parser.evaluate(expression, degrees: degrees) else { return nil }
        return Self.format(value)
    }

    /// Large display: the result after "=", else what is being typed.
    var display: String { shownResult ?? (expression.isEmpty ? "0" : expression) }

    // MARK: Input

    func input(_ token: String) {
        if let shown = shownResult {
            // After "=": an operator continues with the result, anything
            // else starts a new calculation.
            shownResult = nil
            expression = Self.continuesResult(token) ? Self.parseable(shown) : ""
            if shown == L("Fehler", "Error") { expression = "" }
        }
        expression += token
    }

    func equals() {
        guard !expression.isEmpty else { return }
        // Close brackets left open.
        let open = expression.filter { $0 == "(" }.count - expression.filter { $0 == ")" }.count
        let complete = expression + String(repeating: ")", count: max(0, open))
        lastExpression = complete + " ="
        if let value = Parser.evaluate(complete, degrees: degrees), value.isFinite {
            let text = Self.format(value)
            shownResult = text
            remember("\(complete) = \(text)")
        } else {
            shownResult = L("Fehler", "Error")
        }
        expression = ""
    }

    /// AC: everything; C (while typing): the expression.
    func clear() {
        if !expression.isEmpty {
            expression = ""
        } else {
            shownResult = nil
            lastExpression = ""
        }
    }

    var clearTitle: String { expression.isEmpty ? "AC" : "C" }

    func backspace() {
        if shownResult != nil { shownResult = nil; return }
        // Remove whole function names at once ("sin(").
        for name in ["sin(", "cos(", "tan(", "ln(", "log(", "√("] where expression.hasSuffix(name) {
            expression.removeLast(name.count)
            return
        }
        if !expression.isEmpty { expression.removeLast() }
    }

    /// ± negates what was typed (or the shown result).
    func toggleSign() {
        if let shown = shownResult {
            shownResult = nil
            expression = Self.parseable(shown)
        }
        guard !expression.isEmpty else { expression = "−"; return }
        if expression.hasPrefix("−("), expression.hasSuffix(")") {
            expression = String(expression.dropFirst(2).dropLast())
        } else {
            expression = "−(" + expression + ")"
        }
    }

    // MARK: History

    static let historyLimit = 30

    /// Stored as "12×3 = 36", newest first, in the settings.
    private func remember(_ entry: String) {
        var history = AppSettings.shared.calculatorHistory
        history.removeAll { $0 == entry }
        history.insert(entry, at: 0)
        AppSettings.shared.calculatorHistory = Array(history.prefix(Self.historyLimit))
    }

    /// The result part of a history entry ("36" from "12×3 = 36").
    static func result(of entry: String) -> String {
        entry.components(separatedBy: "= ").last ?? entry
    }

    /// A result from the history goes into the expression.
    func recall(_ entry: String) {
        let value = Self.parseable(Self.result(of: entry))
        if shownResult != nil { shownResult = nil; expression = "" }
        expression += value
    }

    func clearHistory() {
        AppSettings.shared.calculatorHistory = []
    }

    // MARK: Formatting

    private static func continuesResult(_ token: String) -> Bool {
        ["+", "−", "×", "÷", "^", "²", "%"].contains(token)
    }

    /// "1.234,5" → "1234,5" (grouping removed, ready to be parsed again).
    private static func parseable(_ text: String) -> String {
        text.replacingOccurrences(of: ".", with: "")
    }

    static func format(_ number: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        if abs(number) >= 1e15 || (abs(number) < 1e-9 && number != 0) {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 6
        }
        let text = formatter.string(from: NSNumber(value: number)) ?? "\(number)"
        return text == "-0" ? "0" : text.replacingOccurrences(of: "-", with: "−")
    }
}

/// Recursive-descent parser for the calculator's expressions.
private struct Parser {
    private struct Failure: Error {}

    private let characters: [Character]
    private var index = 0
    private let degrees: Bool

    init(_ text: String, degrees: Bool) {
        characters = Array(text.replacingOccurrences(of: " ", with: ""))
        self.degrees = degrees
    }

    static func evaluate(_ text: String, degrees: Bool) -> Double? {
        var parser = Parser(text, degrees: degrees)
        return try? parser.parse()
    }

    private static let functions = ["sin", "cos", "tan", "log", "ln"]

    private static func isDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }

    /// The function name or "e" starting at the current position.
    private func name() -> String? {
        let rest = String(characters[index...].prefix(3))
        if let f = Self.functions.first(where: { rest.hasPrefix($0) }) { return f }
        return rest.hasPrefix("e") ? "e" : nil
    }

    mutating func parse() throws -> Double {
        let value = try sum()
        guard index == characters.count else { throw Failure() }
        return value
    }

    private var current: Character? { index < characters.count ? characters[index] : nil }

    // sum := product (("+" | "−") product)*
    private mutating func sum() throws -> Double {
        var value = try product()
        while let c = current, c == "+" || c == "−" || c == "-" {
            index += 1
            let rhs = try product()
            value = c == "+" ? value + rhs : value - rhs
        }
        return value
    }

    // product := power (("×" | "÷") power | implicit power)*
    private mutating func product() throws -> Double {
        var value = try power()
        while let c = current {
            if c == "×" || c == "*" || c == "÷" || c == "/" {
                index += 1
                let rhs = try power()
                value = (c == "×" || c == "*") ? value * rhs : value / rhs
            } else if c == "(" || c == "π" || c == "√" || name() != nil {
                // "2π", "3(4+1)", "2sin(30)": implicit multiplication.
                value *= try power()
            } else {
                break
            }
        }
        return value
    }

    // power := unary ("^" power)?   (right-associative)
    private mutating func power() throws -> Double {
        let base = try unary()
        if current == "^" {
            index += 1
            return pow(base, try power())
        }
        return base
    }

    // unary := ("−" | "+") unary | postfix
    private mutating func unary() throws -> Double {
        if current == "−" || current == "-" { index += 1; return -(try unary()) }
        if current == "+" { index += 1; return try unary() }
        return try postfix()
    }

    // postfix := primary ("²" | "%")*
    private mutating func postfix() throws -> Double {
        var value = try primary()
        while let c = current, c == "²" || c == "%" {
            index += 1
            value = c == "²" ? value * value : value / 100
        }
        return value
    }

    private mutating func primary() throws -> Double {
        guard let c = current else { throw Failure() }
        if Self.isDigit(c) || c == "," || c == "." { return try number() }
        if c == "(" {
            index += 1
            let value = try sum()
            if current == ")" { index += 1 }
            return value
        }
        if c == "π" { index += 1; return .pi }
        if c == "√" {
            index += 1
            return sqrt(try postfix())
        }
        if let name = name() {
            index += name.count
            if name == "e" { return M_E }
            let argument = try postfix()
            let radians = degrees ? argument * .pi / 180 : argument
            switch name {
            case "sin": return Self.clean(sin(radians))
            case "cos": return Self.clean(cos(radians))
            case "tan": return Self.clean(tan(radians))
            case "ln": return log(argument)
            case "log": return log10(argument)
            default: throw Failure()
            }
        }
        throw Failure()
    }

    private mutating func number() throws -> Double {
        var text = ""
        while let c = current, Self.isDigit(c) || c == "," || c == "." {
            text.append(c == "," ? "." : c)
            index += 1
        }
        // Scientific results such as "1,2E15" or "3E-10".
        if current == "E" {
            text.append("e")
            index += 1
            if current == "−" || current == "-" { text.append("-"); index += 1 }
            while let c = current, Self.isDigit(c) { text.append(c); index += 1 }
        }
        guard let value = Double(text) else { throw Failure() }
        return value
    }

    /// sin(180°) is 1.2e-16 in floating point; show 0.
    private static func clean(_ value: Double) -> Double {
        abs(value) < 1e-12 ? 0 : value
    }
}

// MARK: - View

extension Notification.Name {
    /// Asks the island panel to take keyboard focus without activating the app.
    static let islandWantsKeyboard = Notification.Name("horizon.islandWantsKeyboard")
}

/// History sidebar (toggle at the top left) and the calculator: DEG/RAD,
/// the last calculation and the result, then three rows of keys.
private struct CalculatorView: View {
    @ObservedObject var engine: CalculatorEngine
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var focused: Bool
    @State private var showHistory = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            if showHistory {
                HistorySidebar(entries: settings.calculatorHistory,
                               onPick: { engine.recall($0) },
                               onClear: { engine.clearHistory() })
                    .frame(width: 150)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 8) {
                displayRow
                ScientificKeypad(engine: engine)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showHistory)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear {
            NotificationCenter.default.post(name: .islandWantsKeyboard, object: nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    private var displayRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SmallToggle(symbol: "sidebar.left", active: showHistory) { showHistory.toggle() }
                        .help(L("Verlauf ein-/ausblenden", "Show/hide history"))
                    Button { engine.degrees.toggle() } label: {
                        Text(engine.degrees ? "DEG" : "RAD")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.orange)
                            .frame(width: 44, height: 22)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .help(L("Winkel in Grad oder Bogenmaß", "Angles in degrees or radians"))
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(copied ? L("Kopiert", "Copied") : topLine)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(copied ? Color.orange : .white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(engine.display)
                    .font(.system(size: 34, weight: .light).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .truncationMode(.head)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: engine.display)
                    .onTapGesture { copy() }
                    .help(L("Klicken zum Kopieren", "Click to copy"))
            }
        }
        .frame(height: 58)
    }

    /// While typing: the live result; after "=": the calculation.
    private var topLine: String {
        if engine.shownResult != nil { return engine.lastExpression }
        if let preview = engine.preview, preview != engine.expression { return "= " + preview }
        return engine.lastExpression
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.shownResult ?? engine.preview ?? engine.display, forType: .string)
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
        case let c where c.count == 1 && "0123456789".contains(c): engine.input(c)
        case ",", ".": engine.input(",")
        case "+": engine.input("+")
        case "-": engine.input("−")
        case "*", "x", "X": engine.input("×")
        case "/", ":": engine.input("÷")
        case "^": engine.input("^")
        case "(", ")": engine.input(press.characters)
        case "%": engine.input("%")
        case "=": engine.equals()
        case "p": engine.input("π")
        case "e": engine.input("e")
        case "s": engine.input("sin(")
        case "c": engine.input("cos(")
        case "t": engine.input("tan(")
        case "r": engine.input("√(")
        default: return .ignored
        }
        return .handled
    }
}

/// Three rows of ten keys, like a scientific calculator turned sideways:
/// functions on dark grey, digits on grey, operators in orange.
private struct ScientificKeypad: View {
    @ObservedObject var engine: CalculatorEngine

    private enum Kind { case function, digit, operation, clear }

    private struct KeyDef: Hashable {
        let label: String
        let token: String
        let kind: Kind
    }

    private var rows: [[KeyDef]] {
        [
            [f("sin", "sin("), f("cos", "cos("), f("tan", "tan("), f("π", "π"), f("e", "e"),
             f("x²", "²"), f("√", "√("), f("(", "("), f(")", ")"), o("÷")],
            [d("7"), d("8"), d("9"), d("4"), d("5"), d("6"), o("×"),
             KeyDef(label: engine.clearTitle, token: "clear", kind: .clear),
             KeyDef(label: "±", token: "sign", kind: .clear), o("−")],
            [d("1"), d("2"), d("3"), d("0"), d(","), f("%", "%"), f("ln", "ln("), f("log", "log("),
             f("xʸ", "^"), KeyDef(label: "=", token: "=", kind: .operation)],
        ]
    }

    private func f(_ label: String, _ token: String) -> KeyDef { KeyDef(label: label, token: token, kind: .function) }
    private func d(_ label: String) -> KeyDef { KeyDef(label: label, token: label, kind: .digit) }
    private func o(_ label: String) -> KeyDef { KeyDef(label: label, token: label, kind: .operation) }

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 5) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.self) { key in
                        CalcKey(label: key.label, fill: fill(key.kind), foreground: key.kind == .clear ? .black : .white) {
                            press(key)
                        }
                    }
                }
            }
        }
    }

    private func fill(_ kind: Kind) -> Color {
        switch kind {
        case .function: return Color.white.opacity(0.09)
        case .digit: return Color(white: 0.2)
        case .operation: return Color.orange
        case .clear: return Color(white: 0.65)
        }
    }

    private func press(_ key: KeyDef) {
        switch key.token {
        case "=": engine.equals()
        case "clear": engine.clear()
        case "sign": engine.toggleSign()
        default: engine.input(key.token)
        }
    }
}

private struct CalcKey: View {
    let label: String
    let fill: Color
    let foreground: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill).brightness(hovering ? 0.08 : 0))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
    }
}

/// Small round icon button (the history toggle).
private struct SmallToggle: View {
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? .black : .white.opacity(0.75))
                .frame(width: 28, height: 22)
                .background(Capsule().fill(active ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Past calculations, newest at the top; a click puts the result into the
/// calculation. The bin clears the list.
private struct HistorySidebar: View {
    let entries: [String]
    let onPick: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Verlauf", "History"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !entries.isEmpty {
                    Button(action: onClear) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Verlauf löschen", "Clear history"))
                }
            }
            if entries.isEmpty {
                Text(L("Noch keine Rechnungen", "No calculations yet"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            if index > 0 {
                                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                            }
                            HistoryRow(entry: entry) { onPick(entry) }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

private struct HistoryRow: View {
    let entry: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let result = CalculatorEngine.result(of: entry)
        let calculation = String(entry.dropLast(result.count)).trimmingCharacters(in: .whitespaces)
        Button(action: action) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(calculation)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(result)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hovering ? Color.orange : .white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("In die Rechnung übernehmen", "Use in the calculation"))
    }
}
