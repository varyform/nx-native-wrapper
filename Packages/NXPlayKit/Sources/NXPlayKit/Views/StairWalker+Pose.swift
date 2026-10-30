import Foundation

/// The figure's joints for a frame, solved from the simulation: legs and (in the suit) the cannon arm by two-bone IK.
extension StairWalker {
    static let ballRadius = 4.6
    /// The cannon's reach from the shoulder, a little short of a straight arm.
    static var cannonReach: Double { (upperArm + forearm) * 0.92 }

    /// The joints to draw, y up.
    struct Pose {
        var hip, shoulder, head: CGPoint
        /// Far side first: knee and foot of each leg, elbow and hand of each arm.
        var knees: [CGPoint], feet: [CGPoint], elbows: [CGPoint], hands: [CGPoint]
        var facing: Double
        /// The suit: helmet, shoulder pad, the near arm a cannon.
        var suit = false
        /// The morph ball instead of the figure, rolled by its angle.
        var ball: (center: CGPoint, angle: Double)?
    }

    var pose: Pose {
        // a bob in the step, a breath when standing; the suit crouches on its way into the ball
        let swinging = feet.first { !$0.planted }
        let bob = swinging.map { 0.45 * sin(.pi * $0.t) } ?? 0.25 * sin(clock * 2.2)
        let crouch = metroid ? min(ball * 2, 1) * Self.leg * 0.42 : 0
        let hip = CGPoint(x: x, y: hipY + bob - crouch)
        let shoulder = CGPoint(x: x + facing * 0.4, y: hip.y + Self.torso)
        let look = idling ? 0.9 * sin(clock * 1.6) : facing * 0.5
        let head = CGPoint(x: shoulder.x + look, y: shoulder.y + Self.neck + Self.head)
        var footPoints = feet.map { CGPoint(x: $0.x, y: $0.y) }
        if idling && !metroid {
            // a tap of the front foot's toes
            let front = (feet[0].x - x) * facing > (feet[1].x - x) * facing ? 0 : 1
            footPoints[front].y += max(0, sin(clock * 7)) * 1.1
        }
        let knees = footPoints.map {
            Self.joint(from: hip, to: $0, first: Self.thigh, second: Self.shin, bend: facing)
        }
        var elbows: [CGPoint] = []
        var hands: [CGPoint] = []
        for arm in 0..<2 {
            if metroid && arm == 1 {
                // the cannon: the hand reaches along the aim, the elbow below the line
                let hand = CGPoint(
                    x: shoulder.x + Self.cannonReach * cos(aim),
                    y: shoulder.y + Self.cannonReach * sin(aim))
                let under = cos(aim) >= 0 ? -1.0 : 1.0
                elbows.append(
                    Self.joint(
                        from: shoulder, to: hand, first: Self.upperArm, second: Self.forearm,
                        bend: under))
                hands.append(hand)
                continue
            }
            // an arm swings with the opposite leg
            let lead = (feet[1 - arm].x - x) / Self.stride
            var upper = -.pi / 2 + 0.55 * min(max(lead, -1), 1) + 0.04 * sin(clock * 1.5)
            var lower = upper + facing * 0.35
            if waving && arm == 1 {
                upper = .pi / 2 - facing * 0.45
                lower = upper - facing * (0.35 + 0.45 * sin(clock * 9))
            }
            let elbow = CGPoint(
                x: shoulder.x + Self.upperArm * cos(upper),
                y: shoulder.y + Self.upperArm * sin(upper))
            elbows.append(elbow)
            hands.append(
                CGPoint(
                    x: elbow.x + Self.forearm * cos(lower), y: elbow.y + Self.forearm * sin(lower)))
        }
        return Pose(
            hip: hip, shoulder: shoulder, head: head, knees: knees, feet: footPoints,
            elbows: elbows, hands: hands, facing: facing, suit: metroid,
            ball: metroid && ball >= 0.5 ? (CGPoint(x: x, y: ballY), ballAngle) : nil)
    }

    /// Two-bone IK: the knee of a thigh and a shin from the hip to the foot, bent toward `forward`.
    static func knee(hip: CGPoint, foot: CGPoint, forward: Double) -> CGPoint {
        joint(from: hip, to: foot, first: thigh, second: shin, bend: forward)
    }

    /// Two-bone IK: the middle joint of bones `first` and `second` from `root` to `end`, by the law of cosines, on the
    /// side `bend` turns to (+1 counterclockwise); an end out of reach gets a straight limb pointing at it.
    static func joint(
        from root: CGPoint, to end: CGPoint, first: Double, second: Double, bend: Double
    ) -> CGPoint {
        let dx = end.x - root.x
        let dy = end.y - root.y
        let reach = min(max(hypot(dx, dy), 0.001), first + second - 0.001)
        let cosine = (first * first + reach * reach - second * second) / (2 * first * reach)
        let angle = atan2(dy, dx) + bend * acos(min(max(cosine, -1), 1))
        return CGPoint(x: root.x + first * cos(angle), y: root.y + first * sin(angle))
    }
}
