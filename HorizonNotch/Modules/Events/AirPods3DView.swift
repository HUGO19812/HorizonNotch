import AppKit
import SceneKit
import SwiftUI
import simd

/// A pair of earbuds as a real 3D model, built in code (no bundled Apple
/// artwork). Each bud is one smooth, seamless body – head, lobe, nozzle and
/// stem blended into each other like moulded plastic – plus a soft silicone
/// tip. Dark mesh and vents are painted onto the surface. Lit like a studio
/// shot, slowly swinging, on a transparent background.
struct AirPods3DView: NSViewRepresentable {
    /// Swings slowly; off for small, static uses.
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
        scene.lightingEnvironment.intensity = 3.2
        let pair = SCNNode()
        let left = SCNNode()
        left.addChildNode(SCNNode(geometry: Parts.left.body))
        left.addChildNode(SCNNode(geometry: Parts.left.tip))
        left.position = SCNVector3(-0.62, 0, 0)
        left.eulerAngles = SCNVector3(0.1, 0.45, 0.12)
        let right = SCNNode()
        right.addChildNode(SCNNode(geometry: Parts.right.body))
        right.addChildNode(SCNNode(geometry: Parts.right.tip))
        right.position = SCNVector3(0.62, 0, 0)
        right.eulerAngles = SCNVector3(0.1, -0.45, -0.12)
        pair.addChildNode(left)
        pair.addChildNode(right)
        pair.position = SCNVector3(0, 0.3, 0)
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
        camera.position = SCNVector3(0, 0.9, 4.3)
        camera.look(at: SCNVector3(0, 0.05, 0))
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1300
        key.eulerAngles = SCNVector3(-0.8, 0.6, 0)
        scene.rootNode.addChildNode(key)
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 380
        rim.eulerAngles = SCNVector3(-0.3, -2.6, 0)
        scene.rootNode.addChildNode(rim)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 120
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    // MARK: - Model

    /// Both buds' meshes, built once and shared by every view.
    private struct Parts {
        let body: SCNGeometry
        let tip: SCNGeometry

        static let left = Parts(side: 1)
        static let right = Parts(side: -1)

        /// side 1 = left bud (tip pointing right, towards the other one).
        private init(side m: Float) {
            let shape = BudShape(m: m)
            body = SmoothMesh.build(min: [-0.75, -1.2, -0.55], max: [0.75, 0.55, 0.5], step: 0.018,
                                    distance: shape.body, shade: shape.bodyShade)
            body.firstMaterial = AirPods3DView.plastic()
            tip = SmoothMesh.build(min: [-0.95, -0.35, -0.6], max: [0.95, 0.45, 0.3], step: 0.016,
                                   distance: shape.tip, shade: shape.tipShade)
            tip.firstMaterial = AirPods3DView.silicone()
        }
    }

    /// The bud as a signed distance field: negative inside. The parts are
    /// joined with a smooth minimum, so there are no seams between them.
    private struct BudShape {
        let m: Float

        var lobeCenter: SIMD3<Float> { [m * 0.2, 0.02, -0.07] }
        var nozzleStart: SIMD3<Float> { [m * 0.28, 0.03, -0.1] }
        var nozzleEnd: SIMD3<Float> { [m * 0.47, 0.05, -0.17] }
        var stemTop: SIMD3<Float> { [-m * 0.1, -0.18, 0.04] }
        var stemBottom: SIMD3<Float> { [-m * 0.16, -0.96, 0.1] }
        var axis: SIMD3<Float> { simd_normalize(nozzleEnd - nozzleStart) }
        var tipCenter: SIMD3<Float> { nozzleEnd + axis * 0.07 }

        func body(_ p: SIMD3<Float>) -> Float {
            let head = ellipsoid(p, radii: [0.4, 0.35, 0.33])
            let lobe = ellipsoid(p - lobeCenter, radii: [0.29, 0.27, 0.27])
            let nozzle = capsule(p, nozzleStart, nozzleEnd, 0.16, 0.13)
            // The stem is flatter front to back than it is wide.
            let flat = SIMD3<Float>(p.x, p.y, (p.z - 0.05) * 1.35 + 0.05)
            let stem = capsule(flat, stemTop, stemBottom, 0.105, 0.088)
            return smin(smin(smin(head, lobe, 0.2), nozzle, 0.16), stem, 0.16)
        }

