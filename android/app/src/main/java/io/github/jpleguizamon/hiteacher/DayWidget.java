package io.github.jpleguizamon.hiteacher;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.view.View;
import android.widget.RemoteViews;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Quadro "Aulas de hoje" na tela inicial do celular/tablet (8.59; 8.61: turmas num cartão só e
 * lista que rola). O site manda as aulas dos próximos dias (AppBridge.setWidget) e o quadro mostra
 * as do dia, mesmo sem abrir o app. Atualiza sozinho a cada 30 min e toda vez que o app manda a lista.
 */
public class DayWidget extends AppWidgetProvider {
    static final String KEY = "widget_days";
    static final int BLUE = 0xFF4F7DFF, MUTED = 0xFF64748B, WHITE = 0xFFFFFFFF;

    /** Um horário do dia: todos os alunos que começam na mesma hora (a turma) ficam juntos. */
    static final class Slot {
        String start, end = "";
        final List<String> names = new ArrayList<>();
        boolean extra;
    }

    /** Lista nova vinda do site: {"AAAA-MM-DD": [["08:00","09:00","Ana","reposição"], ...]}. */
    static void save(Context c, String json) {
        AppBridge.prefs(c).edit().putString(KEY, json == null ? "{}" : json).apply();
        refreshAll(c);
    }

    static void refreshAll(Context c) {
        AppWidgetManager m = AppWidgetManager.getInstance(c);
        int[] ids = m.getAppWidgetIds(new ComponentName(c, DayWidget.class));
        if (ids == null || ids.length == 0) return;
        for (int id : ids) m.updateAppWidget(id, build(c, id));
        m.notifyAppWidgetViewDataChanged(ids, R.id.w_list);
    }

    @Override
    public void onUpdate(Context c, AppWidgetManager m, int[] ids) {
        for (int id : ids) m.updateAppWidget(id, build(c, id));
        m.notifyAppWidgetViewDataChanged(ids, R.id.w_list);
    }

    static String nowHm() { return new SimpleDateFormat("HH:mm", Locale.US).format(Calendar.getInstance().getTime()); }

    /** Aulas de hoje agrupadas por horário, em ordem. */
    static List<Slot> todaySlots(Context c) {
        String today = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Calendar.getInstance().getTime());
        JSONArray list = null;
        try { list = new JSONObject(AppBridge.prefs(c).getString(KEY, "{}")).optJSONArray(today); } catch (Exception ignored) {}
        Map<String, Slot> by = new LinkedHashMap<>();
        if (list != null) for (int i = 0; i < list.length(); i++) {
            JSONArray x = list.optJSONArray(i);
            if (x == null) continue;
            String start = x.optString(0);
            Slot s = by.get(start);
            if (s == null) { s = new Slot(); s.start = start; by.put(start, s); }
            String end = x.optString(1);
            if (end.compareTo(s.end) > 0) s.end = end;
            s.names.add(x.optString(2));
            if (!x.optString(3).isEmpty()) s.extra = true;
        }
        List<Slot> out = new ArrayList<>(by.values());
        out.sort((a, b) -> a.start.compareTo(b.start));
        return out;
    }

    static boolean past(Slot s, String now) { return !s.end.isEmpty() && s.end.compareTo(now) <= 0; }

    static RemoteViews build(Context c, int widgetId) {
        boolean en = PushTr.english(c);
        List<Slot> slots = todaySlots(c);
        int lessons = 0;
        for (Slot s : slots) lessons += s.names.size();
        String now = nowHm();
        int next = -1;
        for (int i = 0; i < slots.size(); i++) if (!past(slots.get(i), now)) { next = i; break; }

        RemoteViews v = new RemoteViews(c.getPackageName(), R.layout.day_widget);
        Calendar cal = Calendar.getInstance();
        String day = new SimpleDateFormat(en ? "EEEE, MMM d" : "EEEE, dd/MM", en ? Locale.US : new Locale("pt", "BR")).format(cal.getTime());
        v.setTextViewText(R.id.w_title, en ? "Today's lessons" : "Aulas de hoje");
        v.setTextViewText(R.id.w_date, day.substring(0, 1).toUpperCase(Locale.ROOT) + day.substring(1));
        v.setTextViewText(R.id.w_count, String.valueOf(lessons));
        v.setViewVisibility(R.id.w_count, lessons == 0 ? View.GONE : View.VISIBLE);
        v.setTextViewText(R.id.w_empty, en ? "No lessons today." : "Nenhuma aula hoje.");

        // Lista que rola: cada linha vem do DayWidgetService.
        Intent svc = new Intent(c, DayWidgetService.class).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId);
        svc.setData(Uri.parse(svc.toUri(Intent.URI_INTENT_SCHEME)));
        v.setRemoteAdapter(R.id.w_list, svc);
        v.setEmptyView(R.id.w_list, R.id.w_empty);
        if (next > 0) v.setScrollPosition(R.id.w_list, next);

        Intent open = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("page", "dia");
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
        v.setOnClickPendingIntent(R.id.w_head, PendingIntent.getActivity(c, 58, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        v.setPendingIntentTemplate(R.id.w_list, PendingIntent.getActivity(c, 59, open, flags));
        return v;
    }
}
