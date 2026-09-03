import AppKit
import SceneKit
import SwiftUI

private extension CompactAgentSignalKind {
    var accentColor: Color {
        switch self {
        case .waitingForApproval: .signalAmber
        case .waitingForInput: .signalCyan
        case .failed: .signalCoral
        case .completed: .signalMint
        }
    }

    var glyph: String {
        switch self {
        case .waitingForInput: "?"
        case .completed: "✓"
        case .waitingForApproval, .failed: "!"
        }
    }
}

extension CompactAgentSignalKind {
    var compactMascotAccessibilityLabel: String {
        switch self {
        case .waitingForApproval: "Агент ждёт подтверждения"
        case .waitingForInput: "Агент ждёт ввода"
        case .failed: "Агент завершился с ошибкой"
        case .completed: "Агент завершил работу"
        }
    }
}

struct CompactAgentMascot: View {
    let signal: CompactAgentSignal

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NoolWavingMascot()
                .frame(width: 46, height: 52)

            Text(signal.kind.glyph)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 11, height: 11)
                .background(signal.kind.accentColor, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                }
                .offset(x: 1, y: 1)
                .accessibilityHidden(true)
        }
        .frame(width: 46, height: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signal.kind.compactMascotAccessibilityLabel)
    }
}

struct NoolWavingMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NoolMascotSceneView(reduceMotion: reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct NoolMascotSceneView: NSViewRepresentable {
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let sceneView = SCNView(frame: .zero)
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = false
        sceneView.preferredFramesPerSecond = 30
        sceneView.rendersContinuously = false

        guard let sceneURL = Bundle.module.url(
            forResource: "NoolMascot",
            withExtension: "usdc"
        ), let scene = try? SCNScene(url: sceneURL, options: nil) else {
            return sceneView
        }

        scene.background.contents = NSColor.clear
        sceneView.scene = scene
        configureCameraAndLighting(in: scene, for: sceneView)

        if let waveNode = scene.rootNode.childNode(
            withName: "NoolPhotoYork_Wave_Pivot",
            recursively: true
        ) {
            waveNode.eulerAngles.y = -1.05
            context.coordinator.waveNode = waveNode
            context.coordinator.neutralRotation = waveNode.eulerAngles
        }

        updateAnimation(in: sceneView, coordinator: context.coordinator)
        return sceneView
    }

    func updateNSView(_ sceneView: SCNView, context: Context) {
        updateAnimation(in: sceneView, coordinator: context.coordinator)
    }

    private func configureCameraAndLighting(in scene: SCNScene, for sceneView: SCNView) {
        let target = SCNNode()
        target.name = "Nool_UI_Target"
        target.position = SCNVector3(0.08, -0.09, 1.91)
        scene.rootNode.addChildNode(target)

        let cameraNode = SCNNode()
        cameraNode.name = "Nool_UI_Camera"
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 2.35
        camera.zNear = 0.1
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(8.2, -11.5, 6.35)
        let cameraLookAt = SCNLookAtConstraint(target: target)
        cameraLookAt.isGimbalLockEnabled = true
        cameraLookAt.worldUp = SCNVector3(0, 0, 1)
        cameraNode.constraints = [cameraLookAt]
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode

        let ambientNode = SCNNode()
        ambientNode.name = "Nool_UI_Ambient"
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.65, alpha: 1)
        ambient.intensity = 600
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let keyNode = SCNNode()
        keyNode.name = "Nool_UI_Key"
        let key = SCNLight()
        key.type = .directional
        key.color = NSColor.white
        key.intensity = 1_200
        key.castsShadow = false
        keyNode.light = key
        keyNode.position = SCNVector3(-4, -6, 8)
        let keyLookAt = SCNLookAtConstraint(target: target)
        keyLookAt.worldUp = SCNVector3(0, 0, 1)
        keyNode.constraints = [keyLookAt]
        scene.rootNode.addChildNode(keyNode)
    }

    private func updateAnimation(in sceneView: SCNView, coordinator: Coordinator) {
        guard let waveNode = coordinator.waveNode else { return }

        if reduceMotion {
            waveNode.removeAction(forKey: Coordinator.waveActionKey)
            waveNode.eulerAngles = coordinator.neutralRotation
            sceneView.isPlaying = false
        } else {
            if waveNode.action(forKey: Coordinator.waveActionKey) == nil {
                waveNode.runAction(
                    Coordinator.waveAction,
                    forKey: Coordinator.waveActionKey
                )
            }
            sceneView.isPlaying = true
        }
    }

    @MainActor
    final class Coordinator {
        static let waveActionKey = "nool-wave"
        static let waveAction: SCNAction = {
            func turn(_ radians: CGFloat, duration: TimeInterval) -> SCNAction {
                let action = SCNAction.rotateBy(
                    x: 0,
                    y: radians,
                    z: 0,
                    duration: duration
                )
                action.timingMode = .easeInEaseOut
                return action
            }

            return .repeatForever(.sequence([
                .wait(duration: 2.0),
                turn(-0.24, duration: 0.16),
                turn(0.48, duration: 0.22),
                turn(-0.48, duration: 0.22),
                turn(0.48, duration: 0.22),
                turn(-0.24, duration: 0.16)
            ]))
        }()

        var waveNode: SCNNode?
        var neutralRotation = SCNVector3Zero
    }
}
