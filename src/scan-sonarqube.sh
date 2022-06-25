
# run this in image -> sonarsource/sonar-scanner-cli:4.6

set -e

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START=$(date +%s);

POLYMATIC_SONAR_TOKEN=$(< ops/settings.json jq -r '.sonar_token');

# get custom sonar flags

PIPE_SONAR_FLAGS="";
export PIPE_SONAR_FLAGS;
if [ -f ./pipeline/options_scan_sonarqube.txt ]; then
  PIPE_SONAR_FLAGS="$(cat ./pipeline/options_scan_sonarqube.txt)";
fi;

# view files in ops directory

clog "running sonar scanner";

PIPE_SONAR_OPTIONAL_FLAGS="";
export PIPE_SONAR_OPTIONAL_FLAGS;
if [ -n "${POLYMATIC_GIT_USER}" ] && [ -n "${POLYMATIC_GIT_PASS}" ]; then
  PIPE_SONAR_OPTIONAL_FLAGS="${PIPE_SONAR_OPTIONAL_FLAGS} -Dsonar.svn.username='${POLYMATIC_GIT_USER}' -Dsonar.svn.password.secured='${POLYMATIC_GIT_PASS}' ";
fi;

POLYMATIC_DOMAIN_NAME="$(< ops/settings.json jq -r '.domain_name')";
export POLYMATIC_DOMAIN_NAME;

sonar-scanner \
  -Dsonar.projectKey="${POLYMATIC_PROJECT_NAMESPACE}:${POLYMATIC_PROJECT_NAME}" \
  -Dsonar.projectName="${POLYMATIC_PROJECT_NAMESPACE}:${POLYMATIC_PROJECT_NAME}" \
  -Dsonar.projectVersion="${POLYMATIC_GIT_NAME}" \
  -Dsonar.sources=src \
  -Dsonar.host.url="https://sonarqube.operations.${POLYMATIC_DOMAIN_NAME}" \
  -Dsonar.login="${POLYMATIC_SONAR_TOKEN}" \
  -Dsonar.branch.name="${POLYMATIC_GIT_NAME} ${PIPE_SONAR_OPTIONAL_FLAGS} ${PIPE_SONAR_FLAGS}";

clog 'view the results by clicking the SonarQube link above'

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} scan -> $(($(date +%s) - POLYMATIC_START)) ;"
