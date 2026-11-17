import AppKit
import SceneKit
import SwiftUI

/// A pair of earbuds as a real 3D model, built from simple shapes in
/// SceneKit (no bundled Apple artwork): glossy white bodies with a dark
/// grille, grey silicone tips and short stems, lit from above, slowly
/// turning. Transparent background, so it sits on any glow.
struct AirPods3DView: NSViewRepresentable {
    /// Turns slowly; off for small, static uses.
    var spinning = true

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene(spinning: spinning)
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.isPlaying = spinning
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    private static func makeScene(spinning: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.lightingEnvironment.contents = studio()
        scene.lightingEnvironment.intensity = 1.3
        let pair = SCNNode()
        let left = bud(mirrored: false)
        left.position = SCNVector3(-0.8, 0, 0)
        left.eulerAngles = SCNVector3(0.08, 0.6, 0.1)
        let right = bud(mirrored: true)
        right.position = SCNVector3(0.8, 0, 0)
        right.eulerAngles = SCNVector3(0.08, -0.6, -0.1)
        pair.addChildNode(left)
        pair.addChildNode(right)
        pair.position = SCNVector3(0, 0.35, 0)
        scene.rootNode.addChildNode(pair)
        if spinning {
            let swing = SCNAction.sequence([
                .rotateTo(x: 0, y: 0.35, z: 0, duration: 3, usesShortestUnitArc: true),
                .rotateTo(x: 0, y: -0.35, z: 0, duration: 3, usesShortestUnitArc: true),
            ])
            swing.timingMode = .easeInEaseOut
            pair.runAction(.repeatForever(swing))
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.position = SCNVector3(0, 0.05, 4.9)
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.eulerAngles = SCNVector3(-0.9, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.intensity = 450
        fill.position = SCNVector3(-3, -1, 3)
        scene.rootNode.addChildNode(fill)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 150
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    /// One AirPods-Pro-like earbud, modelled after the real shape: a
    /// bean-shaped glossy head that narrows into a short nozzle carrying an
    /// oval silicone tip, a dark mesh on top of the head and on the inner
    /// sensor, and a short, flat stem with rounded edges, a pressure strip
    /// on its front and a dark vent near the top.
    private static func bud(mirrored: Bool) -> SCNNode {
        let node = SCNNode()
        // Mirrored by placing the parts on the other side, not by a
        // negative scale (that would turn the surfaces inside out).
        let m: CGFloat = mirrored ? -1 : 1
        let gloss = glossy()
        let dark = material(white: 0.08, roughness: 0.7)

        func add(_ geometry: SCNGeometry, _ material: SCNMaterial, at position: SCNVector3,
                 angles: SCNVector3 = SCNVector3(0, 0, 0), scale: SCNVector3 = SCNVector3(1, 1, 1)) {
            geometry.firstMaterial = material
            let part = SCNNode(geometry: geometry)
            part.position = position
            part.eulerAngles = angles
            part.scale = scale
            node.addChildNode(part)
        }

        // Head: a main body and a smaller lobe towards the tip make the bean.
        let head = SCNSphere(radius: 0.4)
        head.segmentCount = 96
        add(head, gloss, at: SCNVector3(0, 0, 0), scale: SCNVector3(1.0, 0.9, 0.92))
        let lobe = SCNSphere(radius: 0.3)
        lobe.segmentCount = 72
        add(lobe, gloss, at: SCNVector3(m * 0.2, 0.04, 0.03), scale: SCNVector3(1, 0.95, 0.95))
        // Nozzle and silicone tip.
        add(SCNCylinder(radius: 0.17, height: 0.2), gloss, at: SCNVector3(m * 0.42, 0.05, 0.04),
            angles: SCNVector3(0, 0, CGFloat.pi / 2))
        let tip = SCNSphere(radius: 0.25)
        tip.segmentCount = 64
        add(tip, material(white: 0.88, roughness: 0.9), at: SCNVector3(m * 0.58, 0.05, 0.04),
            scale: SCNVector3(0.62, 1, 1.02))
        add(SCNCylinder(radius: 0.08, height: 0.02), dark, at: SCNVector3(m * 0.735, 0.05, 0.04),
            angles: SCNVector3(0, 0, CGFloat.pi / 2))
        // Mesh on top of the head and the inner sensor.
        add(SCNBox(width: 0.2, height: 0.05, length: 0.11, chamferRadius: 0.025), dark,
            at: SCNVector3(-m * 0.04, 0.35, 0.1), angles: SCNVector3(0.35, 0, -m * 0.1))
        add(SCNCylinder(radius: 0.06, height: 0.02), dark, at: SCNVector3(m * 0.12, -0.06, 0.37),
            angles: SCNVector3(CGFloat.pi / 2, 0, 0))
        // Stem: short and flat, gently tilted.
        let tilt: CGFloat = m * 0.1
        add(SCNBox(width: 0.22, height: 0.82, length: 0.17, chamferRadius: 0.085), gloss,
            at: SCNVector3(-m * 0.1, -0.62, -0.02), angles: SCNVector3(0, 0, tilt))
        add(SCNBox(width: 0.09, height: 0.24, length: 0.006, chamferRadius: 0.003), material(white: 0.86, roughness: 0.35),
            at: SCNVector3(-m * 0.115, -0.66, 0.067), angles: SCNVector3(0, 0, tilt))
        add(SCNBox(width: 0.11, height: 0.04, length: 0.01, chamferRadius: 0.005), dark,
            at: SCNVector3(-m * 0.085, -0.33, 0.066), angles: SCNVector3(0, 0, tilt))
        return node
    }

    /// White plastic with a clear, glossy coat.
    private static func glossy() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: 0.96, alpha: 1)
        material.roughness.contents = 0.22
        material.metalness.contents = 0.0
        material.clearCoat.contents = 1.0
        material.clearCoatRoughness.contents = 0.06
        return material
    }

    /// A soft studio: bright from above, dark below – gives the gloss its
    /// reflections.
    private static func studio() -> NSImage {
        let size = NSSize(width: 64, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.75, alpha: 1),
                            NSColor(white: 0.25, alpha: 1), NSColor(white: 0.05, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }

    private static func material(white: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: white, alpha: 1)
        material.roughness.contents = roughness
        material.metalness.contents = 0.0
        return material
    }
}
