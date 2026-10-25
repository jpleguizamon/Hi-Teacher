package io.github.jpleguizamon.hiteacher;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashSet;
import java.util.Set;

/**
 * Avisos marcados no próprio celular (8.32): o site manda a lista dos próximos dias
 * (aula começando, aula terminou, resumo do dia, lembrete do aluno) e o app avisa na hora,
 * mesmo fechado e sem internet. Fica um alarme só, sempre para o próximo aviso da lista.
 */
public class Scheduler extends BroadcastReceiver {
    static final String KEY_LIST = "sched_list", KEY_DONE = "sched_done";
    static final long LATE_OK = 30 * 60_000L; // aviso atrasado (celular desligado) ainda vale por 30 min

    /** Lista nova vinda do site: [{id, at (ms), title, body, page}]. */
    static void save(Context c, String json) {
        SharedPreferences p = AppBridge.prefs(c);
        Set<String> ids = new HashSet<>();
        try {
            JSONArray a = new JSONArray(json);
            for (int i = 0; i < a.length(); i++) ids.add(a.getJSONObject(i).optString("id"));
        } catch (Exception e) { json = "[]"; }
        // Esquece os já mostrados que saíram da lista (a lista anda com os dias).
        Set<String> done = new HashSet<>(p.getStringSet(KEY_DONE, new HashSet<>()));
        done.retainAll(ids);
        p.edit().putString(KEY_LIST, json).putStringSet(KEY_DONE, done).apply();
        arm(c);
    }

    /** Mostra o que já deu a hora e marca o alarme para o próximo. */
    static synchronized void arm(Context c) {
        SharedPreferences p = AppBridge.prefs(c);
        Set<String> done = new HashSet<>(p.getStringSet(KEY_DONE, new HashSet<>()));
        long now = System.currentTimeMillis(), next = Long.MAX_VALUE;
        boolean changed = false;
        try {
            JSONArray a = new JSONArray(p.getString(KEY_LIST, "[]"));
            for (int i = 0; i < a.length(); i++) {
                JSONObject o = a.getJSONObject(i);
                String id = o.optString("id");
                long at = o.optLong("at");
                if (id.isEmpty() || done.contains(id)) continue;
                if (at <= now + 5_000) {
                    if (now - at <= LATE_OK) PushService.show(c, PushService.CHANNEL_REMIND, o.optString("title", "Hi Teacher"), o.optString("body"), o.optString("page", null), id);
                    done.add(id);
                    changed = true;
                } else if (at < next) next = at;
            }
        } catch (Exception ignored) {}
        if (changed) p.edit().putStringSet(KEY_DONE, done).apply();

        AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
        PendingIntent pi = PendingIntent.getBroadcast(c, 7, new Intent(c, Scheduler.class), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        am.cancel(pi);
        if (next == Long.MAX_VALUE) return;
        try {
            if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
            else am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
        } catch (SecurityException e) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
        }
    }

    /** Android 12+ pode não deixar marcar na hora exata (a pessoa libera em "Alarmes e lembretes"). */
    static boolean exactOk(Context c) {
        if (Build.VERSION.SDK_INT < 31) return true;
        AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
        return am != null && am.canScheduleExactAlarms();
    }

    /** Alarme tocou, celular ligou, app atualizado, hora mudou ou permissão de alarme mudou: confere de novo. */
    @Override
    public void onReceive(Context c, Intent intent) { arm(c); }
}
