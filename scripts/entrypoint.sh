#!/bin/bash
set -e



/scripts/start.sh

if [[ ${GEONODE} =~ [Tt][Rr][Uu][Ee] ]];then
  echo $"\n\n\n"
  echo "-----------------------------------------------------"
  echo "STARTING GEOSERVER ENTRYPOINT -----------------------"
  date

  ############################
  # 0. Defining BASEURL
  ############################

  echo "-----------------------------------------------------"
  echo "0. Defining BASEURL"

  if [ ! -z "$HTTPS_HOST" ]; then
      BASEURL="https://$HTTPS_HOST"
      if [ "$HTTPS_PORT" != "443" ]; then
          BASEURL="$BASEURL:$HTTPS_PORT"
      fi
  else
      BASEURL="http://$HTTP_HOST"
      if [ "$HTTP_PORT" != "80" ]; then
          BASEURL="$BASEURL:$HTTP_PORT"
      fi
  fi
  export INTERNAL_OAUTH2_BASEURL="${INTERNAL_OAUTH2_BASEURL:=$BASEURL}"
  export GEONODE_URL="${GEONODE_URL:=$BASEURL}"
  export BASEURL="$BASEURL/geoserver"

  echo "INTERNAL_OAUTH2_BASEURL is $INTERNAL_OAUTH2_BASEURL"
  echo "GEONODE_URL is $GEONODE_URL"
  echo "BASEURL is $BASEURL"



  ############################
  # 3. WAIT FOR POSTGRESQL
  ############################

  if [[ ${SPC_GEONODE} =~ [Tt][Rr][Uu][Ee] ]]; then
    echo "-----------------------------------------------------"
    echo "3. Wait for PostgreSQL to be ready and initialized"

    # Wait for PostgreSQL
    set +e
    for i in $(seq 60); do
        sleep 10
        echo "$DATABASE_URL -v ON_ERROR_STOP=1 -c SELECT client_id FROM oauth2_provider_application"
        psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT client_id FROM oauth2_provider_application" &>/dev/null && break
    done
    if [ $? != 0 ]; then
        echo "PostgreSQL not ready or not initialized"
        exit 1
    fi
    set -e
  fi

  ############################
  # 4. OAUTH2 CONFIGURATION
  ############################

  echo "-----------------------------------------------------"
  echo "4. (Re)setting OAuth2 Configuration"

  # Edit ${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml
  # Getting oauth keys and secrets from the database
  if [[ ${SPC_GEONODE} =~ [Tt][Rr][Uu][Ee] ]]; then
    CLIENT_ID=$(psql "$DATABASE_URL" -c "SELECT client_id FROM oauth2_provider_application WHERE name='GeoServer'" -t | tr -d '[:space:]')
    CLIENT_SECRET=$(psql "$DATABASE_URL" -c "SELECT client_secret FROM oauth2_provider_application WHERE name='GeoServer'" -t | tr -d '[:space:]')
  else
    CLIENT_ID=${OAUTH2_CLIENT_ID}
    CLIENT_SECRET=${OAUTH2_CLIENT_SECRET}
  fi

  if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
      echo "Could not get OAuth2 ID and SECRET from database. Make sure Postgres container is started and Django has finished it's migrations."
      exit 1
  fi

  sed -i -r "s|<cliendId>.*</cliendId>|<cliendId>$CLIENT_ID</cliendId>|" "${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml"
  sed -i -r "s|<clientSecret>.*</clientSecret>|<clientSecret>$CLIENT_SECRET</clientSecret>|" "${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml"
  # OAuth endpoints (client)
  # These must be reachable by user
  sed -i -r "s|<userAuthorizationUri>.*</userAuthorizationUri>|<userAuthorizationUri>$GEONODE_URL/o/authorize/</userAuthorizationUri>|" "${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml"
  sed -i -r "s|<redirectUri>.*</redirectUri>|<redirectUri>$BASEURL/index.html</redirectUri>|" "${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml"
  sed -i -r "s|<logoutUri>.*</logoutUri>|<logoutUri>$GEONODE_URL/account/logout/</logoutUri>|" "${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml"
  # OAuth endpoints (server)
  # These must be reachable by server (GeoServer must be able to reach GeoNode)
  sed -i -r "s|<accessTokenUri>.*</accessTokenUri>|<accessTokenUri>$INTERNAL_OAUTH2_BASEURL/o/token/</accessTokenUri>|" "${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml"
  sed -i -r "s|<checkTokenEndpointUrl>.*</checkTokenEndpointUrl>|<checkTokenEndpointUrl>$INTERNAL_OAUTH2_BASEURL/api/o/v4/tokeninfo/</checkTokenEndpointUrl>|" "${GEOSERVER_DATA_DIR}/security/filter/geonode-oauth2/config.xml"

  # Edit /security/role/geonode REST role service/config.xml
  sed -i -r "s|<baseUrl>.*</baseUrl>|<baseUrl>$GEONODE_URL</baseUrl>|" "${GEOSERVER_DATA_DIR}/security/role/geonode REST role service/config.xml"

  CLIENT_ID=""
  CLIENT_SECRET=""


  ############################
  # 5. RE(SETTING) BASE URL
  ############################

  echo "-----------------------------------------------------"
  echo "5. (Re)setting Baseurl"

  sed -i -r "s|<proxyBaseUrl>.*</proxyBaseUrl>|<proxyBaseUrl>$BASEURL</proxyBaseUrl>|" "${GEOSERVER_DATA_DIR}/global.xml"

  ############################
  # 6. IMPORTING SSL CERTIFICATE
  ############################

  echo "-----------------------------------------------------"
  echo "6. Importing SSL certificate (if using HTTPS)"

  # https://docs.geoserver.org/stable/en/user/community/oauth2/index.html#ssl-trusted-certificates
  if [ ! -z "$HTTPS_HOST" ]; then
      # Random password are generated every container restart
      PASSWORD=$(openssl rand -base64 18)
      # Since keystore password are autogenerated every container restart,
      # The same keystore will not be able to be opened again.
      # So, we create a new one.
      if [[ -f ${GEOSERVER_HOME}/keystore.jks ]]; then
        rm -f ${GEOSERVER_HOME}/keystore.jks
      fi

      # Support for Kubernetes/Docker file secrets if the certificate file path is defined
      if [ ! -z "${SSL_CERT_FILE}" ]; then
        cp -f ${SSL_CERT_FILE} server.crt
      else
        openssl s_client -connect ${HTTPS_HOST#https://}:${HTTPS_PORT} </dev/null |
            openssl x509 -out ${GEOSERVER_HOME}/server.crt
      fi

      # create a keystore and import certificate
      if [ "$(ls -A ${GEOSERVER_HOME}/keystore.jks)" ]; then
          echo 'Keystore not empty, skipping initialization...'
      else
          echo 'Keystore empty, we run initialization...'
          keytool -import -noprompt -trustcacerts \
              -alias ${HTTPS_HOST} -file server.crt \
              -keystore ${GEOSERVER_HOME}/keystore.jks -storepass ${PASSWORD}
      fi
      rm ${GEOSERVER_HOME}/server.crt


  fi

fi


CLUSTER_CONFIG_DIR="${GEOSERVER_DATA_DIR}/cluster/instance_$RANDOMSTRING"
MONITOR_AUDIT_PATH="${GEOSERVER_DATA_DIR}/monitoring/monitor_$RANDOMSTRING"

export GEOSERVER_OPTS="-Djava.awt.headless=true -server -Xms${INITIAL_MEMORY} -Xmx${MAXIMUM_MEMORY} \
       -XX:PerfDataSamplingInterval=500 -Dorg.geotools.referencing.forceXY=true \
       -XX:SoftRefLRUPolicyMSPerMB=36000  -XX:NewRatio=2 \
       -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:ParallelGCThreads=20 -XX:ConcGCThreads=5 \
       -XX:InitiatingHeapOccupancyPercent=70 -XX:+CMSClassUnloadingEnabled \
       -Djts.overlay=ng \
       -Dfile.encoding=${ENCODING} \
       -Duser.timezone=${TIMEZONE} \
       -Djavax.servlet.request.encoding=${CHARACTER_ENCODING} \
       -Djavax.servlet.response.encoding=${CHARACTER_ENCODING} \
       -DCLUSTER_CONFIG_DIR=${CLUSTER_CONFIG_DIR} \
       -DGEOSERVER_DATA_DIR=${GEOSERVER_DATA_DIR} \
       -DGEOSERVER_AUDIT_PATH=${MONITOR_AUDIT_PATH} \
       -Dorg.geotools.shapefile.datetime=true \
       -Ds3.properties.location=${GEOSERVER_DATA_DIR}/s3.properties \
       -Dsun.java2d.renderer.useThreadLocal=false \
       -Dsun.java2d.renderer.pixelsize=8192 -server -XX:NewSize=300m \
       -Dlog4j.configuration=${CATALINA_HOME}/log4j.properties \
       --patch-module java.desktop=${CATALINA_HOME}/marlin-0.9.4.2-Unsafe-OpenJDK9.jar  \
       -Dsun.java2d.renderer=org.marlin.pisces.PiscesRenderingEngine \
       -Dgeoserver.login.autocomplete=${LOGIN_STATUS} \
       -DGEOSERVER_CONSOLE_DISABLED=${WEB_INTERFACE} \
       -DGEOSERVER_CSRF_WHITELIST=${CSRF_WHITELIST} \
       -Dgeoserver.xframe.shouldSetPolicy=${XFRAME_OPTIONS} \
       -Djavax.net.ssl.keyStore=${GEOSERVER_HOME}/keystore.jks \
       -Djavax.net.ssl.keyStorePassword=$PASSWORD "

## Prepare the JVM command line arguments
export JAVA_OPTS="${JAVA_OPTS} ${GEOSERVER_OPTS}"

if ls /geoserver/start.jar >/dev/null 2>&1; then
  cd /geoserver/
  exec java $JAVA_OPTS  -jar start.jar
else
  exec /usr/local/tomcat/bin/catalina.sh run
fi
