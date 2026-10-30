import SwiftUI

/// The staircase's figure drawn into its Canvas: a white stick figure, far limbs dimmer; in the Metroid suit a helmet
/// with a green visor, a shoulder pad, the near forearm a cannon, its shots, or the morph ball rolling.
extension BuildStairs {
    static let visor = Color(red: 0.55, green: 1, blue: 0.6)
    static let beam = Color(red: 0.6, green: 1, blue: 0.95)

    static func draw(
        _ pose: StairWalker.Pose, shots: [StairWalker.Shot], in context: GraphicsContext,
        height: Double
    ) {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
        func circle(_ center: CGPoint, _ radius: Double) -> Path {
            let c = point(center)
            return Path(
                ellipseIn: CGRect(
                    x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
        }
        func limb(_ points: [CGPoint], opacity: Double, width: Double = 2.2) {
            var path = Path()
            path.addLines(points.map(point))
            context.stroke(
                path, with: .color(.white.opacity(opacity)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }

        for shot in shots {
            let center = CGPoint(x: shot.x, y: shot.y)
            let fade = min(1, shot.life / 0.3)
            context.fill(circle(center, 3.2), with: .color(beam.opacity(0.3 * fade)))
            context.fill(circle(center, 1.6), with: .color(beam.opacity(fade)))
        }

        if let ball = pose.ball {
            // the morph ball: a shell, two bands turning with the roll, a glowing core
            let r = StairWalker.ballRadius
            context.fill(circle(ball.center, r), with: .color(.white.opacity(0.18)))
            context.stroke(circle(ball.center, r), with: .color(.white), lineWidth: 1.8)
            for band in [0.0, .pi / 2] {
                let angle = ball.angle + band
                let from = CGPoint(
                    x: ball.center.x + r * 0.8 * cos(angle), y: ball.center.y + r * 0.8 * sin(angle)
                )
                let to = CGPoint(
                    x: ball.center.x - r * 0.8 * cos(angle), y: ball.center.y - r * 0.8 * sin(angle)
                )
                limb([from, to], opacity: 0.7, width: 1.2)
            }
            context.fill(circle(ball.center, 1.3), with: .color(visor))
            return
        }

        limb([pose.shoulder, pose.elbows[0], pose.hands[0]], opacity: 0.55)
        limb([pose.hip, pose.knees[0], pose.feet[0]], opacity: 0.55)
        limb([pose.hip, pose.shoulder], opacity: 1, width: pose.suit ? 3 : 2.2)
        let r = StairWalker.head
        context.fill(circle(pose.head, r), with: .color(.white))
        if pose.suit {
            // the helmet's visor, toward where it faces
            let c = point(CGPoint(x: pose.head.x + pose.facing * 1.1, y: pose.head.y + 0.2))
            context.fill(
                Path(
                    roundedRect: CGRect(x: c.x - 1.6, y: c.y - 0.9, width: 3.2, height: 1.8),
                    cornerRadius: 0.9),
                with: .color(visor))
        }
        limb([pose.hip, pose.knees[1], pose.feet[1]], opacity: 1, width: pose.suit ? 2.6 : 2.2)
        if pose.suit {
            limb([pose.shoulder, pose.elbows[1]], opacity: 1)
            limb([pose.elbows[1], pose.hands[1]], opacity: 1, width: 4.4)  // the arm cannon
            context.fill(circle(pose.hands[1], 1.1), with: .color(beam))  // its muzzle
            context.fill(circle(pose.shoulder, 2.2), with: .color(.white))  // the shoulder pad
        } else {
            limb([pose.shoulder, pose.elbows[1], pose.hands[1]], opacity: 1)
        }
    }
}
