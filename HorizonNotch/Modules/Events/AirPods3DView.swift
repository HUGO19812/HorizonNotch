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
        let pair = SCNNode()
        let left = bud(mirrored: false)
        left.position = SCNVector3(-0.62, 0, 0)
        left.eulerAngles = SCNVector3(0, 0.45, 0.12)
        let right = bud(mirrored: true)
        right.position = SCNVector3(0.62, 0, 0)
        right.eulerAngles = SCNVector3(0, -0.45, -0.12)
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
        camera.position = SCNVector3(0, 0.1, 5.2)
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
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
        ambient.light?.intensity = 380
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    /// One earbud: rounded head, tip pointing towards the camera's side,
    /// grille, and the stem going down.
    private static func bud(mirrored: Bool) -> SCNNode {
        let node = SCNNode()
        // Mirrored by placing the parts on the other side, not by a
        // negative scale (that would turn the surfaces inside out).
        let m: CGFloat = mirrored ? -1 : 1
        let white = material(white: 0.97, roughness: 0.22)

        let head = SCNNode(geometry: SCNSphere(radius: 0.42))
        head.geometry?.firstMaterial = white
        head.scale = SCNVector3(1, 0.92, 0.88)
        node.addChildNode(head)

        let tip = SCNNode(geometry: SCNCone(topRadius: 0.17, bottomRadius: 0.27, height: 0.26))
        tip.geometry?.firstMaterial = material(white: 0.82, roughness: 0.75)
        tip.eulerAngles = SCNVector3(0, 0, -m * CGFloat.pi / 2)
        tip.position = SCNVector3(m * 0.42, 0.04, 0.05)
        node.addChildNode(tip)

        let grille = SCNNode(geometry: SCNCylinder(radius: 0.09, height: 0.02))
        grille.geometry?.firstMaterial = material(white: 0.12, roughness: 0.6)
        grille.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        grille.position = SCNVector3(-m * 0.08, 0.12, 0.37)
        node.addChildNode(grille)

        let stem = SCNNode(geometry: SCNCapsule(capRadius: 0.13, height: 1.05))
        stem.geometry?.firstMaterial = white
        stem.position = SCNVector3(-m * 0.12, -0.62, 0)
        stem.eulerAngles = SCNVector3(0, 0, m * 0.12)
        node.addChildNode(stem)

        let sensor = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.02))
        sensor.geometry?.firstMaterial = material(white: 0.4, roughness: 0.3)
        sensor.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        sensor.position = SCNVector3(-m * 0.18, -1.0, 0.12)
        node.addChildNode(sensor)
        return node
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
