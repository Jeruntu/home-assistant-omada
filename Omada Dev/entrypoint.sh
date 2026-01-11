#!/usr/bin/env bashio
set -e

# ======================================
# Home Assistant Preprocessing
# ======================================

bashio::log.info "Preparing Home Assistant environment..."

# Create logs directory in persistent volume
mkdir -p "/data/logs"

# Handle Data Migration/Backup
if [ ! -d /data/data ]; then
  if [ -d /opt/tplink/EAPController/data_backup ]; then
    bashio::log.info "Restoring /data/data from backup..."
    cp -r /opt/tplink/EAPController/data_backup /data/data
  fi

  # Migration from old file structure
  for dir in db keystore pdf;
  do
    if [ -d "/data/$dir" ]; then
      bashio::log.info "Migrating /data/$dir to /data/data/$dir"
      cp -r "/data/$dir" "/data/data/"
      rm -rf "/data/$dir"
    fi
  done
fi

# Set permissions on /data
# We assume PUID/PGID 508 for omada user
chown -R 508:508 "/data"

# SSL Configuration
if bashio::config.true 'enable_hass_ssl'; then
  bashio::log.info "Configuring SSL from Home Assistant..."
  SSL_CERT_NAME=$(bashio::config 'certfile')
  SSL_KEY_NAME=$(bashio::config 'keyfile')
  
  # Copy to temporary location for Omada import logic
  mkdir -p /cert
  cp "$SSL_CERT_NAME" /cert/
  cp "$SSL_KEY_NAME" /cert/

  # Update variable names to just filenames for the import logic
  SSL_CERT_NAME="$(basename "$SSL_CERT_NAME")"
  SSL_KEY_NAME="$(basename "$SSL_KEY_NAME")"
fi

# MongoDB Configuration
export MONGO_EXTERNAL=true # Always force "external" mode for Omada properties
bashio::log.info "Using internal MongoDB (S6 Managed)"
export EAP_MONGOD_URI="mongodb://127.0.0.1:27217/omada"

# ======================================
# Omada Controller Startup Logic
# ======================================

bashio::log.info "Starting Omada Controller setup..."

export TZ="${TZ:-Etc/UTC}"
PUID="508"
PGID="508"
PUSERNAME="omada"
PGROUP="omada"

# Ensure user/group exists
if ! getent group "${PGROUP}" >/dev/null; then
  bashio::log.info "Creating group ${PGROUP} (${PGID})..."
  groupadd -g "${PGID}" "${PGROUP}"
fi
if ! id -u "${PUSERNAME}" >/dev/null 2>&1; then
  bashio::log.info "Creating user ${PUSERNAME} (${PUID})..."
  useradd -u "${PUID}" -g "${PGID}" -d /opt/tplink/EAPController/data -s /bin/sh "${PUSERNAME}"
fi

