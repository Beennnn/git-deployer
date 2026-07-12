ARG BUILD_FROM
FROM $BUILD_FROM

# git + curl : cloner le dépôt + parler à l'API core HA.
# Pas de rsync : on applique fichier par fichier via git (plus sûr + traçable).
RUN apk add --no-cache \
        git \
        curl

COPY root /
RUN chmod a+x /run.sh
ENTRYPOINT [ "/run.sh" ]
