import Foundation

/// The staircase's shape, in points from its bottom-left corner: a step per stage, rising left to right, a gap between.
struct StairGeometry {
    let stages: Int
    let width: Double
    let gap: Double

    func start(_ index: Int) -> Double { Double(index) * (width + gap) }
    /// The step under x (in a gap, the one before it).
    func step(at x: Double) -> Int { min(max(Int(x / (width + gap)), 0), stages - 1) }
    func span(_ index: Int) -> ClosedRange<Double> { start(index)...(start(index) + width) }
    func height(_ index: Int) -> Double { BuildStairs.height(index, of: stages) }
    var end: Double { start(stages - 1) + width }

    /// The height to stand at: the step's top, in a gap the riser of the step after it.
    func ground(_ x: Double) -> Double {
        guard x > 0 else { return height(0) }
        let index = min(Int(x / (width + gap)), stages - 1)
        return x - start(index) <= width || index == stages - 1 ? height(index) : height(index + 1)
    }

    /// A foot's landing spot off the gaps: on the step ahead when walking up, the step behind when walking down.
    func landing(_ x: Double, facing: Double) -> Double {
        let x = min(max(x, 1), end - 1)
        let index = min(Int(x / (width + gap)), stages - 1)
        guard x - start(index) > width, index < stages - 1 else { return x }
        return facing > 0 ? start(index + 1) + 1 : start(index) + width - 1
    }
}

/// The figure on Console Mode's build staircase, as a small simulation stepped every frame: a hip that walks to a goal,
/// feet that plant on the steps and swing in arcs from one hold to the next, legs bent by two-bone inverse kinematics
/// (thigh and shin from the hip to the foot, the knee forward), arms swinging against the legs. It walks to where the
/// build is; while the build doesn't move (a stage with no count, or none for a few seconds) it paces its step, stops,
/// looks around and taps a foot; at the top it waves. Points from the staircase's bottom-left corner, y up.
@MainActor final class StairWalker {
    struct Foot {
        var x = 0.0, y = 0.0
        var fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0
        /// Its swing, 0 to 1; 1 when planted.
        var t = 1.0
        var duration = 0.25
        var planted: Bool { t >= 1 }
        /// Where it stands, or will once its swing lands.
        var holdY: Double { planted ? y : toY }
    }

    static let thigh = 6.5, shin = 6.5, torso = 8.5, neck = 1.4, head = 3.3
    static let upperArm = 5.0, forearm = 4.6
    static var leg: Double { thigh + shin }
    /// Half a stride: how far the hip gets past the back foot before it steps.
    static let stride = 4.5
    /// Seconds without the goal moving before it paces.
    static let patience = 4.0

    private(set) var x = 0.0, facing = 1.0
    /// The suit sets it too, rising out of the morph ball.
    var hipY = 0.0
    private(set) var feet = [Foot(), Foot()]
    private(set) var clock = 0.0
    private(set) var moving = false
    /// Standing still while pacing: looking around, tapping a foot.
    private(set) var idling = false
    private(set) var waving = false

    // The Metroid suit (StairWalker+Metroid.swift): an arm cannon aimed by IK, shots, the morph ball.
    private(set) var metroid = false
    /// 0 standing, 1 curled into the morph ball; the crouch on the way between.
    var ball = 0.0
    var ballY = 0.0
    var ballAngle = 0.0
    /// The cannon arm's aim, radians from +x, y up.
    var aim = 0.0
    var aimTarget = 0.0
    var shots: [Shot] = []
    var nextShot = 0.0
    var fireAt: Double?
    var lastPaceTarget: Double?
    var rollsThisLeg = false

    struct Shot {
        var x, y, vx, vy, life: Double
    }

    private var started = false
    private var speed = 0.0
    private var last: Date?
    private var goal: Double?
    private var goalMoved = 0.0
    /// When it got to the current goal: its patience runs from there.
    private var reachedGoal: Double?
    private var paceTarget: Double?
    private var pauseUntil = 0.0
    private var idleSince = 0.0

    /// One frame: `goal` is where the build is along the stairs, `step` the stage it's in.
    func update(
        now: Date, stairs: StairGeometry, goal newGoal: Double, step: Int, countable: Bool,
        finished: Bool, animate: Bool, metroid: Bool = false
    ) {
        let dt = min(max(last.map { now.timeIntervalSince($0) } ?? 0, 0), 1.0 / 20)
        last = now
        clock += dt
        waving = finished
        self.metroid = metroid
        if !started || !animate {
            place(at: newGoal, on: stairs)
            started = true
            goal = newGoal
            return
        }
        if goal.map({ abs($0 - newGoal) > 0.5 }) ?? true {
            goal = newGoal
            goalMoved = clock
            reachedGoal = nil
            paceTarget = nil
            pauseUntil = 0
        }
        if reachedGoal == nil, abs(x - newGoal) < 0.5 { reachedGoal = clock }
        let target = target(for: newGoal, step: step, on: stairs, countable: countable)
        let before = x
        walk(toward: target, dt: dt, stairs: stairs)
        if metroid {
            suit(dt: dt, stairs: stairs, target: target, rolled: x - before)
        } else {
            ball = 0
            shots.removeAll()
        }
        if ball < 0.5 {
            stepFeet(dt: dt, stairs: stairs)
            settleHip(dt: dt)
        }
    }

