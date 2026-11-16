import AppKit
import Combine
import CoreLocation
import EventKit
import SwiftUI

/// What the setup in the notch can ask the app to do (set by the app
/// delegate, which owns the calendar and weather services).
enum OnboardingActions {
    static var requestCalendar: () -> Void = {}
    static var requestLocation: () -> Void = {}
    static var accessibilityChanged: () -> Void = {}
}

/// First launch, right in the notch on a larger stage: "hello" is
/// written out, then one page with every permission (Allow beside each),
/// one to connect Claude Code, and a short "all set". Back, page dots and
/// Continue along the bottom.
struct OnboardingView: View {
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case hello, permissions, agent, done
    }

    @State private var step: Step = .hello
    @State private var forward = true
    @State private var granted: Set<String> = []
    @State private var claudeConnected = ClaudeHooks.isInstalled
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .hello:
                    HelloView { go(.permissions) }
                case .permissions:
                    PermissionsPage(granted: granted, allow: allow)
                        .transition(slide)
                case .agent:
                    AgentPage(connected: claudeConnected, connect: connectClaude)
                        .transition(slide)
                case .done:
                    DoneStep()
                        .transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if step != .hello { bottomBar }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
                    removal: .opacity.combined(with: .offset(x: forward ? -40 : 40)))
    }

    private var bottomBar: some View {
        HStack {
            Button(L("Zurück", "Back")) { go(Step(rawValue: step.rawValue - 1) ?? .hello) }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 110, alignment: .leading)
            Spacer()
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(Color.white.opacity(item == step ? 1 : 0.3))
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            Spacer()
            Button {
                if step == .done { onFinish() } else { go(Step(rawValue: step.rawValue + 1) ?? .done) }
            } label: {
                Text(primaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryFilled ? .black : .white)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(primaryFilled ? Color.white : Color.white.opacity(0.14)))
            }
            .buttonStyle(PressScaleStyle())
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// Permissions still missing: "Later" in grey, otherwise "Continue".
    private var primaryFilled: Bool { !(step == .permissions && granted.count < 3) }

    private var primaryTitle: String {
        switch step {
        case .done: return L("Fertig", "Done")
        case .permissions where granted.count < 3: return L("Später", "Skip for now")
        default: return L("Weiter", "Continue")
        }
    }

    private func go(_ next: Step) {
        forward = next.rawValue > step.rawValue
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = next }
    }

    private func allow(_ key: String) {
        switch key {
        case "accessibility":
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        case "calendar":
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                OnboardingActions.requestCalendar()
            } else {
                Permissions.openPrivacySettings("Privacy_Calendars")
            }
        case "location":
            if CLLocationManager().authorizationStatus == .notDetermined {
                OnboardingActions.requestLocation()
            } else {
                Permissions.openPrivacySettings("Privacy_LocationServices")
            }
        default:
            break
        }
    }

    private func connectClaude() {
        try? ClaudeHooks.install()
        withAnimation { claudeConnected = ClaudeHooks.isInstalled }
    }

    private func refresh() {
        var now: Set<String> = []
        if Permissions.accessibilityGranted { now.insert("accessibility") }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { now.insert("calendar") }
        if Permissions.locationGranted { now.insert("location") }
        if now.contains("accessibility") && !granted.contains("accessibility") { OnboardingActions.accessibilityChanged() }
        if now != granted { withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { granted = now } }
    }
}

/// Title and subtitle at the top of a setup page.
private struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 19, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
    }
}

/// One row: a coloured tile, name and what it is for, a button on the right.
private struct SetupRow<Trailing: View>: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

private func pillButton(_ title: String, filled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(filled ? .black : .white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.14)))
    }
    .buttonStyle(PressScaleStyle())
}

private struct GrantedMark: View {
    var title = L("Erlaubt", "Allowed")

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
            .transition(.scale.combined(with: .opacity))
    }
}

private struct PermissionsPage: View {
    let granted: Set<String>
    let allow: (String) -> Void

    private var missing: Int { 3 - granted.count }

