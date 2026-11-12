import Foundation
import GestureEngine
import Observation

/// Saved recordings, one JSON file each, in Application Support.
///
/// Kept out of the project folder on purpose: these are recordings of one
/// person's head and jaw, and the repo is public.
@MainActor
@Observable
final class RecordingStore {
    struct Summary: Identifiable, Hashable {
        let id: UUID
        let label: String
        let kind: Recording.Kind
        let recordedAt: Date
        let duration: TimeInterval
        let fileURL: URL
    }

    private(set) var summaries: [Summary] = []
    private(set) var lastError: String?

    let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AirPod Kit/Recordings", isDirectory: true)

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        reload()
    }

    /// Counts per gesture label, for the "you have 12 nods" lines.
    var takeCounts: [(label: String, count: Int)] {
        Dictionary(grouping: summaries.filter { $0.kind == .take }, by: \.label)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.label < $1.label }
    }

    var backgroundMinutes: Double {
        summaries.filter { $0.kind == .background }.map(\.duration).reduce(0, +) / 60
    }

    func save(_ recording: Recording) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Date first so the files sort in recording order in Finder.
            let stamp = ISO8601DateFormatter().string(from: recording.recordedAt).replacingOccurrences(of: ":", with: "-")
            let name = "\(stamp)-\(safeFileName(recording.label))-\(recording.id.uuidString.prefix(8)).json"
            try encoder.encode(recording).write(to: folder.appendingPathComponent(name), options: .atomic)
            reload()
        } catch {
            lastError = "Could not save the recording: \(error.localizedDescription)"
        }
    }

    func delete(_ summary: Summary) {
        try? FileManager.default.removeItem(at: summary.fileURL)
        reload()
    }

    func deleteAll(label: String) {
        for summary in summaries where summary.label == label {
            try? FileManager.default.removeItem(at: summary.fileURL)
        }
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        summaries = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let recording = try? decoder.decode(Recording.self, from: data) else { return nil }
                return Summary(id: recording.id, label: recording.label, kind: recording.kind,
                               recordedAt: recording.recordedAt, duration: recording.duration, fileURL: url)
            }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private func safeFileName(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(label.lowercased().replacingOccurrences(of: " ", with: "-").unicodeScalars.filter(allowed.contains))
    }
}
