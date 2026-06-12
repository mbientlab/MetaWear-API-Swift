import SwiftUI
import RealityKit
import MetaWear

/// Live 3D orientation visualisation driven by quaternion samples.
///
/// Loads `MetaMotion.usdz` from the app bundle when present — drop a USDZ
/// file (converted from the MetaMotion STEP via Reality Converter or Blender's
/// USD exporter) into the Xcode project to replace the procedural placeholder.
/// The placeholder is a rounded white box approximating a MetaMotion S
/// (≈24 × 12 × 33 mm) with a subtle LED accent strip on the front face.
struct QuaternionRealityView: View {
    let latest: AnyChartSample?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        RealityView { content in
            let entity = await Self.makeEntity()
            content.add(entity)

            let key = DirectionalLight()
            key.light.intensity = 6000
            key.orientation = simd_quatf(angle: -.pi / 4, axis: [1, 0, 0])
            key.position = [0.4, 0.6, 0.5]
            content.add(key)

            let fill = DirectionalLight()
            fill.light.intensity = 2000
            fill.orientation = simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
            fill.position = [-0.4, 0.2, 0.5]
            content.add(fill)

            content.camera = .virtual
        } update: { content in
            guard let latest, let entity = content.entities.first else { return }
            let q = simd_quatf(ix: latest.f1, iy: latest.f2, iz: latest.f3, r: latest.f0)
            if reduceMotion {
                entity.orientation = q
            } else {
                entity.move(
                    to: Transform(scale: .one, rotation: q, translation: entity.position),
                    relativeTo: entity.parent,
                    duration: 0.05,
                    timingFunction: .linear
                )
            }
        }
        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
            max(280, length * (isCompact ? 0.55 : 0.45))
        }
        .glassCard()
        .accessibilityLabel("3D orientation of the device")
    }

    /// Build the entity placed at scene origin. If a `MetaMotion.usdz` resource
    /// ships in the bundle it's loaded and re-centered; otherwise we build a
    /// procedural MetaMotion-shaped placeholder.
    ///
    /// TODO: Ship the real MetaMotion 3D model.
    ///   1. Convert the STEP file → USDZ using Apple's Reality Converter
    ///      (drag-and-drop STEP, export USDZ) or Blender's USD exporter.
    ///   2. Drag `MetaMotion.usdz` into the Xcode project and confirm it's a
    ///      member of the `MetaWearApp` target.
    ///   3. Run — this loader picks it up automatically.
    ///   4. If the board appears rotated 90° on one axis once loaded, the
    ///      model's forward axis differs from `+Z`; apply a one-time
    ///      `entity.orientation *= simd_quatf(angle: .pi/2, axis: …)`
    ///      correction below before returning.
    private static func makeEntity() async -> Entity {
        if let url = Bundle.main.url(forResource: "MetaMotion", withExtension: "usdz"),
           let entity = try? await Entity(contentsOf: url) {
            recenterAndScale(entity, targetLongestEdge: 0.18)
            entity.position = [0, 0, -0.35]
            return entity
        }
        return makeProceduralBoard()
    }

    /// Procedural MetaMotion-S placeholder. Proportions match the real
    /// 24 × 12 × 33 mm board, scaled up so it reads at scene scale. White ABS
    /// finish with a thin teal accent on the leading edge for the LED.
    private static func makeProceduralBoard() -> Entity {
        let parent = Entity()
        let w: Float = 0.10   // width  (matches 24 mm)
        let h: Float = 0.05   // depth  (matches 12 mm, scaled for visual presence)
        let d: Float = 0.138  // length (matches 33 mm)

        var body = PhysicallyBasedMaterial()
        body.baseColor = .init(tint: .init(white: 0.92, alpha: 1.0))
        body.roughness = 0.45
        body.metallic = 0.0
        let bodyMesh = MeshResource.generateBox(width: w, height: h, depth: d, cornerRadius: 0.014)
        let board = ModelEntity(mesh: bodyMesh, materials: [body])
        parent.addChild(board)

        var accent = PhysicallyBasedMaterial()
        accent.baseColor = .init(tint: .init(red: 0.22, green: 0.62, blue: 0.78, alpha: 1.0))
        accent.emissiveColor = .init(color: .init(red: 0.30, green: 0.78, blue: 0.95, alpha: 1.0))
        accent.emissiveIntensity = 0.6
        let ledMesh = MeshResource.generateBox(width: w * 0.18, height: h * 0.4, depth: d * 0.04, cornerRadius: 0.002)
        let led = ModelEntity(mesh: ledMesh, materials: [accent])
        led.position = [w * 0.32, h * 0.5 + 0.0005, d * 0.45]
        parent.addChild(led)

        var port = PhysicallyBasedMaterial()
        port.baseColor = .init(tint: .init(white: 0.18, alpha: 1.0))
        port.roughness = 0.6
        let portMesh = MeshResource.generateBox(width: w * 0.38, height: h * 0.45, depth: d * 0.03, cornerRadius: 0.003)
        let port3d = ModelEntity(mesh: portMesh, materials: [port])
        port3d.position = [0, 0, -d * 0.5]
        parent.addChild(port3d)

        parent.position = [0, 0, -0.35]
        return parent
    }

    /// Normalise an externally-loaded entity: place its centre at the origin
    /// and scale so its longest bounding edge equals `targetLongestEdge`.
    private static func recenterAndScale(_ entity: Entity, targetLongestEdge: Float) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let extents = bounds.extents
        let longest = max(extents.x, extents.y, extents.z)
        if longest > 0 {
            let scale = targetLongestEdge / longest
            entity.scale = [scale, scale, scale]
        }
        let center = bounds.center
        entity.position -= center
    }
}
