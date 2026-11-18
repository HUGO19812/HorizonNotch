import AppKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// A 3D model of the headphones the user picked in the settings (USDZ,
/// USD or SceneKit). It is copied to Application Support and never part of
/// the app or the repository; its credit line is kept with it, as licences
/// like CC BY require.
enum CustomDeviceModel {
    static let fileTypes: [UTType] = [UTType(filenameExtension: "usdz"), UTType(filenameExtension: "usdc"),
                                      UTType(filenameExtension: "usd"), UTType(filenameExtension: "scn")]
        .compactMap { $0 }
    static let creditKey = "deviceModelCredit"

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HorizonNotch")
    private static let extensions = ["usdz", "usdc", "usd", "scn"]

    /// The installed model, if any.
    static var url: URL? {
        extensions.lazy
            .map { folder.appendingPathComponent("device-model.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func install(from source: URL) throws {
        remove()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("device-model.\(ext)"))
        cached = nil
    }

    static func remove() {
        for ext in extensions { try? FileManager.default.removeItem(at: folder.appendingPathComponent("device-model.\(ext)")) }
        cached = nil
    }

    private static var cached: (url: URL, node: SCNNode)?

    /// A fresh copy of the model, centred and scaled to fit a 2-unit box.
    static func makeNode() -> SCNNode? {
        guard let url else { return nil }
        if let cached, cached.url == url { return cached.node.clone() }
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let content = SCNNode()
        for child in scene.rootNode.childNodes { content.addChildNode(child) }
        guard let bounds = worldBounds(of: content) else { return nil }
        let size = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        guard size > 0 else { return nil }
        let scale = 2 / size
        let center = SCNVector3((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2,
                                (bounds.min.z + bounds.max.z) / 2)
        content.scale = SCNVector3(scale, scale, scale)
        content.position = SCNVector3(-center.x * scale, -center.y * scale, -center.z * scale)
        let holder = SCNNode()
        holder.addChildNode(content)
        cached = (url, holder)
        return holder.clone()
    }

    /// The box around every mesh, in the coordinates of `root`. Nested
    /// transforms (models exported from other tools carry many) are applied.
    private static func worldBounds(of root: SCNNode) -> (min: SCNVector3, max: SCNVector3)? {
        var low = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var high = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var found = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = root.convertPosition(SCNVector3(x, y, z), from: node)
                low = SCNVector3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
                high = SCNVector3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
                found = true
            }}}
        }
        return found ? (low, high) : nil
    }
}

/// The user's model, lit like a studio shot and swinging gently, on a
/// transparent background.
struct DeviceModelView: NSViewRepresentable {
    var spinning = true

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.scene = Self.makeScene(spinning: spinning)
        view.isPlaying = spinning
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    static func makeScene(spinning: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.lightingEnvironment.contents = studio()
        scene.lightingEnvironment.intensity = 1.5
        if let model = CustomDeviceModel.makeNode() {
            scene.rootNode.addChildNode(model)
            if spinning {
                let swing = SCNAction.sequence([
                    .rotateTo(x: 0, y: 0.35, z: 0, duration: 3.5, usesShortestUnitArc: true),
                    .rotateTo(x: 0, y: -0.35, z: 0, duration: 3.5, usesShortestUnitArc: true),
                ])
                swing.timingMode = .easeInEaseOut
                model.runAction(.repeatForever(swing))
            }
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.camera?.zNear = 0.05
        camera.position = SCNVector3(0, 0.6, 3.9)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 850
        key.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 80
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    /// Bright from above, dark below – gives glossy surfaces reflections.
    private static func studio() -> NSImage {
        let size = NSSize(width: 64, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.7, alpha: 1),
                            NSColor(white: 0.25, alpha: 1), NSColor(white: 0.05, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }
}
