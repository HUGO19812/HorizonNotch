import AppKit
import SwiftUI

/// Locale for dates in the island, following the app language setting.
var appLocale: Locale { Locale(identifier: AppSettings.shared.isGerman ? "de_AT" : "en_US") }

/// Horizontally scrolling days that snap into place; the day in the middle
/// is the selected one. Every snap gives a trackpad click (if enabled).
/// Used by the calendar and the weather page.
struct DayStrip<Cell: View>: View {
    let days: [Date]
    @Binding var selected: Date?
    var cellWidth: CGFloat = 36
    @ViewBuilder let cell: (_ day: Date, _ isSelected: Bool) -> Cell

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(days, id: \.self) { day in
                            cell(day, selected.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false)
                                .frame(width: cellWidth)
                                .id(day)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selected = day }
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(0, (proxy.size.width - cellWidth) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selected, anchor: .center)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                             .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                // Marks the strip: sideways swipes over it scroll the days
                // instead of switching tabs; mouse wheels scroll it too.
                .background(HorizontalWheelScroll())
                .onChange(of: selected) { _, _ in
                    let settings = AppSettings.shared
                    if settings.scrollHaptics { TrackpadHaptics.click(level: settings.hapticLevel) }
                }
                // The scroll position binding does not move the view on first
                // appearance; centre the selected day explicitly.
                .onAppear {
                    DispatchQueue.main.async { if let selected { reader.scrollTo(selected, anchor: .center) } }
                }
            }
        }
    }
}

/// Selection look shared by the strips: accent background when selected.
struct DayCellBackground: ViewModifier {
    let isSelected: Bool
    let isToday: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(isToday ? 0.35 : 0.55) : .clear))
            .contentShape(Rectangle())
    }
}

/// Marks a sideways-scrolling strip: mouse wheels scroll it sideways, and
/// trackpad swipes over it scroll it instead of switching tabs.
struct HorizontalWheelScroll: NSViewRepresentable {
    private static let views = NSHashTable<WheelView>.weakObjects()

    /// Is the mouse pointer over one of the strips on screen?
    static func containsPointer() -> Bool {
        let location = NSEvent.mouseLocation
        return views.allObjects.contains { view in
            guard let window = view.window, window.isVisible else { return false }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            return rect.contains(location)
        }
    }

    func makeNSView(context: Context) -> NSView { WheelView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WheelView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            HorizontalWheelScroll.views.add(self)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Mouse wheels only; the trackpad scrolls sideways itself.
                guard let self, let window = self.window, event.window === window,
                      !event.hasPreciseScrollingDeltas,
                      event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      let cgEvent = event.cgEvent?.copy() else { return event }
                // Move the vertical deltas to the horizontal axis, like
                // holding Shift does.
                let pairs: [(CGEventField, CGEventField)] = [
                    (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
                    (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
                ]
                for (vertical, horizontal) in pairs {
                    cgEvent.setIntegerValueField(horizontal, value: cgEvent.getIntegerValueField(vertical))
                    cgEvent.setIntegerValueField(vertical, value: 0)
                }
                cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                            value: cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
                cgEvent.setIntegerValueField(.eventSourceUserData, value: NotchWindowController.convertedScrollMarker)
                return NSEvent(cgEvent: cgEvent) ?? event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

