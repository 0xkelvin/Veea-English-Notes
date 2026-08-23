//
//  WordOfDayWidgetLiveActivity.swift
//  WordOfDayWidget
//
//  Created by kelvinm on 23/8/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct WordOfDayWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct WordOfDayWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WordOfDayWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension WordOfDayWidgetAttributes {
    fileprivate static var preview: WordOfDayWidgetAttributes {
        WordOfDayWidgetAttributes(name: "World")
    }
}

extension WordOfDayWidgetAttributes.ContentState {
    fileprivate static var smiley: WordOfDayWidgetAttributes.ContentState {
        WordOfDayWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: WordOfDayWidgetAttributes.ContentState {
         WordOfDayWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: WordOfDayWidgetAttributes.preview) {
   WordOfDayWidgetLiveActivity()
} contentStates: {
    WordOfDayWidgetAttributes.ContentState.smiley
    WordOfDayWidgetAttributes.ContentState.starEyes
}
