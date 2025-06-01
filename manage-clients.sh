#!/bin/bash

# --- Script para Clientes OpenVPN ---
# Este es mi script para manejar los clientes, todo en uno.
# No depende de archivos de config externos. Parámetros fijos o los pido.

# --- Funciones Auxiliares (Integradas) ---
# Estas funciones me ayudan a mostrar mensajes bonitos y controlar errores.
log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_fatal() { log_error "$1"; exit 1; } # Si algo es fatal, muestro error y salgo.

run_cmd() {
    # Esta función corre un comando y me avisa si falla. Útil.
    log_info "Ejecutando: $@"
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then log_error "Comando falló con estado $status: $@"; fi
    return $status
}

ask_yes_no() {
    # Para preguntas de sí o no, con un default.
    local q="$1"; local d="${2:-n}"; local p="[s/N]"; if [[ "$d" == "s" ]]; then p="[S/n]"; fi
    while true; do read -rp "$q ${p}: " ans; ans="${ans:-$d}"; case "$ans" in [SsYy]*) return 0;; [Nn]*) return 1;; *) log_warn "Responde 's' o 'n'.";; esac; done
}
# --- Fin Funciones Auxiliares ---

# --- Verificación de Root ---
# Necesito ser root para esto, si no, no funciona.
if [[ $EUID -ne 0 ]]; then log_fatal "Este script debe ser ejecutado como root."; fi

# --- Parámetros de Configuración (Hardcodeados o Pedidos si están vacíos) ---
# Aquí pongo los valores que casi siempre uso.
# Si alguno está vacío, el script me lo va a preguntar después.
EASYRSA_DIR="/etc/openvpn/easy-rsa"       # Donde está mi EasyRSA.
SERVER_CONFIG_DIR="/etc/openvpn/server"   # Donde guardo ta.key y crl.pem del server.
CLIENT_OVPN_OUTPUT_DIR="/root/ovpn-clients" # Aquí van los .ovpn para los clientes.

PUBLIC_IP="201.230.143.55" # Mi IP pública. OJO: si cambia, tengo que actualizarla aquí.
VPN_PORT="443"
VPN_PROTO_CLIENT="tcp" # 'tcp' o 'udp', para el archivo .ovpn del cliente.
SERVER_CN="server"     # El Common Name que diseñé para el certificado de mi servidor.

# Si quiero que siempre me pregunte, descomento estas líneas.
# if [ -z "$EASYRSA_DIR" ]; then read -rp "Ingresa la ruta al directorio Easy-RSA (ej: /etc/openvpn/easy-rsa): " EASYRSA_DIR; fi
# if [ -z "$SERVER_CONFIG_DIR" ]; then read -rp "Ingresa la ruta al directorio de config del servidor OpenVPN (ej: /etc/openvpn/server): " SERVER_CONFIG_DIR; fi
# if [ -z "$CLIENT_OVPN_OUTPUT_DIR" ]; then read -rp "Ingresa la ruta para guardar los archivos .ovpn (ej: /root/ovpn-clients): " CLIENT_OVPN_OUTPUT_DIR; fi
# if [ -z "$PUBLIC_IP" ]; then read -rp "Ingresa la IP pública o dominio del servidor OpenVPN: " PUBLIC_IP; fi
# if [ -z "$VPN_PORT" ]; then read -rp "Ingresa el puerto del servidor OpenVPN (ej: 443): " VPN_PORT; fi
# if [ -z "$VPN_PROTO_CLIENT" ]; then read -rp "Ingresa el protocolo del cliente (tcp o udp): " VPN_PROTO_CLIENT; fi

# Validaciones básicas, para no empezar con problemas.
if [ ! -d "$EASYRSA_DIR" ] || [ ! -x "${EASYRSA_DIR}/easyrsa" ]; then
    log_fatal "Directorio Easy-RSA ($EASYRSA_DIR) no encontrado o 'easyrsa' no es ejecutable."