        func tip(_ p: SIMD3<Float>) -> Float {
            // An oval cushion sitting on the nozzle.
            let local = p - tipCenter
            let along = simd_dot(local, axis)
            let across = local - along * axis
            let side = simd_normalize(simd_cross(axis, [0, 1, 0]))
            return ellipsoid([along, across.y, simd_dot(across, side)], radii: [0.12, 0.24, 0.22])
        }

        /// Plastic white with the dark acoustic mesh on top, the vent at the
        /// top of the stem, the inner sensor and the microphone at its end.
        func bodyShade(_ p: SIMD3<Float>) -> Float {
            var dark: Float = 0
            dark = max(dark, spot(p, center: [-m * 0.05, 0.33, 0.08], radii: [0.1, 0.06, 0.07]))
            dark = max(dark, spot(p, center: [-m * 0.125, -0.47, 0.14], radii: [0.055, 0.018, 0.08]))
            dark = max(dark, spot(p, center: [-m * 0.16, -1.05, 0.1], radii: [0.05, 0.04, 0.04]))
            // The force sensor: a faint flat strip on the stem's front.
            let sensor = spot(p, center: [-m * 0.14, -0.7, 0.19], radii: [0.045, 0.14, 0.06]) * 0.12
            return 0.95 - dark * 0.86 - sensor
        }

        func tipShade(_ p: SIMD3<Float>) -> Float {
            // The opening at the very end shows the dark mesh behind it.
            let local = p - tipCenter
            let along = simd_dot(local, axis)
            let ring = simd_length(local - along * axis)
            return 0.84 - smoothstep(0.06, 0.1, along) * (1 - smoothstep(0.07, 0.1, ring)) * 0.7
        }

        private func spot(_ p: SIMD3<Float>, center: SIMD3<Float>, radii: SIMD3<Float>) -> Float {
            1 - smoothstep(0.75, 1.0, simd_length((p - center) / radii))
        }
    }

    // MARK: - Materials and light

    /// White plastic with a clear, glossy coat; the vertex colours add the
    /// dark mesh.
    private static func plastic() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: 1, alpha: 1)
        material.roughness.contents = 0.28
        material.metalness.contents = 0.0
        material.clearCoat.contents = 0.8
        material.clearCoatRoughness.contents = 0.08
        // A touch of glow keeps the white white in the shade.
        material.emission.contents = NSColor(white: 0.16, alpha: 1)
        return material
    }

    private static func silicone() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: 1, alpha: 1)
        material.roughness.contents = 0.75
        material.metalness.contents = 0.0
        material.emission.contents = NSColor(white: 0.12, alpha: 1)
        return material
    }

    /// A soft studio: bright from above, dark below – gives the gloss its
    /// reflections and the lower half its shade.
    private static func studio() -> NSImage {
        let size = NSSize(width: 64, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.6, alpha: 1),
                            NSColor(white: 0.18, alpha: 1), NSColor(white: 0.03, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }
}

// MARK: - Distance field helpers

private func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
    let h = max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
}

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Approximate distance to an ellipsoid (good enough for blending).
private func ellipsoid(_ p: SIMD3<Float>, radii: SIMD3<Float>) -> Float {
    let k0 = simd_length(p / radii)
    let k1 = simd_length(p / (radii * radii))
    return k1 > 0 ? k0 * (k0 - 1) / k1 : -radii.min()
}

/// A capsule whose radius goes from r0 at a to r1 at b.
private func capsule(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r0: Float, _ r1: Float) -> Float {
    let ab = b - a
    let t = min(max(simd_dot(p - a, ab) / simd_dot(ab, ab), 0), 1)
    return simd_length(p - (a + ab * t)) - (r0 + (r1 - r0) * t)
}

