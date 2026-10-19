import Foundation

enum EqualizerBands {
    static let simple: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let advanced: [Double] = [50, 100, 156, 220, 311, 440, 622, 880, 1250, 1750, 2500, 3500, 5000, 10000, 20000]
    static func frequencies(count: Int) -> [Double] { count == 15 ? advanced : simple }
    static func resample(_ gains: [Double], to count: Int) -> [Double] {
        guard [10, 15].contains(gains.count), [10, 15].contains(count) else { return Array(repeating: 0, count: count) }
        let source = frequencies(count: gains.count)
        return frequencies(count: count).map { frequency in
            if frequency <= source[0] { return gains[0] }
            if frequency >= source.last! { return gains.last! }
            let upper = source.firstIndex(where: { $0 >= frequency })!
            let lower = upper - 1
            let fraction = log(frequency / source[lower]) / log(source[upper] / source[lower])
            return gains[lower] + fraction * (gains[upper] - gains[lower])
        }
    }
}
struct SoftwareEQPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var media: [Double]
    var chat: [Double]
    var valid: Bool { [media, chat].allSatisfy { [10, 15].contains($0.count) && $0.allSatisfy { $0.isFinite && (-12...12).contains($0) } } }
}