fi
if [ ! -d "$SERVER_CONFIG_DIR" ]; then
    log_fatal "Directorio de configuración del servidor ($SERVER_CONFIG_DIR) no encontrado."
fi
if [ ! -f "${SERVER_CONFIG_DIR}/ta.key" ]; then # Chequeo que ta.key exista, lo necesito.
    log_fatal "Archivo ta.key no encontrado en $SERVER_CONFIG_DIR. Necesario para <tls-crypt>."
fi
if [ -z "$PUBLIC_IP" ] || [ -z "$VPN_PORT" ] || [ -z "$VPN_PROTO_CLIENT" ]; then
    log_fatal "IP del servidor, puerto o protocolo no definidos. No se puede continuar."
fi
run_cmd mkdir -p "$CLIENT_OVPN_OUTPUT_DIR" # Me aseguro que la carpeta de salida exista.

# --- Contraseña de CA (se pedirá cuando sea necesario) ---
# Guardo la pass de la CA aquí para no escribirla a cada rato.
CA_PASSWORD=""
get_ca_password() {
    if [ -n "$CA_PASSWORD" ]; then return 0; fi # Si ya la tengo, no la pido.
    log_info "Se requiere la contraseña de la Autoridad Certificadora (CA)."
    while true; do
        read -s -p "Ingresa la contraseña para la CA: " CA_PASSWORD_TEMP; echo
        if [ -n "$CA_PASSWORD_TEMP" ]; then CA_PASSWORD=$CA_PASSWORD_TEMP; return 0;
        else log_warn "La contraseña no puede estar vacía."; fi
    done
}

# --- Menú Principal de Gestión de Clientes ---
echo "--- Gestión de Clientes OpenVPN (Standalone) ---"
echo "Directorio Easy-RSA: $EASYRSA_DIR"
echo "Salida .ovpn: $CLIENT_OVPN_OUTPUT_DIR"
echo "Servidor para .ovpn: $PUBLIC_IP:$VPN_PORT ($VPN_PROTO_CLIENT)"
echo "CN del Servidor (diseñado por mí): $SERVER_CN" # Aclarando que este CN lo definí yo.
echo ""
echo "Selecciona una opción:"
echo "  1) Añadir nuevo cliente"
echo "  2) Revocar cliente existente"
echo "  q) Salir"
read -rp "Opción: " choice

ORIGINAL_PWD=$(pwd) # Guardo el directorio actual para volver después.
cd "$EASYRSA_DIR" || log_fatal "No se pudo cambiar al directorio Easy-RSA: $EASYRSA_DIR"

