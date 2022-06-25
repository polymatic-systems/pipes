
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START=$(date +%s);

# operations

POLYMATIC_DOMAIN_NAME="$(< ops/settings.json jq -r '.domain_name')";
export POLYMATIC_DOMAIN_NAME;

if [[ -n "${POLYMATIC_REGISTRY_URL}" ]]; then
  export POLYMATIC_K8S_REGISTRY_URL="${POLYMATIC_REGISTRY_URL}";
else
  export POLYMATIC_K8S_REGISTRY_URL="registry.operations.${POLYMATIC_DOMAIN_NAME}";
fi;

# login to the registry

POLYMATIC_K8S_REGISTRY_USER=$(< ops/settings.json jq -r '.registry_user_base64' | base64 -d);
POLYMATIC_K8S_REGISTRY_PASSWORD=$(< ops/settings.json jq -r '.registry_password_base64' | base64 -d);

# get images

mkdir -p "${PWD}/ops/images";
for filename in ./build/*Dockerfile; do
  [ -f "$filename" ] || continue;
  sname=${filename#"./build/"};
  rname=${sname%"Dockerfile"};
  if [[ -n "$rname" ]]; then
    rname="-$(printf "%s" "${rname%"."}" | tr '.' '-')"
  fi;
  clog "pulling -> ${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}${rname}";
  POLYMATIC_START="$(date +%s)";
  skopeo copy --src-creds="${POLYMATIC_K8S_REGISTRY_USER}:${POLYMATIC_K8S_REGISTRY_PASSWORD}" "docker://${POLYMATIC_K8S_REGISTRY_URL}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}${rname}" "oci://${PWD}/ops/images/${POLYMATIC_PROJECT_NAME}-${POLYMATIC_GIT_NAME}${rname}";
  POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} image pull ${POLYMATIC_K8S_REGISTRY_URL}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}${rname} -> $(($(date +%s)-POLYMATIC_START)) ;";
done;

# run trivy

mkdir -p ./artifacts/scanner;

if ! command -v trivy > /dev/null; then
  clog "installing trivy";
  mkdir -p /contrib;
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/v0.19.2/contrib/install.sh | sh -s -- -b /usr/local/bin v0.19.2;
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/html.tpl -o /contrib/html.tpl
fi;

POLYMATIC_START="$(date +%s)";

for filename in ./build/*Dockerfile; do
  [ -f "$filename" ] || continue;
  sname=${filename#"./build/"};
  rname=${sname%"Dockerfile"};
  if [[ -n "$rname" ]]; then
    rname="-$(printf "%s" "${rname%"."}" | tr '.' '-')"
  fi;

  clog "running trivy container scan on -> ${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}${rname}";

  trivy --quiet client --format template --template "@/contrib/html.tpl" -o "./artifacts/scanner/client-${POLYMATIC_GIT_NAME}${rname}-report.html" --remote "https://scanner.operations.${POLYMATIC_DOMAIN_NAME}" --exit-code 0 --input "${PWD}/ops/images/${POLYMATIC_PROJECT_NAME}-${POLYMATIC_GIT_NAME}${rname}";

  POLYMATIC_CVE_HIGH="${POLYMATIC_CVE_HIGH}
$(trivy --quiet client --remote "https://scanner.operations.${POLYMATIC_DOMAIN_NAME}" --exit-code 0 --severity 'UNKNOWN,LOW,MEDIUM,HIGH' --format json --input "${PWD}/ops/images/${POLYMATIC_PROJECT_NAME}-${POLYMATIC_GIT_NAME}${rname}" \
    | jq -r '.[] | .Target as $target | .Vulnerabilities[]? | "TARGET     \($target)@ID         \(.VulnerabilityID)@SEVERITY   \(.Severity)@RESOLUTION Upgrade \(.PkgName) from \(.InstalledVersion) to \(.FixedVersion)@MORE INFO  \(.PrimaryURL)"' \
    | awk -F '@' '{ printf("%s\n%s\n%s\n%s\n%s\n---\n", $1, $2, $3, $4, $5) }')";

  POLYMATIC_CVE_CRITICAL="${POLYMATIC_CVE_CRITICAL}
$(trivy --quiet client --remote "https://scanner.operations.${POLYMATIC_DOMAIN_NAME}" --exit-code 0 --severity 'CRITICAL' --format json --input "${PWD}/ops/images/${POLYMATIC_PROJECT_NAME}-${POLYMATIC_GIT_NAME}${rname}" \
    | jq -r '.[] | .Target as $target | .Vulnerabilities[]? | "TARGET     \($target)@ID         \(.VulnerabilityID)@SEVERITY   \(.Severity)@RESOLUTION Upgrade \(.PkgName) from \(.InstalledVersion) to \(.FixedVersion)@MORE INFO  \(.PrimaryURL)"' \
    | awk -F '@' '{ printf("%s\n%s\n%s\n%s\n%s\n---\n", $1, $2, $3, $4, $5) }')";
done;

clog "running trivy config check on ./build directory ";

  trivy --quiet config --format template --template "@/contrib/html.tpl" -o ./artifacts/scanner/config-report.html ./build;

  POLYMATIC_CVE_HIGH="${POLYMATIC_CVE_HIGH}
$(trivy --quiet config --format json --severity 'UNKNOWN,LOW,MEDIUM,HIGH' ./build \
  | jq -r '.[] | .Target as $target | .Misconfigurations[]? | "TARGET     \($target)@SEVERITY   \(.Severity)@ID         \(.ID)@RESOLUTION \(.Resolution)@MORE INFO  \(.PrimaryURL)"' \
  | awk -F '@' '{ printf("%s\n%s\n%s\n%s\n%s\n---\n", $1, $2, $3, $4, $5) }')";

  POLYMATIC_CVE_CRITICAL="${POLYMATIC_CVE_CRITICAL}
$(trivy --quiet config --format json --severity 'CRITICAL' ./build \
  | jq -r '.[] | .Target as $target | .Misconfigurations[]? | "TARGET     \($target)@SEVERITY   \(.Severity)@ID         \(.ID)@RESOLUTION \(.Resolution)@MORE INFO  \(.PrimaryURL)"' \
  | awk -F '@' '{ printf("%s\n%s\n%s\n%s\n%s\n---\n", $1, $2, $3, $4, $5) }')";

clog "trivy scan results -> ###################################### NON-CRITICAL";

echo "${POLYMATIC_CVE_HIGH}";

clog "trivy scan results -> ###################################### CRITICAL";

echo "${POLYMATIC_CVE_CRITICAL}";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} scan -> $(($(date +%s) - POLYMATIC_START)) ;"

POLYMATIC_CRITICAL_COUNT="$(printf "%s" "${POLYMATIC_CVE_CRITICAL}" | (grep CRITICAL || true) | wc -l | xargs)";

clog "critical count -> ${POLYMATIC_CRITICAL_COUNT}";

if [ "${POLYMATIC_CRITICAL_COUNT}" -gt 0 ]; then
  echo "this job only fails if critical issues are found, this job has been marked as fail";
  export POLYMATIC_JOB_FAIL="yes";
else
  echo "no critical issues found, job marked as success";
fi;
