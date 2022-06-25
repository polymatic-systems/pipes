
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START=$(date +%s);

export POLYMATIC_URL_PREFIX="";
if [ "${POLYMATIC_ENVIRONMENT}" = "review" ]; then
  POLYMATIC_URL_PREFIX="${POLYMATIC_GIT_SLUG}-";
fi;

for filename in ./deploy/*"${POLYMATIC_ENVIRONMENT}"/*.values.y*ml; do
  [ -f "$filename" ] || continue;

  clog "scanning -> ${filename}";

  # shellcheck disable=SC2016
  < "${filename}" sed 's/\${/dolllarsign{/g' | sed 's/\$/\${DOLLAR}/g' | sed 's/dolllarsign{/\${/g' | envsubst > ops/values.yaml;

  < ./ops/values.yaml yq eval '.ingress[].urls' - | sed "s/^- /${POLYMATIC_URL_PREFIX}/g" | tr '\n' ' ' >> ./ops/security_urls;
done;

if [ ! -s ./ops/security_urls ]; then
  clog 'there are no URLs to security test';
  exit 0;
else
  clog "urls being passed to security ->" && cat ./ops/security_urls;
  echo;
fi;

# https://github.com/Grunny/zap-cli
# get custom zap flags

PIPE_ZAP_FLAGS='';
export PIPE_ZAP_FLAGS;
if [ -f ./pipeline/options_security.txt ]; then
  PIPE_ZAP_FLAGS="${PIPE_ZAP_FLAGS} $(cat ./pipeline/options_security.txt)";
fi;

mkdir -p /zap/wrk;

# shellcheck disable=SC2013
for url in $(cat ./ops/security_urls); do
  clog "running security test on -> ${url}";
  mkdir -p "/zap/wrk/$url";
  zap-baseline.py "${PIPE_ZAP_FLAGS}" -I -m 5 -s \
    -r "$url/report.html" \
    -t "https://$url";
  sleep 10;
done;

mkdir -p ./artifacts/security;
cp -R /zap/wrk/* ./artifacts/security/;

clog "completed security testing";
clog "you can view the results above or by downloading the artifacts";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} security -> $(($(date +%s)-POLYMATIC_START)) ;";
