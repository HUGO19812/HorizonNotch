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
        setResult(pending.apply(accumulator, operand))
        self.accumulator = nil
        self.pending = nil
        typing = false
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
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .trailing, spacing: 2) {
                Spacer(minLength: 0)
                Text(engine.expression)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Text(engine.display)
                    .font(.system(size: 42, weight: .light, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: engine.display)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, 6)

            Keypad(engine: engine)
                .frame(width: 252)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear {
            NotificationCenter.default.post(name: .islandWantsKeyboard, object: nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return: engine.equals(); return .handled
        case .escape: engine.clear(); return .handled
        case .delete, .deleteForward: engine.backspace(); return .handled
        default: break
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
                Key("=", kind: .operation) { engine.equals() }
            }
        }
    }
}

private struct Key: View {
    enum Kind { case digit, function, operation }

    let title: String
    let kind: Kind
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, kind: Kind = .digit, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: kind == .operation ? 15 : 13, weight: kind == .digit ? .medium : .semibold))
                .foregroundStyle(active ? Color.orange : (kind == .function ? .black : .white))
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                .background(Capsule().fill(fill).brightness(hovering ? 0.08 : 0))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        switch kind {
        case .digit: return Color.white.opacity(0.13)
        case .function: return Color(white: 0.65)
        case .operation: return active ? .white : .orange
        }
    }
}
