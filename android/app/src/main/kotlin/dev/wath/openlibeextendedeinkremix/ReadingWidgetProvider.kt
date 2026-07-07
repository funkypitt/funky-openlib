package dev.wath.openlibeextendedeinkremix

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.io.File

/**
 * Home-screen widget showing the book currently being read (title, author,
 * cover, progress). Tapping it opens the app directly on that book, at the
 * saved reading position.
 */
class ReadingWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.reading_widget)

            val fileName = widgetData.getString("reading_file", null)
            val title = widgetData.getString("reading_title", null)
            val author = widgetData.getString("reading_author", "") ?: ""
            val percent = try {
                widgetData.getInt("reading_percent", -1)
            } catch (e: ClassCastException) {
                widgetData.getLong("reading_percent", -1L).toInt()
            }
            val coverPath = widgetData.getString("reading_cover", "") ?: ""

            if (fileName.isNullOrEmpty() || title.isNullOrEmpty()) {
                // Nothing read yet: show a hint and just open the app on tap.
                views.setTextViewText(
                    R.id.widget_title,
                    context.getString(R.string.widget_no_book)
                )
                views.setViewVisibility(R.id.widget_author, View.GONE)
                views.setViewVisibility(R.id.widget_progress_row, View.GONE)
                views.setViewVisibility(R.id.widget_cover, View.GONE)
                views.setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
                )
            } else {
                views.setTextViewText(R.id.widget_title, title)

                if (author.isNotEmpty()) {
                    views.setViewVisibility(R.id.widget_author, View.VISIBLE)
                    views.setTextViewText(R.id.widget_author, author)
                } else {
                    views.setViewVisibility(R.id.widget_author, View.GONE)
                }

                if (percent in 0..100) {
                    views.setViewVisibility(R.id.widget_progress_row, View.VISIBLE)
                    views.setProgressBar(R.id.widget_progress, 100, percent, false)
                    views.setTextViewText(R.id.widget_percent, "$percent %")
                } else {
                    views.setViewVisibility(R.id.widget_progress_row, View.GONE)
                }

                var coverShown = false
                if (coverPath.isNotEmpty()) {
                    try {
                        val file = File(coverPath)
                        if (file.exists()) {
                            val bitmap = BitmapFactory.decodeFile(file.absolutePath)
                            if (bitmap != null) {
                                views.setImageViewBitmap(R.id.widget_cover, bitmap)
                                coverShown = true
                            }
                        }
                    } catch (e: Exception) {
                        // fall through to hiding the cover
                    }
                }
                views.setViewVisibility(
                    R.id.widget_cover,
                    if (coverShown) View.VISIBLE else View.GONE
                )

                val launchIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("openlibwidget://open?file=" + Uri.encode(fileName))
                )
                views.setOnClickPendingIntent(R.id.widget_root, launchIntent)
            }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
