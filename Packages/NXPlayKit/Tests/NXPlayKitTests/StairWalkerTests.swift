import Foundation
import Testing

@testable import NXPlayKit

/// Console Mode's figure on the build staircase.
@MainActor @Suite struct StairWalkerTests {
    let stairs = StairGeometry(stages: 9, width: 52, gap: 6)

    /// Runs the walker for `seconds` at 60 frames a second toward `goal`.
    private func run(
        _ walker: StairWalker, from start: Date, seconds: Double, goal: Double, step: Int,
        countable: Bool = true, finished: Bool = false, metroid: Bool = false,
        every frame: ((StairWalker) -> Void)? = nil
    ) -> Date {
        var now = start
        for _ in 0..<Int(seconds * 60) {
            now += 1.0 / 60
            walker.update(
                now: now, stairs: stairs, goal: goal, step: step, countable: countable,
                finished: finished, animate: true, metroid: metroid)
            frame?(walker)
        }
        return now
    }

    @Test func theSuitRollsUpAStepAsTheMorphBallAndStandsAgain() {
        let walker = StairWalker()
        var now = run(walker, from: .now, seconds: 0.1, goal: 20, step: 0, metroid: true)
        var rolled = false
        var ballThroughStep = false
        let goal = stairs.start(1) + 26
        now = run(walker, from: now, seconds: 5, goal: goal, step: 1, metroid: true) { walker in
            if let ball = walker.pose.ball {
                rolled = true
                if ball.center.y - StairWalker.ballRadius < self.stairs.ground(ball.center.x) - 1.6
                {
                    ballThroughStep = true
                }
            }
        }
        #expect(rolled && !ballThroughStep)
        #expect(walker.pose.ball == nil && abs(walker.x - goal) < 1)  // on its feet at the build's point
        #expect(walker.feet.allSatisfy { $0.planted && abs($0.y - stairs.height(1)) < 0.01 })
    }

    @Test func waitingTheSuitTakesAimAndFires() {
        let walker = StairWalker()
        let goal = stairs.start(2) + 20
        var now = run(walker, from: .now, seconds: 0.1, goal: goal, step: 2, metroid: true)
        var fired = false
        var aimedUp = false
        // its aim is picked at random, two times in three upward: a minute gives it a dozen or so tries
        now = run(walker, from: now, seconds: 60, goal: goal, step: 2, metroid: true) { walker in
            if !walker.shots.isEmpty { fired = true }
            if walker.pose.ball == nil, walker.aim > 0.5 { aimedUp = true }
        }
        #expect(fired && aimedUp)
        // the cannon hand reaches along the aim
        let pose = walker.pose
        let reach = hypot(pose.hands[1].x - pose.shoulder.x, pose.hands[1].y - pose.shoulder.y)
        #expect(abs(reach - StairWalker.cannonReach) < 0.01)
    }

    @Test func atTheTopTheSuitFiresUp() {
        let walker = StairWalker()
        let goal = stairs.start(8) + 40
        var now = run(walker, from: .now, seconds: 0.1, goal: goal, step: 8, metroid: true)
        now = run(walker, from: now, seconds: 2, goal: goal, step: 8, finished: true, metroid: true)
        #expect(abs(walker.aim - .pi / 2) < 0.05 && !walker.shots.isEmpty)
        #expect(walker.shots.allSatisfy { $0.vy > 100 })
    }

    @Test func onlyAMetroidSuitsUp() {
        func game(_ name: String) -> Game {
            Game(
                folder: URL(filePath: "/games/\(name)"), name: name, titleID: nil, version: nil,
                languages: [], iconURL: nil, buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil,
                hasPackages: true, state: .ready)
        }
        #expect(game("Metroid Dread").isMetroid && game("MetroidDread").isMetroid)
        #expect(game("Metroid Prime 4 Beyond").isMetroid)
        #expect(!game("Super Mario Bros. Wonder").isMetroid)
    }

    @Test func theKneeKeepsItsBonesAndBendsForward() {
        let hip = CGPoint(x: 10, y: 20)
        let foot = CGPoint(x: 12, y: 9)
        for forward in [1.0, -1.0] {
            let knee = StairWalker.knee(hip: hip, foot: foot, forward: forward)
            #expect(abs(hypot(knee.x - hip.x, knee.y - hip.y) - StairWalker.thigh) < 0.01)
            #expect(abs(hypot(foot.x - knee.x, foot.y - knee.y) - StairWalker.shin) < 0.01)
            // forward of the line from the hip to the foot
            let side = (foot.x - hip.x) * (knee.y - hip.y) - (foot.y - hip.y) * (knee.x - hip.x)
            #expect(forward > 0 ? side > 0 : side < 0)
        }
    }

    @Test func feetLandOnStepsNotInTheGaps() {
        #expect(stairs.ground(10) == stairs.height(0))
        #expect(stairs.ground(55) == stairs.height(1))  // the gap: the next step's riser
        #expect(stairs.landing(55, facing: 1) == stairs.start(1) + 1)
        #expect(stairs.landing(55, facing: -1) == stairs.start(0) + 51)
    }

    @Test func itWalksUpToTheBuildAndClimbs() {
        let walker = StairWalker()
        var now = run(walker, from: .now, seconds: 0.1, goal: 20, step: 0)
        let lowHip = walker.hipY
        let goal = stairs.start(2) + 26
        var lowestFoot = Double.infinity
        now = run(walker, from: now, seconds: 6, goal: goal, step: 2) { walker in
            // never through a step: a foot is never below the ground it's over
            for foot in walker.feet {
                lowestFoot = min(lowestFoot, foot.y - self.stairs.ground(foot.x))
            }
        }
        #expect(abs(walker.x - goal) < 1)
        #expect(walker.hipY > lowHip + 5)  // two steps up
        #expect(walker.feet.allSatisfy { $0.planted && abs($0.y - stairs.height(2)) < 0.01 })
        #expect(lowestFoot > -0.5)
    }

    @Test func itPacesItsStepWhileTheBuildDoesntMove() {
        let walker = StairWalker()
        let goal = stairs.start(3) + 10
        var now = run(walker, from: .now, seconds: 0.1, goal: goal, step: 3)
        now = run(walker, from: now, seconds: 3, goal: goal, step: 3)
        #expect(abs(walker.x - goal) < 1)  // patient for a while
        var span = (low: walker.x, high: walker.x)
        _ = run(walker, from: now, seconds: 20, goal: goal, step: 3) { walker in
            span = (min(span.low, walker.x), max(span.high, walker.x))
        }
        #expect(span.high - span.low > 15)  // back and forth
        #expect(stairs.span(3).contains(span.low) && stairs.span(3).contains(span.high))  // on its own step
    }

    @Test func aStageWithoutACountPacesAtOnce() {
        let walker = StairWalker()
        let goal = stairs.start(0) + 26
        var now = run(walker, from: .now, seconds: 0.1, goal: goal, step: 0, countable: false)
        var moved = false
        now = run(walker, from: now, seconds: 3, goal: goal, step: 0, countable: false) { walker in
            if abs(walker.x - goal) > 3 { moved = true }
        }
        #expect(moved)
    }
}
