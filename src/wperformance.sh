
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

  < ./ops/values.yaml yq eval '.ingress[].urls' - | sed "s/^- /https:\/\/${POLYMATIC_URL_PREFIX}/g" | tr '\n' ' ' >> ./ops/performance_urls;
done;

if [ ! -s ./ops/performance_urls ]; then
  clog 'there are no URLs to performance test';
  exit 0;
else
  clog "urls being passed to performance ->" && cat ./ops/performance_urls;
  echo;
fi;

# https://www.sitespeed.io/documentation/sitespeed.io/configuration
# get custom sonar flags

PIPE_SITESPEED_FLAGS='-b chrome -n 2 -d 1';
export PIPE_SITESPEED_FLAGS;
if [ -f ./pipeline/options_wperformance.txt ]; then
  PIPE_SITESPEED_FLAGS="${PIPE_SITESPEED_FLAGS} $(cat ./pipeline/options_wperformance.txt)";
fi;

if [ -n "${PIPE_SLACK_TOKEN}" ]; then
  PIPE_SITESPEED_FLAGS="${PIPE_SITESPEED_FLAGS} --slack.hookUrl https://hooks.slack.com/services/${PIPE_SLACK_TOKEN} --slack.type summary"
fi;

# not used:
# --plugins.add /lighthouse --plugins.add /gpsi

mkdir -p "${PWD}/artifacts/wperformance";

clog "running performance test";

/usr/src/app/bin/sitespeed.js --cpu --outputFolder "${PWD}/artifacts/wperformance" \
  --plugins.remove /lighthouse --plugins.remove /gpsi \
  --plugins.list --metrics.list "${PIPE_SITESPEED_FLAGS}" \
  --summary \
  ./ops/performance_urls;

clog "completed performance testing";

POLYMATIC_DOMAIN_NAME="$(< ops/settings.json jq -r '.domain_name')";
export POLYMATIC_DOMAIN_NAME;

clog "you can view results by downloading the artifacts or by visiting https://performance.operations.${POLYMATIC_DOMAIN_NAME}";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} performance -> $(($(date +%s)-POLYMATIC_START)) ;";
