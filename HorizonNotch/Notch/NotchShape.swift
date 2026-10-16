import SwiftUI

/// The island outline. Attached to a hardware notch it has a flat top edge
/// flush with the screen and concave "ears" curving down into the body, so it
/// continues the notch seamlessly. Floating (no notch) it uses rounded top
/// corners instead and becomes a capsule. All radii animate.
struct NotchShape: Shape {
    var earRadius: CGFloat
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(earRadius, AnimatablePair(topRadius, bottomRadius)) }
        set {
            earRadius = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let body = rect.insetBy(dx: ear, dy: 0)
        let top = max(0, min(topRadius, body.width / 2, body.height / 2))
        let bottom = max(0, min(bottomRadius, body.width / 2, body.height - max(ear, top)))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if ear > 0 {
            p.addQuadCurve(to: CGPoint(x: body.minX, y: rect.minY + ear),
                           control: CGPoint(x: body.minX, y: rect.minY))
        } else {
            p.move(to: CGPoint(x: body.minX, y: rect.minY + top))
            p.addQuadCurve(to: CGPoint(x: body.minX + top, y: rect.minY),
                           control: CGPoint(x: body.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: body.maxX - top, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: body.maxX, y: rect.minY + top),
                           control: CGPoint(x: body.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: body.maxX, y: rect.maxY - bottom))
            p.addQuadCurve(to: CGPoint(x: body.maxX - bottom, y: rect.maxY),
                           control: CGPoint(x: body.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: body.minX + bottom, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: body.minX, y: rect.maxY - bottom),
                           control: CGPoint(x: body.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
        p.addLine(to: CGPoint(x: body.minX, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: body.minX + bottom, y: rect.maxY),
                       control: CGPoint(x: body.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: body.maxX - bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: rect.maxY - bottom),
                       control: CGPoint(x: body.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: body.maxX, y: rect.minY + ear))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: body.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
