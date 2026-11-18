import AppKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// 3D models of the headphones the user picked in the settings (USDZ, USD
/// or SceneKit), one for AirPods / AirPods Pro and one for AirPods Max.
/// They are copied to Application Support and never part of the app or the
/// repository; each keeps its credit line, as licences like CC BY require.
enum CustomDeviceModel: String, CaseIterable, Identifiable {
    case pro, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro: return "AirPods / AirPods Pro"
        case .max: return "AirPods Max"
        }
    }

    /// The model for a Bluetooth device's name, if it is AirPods at all.
    static func kind(for deviceName: String) -> CustomDeviceModel? {
        let name = deviceName.lowercased()
        guard name.contains("airpods") else { return nil }
        return name.contains("max") ? .max : .pro
    }

    static let fileTypes: [UTType] = ["usdz", "usdc", "usd", "scn"].compactMap { UTType(filenameExtension: $0) }

    var creditKey: String { self == .pro ? "deviceModelCredit" : "deviceModelCreditMax" }

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HorizonNotch")
    private static let extensions = ["usdz", "usdc", "usd", "scn"]

    private func file(_ ext: String) -> URL {
        Self.folder.appendingPathComponent("device-model-\(rawValue).\(ext)")
    }

    /// The installed model, if any. The first version kept a single model
    /// as "device-model.*"; it becomes the Pro one.
    var url: URL? {
        let manager = FileManager.default
        if self == .pro {
            for ext in Self.extensions {
                let old = Self.folder.appendingPathComponent("device-model.\(ext)")
                if manager.fileExists(atPath: old.path) { try? manager.moveItem(at: old, to: file(ext)) }
            }
        }
        return Self.extensions.lazy.map { file($0) }.first { manager.fileExists(atPath: $0.path) }
    }

    func install(from source: URL) throws {
        remove()
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: file(source.pathExtension.lowercased()))
        Self.cache[self] = nil
    }

    func remove() {
        for ext in Self.extensions { try? FileManager.default.removeItem(at: file(ext)) }
        Self.cache[self] = nil
    }

    private static var cache: [CustomDeviceModel: (url: URL, node: SCNNode)] = [:]

    /// A fresh copy of the model, centred and scaled to fit a 2-unit box.
    func makeNode() -> SCNNode? {
        guard let url else { return nil }
        if let cached = Self.cache[self], cached.url == url { return cached.node.clone() }
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let content = SCNNode()
        for child in scene.rootNode.childNodes { content.addChildNode(child) }
        guard let bounds = Self.bounds(of: content) else { return nil }
        let size = Swift.max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        guard size > 0 else { return nil }
        let scale = 2 / size
        content.scale = SCNVector3(scale, scale, scale)
        content.position = SCNVector3(-(bounds.min.x + bounds.max.x) / 2 * scale,
                                      -(bounds.min.y + bounds.max.y) / 2 * scale,
                                      -(bounds.min.z + bounds.max.z) / 2 * scale)
        let holder = SCNNode()
        holder.addChildNode(content)
        Self.cache[self] = (url, holder)
        return holder.clone()
    }

    /// The box around every mesh, in the coordinates of `root`. Nested
    /// transforms (models exported from other tools carry many) are applied.
    private static func bounds(of root: SCNNode) -> (min: SCNVector3, max: SCNVector3)? {
        var low = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var high = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var found = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = root.convertPosition(SCNVector3(x, y, z), from: node)
                low = SCNVector3(Swift.min(low.x, p.x), Swift.min(low.y, p.y), Swift.min(low.z, p.z))
                high = SCNVector3(Swift.max(high.x, p.x), Swift.max(high.y, p.y), Swift.max(high.z, p.z))
                found = true
            }}}
        }
        return found ? (low, high) : nil
    }
}

/// A user's model, lit like a studio shot and turning all the way round,
/// on a transparent background.
struct DeviceModelView: NSViewRepresentable {
    let model: CustomDeviceModel
    var spinning = true

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.scene = Self.makeScene(model, spinning: spinning)
        view.isPlaying = spinning
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    static func makeScene(_ model: CustomDeviceModel, spinning: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.lightingEnvironment.contents = studio()
        scene.lightingEnvironment.intensity = 1.5
        if let node = model.makeNode() {
            scene.rootNode.addChildNode(node)
            if spinning {
                // A full turn every eight seconds, steady like a turntable.
                node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 8)))
            }
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.camera?.zNear = 0.05
        camera.position = SCNVector3(0, 0.8, 5.2)
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

extension Notification.Name {
    /// Settings → "Try it": show the device card for a sample device.
    static let testDeviceCard = Notification.Name("horizon.testDeviceCard")
}
