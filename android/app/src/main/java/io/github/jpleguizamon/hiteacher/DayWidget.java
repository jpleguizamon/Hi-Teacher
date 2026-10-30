package io.github.jpleguizamon.hiteacher;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.StyleSpan;
import android.widget.RemoteViews;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Locale;

/**
 * Quadro "Aulas de hoje" na tela inicial do celular/tablet (8.58). O site manda as aulas dos
 * próximos dias (AppBridge.setWidget) e o quadro mostra as do dia, mesmo sem abrir o app.
 * Atualiza sozinho a cada 30 min (vira o dia) e toda vez que o app manda a lista.
 */
public class DayWidget extends AppWidgetProvider {
    static final String KEY = "widget_days";
    static final int BLUE = 0xFF4F7DFF, MUTED = 0xFF7C86A2;

    /** Lista nova vinda do site: {"AAAA-MM-DD": [["08:00","09:00","Ana","reposição"], ...]}. */
    static void save(Context c, String json) {
        AppBridge.prefs(c).edit().putString(KEY, json == null ? "{}" : json).apply();
        refreshAll(c);
    }

    static void refreshAll(Context c) {
        AppWidgetManager m = AppWidgetManager.getInstance(c);
        int[] ids = m.getAppWidgetIds(new ComponentName(c, DayWidget.class));
        if (ids != null && ids.length > 0) for (int id : ids) m.updateAppWidget(id, build(c));
    }

    @Override
    public void onUpdate(Context c, AppWidgetManager m, int[] ids) {
        for (int id : ids) m.updateAppWidget(id, build(c));
    }

    static RemoteViews build(Context c) {
        boolean en = PushTr.english(c);
        Calendar now = Calendar.getInstance();
        String today = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now.getTime());
        String nowHm = new SimpleDateFormat("HH:mm", Locale.US).format(now.getTime());
        JSONArray list = new JSONArray();
        try { list = new JSONObject(AppBridge.prefs(c).getString(KEY, "{}")).optJSONArray(today); } catch (Exception ignored) {}
        if (list == null) list = new JSONArray();

        String day = new SimpleDateFormat(en ? "EEE, MMM d" : "EEE, dd/MM", en ? Locale.US : new Locale("pt", "BR")).format(now.getTime());
        int n = list.length();
        String head = (en ? "Today's lessons" : "Aulas de hoje") + " · " + day;
        String count = n == 0 ? "" : en ? n + (n == 1 ? " lesson" : " lessons") : n + (n == 1 ? " aula" : " aulas");

        SpannableStringBuilder sb = new SpannableStringBuilder();
        if (n == 0) sb.append(en ? "No lessons today." : "Nenhuma aula hoje.");
        for (int i = 0; i < n; i++) {
            JSONArray x = list.optJSONArray(i);
            if (x == null) continue;
            String start = x.optString(0), end = x.optString(1), name = x.optString(2), note = x.optString(3);
            boolean past = !end.isEmpty() && end.compareTo(nowHm) <= 0;
            if (sb.length() > 0) sb.append("\n");
            int a = sb.length();
            sb.append(start);
            sb.setSpan(new StyleSpan(Typeface.BOLD), a, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            sb.setSpan(new ForegroundColorSpan(past ? MUTED : BLUE), a, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            int b = sb.length();
            sb.append("  ").append(name);
            if (!note.isEmpty()) sb.append(" · ").append(en ? "make-up" : note);
            if (past) sb.setSpan(new ForegroundColorSpan(MUTED), b, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }

        RemoteViews v = new RemoteViews(c.getPackageName(), R.layout.day_widget);
        v.setTextViewText(R.id.w_title, head);
        v.setTextViewText(R.id.w_count, count);
        v.setTextViewText(R.id.w_list, sb);
        Intent open = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("page", "dia");
        v.setOnClickPendingIntent(R.id.w_root, PendingIntent.getActivity(c, 58, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        return v;
    }
}
