import WidgetKit
import SwiftUI
import AppIntents

struct NextWordIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Word"
    static var description = IntentDescription("Rotates to the next vocabulary word.")

    func perform() async throws -> some IntentResult {
        let userDefaults = UserDefaults(suiteName: "group.com.veea.veea_english_app")
        let jsonString = userDefaults?.string(forKey: "widget_words_json") ?? ""

        struct WordItem: Decodable {
            let word: String
        }

        if let data = jsonString.data(using: .utf8),
           let list = try? JSONDecoder().decode([WordItem].self, from: data), !list.isEmpty {
            let currentIndex = userDefaults?.integer(forKey: "widget_rotation_index") ?? 0
            let nextIndex = (currentIndex + 1) % list.count
            userDefaults?.set(nextIndex, forKey: "widget_rotation_index")
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct WordOfDayEntry: TimelineEntry {
    let date: Date
    let word: String
    let ipa: String
    let pos: String
    let meaning: String
    let example: String
    let streakDays: Int
}

struct RawWord: Decodable {
    let word: String
    let ipa: String
    let pos: String
    let meaning: String
    let example: String
}

struct WordOfDayProvider: TimelineProvider {
    func placeholder(in context: Context) -> WordOfDayEntry {
        WordOfDayEntry(
            date: Date(),
            word: "resilient",
            ipa: "/rɪˈzɪliənt/",
            pos: "adj.",
            meaning: "kiên cường, dẻo dai",
            example: "a resilient distributed system",
            streakDays: 12
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WordOfDayEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WordOfDayEntry>) -> Void) {
        let entries = loadEntries()
        let timeline = Timeline(entries: entries, policy: .atEnd)
        completion(timeline)
    }

    private func loadEntries() -> [WordOfDayEntry] {
        let userDefaults = UserDefaults(suiteName: "group.com.veea.veea_english_app")
        let streak = userDefaults?.integer(forKey: "widget_streak") ?? 12
        let jsonString = userDefaults?.string(forKey: "widget_words_json") ?? ""

        var parsedWords: [RawWord] = []
        if let data = jsonString.data(using: .utf8),
           let list = try? JSONDecoder().decode([RawWord].self, from: data) {
            parsedWords = list
        }

        if parsedWords.isEmpty {
            return [loadEntry()]
        }

        let currentIndex = userDefaults?.integer(forKey: "widget_rotation_index") ?? 0

        var entries: [WordOfDayEntry] = []
        let currentDate = Date()
        let totalWords = parsedWords.count

        // Generate 1-minute repeating timeline loop starting from current rotation index
        for step in 0..<120 {
            let item = parsedWords[(currentIndex + step) % totalWords]
            let entryDate = Calendar.current.date(byAdding: .minute, value: step * 1, to: currentDate) ?? currentDate
            entries.append(
                WordOfDayEntry(
                    date: entryDate,
                    word: item.word.isEmpty ? "resilient" : item.word,
                    ipa: item.ipa.isEmpty ? "/rɪˈzɪliənt/" : item.ipa,
                    pos: item.pos,
                    meaning: item.meaning.isEmpty ? "kiên cường, dẻo dai" : item.meaning,
                    example: item.example,
                    streakDays: streak
                )
            )
        }

        return entries
    }

    private func loadEntry() -> WordOfDayEntry {
        let userDefaults = UserDefaults(suiteName: "group.com.veea.veea_english_app")
        let streak = userDefaults?.integer(forKey: "widget_streak") ?? 12
        let jsonString = userDefaults?.string(forKey: "widget_words_json") ?? ""

        var parsedWords: [RawWord] = []
        if let data = jsonString.data(using: .utf8),
           let list = try? JSONDecoder().decode([RawWord].self, from: data) {
            parsedWords = list
        }

        if parsedWords.isEmpty {
            let word = userDefaults?.string(forKey: "widget_word") ?? "resilient"
            let ipa = userDefaults?.string(forKey: "widget_ipa") ?? "/rɪˈzɪliənt/"
            let pos = userDefaults?.string(forKey: "widget_pos") ?? "adj."
            let meaning = userDefaults?.string(forKey: "widget_meaning") ?? "kiên cường, dẻo dai"
            let example = userDefaults?.string(forKey: "widget_example") ?? "a resilient distributed system"

            return WordOfDayEntry(
                date: Date(),
                word: word.isEmpty ? "resilient" : word,
                ipa: ipa.isEmpty ? "/rɪˈzɪliənt/" : ipa,
                pos: pos,
                meaning: meaning.isEmpty ? "kiên cường, dẻo dai" : meaning,
                example: example,
                streakDays: streak
            )
        }

        let currentIndex = userDefaults?.integer(forKey: "widget_rotation_index") ?? 0
        let item = parsedWords[currentIndex % parsedWords.count]

        return WordOfDayEntry(
            date: Date(),
            word: item.word.isEmpty ? "resilient" : item.word,
            ipa: item.ipa.isEmpty ? "/rɪˈzɪliənt/" : item.ipa,
            pos: item.pos,
            meaning: item.meaning.isEmpty ? "kiên cường, dẻo dai" : item.meaning,
            example: item.example,
            streakDays: streak
        )
    }
}

struct WordOfDayWidgetEntryView : View {
    var entry: WordOfDayProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryInline:
            // Lock Screen Top Bar Slot (above clock)
            Button(intent: NextWordIntent()) {
                Text("Veea: \(entry.word) • \(entry.meaning)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.plain)
            .containerBackground(for: .widget) { Color.clear }

        case .accessoryRectangular:
            // Lock Screen Main Rectangular Slot (below clock)
            Button(intent: NextWordIntent()) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.word)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                        Spacer(minLength: 2)
                        Text("🔥\(entry.streakDays)")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(entry.ipa)
                        .font(.system(size: 10, design: .monospaced))
                    Text(entry.meaning)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(2)
            }
            .buttonStyle(.plain)
            .containerBackground(for: .widget) { AccessoryWidgetBackground() }

        case .accessoryCircular:
            // Lock Screen Small Circular Slot
            Button(intent: NextWordIntent()) {
                VStack(spacing: 1) {
                    Text("🔥\(entry.streakDays)")
                        .font(.system(size: 10, weight: .bold))
                    Text(entry.word)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .containerBackground(for: .widget) { AccessoryWidgetBackground() }

        default:
            // Home Screen Medium / Small Widget
            Button(intent: NextWordIntent()) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("WORD OF THE DAY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.45, green: 0.46, blue: 0.40))
                        Spacer()
                        Text("🔥 \(entry.streakDays) STREAK")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.95, green: 0.40, blue: 0.10))
                    }

                    Spacer().frame(height: 1)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.word)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.90, green: 0.89, blue: 0.85))

                        Text(entry.pos)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(red: 0.60, green: 0.61, blue: 0.55))
                    }

                    Text(entry.ipa)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(red: 0.61, green: 0.74, blue: 0.06))

                    Text(entry.meaning)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(red: 0.90, green: 0.89, blue: 0.85))

                    if !entry.example.isEmpty {
                        Text("\"\(entry.example)\"")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(red: 0.60, green: 0.61, blue: 0.55))
                            .lineLimit(1)
                    }
                }
                .padding()
            }
            .buttonStyle(.plain)
            .containerBackground(for: .widget) { Color(red: 0.11, green: 0.12, blue: 0.09) }
        }
    }
}

struct WordOfDayWidget: Widget {
    let kind: String = "WordOfDayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WordOfDayProvider()) { entry in
            WordOfDayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Word of the Day")
        .description("Displays daily review words, IPA pronunciation, Vietnamese meaning, and streak badge.")
        .supportedFamilies([
            .systemMedium,
            .systemSmall,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCircular
        ])
    }
}
