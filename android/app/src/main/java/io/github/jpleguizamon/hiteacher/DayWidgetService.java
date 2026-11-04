package io.github.jpleguizamon.hiteacher;

import android.content.Context;
import android.content.Intent;
import android.widget.RemoteViews;
import android.widget.RemoteViewsService;

import java.util.ArrayList;
import java.util.List;

/** Linhas da lista do quadro "Aulas de hoje": um cartão por horário, com a turma inteira. */
public class DayWidgetService extends RemoteViewsService {
    @Override
    public RemoteViewsFactory onGetViewFactory(Intent intent) { return new Factory(getApplicationContext()); }

    static final class Factory implements RemoteViewsFactory {
        final Context c;
        List<DayWidget.Slot> slots = new ArrayList<>();
        String now = "", next = "";

        Factory(Context c) { this.c = c; }

        @Override public void onCreate() {}
        @Override public void onDestroy() {}

        @Override
        public void onDataSetChanged() {
            slots = DayWidget.todaySlots(c);
            now = DayWidget.nowHm();
            next = "";
            for (DayWidget.Slot s : slots) if (!DayWidget.past(s, now)) { next = s.start; break; }
        }

        @Override public int getCount() { return slots.size(); }

        @Override
        public RemoteViews getViewAt(int i) {
            RemoteViews v = new RemoteViews(c.getPackageName(), R.layout.day_widget_item);
            if (i >= slots.size()) return v;
            DayWidget.Slot s = slots.get(i);
            boolean en = PushTr.english(c), past = DayWidget.past(s, now), isNext = s.start.equals(next);
            v.setTextViewText(R.id.i_time, s.start);
            v.setInt(R.id.i_time, "setBackgroundResource", isNext ? R.drawable.widget_pill_next : R.drawable.widget_pill);
            v.setTextColor(R.id.i_time, isNext ? DayWidget.WHITE : past ? DayWidget.MUTED : DayWidget.BLUE);
            int n = s.names.size();
            String sub = n > 1 ? (en ? "Group · " + n + " students" : "Turma · " + n + " alunos") : "";
            if (s.extra) sub += (sub.isEmpty() ? "" : " · ") + (en ? "make-up" : "reposição");
            v.setTextViewText(R.id.i_sub, sub);
            v.setViewVisibility(R.id.i_sub, sub.isEmpty() ? android.view.View.GONE : android.view.View.VISIBLE);
            v.setTextViewText(R.id.i_names, android.text.TextUtils.join(", ", s.names));
            v.setTextColor(R.id.i_names, past ? DayWidget.MUTED : DayWidget.WHITE);
            v.setOnClickFillInIntent(R.id.i_root, new Intent());
            return v;
        }

        @Override public RemoteViews getLoadingView() { return null; }
        @Override public int getViewTypeCount() { return 1; }
        @Override public long getItemId(int i) { return i; }
        @Override public boolean hasStableIds() { return false; }
    }
}
