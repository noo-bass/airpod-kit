import Foundation
import Testing
@testable import GestureEngine

/// Made-up sensor streams that look like AirPods data: 25 readings a second,
/// a little resting jitter, and movements shaped like the real thing.
struct SyntheticHead {
    var random = SeededRandom(seed: 7)
    var time: TimeInterval = 0
    let step = 1.0 / 25
    /// Resting jitter. The defaults are rough; real AirPods Pro measured
    /// quieter on most channels (about 0.01 rad/s and 0.0016 g).
    var turnJitter = 0.02
    var joltJitter = 0.003

    mutating func rest(seconds: Double) -> [MotionSample] {
        (0..<Int(seconds * 25)).map { _ in reading(rotation: .zero, jolt: .zero) }
    }

    /// Head pitches down and back up: one smooth swing of turning speed.
    mutating func nod(seconds: Double = 0.6, strength: Double = 2) -> [MotionSample] {
        movement(seconds: seconds) { phase in
            (Vector3(x: strength * sin(2 * .pi * phase), y: 0, z: 0), .zero)
        }
    }

    /// Head turns left, right, left, right: two full swings about the yaw axis.
    mutating func shake(seconds: Double = 0.8, strength: Double = 2.5) -> [MotionSample] {
        movement(seconds: seconds) { phase in
            (Vector3(x: 0, y: strength * sin(4 * .pi * phase), z: 0), .zero)
        }
    }

    /// No head turn at all, just a short sharp nudge of the earbud.
    mutating func clench(seconds: Double = 0.16, strength: Double = 0.03) -> [MotionSample] {
        movement(seconds: seconds) { phase in
            (.zero, Vector3(x: 0, y: 0, z: strength * sin(.pi * phase)))
        }
    }

    private mutating func movement(seconds: Double, shape: (Double) -> (Vector3, Vector3)) -> [MotionSample] {
        let count = Int(seconds * 25)
        return (0..<count).map { index in
            let (rotation, jolt) = shape(Double(index) / Double(count - 1))
            return reading(rotation: rotation, jolt: jolt)
        }
    }

    private mutating func reading(rotation: Vector3, jolt: Vector3) -> MotionSample {
        func noisy(_ value: Double, _ size: Double) -> Double { value + random.nextGaussian() * size }
        let sample = MotionSample(
            timestamp: time,
            attitude: .zero,
            rotationRate: Vector3(x: noisy(rotation.x, turnJitter), y: noisy(rotation.y, turnJitter), z: noisy(rotation.z, turnJitter)),
            userAcceleration: Vector3(x: noisy(jolt.x, joltJitter), y: noisy(jolt.y, joltJitter), z: noisy(jolt.z, joltJitter))
        )
        time += step
        return sample
    }
}

/// Repeatable randomness, so a failing test fails the same way every run.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUniform(), 1e-12), u2 = nextUniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Recordings as the app makes them: a few seconds with one go in the middle.
func recordings(_ count: Int, of gesture: (inout SyntheticHead, Int) -> [MotionSample]) -> [[MotionSample]] {
    var head = SyntheticHead()
    return (0..<count).map { index in
        head.rest(seconds: 0.8 + 0.2 * Double(index)) + gesture(&head, index) + head.rest(seconds: 1.2)
    }
}

func fireTimes(of detector: inout GestureDetector<String>, over stream: [MotionSample]) -> [(String, TimeInterval)] {
    stream.flatMap { sample in detector.process(sample).map { ($0, sample.timestamp) } }
}

@Test func learnsANodAndFiresOncePerNod() throws {
    // Examples vary in speed and strength, as a person's do.
    let nodModel = try GestureLearner.learn(from: recordings(4) { head, index in
        head.nod(seconds: 0.5 + 0.05 * Double(index), strength: 1.8 + 0.15 * Double(index))
    })
    var detector = GestureDetector<String>()
    detector.setWatched(["nod": .init(model: nodModel)])

    var head = SyntheticHead(random: SeededRandom(seed: 99))
    let stream = head.rest(seconds: 2) + head.nod(seconds: 0.55, strength: 2)
        + head.rest(seconds: 2) + head.nod(seconds: 0.7, strength: 1.7) + head.rest(seconds: 2)
    let fired = fireTimes(of: &detector, over: stream)

    #expect(fired.map(\.0) == ["nod", "nod"])
    // Each fire lands just after its nod ends, not halfway through it.
    #expect(fired[0].1 > 2.4 && fired[0].1 < 3.0)
    #expect(fired[1].1 > 5.1 && fired[1].1 < 5.8)
}