    var body: some View {
        VStack(spacing: 12) {
            PageTitle(title: L("Zugriff für Horizon Notch", "Give Horizon Notch access"),
                      subtitle: missing == 0
                        ? L("Alles erlaubt.", "All set.")
                        : L("Noch \(missing) offen. Überspringst du, bleiben diese Funktionen aus, bis du sie erlaubst.",
                            "\(missing) still to allow. Skip, and those features stay off until you do."))
            VStack(spacing: 8) {
                row("accessibility", symbol: "accessibility", colors: [Color(red: 0.3, green: 0.6, blue: 1), Color(red: 0.2, green: 0.45, blue: 0.95)],
                    title: L("Bedienungshilfen", "Accessibility"),
                    detail: L("Für Lautstärke, Helligkeit und die Medientasten", "For volume, brightness and the media keys"))
                row("calendar", symbol: "calendar", colors: [Color(red: 1, green: 0.42, blue: 0.4), Color(red: 0.9, green: 0.28, blue: 0.3)],
                    title: L("Kalender", "Calendars"),
                    detail: L("Für deinen Tag und den Countdown bis zu Meetings", "To show your day and count down to calls"))
                row("location", symbol: "location.fill", colors: [Color(red: 0.35, green: 0.8, blue: 0.5), Color(red: 0.2, green: 0.65, blue: 0.4)],
                    title: L("Standort", "Location"),
                    detail: L("Für das Wetter dort, wo du bist", "For the weather where you are"))
            }
        }
        .padding(.top, 6)
    }

    private func row(_ key: String, symbol: String, colors: [Color], title: String, detail: String) -> some View {
        SetupRow(symbol: symbol, colors: colors, title: title, detail: detail) {
            if granted.contains(key) {
                GrantedMark()
            } else {
                pillButton(L("Erlauben", "Allow")) { allow(key) }
            }
        }
    }
}

/// Connect Claude Code: a little picture of what the notch then shows.
private struct AgentPage: View {
    let connected: Bool
    let connect: () -> Void

    private var installed: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path)
    }

    var body: some View {
        VStack(spacing: 12) {
            PageTitle(title: L("Coding-Agent verbinden", "Connect your coding agent"),
                      subtitle: L("Sieh hier, was er gerade tut, wann er dich braucht und wann er fertig ist.",
                                  "See here what it's doing, when it needs you, and when it's done."))
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.32, blue: 0.68), Color(red: 0.22, green: 0.38, blue: 0.7)],
                                         startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 16)
                VStack(spacing: 6) {
                    HStack {
                        Text("✳").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                        Spacer()
                        Text("1:40").font(.system(size: 12, weight: .bold).monospacedDigit())
                    }
                    Text(L("Führt die Tests aus", "Running the tests"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 18)
                .frame(width: 280, height: 58)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous)
                    .fill(Color.black))
            }
            .frame(width: 420, height: 92)
            SetupRow(symbol: "sparkle", colors: [Color(white: 0.25), Color(white: 0.15)],
                     title: "Claude Code",
                     detail: installed ? L("Auf diesem Mac gefunden", "Found on this Mac")
                                       : L("Noch nicht installiert", "Not installed yet")) {
                if connected {
                    GrantedMark(title: L("Verbunden", "Connected"))
                } else {
                    pillButton(L("Verbinden", "Connect"), action: connect)
                }
            }
            Text(L("Fügt einen Hook neben deinen ein und legt eine Sicherung der Datei an. Nichts verlässt deinen Mac.",
                   "Adds a hook next to yours and keeps a copy of the file. Nothing leaves your Mac."))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 6)
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
            Text(L("Alles bereit", "You're all set"))
                .font(.system(size: 20, weight: .bold))
            Text(L("Fahr mit dem Zeiger auf die Notch, um sie zu öffnen. Mit zwei Fingern seitlich wischen wechselt die Seiten.",
                   "Move the pointer onto the notch to open it. Swipe sideways with two fingers to switch pages."))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}

/// "hello" written out in one continuous line like Apple's greeting, in a
/// blue-to-pink gradient, then "Welcome to Horizon Notch" and Get Started.
struct HelloView: View {
    let onStart: () -> Void
    @State private var written: CGFloat = 0
    @State private var showRest = false

