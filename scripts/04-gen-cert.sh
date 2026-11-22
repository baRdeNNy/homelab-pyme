#!/usr/bin/env bash
# homelab-pyme - Fase 4: certificado autofirmado para el proxy inverso de dmz01.
# SAN: www.pyme.test, estado.pyme.test e IP 192.168.1.210 (VIP del FortiGate).
# Idempotente: si el certificado ya existe, no lo regenera.
# Uso: ./04-gen-cert.sh [directorio]   (por defecto: ./nginx/certs)
set -euo pipefail

DIR="${1:-./nginx/certs}"
CRT="$DIR/pyme.crt"
KEY="$DIR/pyme.key"

mkdir -p "$DIR"

if [[ -f "$CRT" && -f "$KEY" ]]; then
    echo "[=] El certificado ya existe en $DIR, no se regenera."
else
    echo "[+] Generando certificado autofirmado en $DIR ..."
    openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes \
        -keyout "$KEY" -out "$CRT" \
        -subj "/C=ES/O=PYME Lab/CN=www.pyme.test" \
        -addext "subjectAltName=DNS:www.pyme.test,DNS:estado.pyme.test,IP:192.168.1.210" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" 2>/dev/null
    chmod 600 "$KEY"
    chmod 644 "$CRT"
fi

openssl x509 -in "$CRT" -noout -subject -enddate -ext subjectAltName
