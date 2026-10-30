import Foundation

/// An easter egg for Metroid games (Game.isMetroid): the figure in a power suit. It curls into the morph ball to roll
/// up a step, to catch up after a jump, and now and then on a pacing leg, hopping up each riser; standing, its cannon
/// arm aims by IK, forward as it walks, and while it waits it takes aim (forward, up the diagonal, straight up) and
/// fires. At the top it fires up in celebration instead of waving.
extension StairWalker {
    /// One frame of the suit, after the hip has moved by `rolled`.
    func suit(dt: Double, stairs: StairGeometry, target: Double, rolled: Double) {
        if pacingTo != lastPaceTarget {
            lastPaceTarget = pacingTo
            rollsThisLeg = pacingTo != nil && Double.random(in: 0..<1) < 0.35
        }
        let climbing = stairs.step(at: target) != stairs.step(at: x)
        let wantsBall =
            !waving && moving
            && (currentSpeed >= 60 || climbing || (rollsThisLeg && pacingTo != nil))
        let before = ball
        ball = min(1, max(0, ball + (wantsBall ? 1 : -1) * dt / 0.22))
        if before < 0.5, ball >= 0.5 {
            ballY = hipY - Self.leg * 0.42  // from the crouch
        }
        if before >= 0.5, ball < 0.5 {
            // out of the ball: feet down, rising from the crouch
            plantFeet(on: stairs)
            hipY = (feet[0].y + feet[1].y) / 2 + Self.leg * 0.92
        }
        if ball >= 0.5 { roll(dt: dt, stairs: stairs, by: rolled) }
        takeAim(dt: dt)
        moveShots(dt: dt)
    }

    /// The ball rides the steps' tops, hopping quickly up a riser, and turns with the distance it rolls.
    private func roll(dt: Double, stairs: StairGeometry, by distance: Double) {
        let rest = stairs.ground(x) + Self.ballRadius
        ballY += (rest - ballY) * min(1, dt * 16)
        ballY = max(ballY, rest - 1.5)
        ballAngle -= distance / Self.ballRadius
    }

    /// Forward and a little down while it moves; while it waits a new aim every few seconds, then a shot; at the top
    /// straight up, shot after shot.
    private func takeAim(dt: Double) {
        func mirrored(_ angle: Double) -> Double { facing > 0 ? angle : .pi - angle }
        if waving {
            aimTarget = .pi / 2
            if clock >= nextShot {
                fire()
                nextShot = clock + 0.45
            }
        } else if moving || ball > 0 {
            aimTarget = mirrored(-0.12)
            fireAt = nil
        } else if idling {
            if fireAt == nil, clock >= nextShot {
                aimTarget = mirrored([0, .pi / 4, .pi / 2.3].randomElement()!)
                fireAt = clock + 0.45  // time to bring the cannon round
            }
            if let fireAt, clock >= fireAt {
                fire()
                self.fireAt = nil
                nextShot = clock + .random(in: 1.8...3.6)
            }
        } else {
            aimTarget = mirrored(-0.12)
        }
        // the shorter way round
        let turn = atan2(sin(aimTarget - aim), cos(aimTarget - aim))
        aim += turn * min(1, dt * 10)
    }

    /// A shot from the cannon's muzzle along the aim.
    private func fire() {
        guard shots.count < 8 else { return }
        let shoulder = (x: x + facing * 0.4, y: hipY + Self.torso)
        let reach = Self.cannonReach + 1
        shots.append(
            Shot(
                x: shoulder.x + reach * cos(aim), y: shoulder.y + reach * sin(aim),
                vx: 120 * cos(aim), vy: 120 * sin(aim), life: 0.8))
    }

    private func moveShots(dt: Double) {
        for index in shots.indices {
            shots[index].x += shots[index].vx * dt
            shots[index].y += shots[index].vy * dt
            shots[index].life -= dt
        }
        shots.removeAll { $0.life <= 0 }
    }
}

extension Game {
    /// A Metroid: the build staircase's figure suits up (StairWalker+Metroid.swift).
    var isMetroid: Bool {
        name.localizedCaseInsensitiveContains("metroid")
            || folder.lastPathComponent.localizedCaseInsensitiveContains("metroid")
    }
}
