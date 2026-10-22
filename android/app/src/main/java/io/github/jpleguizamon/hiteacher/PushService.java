package io.github.jpleguizamon.hiteacher;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.util.Map;

/**
 * Recebe os avisos que a função send-push manda pelo Firebase e mostra a notificação
 * com o nome e o ícone do Hi Teacher. Tocar abre o app na página certa.
 */
public class PushService extends FirebaseMessagingService {
    static final String CHANNEL = "avisos", CHANNEL_REMIND = "lembretes";

    @Override
    public void onNewToken(@NonNull String token) {
        // O site registra o código novo da próxima vez que o app abrir.
        AppBridge.prefs(this).edit().putString("fcm_token", token).putBoolean("token_changed", true).apply();
    }

    @Override
    public void onMessageReceived(@NonNull RemoteMessage msg) {
        Map<String, String> d = msg.getData();
        String title = d.get("title"), body = d.get("body"), page = d.get("page"), tag = d.get("tag");
        if (title == null && msg.getNotification() != null) { title = msg.getNotification().getTitle(); body = msg.getNotification().getBody(); }
        show(this, CHANNEL, title == null ? "Hi Teacher" : PushTr.tr(this, title), body == null ? "" : PushTr.tr(this, body), page, tag);
    }

    static void show(Context c, String channel, String title, String body, String page, String tag) {
        NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(channel) == null) {
            boolean remind = CHANNEL_REMIND.equals(channel);
            nm.createNotificationChannel(new NotificationChannel(channel, PushTr.english(c) ? (remind ? "Reminders and summaries" : "Notifications") : (remind ? "Lembretes e resumos" : "Avisos"), NotificationManager.IMPORTANCE_HIGH));
        }
        Intent open = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        if (page != null) open.putExtra("page", page);
        int id = (tag == null ? title + body : tag).hashCode();
        PendingIntent pi = PendingIntent.getActivity(c, id, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        NotificationCompat.Builder b = new NotificationCompat.Builder(c, channel)
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(0xFF2FD3F2)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pi);
        try { NotificationManagerCompat.from(c).notify(tag, 1, b.build()); } catch (SecurityException ignored) { /* sem permissão */ }
    }
}
