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
