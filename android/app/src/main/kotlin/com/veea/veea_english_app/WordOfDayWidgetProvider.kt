package com.veea.veea_english_app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

class WordOfDayWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.word_of_day_widget).apply {
                val word = widgetData.getString("widget_word", "resilient")
                val ipa = widgetData.getString("widget_ipa", "/rɪˈzɪliənt/")
                val meaning = widgetData.getString("widget_meaning", "kiên cường, dẻo dai")
                val example = widgetData.getString("widget_example", "a resilient distributed system")

                setTextViewText(R.id.widget_word, word)
                setTextViewText(R.id.widget_ipa, ipa)
                setTextViewText(R.id.widget_meaning, meaning)
                setTextViewText(R.id.widget_example, example)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