case "$choice" in
    1) # --- AÑADIR CLIENTE ---
        read -rp "Introduce el nombre para el nuevo cliente (ej: mi-celular, laptop-nueva): " CLIENT_NAME
        if [[ -z "$CLIENT_NAME" ]] || ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            # El nombre tiene que ser válido, si no, problemas.
            log_fatal "Nombre de cliente inválido. Usa solo letras, números, guiones, puntos o guiones bajos."
        fi

        CLIENT_CRT_PATH="./pki/issued/${CLIENT_NAME}.crt"
        CLIENT_KEY_PATH="./pki/private/${CLIENT_NAME}.key"
        CLIENT_OVPN_FILE="${CLIENT_OVPN_OUTPUT_DIR}/${CLIENT_NAME}.ovpn"

        if [ -f "$CLIENT_CRT_PATH" ]; then
            log_warn "El certificado para '$CLIENT_NAME' ya existe ($CLIENT_CRT_PATH)."
            if ! ask_yes_no "¿Regenerar solo el archivo .ovpn (no se regenerarán claves/certificados)?" "n"; then
                log_info "Operación cancelada."; cd "$ORIGINAL_PWD"; exit 0;
            fi
            if [ ! -f "$CLIENT_KEY_PATH" ]; then
                 log_fatal "No se encontró la clave privada ($CLIENT_KEY_PATH) para '$CLIENT_NAME', no se puede regenerar .ovpn.";
            fi
        else
            log_info "Generando solicitud y clave para '$CLIENT_NAME'..."
            # El --req-cn es para el Common Name del certificado del cliente. Importante.
            run_cmd ./easyrsa --batch --req-cn="$CLIENT_NAME" gen-req "$CLIENT_NAME" nopass || log_fatal "gen-req para '$CLIENT_NAME' falló."

            get_ca_password # Aquí pido la pass de la CA.
            log_info "Firmando solicitud para '$CLIENT_NAME'..."
            export EASYRSA_PASSIN="pass:$CA_PASSWORD" # Le paso la pass a easyrsa.
            run_cmd ./easyrsa --batch sign-req client "$CLIENT_NAME" || log_fatal "sign-req para '$CLIENT_NAME' falló."
            unset EASYRSA_PASSIN # Limpio la variable de entorno de la pass.
        fi

        log_info "Generando archivo de configuración .ovpn para '$CLIENT_NAME'..."

        # Necesito el contenido de estos archivos para meterlos en el .ovpn.
        CA_CRT_CONTENT=$(cat "./pki/ca.crt")
        CLIENT_CRT_CONTENT=$(cat "$CLIENT_CRT_PATH")
        CLIENT_KEY_CONTENT=$(cat "$CLIENT_KEY_PATH")
        TLS_CRYPT_CONTENT=$(cat "${SERVER_CONFIG_DIR}/ta.key") # El ta.key del server.

        if [ -z "$CA_CRT_CONTENT" ] || [ -z "$CLIENT_CRT_CONTENT" ] || [ -z "$CLIENT_KEY_CONTENT" ] || [ -z "$TLS_CRYPT_CONTENT" ]; then
            log_fatal "Uno o más archivos de certificado/clave (CA, cliente .crt, cliente .key, ta.key) están vacíos o no se pudieron leer.";
        fi