@Test func aNodModelIgnoresAHeadShakeAndStillness() throws {
    let nodModel = try GestureLearner.learn(from: recordings(3) { head, _ in head.nod() })
    var detector = GestureDetector<String>()
    detector.setWatched(["nod": .init(model: nodModel)])

    var head = SyntheticHead(random: SeededRandom(seed: 5))
    let stream = head.rest(seconds: 10) + head.shake() + head.rest(seconds: 2)
    #expect(fireTimes(of: &detector, over: stream).isEmpty)
}

@Test func tellsAJawClenchFromANod() throws {
    let nodModel = try GestureLearner.learn(from: recordings(3) { head, _ in head.nod() })
    let clenchModel = try GestureLearner.learn(from: recordings(3) { head, _ in head.clench() })
    var detector = GestureDetector<String>()
    detector.setWatched(["nod": .init(model: nodModel), "clench": .init(model: clenchModel)])

    var head = SyntheticHead(random: SeededRandom(seed: 11))
    let stream = head.rest(seconds: 2) + head.clench() + head.rest(seconds: 2)
        + head.nod() + head.rest(seconds: 2)
    #expect(fireTimes(of: &detector, over: stream).map(\.0) == ["clench", "nod"])
}

@Test func refusesToLearnFromTooFewOrEmptyExamples() {
    #expect(throws: GestureLearningError.needMoreExamples(have: 1, need: 2)) {
        try GestureLearner.learn(from: recordings(1) { head, _ in head.nod() })
    }
    #expect(throws: GestureLearningError.noMovementFound(exampleNumber: 2)) {
        var head = SyntheticHead()
        let withMovement = head.rest(seconds: 1) + head.nod() + head.rest(seconds: 1)
        let stillOnly = head.rest(seconds: 2.5)
        try GestureLearner.learn(from: [withMovement, stillOnly])
    }
}

/// Real nods recorded in the app took up most of each take: slow, broad, and
/// with the head still settling from the last take. Estimating resting jitter
/// from the whole take then measured the nod instead, set it about twenty
/// times too high, and lost the gentler nods entirely.
@Test func findsTheMovementWhenItFillsMostOfTheTake() throws {
    let model = try GestureLearner.learn(from: recordings(5) { head, index in
        head.nod(seconds: 1.6, strength: index == 4 ? 0.8 : 2)
    }.map { take in Array(take.dropFirst(15).dropLast(25)) })
    #expect(model.exampleCount == 5)
}

/// Real AirPods Pro were two to two and a half times quieter on three of six
/// channels than the minimum jitter first hard-coded for made-up data. The
/// minimum then shrank real signal, and faint jaw clenches were rejected as
/// no movement at all.
@Test func findsAFaintClenchOnQuietSensors() throws {
    var quiet = SyntheticHead()
    quiet.turnJitter = 0.01
    quiet.joltJitter = 0.0015
    let takes = (0..<4).map { _ in quiet.rest(seconds: 1) + quiet.clench(strength: 0.012) + quiet.rest(seconds: 1) }
    #expect(try GestureLearner.learn(from: takes).exampleCount == 4)
}

/// One take where the gesture did not register used to stop the whole
/// gesture from being learnt, and with it every approach that relied on it.
@Test func skipsATakeWithNoMovementAndSaysWhich() throws {
    var head = SyntheticHead()
    var takes = (0..<3).map { _ in head.rest(seconds: 1) + head.nod() + head.rest(seconds: 1) }
    takes.insert(head.rest(seconds: 2.5), at: 1)
    let model = try GestureLearner.learn(from: takes)
    #expect(model.exampleCount == 3)
    #expect(model.skippedExampleNumbers == [2])
}