    /// The spot it paces to, while it paces (the suit may roll there).
    var pacingTo: Double? { paceTarget }
    var currentSpeed: Double { speed }

    /// Where to head: the build's point, or while it stalls a spot on the current step, with pauses between.
    private func target(for goal: Double, step: Int, on stairs: StairGeometry, countable: Bool)
        -> Double
    {
        let waited = reachedGoal.map { clock - max($0, goalMoved) > Self.patience } ?? false
        let stalled = !waving && (!countable || waited)
        guard stalled else { return goal }
        let span = stairs.span(step)
        let range = (span.lowerBound + 4)...max(span.lowerBound + 4, span.upperBound - 4)
        if clock < pauseUntil { return x }
        if let paceTarget, abs(paceTarget - x) > 0.5 { return paceTarget }
        if paceTarget != nil {
            // there: a breather, then somewhere else on the step
            paceTarget = nil
            pauseUntil = clock + .random(in: 0.8...2.6)
            return x
        }
        var next = Double.random(in: range)
        if abs(next - x) < 6 {
            next =
                x < (range.lowerBound + range.upperBound) / 2 ? range.upperBound : range.lowerBound
        }
        paceTarget = range.contains(x) ? next : (range.lowerBound + range.upperBound) / 2
        return paceTarget!
    }

    private func walk(toward target: Double, dt: Double, stairs: StairGeometry) {
        let dx = target - x
        let pacing = paceTarget != nil
        speed = abs(dx) > 30 ? 60.0 : pacing ? 14.0 : 30.0
        let wasMoving = moving
        moving = abs(dx) > 0.5
        if moving {
            facing = dx > 0 ? 1 : -1
            x += (dx > 0 ? 1 : -1) * min(abs(dx), speed * dt)
            x = min(max(x, 1), stairs.end - 1)
        }
        if wasMoving && !moving { idleSince = clock }
        idling = !moving && !waving && clock - idleSince > 0.6
        for index in feet.indices {
            feet[index].duration = min(max(0.34 - speed * 0.003, 0.17), 0.3)
        }
    }

    /// The swinging foot moves on; with both planted, the back one steps past the hip when it lags, or (standing) a
    /// foot comes back under the hip.
    private func stepFeet(dt: Double, stairs: StairGeometry) {
        for index in feet.indices where !feet[index].planted {
            var foot = feet[index]
            foot.t = min(1, foot.t + dt / foot.duration)
            let ease = 1 - (1 - foot.t) * (1 - foot.t)  // up early: clears a riser
            foot.x = foot.fromX + (foot.toX - foot.fromX) * foot.t
            let arc = 2.6 * sin(.pi * foot.t)
            // never through a step: over a riser it rides the step's top
            foot.y = max(
                foot.fromY + (foot.toY - foot.fromY) * ease + arc, stairs.ground(foot.x) + arc * 0.5
            )
            if foot.planted {
                foot.x = foot.toX
                foot.y = foot.toY
            }
            feet[index] = foot
        }
        guard feet.allSatisfy(\.planted) else { return }
        let ahead = feet.indices.map { (feet[$0].x - x) * facing }
        let back = ahead[0] < ahead[1] ? 0 : 1
        if moving {
            // the back foot lags, or the feet are together (a stride to start): it lands ahead of where the hip will be
            if -ahead[back] > Self.stride * 0.6 || ahead[1 - back] - ahead[back] < 1 {
                let lead = Self.stride + speed * feet[back].duration * 0.6
                swing(back, to: x + facing * lead, stairs: stairs)
            }
        } else {
            // standing: the front foot a little ahead, the back one a little behind
            let rest = [x - facing * 1.6, x + facing * 1.6]
            let order = ahead[0] < ahead[1] ? [0, 1] : [1, 0]
            for (spot, index) in zip(rest, order) where abs(feet[index].x - spot) > 1.8 {
                swing(index, to: spot, stairs: stairs)
                break
            }
        }
    }

    private func swing(_ index: Int, to spot: Double, stairs: StairGeometry) {
        let land = stairs.landing(spot, facing: facing)
        var foot = feet[index]
        foot.fromX = foot.x
        foot.fromY = foot.y
        foot.toX = land
        foot.toY = stairs.ground(land)
        foot.t = 0
        feet[index] = foot
    }

    /// The hip rides above the feet's holds, low enough for both legs to reach.
    private func settleHip(dt: Double) {
        let holds = feet.map(\.holdY)
        let want = min((holds[0] + holds[1]) / 2 + Self.leg * 0.92, holds.min()! + Self.leg * 0.98)
        hipY += (want - hipY) * min(1, dt * 12)
    }

    private func place(at goal: Double, on stairs: StairGeometry) {
        x = min(max(goal, 1), stairs.end - 1)
        plantFeet(on: stairs)
        hipY = (feet[0].y + feet[1].y) / 2 + Self.leg * 0.92
        moving = false
        ball = 0
    }

    /// Both feet planted under the hip, a little apart: on a start, or out of the morph ball.
    func plantFeet(on stairs: StairGeometry) {
        for (index, offset) in [-facing * 1.6, facing * 1.6].enumerated() {
            let spot = stairs.landing(x + offset, facing: facing)
            feet[index] = Foot(x: spot, y: stairs.ground(spot))
        }
    }
}
