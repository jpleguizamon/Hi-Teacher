package io.github.jpleguizamon.hiteacher;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.Window;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;

import java.util.ArrayList;
import java.util.List;

/**
 * Hi Teacher como app Android próprio: o site do app aberto numa janela do próprio app
 * (WebView), sem passar pelo Chrome. O conteúdo continua vindo do site, então as
 * atualizações chegam sozinhas. Os avisos chegam pelo Firebase (PushService).
 */
public class MainActivity extends Activity {
    static final String HOST = "jpleguizamon.github.io";
    static final String HOME = "https://" + HOST + "/Hi-Teacher/";
    static final int REQ_FILE = 1, REQ_MEDIA = 2, REQ_NOTIF = 3;
    static final int BG = Color.rgb(5, 6, 11);

    WebView web;
    AppBridge bridge;
    ValueCallback<Uri[]> fileCallback;
    PermissionRequest pendingMedia;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        Window w = getWindow();
        WindowCompat.setDecorFitsSystemWindows(w, false);
        w.setStatusBarColor(BG);
        w.setNavigationBarColor(BG);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        web = new WebView(this);
        web.setBackgroundColor(BG);
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
        // Barra de status e teclado não cobrem o app.
        ViewCompat.setOnApplyWindowInsetsListener(root, (v, insets) -> {
            Insets i = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.ime() | WindowInsetsCompat.Type.displayCutout());
            v.setPadding(i.left, i.top, i.right, i.bottom);
            return WindowInsetsCompat.CONSUMED;
        });

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setUserAgentString(s.getUserAgentString() + " HiTeacherApp/" + BuildConfig.VERSION_NAME);

        bridge = new AppBridge(this);
        web.addJavascriptInterface(bridge, "HiTeacherApp");
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                return openOutside(req.getUrl());
            }
        });
        web.setWebChromeClient(new Chrome());
        web.setDownloadListener((url, ua, cd, mime, len) -> openOutside(Uri.parse(url), true));

        if (saved != null) web.restoreState(saved);
        else web.loadUrl(urlFrom(getIntent()));
    }

    /** Endereço do app abre aqui dentro; o resto (WhatsApp, e-mail, outros sites) abre fora. */
    boolean openOutside(Uri u) { return openOutside(u, false); }
    boolean openOutside(Uri u, boolean force) {
        if (!force && "https".equals(u.getScheme()) && HOST.equals(u.getHost()) && u.getPath() != null && u.getPath().startsWith("/Hi-Teacher")) return false;
        try {
            Intent i = "intent".equals(u.getScheme()) ? Intent.parseUri(u.toString(), Intent.URI_INTENT_SCHEME) : new Intent(Intent.ACTION_VIEW, u);
            i.addCategory(Intent.CATEGORY_BROWSABLE);
            i.setComponent(null);
            startActivity(i);
        } catch (Exception e) { /* nenhum app abre esse endereço */ }
        return true;
    }

    /** Toque numa notificação: abre a página certa (?p=inicio | aulas | avisos | financeiro). */
    static String urlFrom(Intent intent) {
        String a = authReturn(intent);
        if (a != null) return a;
        String p = intent != null ? intent.getStringExtra("page") : null;
        return p != null && p.matches("[a-z]{2,20}") ? HOME + "?p=" + p : HOME;
    }

    /** Volta do login com Google/Apple: hiteacher://auth?...#... vira o endereço do app com o mesmo final. */
    static String authReturn(Intent intent) {
        Uri d = intent != null ? intent.getData() : null;
        if (d == null || !"hiteacher".equals(d.getScheme()) || !"auth".equals(d.getHost())) return null;
        String q = d.getEncodedQuery(), f = d.getEncodedFragment();
        return HOME + (q != null ? "?" + q : "") + (f != null ? "#" + f : "");
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String a = authReturn(intent);
        if (a != null) { web.loadUrl(a); return; }
        String p = intent.getStringExtra("page");
        if (p == null || !p.matches("[a-z]{2,20}")) return;
        String u = web.getUrl();
        if (u != null && u.startsWith(HOME)) web.evaluateJavascript("window.hiAppOpenPage ? hiAppOpenPage('" + p + "') : location.assign('" + HOME + "?p=" + p + "')", null);
        else web.loadUrl(HOME + "?p=" + p);
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        // O app usa o histórico pra fechar janelas e menus; sem nada pra voltar, sai.
        if (web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onResume() { super.onResume(); web.onResume(); }
    @Override
    protected void onPause() { web.onPause(); super.onPause(); }

    class Chrome extends WebChromeClient {
        @Override
        public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams params) {
            if (fileCallback != null) fileCallback.onReceiveValue(null);
            fileCallback = cb;
            try {
                Intent i = params.createIntent();
                if (params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                startActivityForResult(Intent.createChooser(i, null), REQ_FILE);
            } catch (ActivityNotFoundException e) {
                fileCallback = null;
                return false;
            }
            return true;
        }

        /** Microfone (afinador, gravações) e câmera (gravação em vídeo). */
        @Override
        public void onPermissionRequest(PermissionRequest req) {
            if (req.getOrigin() == null || !HOST.equals(req.getOrigin().getHost())) { req.deny(); return; }
            List<String> need = new ArrayList<>();
            for (String r : req.getResources()) {
                if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(r) && !has(Manifest.permission.RECORD_AUDIO)) need.add(Manifest.permission.RECORD_AUDIO);
                if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r) && !has(Manifest.permission.CAMERA)) need.add(Manifest.permission.CAMERA);
            }
            if (need.isEmpty()) { grantMedia(req); return; }
            pendingMedia = req;
            requestPermissions(need.toArray(new String[0]), REQ_MEDIA);
        }
    }

    boolean has(String perm) { return checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED; }

    void grantMedia(PermissionRequest req) {
        List<String> ok = new ArrayList<>();
        for (String r : req.getResources()) {
            if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(r) && has(Manifest.permission.RECORD_AUDIO)) ok.add(r);
            if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r) && has(Manifest.permission.CAMERA)) ok.add(r);
        }
        if (ok.isEmpty()) req.deny(); else req.grant(ok.toArray(new String[0]));
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        super.onRequestPermissionsResult(code, perms, results);
        if (code == REQ_MEDIA && pendingMedia != null) { grantMedia(pendingMedia); pendingMedia = null; }
        if (code == REQ_NOTIF) bridge.afterNotifPermission();
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code != REQ_FILE || fileCallback == null) return;
        Uri[] uris = null;
        if (result == RESULT_OK && data != null) {
            if (data.getClipData() != null) {
                uris = new Uri[data.getClipData().getItemCount()];
                for (int k = 0; k < uris.length; k++) uris[k] = data.getClipData().getItemAt(k).getUri();
            } else if (data.getData() != null) uris = new Uri[]{data.getData()};
        }
        fileCallback.onReceiveValue(uris);
        fileCallback = null;
    }

    /** Roda um callback do JavaScript na página (sempre na linha principal). */
    void js(String code) { runOnUiThread(() -> web.evaluateJavascript(code, null)); }

    boolean notifAllowed() {
        return Build.VERSION.SDK_INT < 33 || has(Manifest.permission.POST_NOTIFICATIONS);
    }
    void askNotif() {
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIF);
        else bridge.afterNotifPermission();
    }
}
