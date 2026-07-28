import SwiftUI
import RealityKit
import MetaWear

/// Live 3D orientation visualisation driven by quaternion samples.
///
/// Loads `MetaMotion.usdz` from the app bundle when present. Otherwise it uses
/// a procedural MetaMotion-style rectangular board so the live orientation view
/// still reads as real MetaWear hardware.
///
/// ## Why the display is TARED (relative to a reference pose)
/// Three hardware sessions proved the fusion quaternion's absolute frame
/// cannot be trusted as a fixed constant: axis-isolated motions landed on
/// DIFFERENT quaternion components across sessions, which no fixed remap can
/// explain (heading is magnetic-referenced and the world frame is not stable
/// session-to-session). So the view renders the rotation SINCE a reference
/// sample instead: `Δ = ref⁻¹ · q` is the board's motion expressed in the
/// reference pose's own body axes — magnetic north, the session's world
/// frame, and the convention ambiguity all cancel. The reference defaults to
/// the first sample (the board starts face-on), and the Zero button lets the
/// user re-anchor at any time — hold the board facing the screen, tap Zero,
/// and the model mirrors every motion from there.
struct QuaternionRealityView: View {
    let latest: AnyChartSample?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Tare pose: motion renders relative to this sample. Captured from the
    /// first valid sample, replaced when the user taps Zero.
    @State private var reference: simd_quatf?

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
            let raw = simd_quatf(ix: latest.f1, iy: latest.f2, iz: latest.f3, r: latest.f0)
            guard raw.length > 0.5 else { return }   // malformed/zero sample
            // Motion since the tare pose, in the tare pose's body axes.
            let delta = (reference ?? simd_normalize(raw)).inverse * simd_normalize(raw)
            // Change of basis M·Δ·M⁻¹ re-expresses that motion in the
            // scene's frame; at the tare pose Δ = identity → face-on.
            let q = Self.bodyToScene * delta * Self.bodyToScene.inverse
            if reduceMotion {
                entity.orientation = q
            } else {
                entity.move(
                    to: Transform(scale: entity.scale, rotation: q, translation: entity.position),
                    relativeTo: entity.parent,
                    duration: 0.05,
                    timingFunction: .linear
                )
            }
        }
        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
            max(240, length * (isCompact ? 0.42 : 0.35))
        }
        .overlay(alignment: .bottomTrailing) {
            if latest != nil {
                Button("Zero", systemImage: "scope") {
                    if let latest {
                        let raw = simd_quatf(ix: latest.f1, iy: latest.f2, iz: latest.f3, r: latest.f0)
                        if raw.length > 0.5 { reference = simd_normalize(raw) }
                    }
                }
                .buttonStyle(.glass)
                .font(.caption.weight(.medium))
                .padding(10)
                .accessibilityHint("Anchor the 3D board to the device's current orientation")
            }
        }
        .onChange(of: latest?.id) {
            // Default tare: the first valid sample of the stream/replay, so
            // the board starts face-on without the user doing anything.
            guard reference == nil, let latest else { return }
            let raw = simd_quatf(ix: latest.f1, iy: latest.f2, iz: latest.f3, r: latest.f0)
            if raw.length > 0.5 { reference = simd_normalize(raw) }
        }
        .glassCard()
        .accessibilityLabel("3D orientation of the device")
    }

    /// Maps tare-body axes onto the model. IDENTITY is the correct value,
    /// not a placeholder: a physical rotation about a board body axis b
    /// right-multiplies the tared delta (Δ → Δ·Δb), which the display
    /// composes as a rotation about the MODEL'S OWN axis M·b in its local
    /// frame. The model is authored with its case axes = the board's case
    /// axes (X width, Y length, Z out the top face), so M = identity makes
    /// the model do exactly what the physical board does — spin it about
    /// its face normal and the model spins about ITS face normal — for ANY
    /// tare pose. This invariant is what the fixed-frame attempts could
    /// never provide. Kept as a named constant so any residual mirror found
    /// on hardware is a one-line fix here.
    private static let bodyToScene = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    /// Build the entity placed at scene origin. If a `MetaMotion.usdz` resource
    /// ships in the bundle it's loaded and re-centered; otherwise we build a
    /// procedural MetaMotion-style rectangular board.
    ///
    /// To ship the real CAD-derived model later:
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
            recenterAndScale(entity, targetLongestEdge: 1.25)
            entity.position = [0, 0, -0.45]
            return entity
        }
        return makeMetaMotionBoard()
    }

    /// MetaBase-style rectangular MetaMotion model with front-panel details.
    private static func makeMetaMotionBoard() -> Entity {
        let parent = Entity()
        let shell = material(white: 0.92, roughness: 0.48)
        let highlight = material(white: 0.985, roughness: 0.38)
        let dot = material(white: 0.70, roughness: 0.58)
        let edge = material(white: 0.62, roughness: 0.70)

        addRoundedBox(
            to: parent,
            width: 0.090,
            height: 0.142,
            depth: 0.020,
            cornerRadius: 0.024,
            position: [0, 0.002, 0],
            material: shell
        )
        addRoundedBox(
            to: parent,
            width: 0.070,
            height: 0.104,
            depth: 0.004,
            cornerRadius: 0.018,
            position: [0, -0.004, 0.012],
            material: highlight
        )
        addDisc(to: parent, radius: 0.012, position: [-0.030, 0.049, 0.016], material: dot)
        addDisc(to: parent, radius: 0.005, position: [-0.029, -0.050, 0.016], material: dot)

        addRoundedBox(
            to: parent,
            width: 0.040,
            height: 0.008,
            depth: 0.024,
            cornerRadius: 0.003,
            position: [0, -0.073, 0],
            material: edge
        )

        parent.scale = [8.8, 8.8, 8.8]
        parent.position = [0, 0, -0.45]
        return parent
    }

    private static func addRoundedBox(
        to parent: Entity,
        width: Float,
        height: Float,
        depth: Float,
        cornerRadius: Float,
        position: SIMD3<Float>,
        material: PhysicallyBasedMaterial
    ) {
        let mesh = MeshResource.generateBox(
            width: width,
            height: height,
            depth: depth,
            cornerRadius: cornerRadius
        )
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        parent.addChild(entity)
    }

    private static func addDisc(
        to parent: Entity,
        radius: Float,
        position: SIMD3<Float>,
        material: PhysicallyBasedMaterial
    ) {
        let mesh = MeshResource.generateCylinder(height: 0.003, radius: radius)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        entity.position = position
        parent.addChild(entity)
    }

    private static func material(white: CGFloat, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .init(white: white, alpha: 1.0))
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = 0.0
        return material
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
