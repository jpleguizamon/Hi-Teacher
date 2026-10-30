package io.github.jpleguizamon.hiteacher;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.view.View;
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
    static final int BLUE = 0xFF4F7DFF, MUTED = 0xFF64748B, WHITE = 0xFFFFFFFF;

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

    static final int[] ROW = {R.id.r0, R.id.r1, R.id.r2, R.id.r3, R.id.r4, R.id.r5};
    static final int[] TIME = {R.id.t0, R.id.t1, R.id.t2, R.id.t3, R.id.t4, R.id.t5};
    static final int[] NAME = {R.id.n0, R.id.n1, R.id.n2, R.id.n3, R.id.n4, R.id.n5};

    static RemoteViews build(Context c) {
        boolean en = PushTr.english(c);
        Calendar now = Calendar.getInstance();
        String today = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now.getTime());
        String nowHm = new SimpleDateFormat("HH:mm", Locale.US).format(now.getTime());
        JSONArray list = null;
        try { list = new JSONObject(AppBridge.prefs(c).getString(KEY, "{}")).optJSONArray(today); } catch (Exception ignored) {}
        if (list == null) list = new JSONArray();
        int n = list.length();

        RemoteViews v = new RemoteViews(c.getPackageName(), R.layout.day_widget);
        String day = new SimpleDateFormat(en ? "EEEE, MMM d" : "EEEE, dd/MM", en ? Locale.US : new Locale("pt", "BR")).format(now.getTime());
        v.setTextViewText(R.id.w_title, en ? "Today's lessons" : "Aulas de hoje");
        v.setTextViewText(R.id.w_date, day.substring(0, 1).toUpperCase(Locale.ROOT) + day.substring(1));
        v.setTextViewText(R.id.w_count, String.valueOf(n));
        v.setViewVisibility(R.id.w_count, n == 0 ? View.GONE : View.VISIBLE);
        v.setTextViewText(R.id.w_empty, en ? "No lessons today." : "Nenhuma aula hoje.");
        v.setViewVisibility(R.id.w_empty, n == 0 ? View.VISIBLE : View.GONE);

        // Mostra a partir da próxima aula se não couber tudo (as que já passaram saem primeiro).
        int first = 0, next = -1;
        for (int i = 0; i < n; i++) {
            JSONArray x = list.optJSONArray(i);
            if (x != null && (x.optString(1).isEmpty() || x.optString(1).compareTo(nowHm) > 0)) { next = i; break; }
        }
        if (n > ROW.length && next > 0) first = Math.min(next, n - ROW.length);
        for (int r = 0; r < ROW.length; r++) {
            int i = first + r;
            JSONArray x = i < n ? list.optJSONArray(i) : null;
            if (x == null) { v.setViewVisibility(ROW[r], View.GONE); continue; }
            String end = x.optString(1), note = x.optString(3);
            boolean past = !end.isEmpty() && end.compareTo(nowHm) <= 0, isNext = i == next;
            v.setViewVisibility(ROW[r], View.VISIBLE);
            v.setTextViewText(TIME[r], x.optString(0));
            v.setInt(TIME[r], "setBackgroundResource", isNext ? R.drawable.widget_pill_next : R.drawable.widget_pill);
            v.setTextColor(TIME[r], isNext ? WHITE : past ? MUTED : BLUE);
            v.setTextViewText(NAME[r], x.optString(2) + (note.isEmpty() ? "" : " · " + (en ? "make-up" : note)));
            v.setTextColor(NAME[r], past ? MUTED : WHITE);
        }
        int hidden = n - first - ROW.length;
        v.setViewVisibility(R.id.w_more, hidden > 0 ? View.VISIBLE : View.GONE);
        if (hidden > 0) v.setTextViewText(R.id.w_more, en ? "+ " + hidden + " more" : "+ " + hidden + (hidden == 1 ? " aula" : " aulas"));

        Intent open = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("page", "dia");
        v.setOnClickPendingIntent(R.id.w_root, PendingIntent.getActivity(c, 58, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        return v;
    }
}
