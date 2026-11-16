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

/// First launch, right in the notch: "hello" is written out, then one
/// permission per step – what it is for, a button to allow it, a tick when
/// it is granted – and finally a short "all set".
struct OnboardingView: View {
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case hello, accessibility, calendar, location, done
    }

    @State private var step: Step = .hello
    @State private var granted: Set<Step> = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            switch step {
            case .hello:
                HelloView { go(to: .accessibility) }
                    .transition(.opacity)
            case .done:
                DoneStep(onFinish: onFinish)
                    .transition(stepTransition)
            default:
                PermissionStep(info: info(for: step), granted: granted.contains(step),
                               allow: { allow(step) }, next: { advance() })
                    .id(step)
                    .transition(stepTransition)
            }
        }
        .overlay(alignment: .bottom) {
            if step != .hello { progress.padding(.bottom, 2) }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: 30)),
                    removal: .opacity.combined(with: .offset(x: -30)))
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(Step.allCases.dropFirst(), id: \.rawValue) { item in
                Capsule()
                    .fill(Color.white.opacity(item == step ? 0.9 : (item.rawValue < step.rawValue ? 0.45 : 0.18)))
                    .frame(width: item == step ? 16 : 5, height: 5)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
    }

    private func go(to next: Step) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = next }
    }

    private func advance() {
        go(to: Step(rawValue: step.rawValue + 1) ?? .done)
    }

    private func allow(_ step: Step) {
        switch step {
        case .accessibility:
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        case .calendar:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                OnboardingActions.requestCalendar()
            } else {
                Permissions.openPrivacySettings("Privacy_Calendars")
            }
        case .location:
            if CLLocationManager().authorizationStatus == .notDetermined {
                OnboardingActions.requestLocation()
            } else {
                Permissions.openPrivacySettings("Privacy_LocationServices")
            }
        default:
            break
        }
    }

    /// Checks the permissions; a step that just got granted moves on by
    /// itself after a moment.
    private func refresh() {
        var now: Set<Step> = []
        if Permissions.accessibilityGranted { now.insert(.accessibility) }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { now.insert(.calendar) }
        if Permissions.locationGranted { now.insert(.location) }
        let fresh = now.subtracting(granted)
        guard !fresh.isEmpty || now != granted else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { granted = now }
        if fresh.contains(.accessibility) { OnboardingActions.accessibilityChanged() }
        if fresh.contains(step) {
            let current = step
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if step == current { advance() }
            }
        }
    }

    private func info(for step: Step) -> PermissionStep.Info {
        switch step {
        case .accessibility:
            return .init(symbol: "accessibility", color: Color(red: 0.25, green: 0.52, blue: 1),
                         title: L("Bedienungshilfen", "Accessibility"),
                         text: L("Damit Lautstärke und Helligkeit in der Notch statt in der System-Anzeige erscheinen.",
                                 "So volume and brightness show in the notch instead of the system overlay."))
        case .calendar:
            return .init(symbol: "calendar", color: Color(red: 1, green: 0.32, blue: 0.3),
                         title: L("Kalender", "Calendar"),
                         text: L("Für deinen nächsten Termin und den Countdown bis zum Meeting.",
                                 "For your next event and the countdown to a meeting."))
        case .location:
            return .init(symbol: "location.fill", color: Color(red: 0.2, green: 0.75, blue: 0.45),
                         title: L("Standort", "Location"),
                         text: L("Für das Wetter dort, wo du gerade bist. Alternativ suchst du später einen Ort.",
                                 "For the weather where you are. You can also pick a place later."))
        default:
            return .init(symbol: "", color: .clear, title: "", text: "")
        }
    }
}

/// One permission: a coloured tile, what it is for, Allow and Skip.
private struct PermissionStep: View {
    struct Info {
        let symbol: String
        let color: Color
        let title: String
        let text: String
    }

    let info: Info
    let granted: Bool
    let allow: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [info.color, info.color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                Image(systemName: granted ? "checkmark" : info.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 62, height: 62)
            .shadow(color: info.color.opacity(0.45), radius: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.system(size: 16, weight: .bold))
                Text(info.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if granted {
                        Label(L("Erlaubt", "Allowed"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
                        Spacer(minLength: 0)
                        pill(L("Weiter", "Next"), filled: true, action: next)
                    } else {
                        pill(L("Erlauben", "Allow"), filled: true, action: allow)
                        pill(L("Später", "Later"), filled: false, action: next)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(filled ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct DoneStep: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(L("Alles bereit", "You're all set"))
                .font(.system(size: 18, weight: .bold))
            Text(L("Fahr mit dem Zeiger auf die Notch, um sie zu öffnen. Mit zwei Fingern wischen wechselt die Reiter.",
                   "Move the pointer onto the notch to open it. Swipe with two fingers to switch tabs."))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(action: onFinish) {
                Text(L("Fertig", "Done"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
