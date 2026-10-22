package io.github.jpleguizamon.hiteacher;

import android.content.Context;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * App em inglês (8.42): traduz os avisos que chegam pelo Firebase (a função send-push manda
 * em português). O idioma vem do site, por AppBridge.setLang. Mesma lista de i18n/push-en.json.
 */
final class PushTr {
    private PushTr() {}
    static final String[][] PAIRS = {
            {"Notificações ativas", "Notifications are on"},
            {"Teste enviado com sucesso.", "Test sent successfully."},
            {"Resposta do professor", "Reply from your teacher"},
            {"O professor respondeu ao seu recado.", "Your teacher replied to your message."},
            {"Novo recado", "New message"},
            {"{0} avisou que vai faltar na aula de {1}", "{0} said they'll miss the lesson on {1}"},
            {"{0} avisou que vai faltar", "{0} said they'll miss a lesson"},
            {"{0} avisou que pagou", "{0} said they've paid"},
            {"{0} pediu uma alteração nos dados", "{0} asked to change their details"},
            {"{0} pediu para remarcar a aula de {1}", "{0} asked to reschedule the lesson on {1}"},
            {"{0} pediu para remarcar uma aula", "{0} asked to reschedule a lesson"},
            {"{0} escolheu um horário de reposição", "{0} picked a time for a make-up lesson"},
            {"{0} pediu para apagar os dados", "{0} asked to delete their data"},
            {"Pedido de entrada", "Request to join"},
            {"{0} quer entrar", "{0} wants to join"},
            {"Aula remarcada", "Lesson rescheduled"},
            {"Aula cancelada", "Lesson canceled"},
            {"Sua aula de {0} foi remarcada", "Your lesson on {0} was rescheduled"},
            {"Sua aula de {0} foi cancelada", "Your lesson on {0} was canceled"},
            {"Reposição marcada", "Make-up lesson scheduled"},
            {"{0} às {1}", "{0} at {1}"},
            {"Aviso de {0}", "Notice from {0}"},
            {"Novo aviso do seu professor", "New notice from your teacher"},
            {"Mensalidade em atraso", "Monthly fee overdue"},
            {"Confira o financeiro", "Check your payments in the app"},
            {"Aviso da escola", "School notice"},
            {"Novo aviso", "New notice"},
            {"A escola mandou um interessado para você.", "The school sent you a lead."},
            {"Um aluno foi passado para você. Toque para aceitar.", "A student was transferred to you. Tap to accept."},
            {"Escola", "School"},
            {"Um professor pediu para entrar na escola", "A teacher asked to join the school"},
            {"{0} pediu para entrar na escola", "{0} asked to join the school"}
    };

    static boolean english(Context c) { return "en".equals(AppBridge.prefs(c).getString("lang", "pt")); }

    static String tr(Context c, String t) { return t == null || !english(c) ? t : tr(t, 0); }

    static String tr(String t, int depth) {
        if (t == null || depth > 2) return t;
        for (String[] p : PAIRS) {
            List<Integer> names = new ArrayList<>();
            StringBuilder re = new StringBuilder("^");
            Matcher ph = Pattern.compile("\\{(\\d)\\}").matcher(p[0]);
            int last = 0;
            while (ph.find()) {
                re.append(Pattern.quote(p[0].substring(last, ph.start()))).append("(.+?)");
                names.add(Integer.parseInt(ph.group(1)));
                last = ph.end();
            }
            re.append(Pattern.quote(p[0].substring(last))).append("$");
            Matcher m = Pattern.compile(re.toString(), Pattern.DOTALL).matcher(t);
            if (!m.matches()) continue;
            String out = p[1];
            for (int i = 0; i < names.size(); i++) out = out.replace("{" + names.get(i) + "}", tr(m.group(i + 1), depth + 1));
            return out;
        }
        return t;
    }
}
