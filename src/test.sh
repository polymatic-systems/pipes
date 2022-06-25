
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START="$(date +%s)";

# export the postgres url

export DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${DB_HOST}:5432/${POSTGRES_DB}"

# copy repo into directory for herokuish

cp -R ./src /tmp/app

# run magical auto-tester

/bin/herokuish buildpack test

# https://github.com/gliderlabs/herokuish#paths
if [ -f /app/reports/report.xml ]; then
  cp -r /app/reports/report.xml ops/test/report.xml;
fi;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} test -> $(($(date +%s)-POLYMATIC_START)) ;";
