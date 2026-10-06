#!/usr/bin/env bash
# Gera o APK do Hi Teacher para Android (app de verdade, sem barra de endereço).
#
# Antes de rodar:
#   1. Coloque o arquivo hi-teacher.keystore nesta pasta (ele NÃO fica no repositório).
#   2. export BUBBLEWRAP_KEYSTORE_PASSWORD="<senha>" ; export BUBBLEWRAP_KEY_PASSWORD="<senha>"
#   3. Tenha Node 18+, JDK 17 e o Android SDK (build-tools 36.1.0, platforms android-36).
#
# Ao subir o APP_VERSION do app, suba também appVersionName e appVersionCode no
# twa-manifest.json: o Android só aceita atualizar se o appVersionCode for maior.
set -euo pipefail
cd "$(dirname "$0")"

[ -f hi-teacher.keystore ] || { echo "Falta o hi-teacher.keystore nesta pasta."; exit 1; }
: "${BUBBLEWRAP_KEYSTORE_PASSWORD:?defina BUBBLEWRAP_KEYSTORE_PASSWORD}"
: "${BUBBLEWRAP_KEY_PASSWORD:?defina BUBBLEWRAP_KEY_PASSWORD}"

command -v bubblewrap >/dev/null || npm install -g @bubblewrap/cli

bubblewrap update --skipVersionUpgrade
bubblewrap build --skipPwaValidation

echo
echo "APK pronto: $(pwd)/app-release-signed.apk"
echo "Confira a digital da assinatura (tem de bater com o assetlinks.json):"
"${ANDROID_HOME:?defina ANDROID_HOME}/build-tools/36.1.0/apksigner" verify --print-certs app-release-signed.apk | grep -i "SHA-256"
