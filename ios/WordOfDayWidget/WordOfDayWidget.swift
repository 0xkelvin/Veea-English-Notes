import WidgetKit
import SwiftUI

struct WordOfDayEntry: TimelineEntry {
    let date: Date
    let word: String
    let ipa: String
    let pos: String
    let meaning: String
    let example: String
    let streakDays: Int
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
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 4, to: Date()) ?? Date().addingTimeInterval(14400)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadEntry() -> WordOfDayEntry {
        let userDefaults = UserDefaults(suiteName: "group.com.veea.veea_english_app")
        let word = userDefaults?.string(forKey: "widget_word") ?? "resilient"
        let ipa = userDefaults?.string(forKey: "widget_ipa") ?? "/rɪˈzɪliənt/"
        let pos = userDefaults?.string(forKey: "widget_pos") ?? "adj."
        let meaning = userDefaults?.string(forKey: "widget_meaning") ?? "kiên cường, dẻo dai"
        let example = userDefaults?.string(forKey: "widget_example") ?? "a resilient distributed system"
        let streak = userDefaults?.integer(forKey: "widget_streak") ?? 12

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
}

struct WordOfDayWidgetEntryView : View {
    var entry: WordOfDayProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryInline:
            // Lock Screen Top Bar Widget
            Text("Veea: \(entry.word) • \(entry.meaning)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))

        case .accessoryRectangular:
            // Lock Screen Main Widget Slot
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.word)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("🔥\(entry.streakDays)")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(entry.ipa)
                    .font(.system(size: 11, design: .monospaced))
                Text(entry.meaning)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .containerBackground(for: .widget) { Color.clear }

        default:
            // Home Screen Medium / Small Widget
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
            .accessoryInline
        ])
    }
}
