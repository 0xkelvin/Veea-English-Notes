//
//  WordOfDayWidgetBundle.swift
//  WordOfDayWidget
//
//  Created by kelvinm on 23/8/26.
//

import WidgetKit
import SwiftUI

@main
struct WordOfDayWidgetBundle: WidgetBundle {
    var body: some Widget {
        WordOfDayWidget()
        WordOfDayWidgetControl()
        WordOfDayWidgetLiveActivity()
    }
}
