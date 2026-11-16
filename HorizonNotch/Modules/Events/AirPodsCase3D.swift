import AppKit
import SceneKit
import simd
import SwiftUI

/// A real-time 3D AirPods charging case for the device card: built from
/// geometry at runtime (nothing from Apple is bundled), lit like a studio
/// product shot. When the AirPods connect the case turns in, the lid swings
/// open on its hinge and the buds sit in their wells; on disconnect it closes.
struct AirPodsCase3DView: NSViewRepresentable {
    var open: Bool
    var pro: Bool

    func makeCoordinator() -> AirPodsCaseScene { AirPodsCaseScene(pro: pro) }

    func makeNSView(context: Context) -> SCNView {
        let view = PassThroughSCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isPlaying = true
        view.preferredFramesPerSecond = 60
        context.coordinator.present(open: open)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.present(open: open)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: AirPodsCaseScene) {
        view.isPlaying = false
        view.scene = nil
    }
}

/// Clicks go to the card beneath, not to the 3D view.
private final class PassThroughSCNView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AirPodsCaseScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let turntable = SCNNode()
    private let lidHinge = SCNNode()
    private let ledMaterial = SCNMaterial()
    private var isOpen: Bool?

    // MARK: Dimensions (millimetres, AirPods Pro case 60.6 × 45.2 × 21.7)

    private static let halfWidth: CGFloat = 30.3
    private static let halfHeight: CGFloat = 22.6
    private static let halfDepth: CGFloat = 10.85
    /// Squareness of the front outline (smaller = squarer corners).
    private static let frontRoundness: CGFloat = 0.46
    /// Roundness seen from above (the pill-shaped ends).
    private static let topRoundness: CGFloat = 0.6
    /// Where lid and base meet, measured from the centre.
    private static let seam: CGFloat = 8.4
    private static let seamGap: CGFloat = 0.22
    private static let openAngle: CGFloat = -1.86 // ≈ 107°

    init(pro: Bool) {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.25

        buildCamera()
        buildLights()
        scene.rootNode.addChildNode(turntable)
        buildCase(pro: pro)
    }

    // MARK: Animation

    /// Opens or closes the case; the first call also plays the entrance.
    func present(open: Bool) {
        guard open != isOpen else { return }
        let first = isOpen == nil
        isOpen = open

        setLED(on: open)
        lidHinge.removeAllActions()
        let swing = SCNAction.rotateTo(x: open ? Self.openAngle : 0, y: 0, z: 0,
                                       duration: open ? 0.8 : 0.45, usesShortestUnitArc: false)
        swing.timingMode = open ? .easeOut : .easeIn

        if first {
            // Arrives closed (or open, for a disconnect) and then swings.
            lidHinge.eulerAngles = SCNVector3(open ? 0 : Self.openAngle, 0, 0)
            lidHinge.runAction(.sequence([.wait(duration: open ? 0.3 : 0.35), swing]))
            entrance()
        } else {
            lidHinge.runAction(swing)
        }
    }

    private func entrance() {
        turntable.opacity = 0
        turntable.scale = SCNVector3(0.82, 0.82, 0.82)
        turntable.eulerAngles = SCNVector3(0, -1.15, 0)

        let fade = SCNAction.fadeIn(duration: 0.3)
        let grow = SCNAction.scale(to: 1, duration: 0.7)
        grow.timingMode = .easeOut
        let turn = SCNAction.rotateTo(x: 0, y: -0.34, z: 0, duration: 1.1, usesShortestUnitArc: true)
        turn.timingMode = .easeOut
        var steps: [SCNAction] = [.group([fade, grow, turn])]

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Afterwards it keeps turning a little, like on a display stand.
            let right = SCNAction.rotateTo(x: 0, y: -0.14, z: 0, duration: 2.8, usesShortestUnitArc: true)
            let left = SCNAction.rotateTo(x: 0, y: -0.5, z: 0, duration: 2.8, usesShortestUnitArc: true)
            right.timingMode = .easeInEaseOut
            left.timingMode = .easeInEaseOut
            steps.append(.repeatForever(.sequence([right, left])))
        }
        turntable.runAction(.sequence(steps))
    }

    private func setLED(on: Bool) {
        ledMaterial.diffuse.contents = on ? NSColor(red: 0.3, green: 0.95, blue: 0.4, alpha: 1) : NSColor(white: 0.55, alpha: 1)
        ledMaterial.emission.contents = on ? NSColor(red: 0.25, green: 1, blue: 0.4, alpha: 1) : NSColor.black
    }

    // MARK: Camera and light

    private func buildCamera() {
        let cam = SCNCamera()
        cam.fieldOfView = 25
        cam.zNear = 1
        cam.zFar = 1000
        camera.camera = cam
        camera.position = SCNVector3(0, 58, 172)
        camera.look(at: SCNVector3(0, 3, 0))
        scene.rootNode.addChildNode(camera)
    }

    private func buildLights() {
        // Key: soft, from the upper left front, casting the buds' shadows.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 650
        key.castsShadow = true
        key.shadowMode = .forward
        key.shadowSampleCount = 16
        key.shadowRadius = 3
        key.shadowColor = NSColor.black.withAlphaComponent(0.45)
        key.orthographicScale = 60
        key.shadowMapSize = CGSize(width: 1024, height: 1024)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-40, 80, 60)
        keyNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        // Violet rim from behind, to match the glow around the picture.
        let rim = SCNLight()
        rim.type = .omni
        rim.intensity = 700
        rim.color = NSColor(red: 0.62, green: 0.48, blue: 1, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(25, 35, -70)
        scene.rootNode.addChildNode(rimNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 80
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)
    }

    /// An equirectangular studio: bright ceiling with softboxes, grey
    /// horizon and a dark violet floor – what the glossy plastic reflects.
    private static func studioEnvironment() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
            let colors = [NSColor(red: 0.05, green: 0.04, blue: 0.08, alpha: 1),
                          NSColor(red: 0.2, green: 0.15, blue: 0.3, alpha: 1),
                          NSColor(white: 0.5, alpha: 1),
                          NSColor(white: 0.82, alpha: 1),
                          NSColor(white: 0.95, alpha: 1)]
            let locations: [CGFloat] = [0, 0.38, 0.52, 0.72, 1]
            NSGradient(colors: colors, atLocations: locations, colorSpace: .sRGB)?.draw(in: rect, angle: 90)
            NSColor.white.setFill()
            for (x, width) in [(0.06, 0.12), (0.34, 0.16), (0.66, 0.1), (0.86, 0.08)] as [(CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: rect.width * x, y: rect.height * 0.6,
                                                 width: rect.width * width, height: rect.height * 0.24),
                             xRadius: 10, yRadius: 10).fill()
            }
            return true
        }
    }

    // MARK: Model

    private func buildCase(pro: Bool) {
        let shell = Self.material(white: 0.93, roughness: 0.24, clearCoat: 0.55)
        let inside = Self.material(white: 0.8, roughness: 0.5)
        let well = Self.material(white: 0.16, roughness: 0.65)
        let metal = Self.material(white: 0.78, roughness: 0.28, metalness: 1)

        let caseNode = SCNNode()
        caseNode.position = SCNVector3(0, -2, 0)
        turntable.addChildNode(caseNode)

        // Base: lower shell, the inside floor and two wells for the buds.
        let base = SCNNode(geometry: Self.caseGeometry(lid: false, shell: shell, inside: inside))
        caseNode.addChildNode(base)
        for side: CGFloat in [-1, 1] {
            let hole = SCNNode(geometry: SCNCylinder(radius: 1, height: 0.2))
            hole.geometry?.firstMaterial = well
            hole.scale = SCNVector3(6.4, 1, 5.2)
            hole.position = SCNVector3(side * 13.2, Self.seam + 0.06, 0.3)
            caseNode.addChildNode(hole)
            caseNode.addChildNode(bud(side: side, pro: pro))
        }

        // Status light on the front, just below the seam.
        let ledY = Self.seam - 6.5
        let led = SCNNode(geometry: SCNSphere(radius: 0.75))
        ledMaterial.lightingModel = .physicallyBased
        led.geometry?.firstMaterial = ledMaterial
        led.position = SCNVector3(0, ledY, Self.frontZ(atY: ledY) - 0.45)
        led.scale = SCNVector3(1, 1, 0.6)
        caseNode.addChildNode(led)

        // Steel hinge at the back; the lid turns around it.
        let hingeY = Self.seam + Self.seamGap / 2
        let hingeZ = -Self.frontZ(atY: Self.seam) + 1.8
        let pin = SCNNode(geometry: SCNCylinder(radius: 1.2, height: 6))
        pin.geometry?.firstMaterial = metal
        pin.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        pin.position = SCNVector3(0, hingeY, hingeZ)
        caseNode.addChildNode(pin)

        lidHinge.position = SCNVector3(0, hingeY, hingeZ)
        caseNode.addChildNode(lidHinge)
        let lid = SCNNode(geometry: Self.caseGeometry(lid: true, shell: shell, inside: inside))
        lid.position = SCNVector3(0, -hingeY + Self.seamGap, -hingeZ)
        lidHinge.addChildNode(lid)
    }

    /// One earbud in its well: glossy head, silicone tip with its dark
    /// nozzle, the black vent on top and the stem sunk into the case.
    private func bud(side: CGFloat, pro: Bool) -> SCNNode {
        let plastic = Self.material(white: 0.95, roughness: 0.18, clearCoat: 0.5)
        let silicone = Self.material(white: 0.84, roughness: 0.62)
        let dark = Self.material(white: 0.06, roughness: 0.55)
        let grille = Self.material(white: 0.3, roughness: 0.6)
        let vent = Self.material(white: 0.32, roughness: 0.6)

        // As in the real case: tips turned towards each other and the back, tilted up.
        let yaw = SCNNode()
        yaw.position = SCNVector3(side * 13.4, Self.seam + 3.6, 0.2)
        yaw.eulerAngles = SCNVector3(0, -side * 1.9, 0)
        let tilt = SCNNode()
        tilt.eulerAngles = SCNVector3(-0.5, 0, 0)
        yaw.addChildNode(tilt)

        func ellipsoid(_ material: SCNMaterial, _ size: SCNVector3, at position: SCNVector3) -> SCNNode {
            let sphere = SCNSphere(radius: 1)
            sphere.segmentCount = 48
            sphere.firstMaterial = material
            let node = SCNNode(geometry: sphere)
            node.scale = size
            node.position = position
            return node
        }

        tilt.addChildNode(ellipsoid(plastic, SCNVector3(7.6, 7.2, 7.8), at: SCNVector3(0, 0, 0)))
        // Rounded shoulder towards the stem, as on the real bud.
        tilt.addChildNode(ellipsoid(plastic, SCNVector3(5.2, 5.6, 5.2), at: SCNVector3(0, -4.2, -1.8)))
        // Vent mesh on the top outside.
        tilt.addChildNode(ellipsoid(vent, SCNVector3(1, 0.45, 2.3), at: SCNVector3(0, 7, -0.6)))

        if pro {
            tilt.addChildNode(ellipsoid(silicone, SCNVector3(5.4, 5.4, 3.4), at: SCNVector3(0, 0.6, 7.2)))
            tilt.addChildNode(ellipsoid(grille, SCNVector3(1.7, 1.7, 0.6), at: SCNVector3(0, 0.6, 10.3)))
        } else {
            tilt.addChildNode(ellipsoid(dark, SCNVector3(3, 3, 0.8), at: SCNVector3(0, 0.5, 7.3)))
        }

        let stem = SCNNode(geometry: SCNCapsule(capRadius: 2.5, height: 20))
        stem.geometry?.firstMaterial = plastic
        stem.position = SCNVector3(0, -11, -2.2)
        tilt.addChildNode(stem)
        return yaw
    }

    private static func material(white: CGFloat, roughness: CGFloat, metalness: CGFloat = 0,
                                 clearCoat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: white, alpha: 1)
        m.roughness.contents = NSNumber(value: Double(roughness))
        m.metalness.contents = NSNumber(value: Double(metalness))
        if clearCoat > 0 {
            m.clearCoat.contents = NSNumber(value: Double(clearCoat))
            m.clearCoatRoughness.contents = NSNumber(value: 0.08)
        }
        return m
    }

    // MARK: Case geometry

    /// sign(v)·|v|^e – the building block of a superellipsoid.
    private static func spow(_ v: CGFloat, _ e: CGFloat) -> CGFloat {
        v == 0 ? 0 : (v < 0 ? -1 : 1) * pow(abs(v), e)
    }

    /// Depth of the front surface at height y (centre line).
    private static func frontZ(atY y: CGFloat) -> CGFloat {
        let s = pow(min(1, abs(y) / halfHeight), 1 / frontRoundness)
        return halfDepth * pow(max(0, 1 - s * s).squareRoot(), frontRoundness)
    }

    /// The base (below the seam) or the lid (above it): a superellipsoid
    /// shell cut flat at the seam, the cut closed by the inside surface.
    private static func caseGeometry(lid: Bool, shell: SCNMaterial, inside: SCNMaterial) -> SCNGeometry {
        let e1 = frontRoundness, e2 = topRoundness
        let a = halfWidth, b = halfHeight, c = halfDepth
        let segments = 160
        let rings = 72
        let etaSeam = asin(pow(seam / b, 1 / e1))
        let eta0 = lid ? etaSeam : -CGFloat.pi / 2
        let eta1 = lid ? CGFloat.pi / 2 : etaSeam

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var shellIndices: [UInt32] = []
        var capIndices: [UInt32] = []

        func surface(_ eta: CGFloat, _ omega: CGFloat) -> (SCNVector3, SCNVector3) {
            let ce = cos(eta), se = sin(eta), co = cos(omega), so = sin(omega)
            let p = SCNVector3(a * spow(ce, e1) * spow(co, e2), b * spow(se, e1), c * spow(ce, e1) * spow(so, e2))
            var n = SIMD3<Double>(Double(spow(ce, 2 - e1) * spow(co, 2 - e2) / a),
                                  Double(spow(se, 2 - e1) / b),
                                  Double(spow(ce, 2 - e1) * spow(so, 2 - e2) / c))
            let length = simd_length(n)
            n = length > 0 ? n / length : SIMD3(0, se >= 0 ? 1 : -1, 0)
            return (p, SCNVector3(CGFloat(n.x), CGFloat(n.y), CGFloat(n.z)))
        }

        // Shell: rings from bottom to top, each closed around (last = first).
        for i in 0...rings {
            let t = CGFloat(i) / CGFloat(rings)
            let eta = eta0 + (eta1 - eta0) * t
            for j in 0...segments {
                let omega = -CGFloat.pi + 2 * CGFloat.pi * CGFloat(j) / CGFloat(segments)
                let (p, n) = surface(eta, omega)
                positions.append(p)
                normals.append(n)
            }
        }
        let row = UInt32(segments + 1)
        for i in 0..<UInt32(rings) {
            for j in 0..<UInt32(segments) {
                let v00 = i * row + j, v01 = v00 + 1, v10 = v00 + row, v11 = v10 + 1
                shellIndices += [v00, v10, v01, v01, v10, v11]
            }
        }

        // The flat inside at the seam: a fan, facing up on the base, down on the lid.
        let centre = UInt32(positions.count)
        positions.append(SCNVector3(0, seam, 0))
        let capNormal = SCNVector3(0, lid ? -1 : 1, 0)
        normals.append(capNormal)
        let ringStart = UInt32(positions.count)
        for j in 0...segments {
            let omega = -CGFloat.pi + 2 * CGFloat.pi * CGFloat(j) / CGFloat(segments)
            var (p, _) = surface(etaSeam, omega)
            p.y = seam
            positions.append(p)
            normals.append(capNormal)
        }
        for j in 0..<UInt32(segments) {
            let p0 = ringStart + j, p1 = p0 + 1
            capIndices += lid ? [centre, p0, p1] : [centre, p1, p0]
        }

        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions),
                                             SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: shellIndices, primitiveType: .triangles),
                                              SCNGeometryElement(indices: capIndices, primitiveType: .triangles)])
        geometry.materials = [shell, inside]
        return geometry
    }
}

extension AirPodsCase3DView {
    /// nil when the device is not an AirPods case (Max, other headphones),
    /// else whether it is a Pro case (buds with silicone tips).
    static func caseKind(for deviceName: String) -> Bool? {
        let name = deviceName.lowercased()
        guard name.contains("airpods"), !name.contains("max") else { return nil }
        return name.contains("pro")
    }
}
