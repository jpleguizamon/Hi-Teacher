package io.github.jpleguizamon.hiteacher;

import android.Manifest;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.provider.Settings;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.widget.Toast;

import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.FileProvider;

import com.google.firebase.messaging.FirebaseMessaging;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

/**
 * O que o site pode pedir ao app (window.HiTeacherApp): ativar avisos pelo Firebase,
 * compartilhar, salvar arquivos e abrir links fora. O site só usa isso quando está dentro do app.
 */
public class AppBridge {
    static final String PREFS = "hi_app";
    final MainActivity act;
    String pendingCb;

    AppBridge(MainActivity act) { this.act = act; }

    static SharedPreferences prefs(Context c) { return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE); }

    /** {"version":"8.31","notif":"granted|denied|default"} */
    @JavascriptInterface
    public String info() {
        JSONObject o = new JSONObject();
        try {
            o.put("version", BuildConfig.VERSION_NAME);
            o.put("notif", notifState());
        } catch (Exception ignored) {}
        return o.toString();
    }

    String notifState() {
        boolean on = NotificationManagerCompat.from(act).areNotificationsEnabled();
        if (Build.VERSION.SDK_INT >= 33 && !act.has(Manifest.permission.POST_NOTIFICATIONS)) {
            boolean asked = prefs(act).getBoolean("notif_asked", false);
            return asked && !act.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) ? "denied" : "default";
        }
        return on ? "granted" : "denied";
    }

    /** Pede a permissão (se precisar) e devolve o código do aparelho no Firebase. */
    @JavascriptInterface
    public void enablePush(String cb) {
        act.runOnUiThread(() -> {
            if (act.notifAllowed()) { token(cb); return; }
            pendingCb = cb;
            prefs(act).edit().putBoolean("notif_asked", true).apply();
            act.askNotif();
        });
    }

    void afterNotifPermission() {
        String cb = pendingCb;
        pendingCb = null;
        if (cb == null) return;
        if (act.notifAllowed() && NotificationManagerCompat.from(act).areNotificationsEnabled()) token(cb);
        else done(cb, "{\"perm\":\"denied\"}");
    }

    void token(String cb) {
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(t -> {
            JSONObject o = new JSONObject();
            try {
                o.put("perm", NotificationManagerCompat.from(act).areNotificationsEnabled() ? "granted" : "denied");
                if (t.isSuccessful() && t.getResult() != null) {
                    o.put("token", t.getResult());
                    prefs(act).edit().putString("fcm_token", t.getResult()).apply();
                } else {
                    o.put("error", t.getException() != null ? String.valueOf(t.getException().getMessage()) : "sem resposta do Firebase");
                }
            } catch (Exception ignored) {}
            done(cb, o.toString());
        });
    }

    /** Último código do aparelho conhecido (para desligar sem perguntar ao Firebase). */
    @JavascriptInterface
    public String cachedToken() { return prefs(act).getString("fcm_token", ""); }

    /** Abre a tela de notificações do app nas configurações do Android. */
    @JavascriptInterface
    public void openNotifSettings() {
        Intent i = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, act.getPackageName());
        try { act.startActivity(i); } catch (Exception e) {
            act.startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + act.getPackageName())));
        }
    }

    @JavascriptInterface
    public void shareText(String text, String title) {
        Intent i = new Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text);
        if (title != null && !title.isEmpty()) i.putExtra(Intent.EXTRA_SUBJECT, title);
        act.runOnUiThread(() -> act.startActivity(Intent.createChooser(i, title)));
    }

    @JavascriptInterface
    public boolean shareFile(String name, String mime, String b64, String text) {
        try {
            File dir = new File(act.getCacheDir(), "share");
            dir.mkdirs();
            File f = new File(dir, safeName(name));
            try (OutputStream out = new FileOutputStream(f)) { out.write(Base64.decode(b64, Base64.DEFAULT)); }
            Uri u = FileProvider.getUriForFile(act, act.getPackageName() + ".files", f);
            Intent i = new Intent(Intent.ACTION_SEND).setType(mime == null || mime.isEmpty() ? "application/octet-stream" : mime)
                    .putExtra(Intent.EXTRA_STREAM, u).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            if (text != null && !text.isEmpty()) i.putExtra(Intent.EXTRA_TEXT, text);
            act.runOnUiThread(() -> act.startActivity(Intent.createChooser(i, null)));
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** Salva na pasta Downloads (Android 10+); nos mais antigos, abre o compartilhar. */
    @JavascriptInterface
    public boolean saveFile(String name, String mime, String b64) {
        if (Build.VERSION.SDK_INT < 29) return shareFile(name, mime, b64, "");
        try {
            ContentValues v = new ContentValues();
            v.put(MediaStore.Downloads.DISPLAY_NAME, safeName(name));
            v.put(MediaStore.Downloads.MIME_TYPE, mime == null || mime.isEmpty() ? "application/octet-stream" : mime);
            v.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);
            Uri u = act.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (u == null) return shareFile(name, mime, b64, "");
            try (OutputStream out = act.getContentResolver().openOutputStream(u)) { out.write(Base64.decode(b64, Base64.DEFAULT)); }
            act.runOnUiThread(() -> Toast.makeText(act, "Salvo em Downloads: " + safeName(name), Toast.LENGTH_LONG).show());
            return true;
        } catch (Exception e) {
            return shareFile(name, mime, b64, "");
        }
    }

    @JavascriptInterface
    public void openExternal(String url) {
        act.runOnUiThread(() -> act.openOutside(Uri.parse(url), true));
    }

    static String safeName(String n) {
        String s = n == null ? "" : n.replaceAll("[\\\\/:*?\"<>|\\n\\r]", "_").trim();
        return s.isEmpty() ? "arquivo" : s;
    }

    void done(String cb, String json) {
        act.js("window.__hiAppDone && __hiAppDone(" + JSONObject.quote(cb) + "," + json + ")");
    }
}