# Restore default properties if missing
for FILE in /opt/tplink/EAPController/properties.defaults/*;
do
  BASENAME=$(basename "${FILE}")
  DEST="/opt/tplink/EAPController/properties/${BASENAME}"
  if [ ! -f "${DEST}" ]; then
    bashio::log.info "Restoring default property file: ${BASENAME}"
    cp "${FILE}" "${DEST}"
    chown "${PUSERNAME}:${PGROUP}" "${DEST}"
  fi
done

# Create/Verify Data Directories
DIRS=("data/html" "data/pdf" "data/db" "logs")
bashio::log.info "Verifying data directories..."
for d in "${DIRS[@]}"; do
  dir_path="/opt/tplink/EAPController/${d}"
  if [ ! -d "${dir_path}" ]; then
    mkdir -p "${dir_path}"
  fi
  chown -R "${PUSERNAME}:${PGROUP}" "${dir_path}"
done
chown -R "${PUSERNAME}:${PGROUP}" "/opt/tplink/EAPController/properties"

# Import SSL Certs to Keystore
KEYSTORE_DIR="/opt/tplink/EAPController/data/keystore"
if [ ! -d "${KEYSTORE_DIR}" ]; then
    mkdir -p "${KEYSTORE_DIR}"
    chown "${PUSERNAME}:${PGROUP}" "${KEYSTORE_DIR}"
fi

if [ -f "/cert/${SSL_KEY_NAME}" ] && [ -f "/cert/${SSL_CERT_NAME}" ]; then
  bashio::log.info "Importing SSL certificate to Keystore..."
  rm -f "${KEYSTORE_DIR}/eap.keystore"
  openssl pkcs12 -export \
    -inkey "/cert/${SSL_KEY_NAME}" \
    -in "/cert/${SSL_CERT_NAME}" \
    -certfile "/cert/${SSL_CERT_NAME}" \
    -name eap \
    -out "${KEYSTORE_DIR}/eap.keystore" \
    -passout pass:tplink
  chown "${PUSERNAME}:${PGROUP}" "${KEYSTORE_DIR}/eap.keystore"
  chmod 400 "${KEYSTORE_DIR}/eap.keystore"
  
  # Cleanup temp certs
  rm -rf /cert
fi

# Update omada.properties: Ports
bashio::log.info "Updating port configurations in omada.properties..."
PORTS="MANAGE_HTTP_PORT MANAGE_HTTPS_PORT PORTAL_HTTP_PORT PORTAL_HTTPS_PORT PORT_ADOPT_V1 PORT_APP_DISCOVERY PORT_UPGRADE_V1 PORT_MANAGER_V1 PORT_MANAGER_V2 PORT_DISCOVERY PORT_TRANSFER_V2 PORT_RTTY PORT_DEVICE_MONITOR"
for VAR_NAME in $PORTS;
do
  KEY="$(echo "${VAR_NAME}" | tr '[:upper:]' '[:lower:]' | tr '_' '.')"
  VAL="${!VAR_NAME}"
  if [ -n "${VAL}" ]; then
    if grep -q "^${KEY}=" /opt/tplink/EAPController/properties/omada.properties; then
      bashio::log.info "Setting '${KEY}' to ${VAL}"
      sed -i "s~^${KEY}=.*$~${KEY}=${VAL}~g" /opt/tplink/EAPController/properties/omada.properties
    else
      echo "${KEY}=${VAL}" >> /opt/tplink/EAPController/properties/omada.properties
    fi
  fi
done

# Update omada.properties: MongoDB
bashio::log.info "Updating MongoDB configuration in omada.properties..."
SAFE_URI=$(printf '%s\n' "$EAP_MONGOD_URI" | sed -e 's/[\/&]/\\&/g')
sed -i "s~^mongo.external=.*$~mongo.external=${MONGO_EXTERNAL}~g" /opt/tplink/EAPController/properties/omada.properties
sed -i "s~^eap.mongod.uri=.*$~eap.mongod.uri=${SAFE_URI}~g" /opt/tplink/EAPController/properties/omada.properties

# CloudSDK Injection
CLOUDSDK_JAR="$(find /opt/tplink/EAPController/lib -maxdepth 1 -name "cloudsdk-*.jar" | head -n 1)"
if [ -n "${CLOUDSDK_JAR}" ]; then
  if echo "${@}" | grep -q "com.tplink.smb.omada.starter.OmadaLinuxMain"; then
    bashio::log.info "Injecting CloudSDK JAR into classpath..."
    NEW_ARGS=()
    NEXT_IS_CP=false
    for ARG in "${@}"; do
      if [ "${NEXT_IS_CP}" = "true" ]; then
        NEW_ARGS+=("${CLOUDSDK_JAR}:${ARG}")
        NEXT_IS_CP=false
      elif [ "${ARG}" = "-cp" ] || [ "${ARG}" = "-classpath" ]; then
        NEW_ARGS+=("${ARG}")
        NEXT_IS_CP=true
      else
        NEW_ARGS+=("${ARG}")
      fi
    done
    set -- "${NEW_ARGS[@]}"
  fi
fi

# Autobackup Check
if [ ! -d "/opt/tplink/EAPController/data/autobackup" ]; then
  bashio::log.warning "No autobackup directory found at /opt/tplink/EAPController/data/autobackup"
fi

bashio::log.info "Starting Omada Controller..."

# Tail logs
if [ "${SHOW_SERVER_LOGS:-true}" = "true" ]; then
  gosu "${PUSERNAME}" tail -F -n 0 /opt/tplink/EAPController/logs/server.log &
fi
if [ "${SHOW_MONGODB_LOGS:-false}" = "true" ]; then
  gosu "${PUSERNAME}" tail -F -n 0 /opt/tplink/EAPController/logs/mongod.log &
fi

exec gosu "${PUSERNAME}" "${@}"