# --- Plantilla del Archivo .ovpn del Cliente ---
# La directiva remote-cert-tls verifica que el CN del certificado del servidor
# coincida con $SERVER_CN Y que el certificado del servidor tenga el EKU "TLS Web Server Authentication".
# Si $SERVER_CN es "server", entonces el cliente espera que el CN del server.crt sea "server".
# La directiva auth SHA256 no es estrictamente necesaria con AES-GCM, pero no hace daño.
# explicit-exit-notify 2 es para que el TCP se porte mejor al desconectar.
#
# IMPORTANTE: El siguiente bloque cat << EOF ... EOF no debe tnener indentación
# Ni comentarios para que el archivo .ovpn se genere correctamente.
cat << EOF > "$CLIENT_OVPN_FILE"
client
dev tun
proto $VPN_PROTO_CLIENT
remote $PUBLIC_IP $VPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls $SERVER_CN
cipher AES-256-GCM
verb 3
explicit-exit-notify 2
<ca>
$CA_CRT_CONTENT
</ca>
<cert>
$CLIENT_CRT_CONTENT
</cert>
<key>
$CLIENT_KEY_CONTENT
</key>
<tls-crypt>
$TLS_CRYPT_CONTENT
</tls-crypt>
EOF
# --- Fin Plantilla ---

        run_cmd chmod 600 "$CLIENT_OVPN_FILE" # Permisos restrictivos para el .ovpn.
        log_info "Perfil de cliente generado: $CLIENT_OVPN_FILE"
        log_warn "Transfiere este archivo de forma SEGURA a tu dispositivo cliente."
        log_warn "Recuerda que este perfil es para '$CLIENT_NAME'. Si lo usas en varios sitios a la vez, se van a desconectar entre ellos (a menos que uses duplicate-cn en el server)."
        ;;

    2) # --- REVOCAR CLIENTE ---
        log_info "Clientes existentes (certificados emitidos, excluyendo el servidor):"
        # Listo los clientes que tengo, menos el server, para saber cuál revocar.
        find ./pki/issued/ -maxdepth 1 -type f -name "*.crt" -printf "%f\n" | sed 's/\.crt$//' | grep -v "^${SERVER_CN}$" | sort
        echo ""
        read -rp "Introduce el nombre EXACTO del cliente a revocar: " CLIENT_TO_REVOKE

        if [[ -z "$CLIENT_TO_REVOKE" ]]; then
            log_fatal "Nombre de cliente no puede estar vacío."
        fi
        if [ ! -f "./pki/issued/${CLIENT_TO_REVOKE}.crt" ]; then
            log_fatal "Certificado para '$CLIENT_TO_REVOKE' no encontrado en ./pki/issued/.";
        fi
        if [[ "$CLIENT_TO_REVOKE" == "$SERVER_CN" ]]; then
            # ¡Cuidado! No quiero revocar mi propio server por error.
            log_fatal "¡No puedes revocar el certificado del servidor ($SERVER_CN) con este script!"
        fi

        get_ca_password # Necesito la pass de la CA para revocar.
        log_info "Revocando certificado para '$CLIENT_TO_REVOKE'..."
        export EASYRSA_PASSIN="pass:$CA_PASSWORD"
        run_cmd ./easyrsa --batch revoke "$CLIENT_TO_REVOKE" || log_fatal "Revocación para '$CLIENT_TO_REVOKE' falló."

        log_info "Generando nueva CRL..." # La lista de los revocados.
        run_cmd ./easyrsa --batch gen-crl || log_fatal "Generación de CRL falló."
        unset EASYRSA_PASSIN # Limpio la pass.

        CRL_SOURCE_PATH="./pki/crl.pem" # Donde EasyRSA deja la nueva CRL.
        CRL_DEST_PATH="${SERVER_CONFIG_DIR}/crl.pem" # Donde la necesita mi server OpenVPN.

        if [ -f "$CRL_SOURCE_PATH" ]; then
            log_info "Copiando nueva CRL ($CRL_SOURCE_PATH) a $CRL_DEST_PATH..."
            if run_cmd cp "$CRL_SOURCE_PATH" "$CRL_DEST_PATH"; then
                log_info "CRL copiada exitosamente."
                log_warn "IMPORTANTE: Debes reiniciar el servicio OpenVPN en el servidor para que la nueva CRL tenga efecto:"
                log_warn "sudo systemctl restart openvpn-server@server.service  (o el nombre de tu servicio)"
            else
                log_error "Falló la copia de CRL. Por favor, cópiala manualmente desde $CRL_SOURCE_PATH a $CRL_DEST_PATH y reinicia OpenVPN.";
            fi
        else
            log_error "Archivo CRL generado ($CRL_SOURCE_PATH) no encontrado. Algo salió mal.";
        fi

        if ask_yes_no "¿Eliminar archivos del cliente revocado (.crt, .key, .req de EasyRSA y .ovpn de la carpeta de salida)?" "n"; then
            # Pregunto si quiero borrar los archivos viejos del cliente revocado.
            log_info "Intentando eliminar archivos de '$CLIENT_TO_REVOKE'..."
            rm -vf "./pki/issued/${CLIENT_TO_REVOKE}.crt"
            rm -vf "./pki/private/${CLIENT_TO_REVOKE}.key"
            rm -vf "./pki/reqs/${CLIENT_TO_REVOKE}.req"
            # Busco y elimino cualquier archivo .ovpn que comience con el nombre del cliente.
            find "$CLIENT_OVPN_OUTPUT_DIR" -maxdepth 1 -type f -name "${CLIENT_TO_REVOKE}*.ovpn" -delete -print
            log_info "Archivos del cliente eliminados (o intento realizado).";
        fi
        log_info "Cliente '$CLIENT_TO_REVOKE' revocado. No olvides reiniciar el servidor OpenVPN."
        ;;

    [Qq]*)
        log_info "Saliendo."
        ;;
    *)
        log_warn "Opción no válida."
        ;;
esac

CA_PASSWORD="" # Limpio la contraseña de la variable por seguridad al salir.
cd "$ORIGINAL_PWD" || log_warn "No se pudo volver al directorio original: $ORIGINAL_PWD" # Vuelvo a donde empecé.
exit 0
