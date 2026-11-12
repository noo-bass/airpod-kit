import Foundation

/// How different a recent stretch of movement is from a learnt example,
/// allowing either to be done a little faster or slower than the other.
///
/// This is dynamic time warping. A plain point-by-point comparison would call
/// a slow nod and a quick nod different, because their peaks fall at different
/// moments. Warping lets one reading in the example line up with several in
/// the stream (or the other way round), so the shape is compared, not the
/// timing.
///
/// The stream end is pinned to "now" but its start is free: the match may
/// begin anywhere in `stream`. The live detector hands over a window a bit
/// longer than the gesture, and does not have to guess where the gesture began.
///
/// Returns the average per-reading distance along the best alignment, so a
/// long gesture and a short one give comparable numbers.
func subsequenceDistance(template: [[Double]], stream: [[Double]]) -> Double {
    let templateLength = template.count
    let streamLength = stream.count
    guard templateLength > 0, streamLength > 0 else { return .infinity }

    // Two rows are enough: each row of the table only reads the one above.
    // `previous[j]` is the cheapest way to have matched template[0..<i]
    // ending at stream[j - 1]; column 0 means "nothing of the stream used".
    var previous = [Double](repeating: 0, count: streamLength + 1)
    var current = [Double](repeating: .infinity, count: streamLength + 1)
    // Row 0 is all zeros: starting the match at any point in the stream costs
    // nothing. That is the free start.
    for i in 1...templateLength {
        current[0] = .infinity
        for j in 1...streamLength {
            let cost = euclideanDistance(template[i - 1], stream[j - 1])
            current[j] = cost + min(previous[j - 1], previous[j], current[j - 1])
        }
        swap(&previous, &current)
    }
    return previous[streamLength] / Double(templateLength)
}

func euclideanDistance(_ a: [Double], _ b: [Double]) -> Double {
    var sum = 0.0
    for index in a.indices {
        let difference = a[index] - b[index]
        sum += difference * difference
    }
    return sum.squareRoot()
}