    var body: some View {
        VStack(spacing: 8) {
            HelloShape()
                .trim(from: 0, to: written)
                .stroke(LinearGradient(colors: [Color(red: 0.55, green: 0.7, blue: 1), Color(red: 0.62, green: 0.5, blue: 1),
                                                Color(red: 0.8, green: 0.5, blue: 0.95), Color(red: 0.95, green: 0.55, blue: 0.7)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
                .frame(width: 200, height: 76)
            Group {
                Text(L("Willkommen bei Horizon Notch", "Welcome to Horizon Notch"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Button(action: onStart) {
                    Text(L("Los geht's", "Get Started"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(PressScaleStyle())
                .padding(.top, 4)
            }
            .opacity(showRest ? 1 : 0)
            .offset(y: showRest ? 0 : 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).delay(0.3)) { written = 1 }
            withAnimation(.easeOut(duration: 0.5).delay(2.2)) { showRest = true }
        }
    }
}

/// The word "hello" as one monoline cursive stroke, drawn in a 250 × 100
/// box and scaled to fit.
private struct HelloShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 6, y: 86))
        // h: up into the loop, down the stem, over the hump.
        p.addCurve(to: CGPoint(x: 46, y: 12), control1: CGPoint(x: 26, y: 66), control2: CGPoint(x: 50, y: 32))
        p.addCurve(to: CGPoint(x: 30, y: 16), control1: CGPoint(x: 43, y: 0), control2: CGPoint(x: 31, y: 2))
        p.addCurve(to: CGPoint(x: 22, y: 92), control1: CGPoint(x: 29, y: 40), control2: CGPoint(x: 24, y: 70))
        p.addCurve(to: CGPoint(x: 50, y: 56), control1: CGPoint(x: 28, y: 72), control2: CGPoint(x: 38, y: 56))
        p.addCurve(to: CGPoint(x: 58, y: 80), control1: CGPoint(x: 62, y: 56), control2: CGPoint(x: 60, y: 68))
        p.addCurve(to: CGPoint(x: 74, y: 90), control1: CGPoint(x: 56, y: 92), control2: CGPoint(x: 66, y: 94))
        // e
        p.addCurve(to: CGPoint(x: 96, y: 64), control1: CGPoint(x: 86, y: 86), control2: CGPoint(x: 100, y: 74))
        p.addCurve(to: CGPoint(x: 80, y: 76), control1: CGPoint(x: 92, y: 54), control2: CGPoint(x: 80, y: 60))
        p.addCurve(to: CGPoint(x: 110, y: 88), control1: CGPoint(x: 80, y: 94), control2: CGPoint(x: 98, y: 96))
        // l
        p.addCurve(to: CGPoint(x: 134, y: 14), control1: CGPoint(x: 126, y: 78), control2: CGPoint(x: 138, y: 34))
        p.addCurve(to: CGPoint(x: 120, y: 24), control1: CGPoint(x: 131, y: 2), control2: CGPoint(x: 120, y: 6))
        p.addCurve(to: CGPoint(x: 128, y: 90), control1: CGPoint(x: 120, y: 50), control2: CGPoint(x: 119, y: 82))
        p.addCurve(to: CGPoint(x: 150, y: 84), control1: CGPoint(x: 134, y: 96), control2: CGPoint(x: 144, y: 92))
        // l
        p.addCurve(to: CGPoint(x: 172, y: 14), control1: CGPoint(x: 164, y: 74), control2: CGPoint(x: 176, y: 34))
        p.addCurve(to: CGPoint(x: 158, y: 24), control1: CGPoint(x: 169, y: 2), control2: CGPoint(x: 158, y: 6))
        p.addCurve(to: CGPoint(x: 166, y: 90), control1: CGPoint(x: 158, y: 50), control2: CGPoint(x: 157, y: 82))
        p.addCurve(to: CGPoint(x: 190, y: 80), control1: CGPoint(x: 172, y: 96), control2: CGPoint(x: 184, y: 90))
        // o and the closing flourish
        p.addCurve(to: CGPoint(x: 210, y: 58), control1: CGPoint(x: 194, y: 70), control2: CGPoint(x: 200, y: 58))
        p.addCurve(to: CGPoint(x: 214, y: 92), control1: CGPoint(x: 228, y: 58), control2: CGPoint(x: 230, y: 90))
        p.addCurve(to: CGPoint(x: 202, y: 68), control1: CGPoint(x: 200, y: 94), control2: CGPoint(x: 194, y: 78))
        p.addCurve(to: CGPoint(x: 244, y: 62), control1: CGPoint(x: 212, y: 58), control2: CGPoint(x: 232, y: 60))

        let box = CGRect(x: 0, y: 0, width: 250, height: 100)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: rect.midX - box.midX * scale, y: rect.midY - box.midY * scale)
            .scaledBy(x: scale, y: scale)
        return p.applying(transform)
    }
}