/// Turns a distance field into a smooth triangle mesh ("surface nets": one
/// vertex per grid cell the surface passes through, joined into quads),
/// with normals from the field's gradient and a grey level per vertex.
private enum SmoothMesh {
    static func build(min lower: SIMD3<Float>, max upper: SIMD3<Float>, step: Float,
                      distance: (SIMD3<Float>) -> Float, shade: (SIMD3<Float>) -> Float) -> SCNGeometry {
        let size = (upper - lower) / step
        let nx = Int(size.x.rounded(.up)) + 1, ny = Int(size.y.rounded(.up)) + 1, nz = Int(size.z.rounded(.up)) + 1
        func point(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
            lower + SIMD3<Float>(Float(i), Float(j), Float(k)) * step
        }
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        var field = [Float](repeating: 0, count: nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx { field[index(i, j, k)] = distance(point(i, j, k)) } } }

        // One vertex per cell the surface crosses, at the mean of the
        // crossings on the cell's edges.
        let corners: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0],
                                       [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]]
        let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        func cell(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * (ny - 1) + j) * (nx - 1) + i }
        var cellVertex = [Int32](repeating: -1, count: (nx - 1) * (ny - 1) * (nz - 1))
        var positions: [SIMD3<Float>] = []
        var values = [Float](repeating: 0, count: 8)
        for k in 0..<(nz - 1) { for j in 0..<(ny - 1) { for i in 0..<(nx - 1) {
            var inside = 0
            for c in 0..<8 {
                let corner = corners[c]
                values[c] = field[index(i + Int(corner.x), j + Int(corner.y), k + Int(corner.z))]
                if values[c] < 0 { inside += 1 }
            }
            guard inside > 0, inside < 8 else { continue }
            var sum = SIMD3<Float>(repeating: 0)
            var count: Float = 0
            for (a, b) in edges where (values[a] < 0) != (values[b] < 0) {
                let t = values[a] / (values[a] - values[b])
                sum += corners[a] + (corners[b] - corners[a]) * t
                count += 1
            }
            cellVertex[cell(i, j, k)] = Int32(positions.count)
            positions.append(point(i, j, k) + sum / count * step)
        }}}

        // A quad around every grid edge that crosses the surface.
        var indices: [Int32] = []
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int, flip: Bool) {
            let v = [cellVertex[a], cellVertex[b], cellVertex[c], cellVertex[d]]
            guard !v.contains(-1) else { return }
            if flip { indices += [v[0], v[2], v[1], v[0], v[3], v[2]] }
            else { indices += [v[0], v[1], v[2], v[0], v[2], v[3]] }
        }
        for k in 1..<(nz - 1) { for j in 1..<(ny - 1) { for i in 0..<(nx - 1) {
            let a = field[index(i, j, k)], b = field[index(i + 1, j, k)]
            guard (a < 0) != (b < 0) else { continue }
            quad(cell(i, j - 1, k - 1), cell(i, j, k - 1), cell(i, j, k), cell(i, j - 1, k), flip: a < 0)
        }}}
        for k in 1..<(nz - 1) { for j in 0..<(ny - 1) { for i in 1..<(nx - 1) {
            let a = field[index(i, j, k)], b = field[index(i, j + 1, k)]
            guard (a < 0) != (b < 0) else { continue }
            quad(cell(i - 1, j, k - 1), cell(i - 1, j, k), cell(i, j, k), cell(i, j, k - 1), flip: a < 0)
        }}}
        for k in 0..<(nz - 1) { for j in 1..<(ny - 1) { for i in 1..<(nx - 1) {
            let a = field[index(i, j, k)], b = field[index(i, j, k + 1)]
            guard (a < 0) != (b < 0) else { continue }
            quad(cell(i - 1, j - 1, k), cell(i, j - 1, k), cell(i, j, k), cell(i - 1, j, k), flip: a < 0)
        }}}

        let e = step * 0.5
        let normals = positions.map { p -> SCNVector3 in
            let g = SIMD3<Float>(distance(p + [e, 0, 0]) - distance(p - [e, 0, 0]),
                                 distance(p + [0, e, 0]) - distance(p - [0, e, 0]),
                                 distance(p + [0, 0, e]) - distance(p - [0, 0, e]))
            let unit = simd_normalize(g)
            return SCNVector3(CGFloat(unit.x), CGFloat(unit.y), CGFloat(unit.z))
        }
        let colors = positions.map { p -> SIMD4<Float> in
            let grey = shade(p)
            return [grey, grey, grey, 1]
        }
        let vertices = positions.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                            usesFloatComponents: true, componentsPerVector: 4,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<SIMD4<Float>>.stride)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), colorSource],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }
}
