#!/bin/bash

set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START="$(date +%s)";

cd deploy;

POLYMATIC_AUX_URL="$(< ../ops/settings.json jq -r '.aux_url')";
POLYMATIC_AUX_DEPLOY_KEY="$(< ../ops/settings.json jq -r '.aux_deploy_key' | grep -v null)";
POLYMATIC_AUX_VERSION="$(< ../ops/settings.json jq -r '.aux_version' | grep -v null)";

export POLYMATIC_AUX_URL;
export POLYMATIC_AUX_DEPLOY_KEY;
export POLYMATIC_AUX_VERSION;

rm -rf "${POLYMATIC_ORIGINAL_DIRECTORY}"/ops/.aux/* && mkdir -p "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux";
if [ "${POLYMATIC_AUX_URL}" ]; then
  count="0";
  for aux_url in $(printf "%s" "${POLYMATIC_AUX_URL}" | tr ',' ' '); do
    count="$((count + 1))";
    aux_key="$(printf "%s" "${POLYMATIC_AUX_DEPLOY_KEY}" | cut -d',' -f$count)";
    aux_name="$(printf "%s" "${aux_url}" | cut -d':' -f2 | cut -d'.' -f1 | sed 's/\//-/g')"
    aux_domain="$(printf "%s" "${aux_url}" | cut -d':' -f1 | cut -d'@' -f2)"

    if [ -n "${aux_key}" ]; then
        printf "%s\n  %s\n  %s\n  %s\n  %s\n" "Host ${aux_name}.${aux_domain}" "Hostname ${aux_domain}" "IdentityFile ~/.ssh/${aux_name}_key" "IdentitiesOnly yes" "StrictHostKeyChecking no" >> ~/.ssh/config;
        printf "%s\n" "$(printf "%s" "${aux_key}" | base64 -d)" > ~/.ssh/"${aux_name}_key" && chmod 400 ~/.ssh/"${aux_name}_key";
        aux_url_distinct="$(printf "%s" "${aux_url}" | sed "s/${aux_domain}/${aux_name}.${aux_domain}/g")";
      else
        aux_url_distinct="${aux_url}";
    fi;

    clog "checking -> ${aux_url_distinct}";

    aux_grep_version="$(printf "%s" "${POLYMATIC_AUX_VERSION}" | cut -d',' -f$count)";
    if [ -n "$aux_grep_version" ]; then
        aux_version="v$(git ls-remote --tags "${aux_url_distinct}" | cut -d'/' -f3 | tr -d 'v' | grep -E "^${aux_grep_version}\." | sort -V | sed '1!G;h;$!d' | head -n1)";
      else
        aux_version="v$(git ls-remote --tags "${aux_url_distinct}" | cut -d'/' -f3 | tr -d 'v' | sort -V | sed '1!G;h;$!d' | head -n1)";
    fi;

    if [ "$aux_version" = "v" ]; then
      echo "could not determine auxiliary version";
      exit 1;
    fi;

    clog "fetching auxiliaries -> ${aux_version}";

    git clone --depth 1 --branch "${aux_version}" "${aux_url_distinct}" "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.tmp" || exit 1;
    cp -rf "${POLYMATIC_ORIGINAL_DIRECTORY}"/ops/.tmp/src/* "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/" && rm -rf mv "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.tmp";
  done;
fi;

# shellcheck disable=SC2012
clog "available auxiliaries..." && ls -1 "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux" | sed 's/.env//g' | rev | cut -d'/' -f1 | rev;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} pull auxiliaries -> $(($(date +%s)-POLYMATIC_START)) ;";

POLYMATIC_START="$(date +%s)";

# uninstall auxiliaries

for filename in ./{pre,}"${POLYMATIC_ENVIRONMENT}"/*.env; do
  [ -f "$filename" ] || continue;

  POLYMATIC_START="$(date +%s)";

  clog "processing -> ${filename}";

  POLYMATIC_SERVICE_FILE="${filename#"./${POLYMATIC_ENVIRONMENT}/"}"; 
  POLYMATIC_SERVICE_FILE="${POLYMATIC_SERVICE_FILE%".env"}";
  export POLYMATIC_SERVICE_FILE;

  if [ ! -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/default.env" ]; then
    clog "${POLYMATIC_SERVICE_FILE} auxiliary file not found, contact your administrator for support";
    exit 1;
  fi;

  POLYMATIC_SERVICE_NAME=$(echo "${POLYMATIC_SERVICE_FILE}" | rev | cut -d'-' -f2- | rev);
  export POLYMATIC_SERVICE_NAME;

  TEMPRO_SILENT='yes';
  TEMPRO_AUTO_APPROVE='yes';

  export TEMPRO_SILENT;
  export TEMPRO_AUTO_APPROVE;

  for POLYMATIC_CURRENT_CLUSTER in ${POLYMATIC_K8S_CLUSTER_NAMES}; do
    KUBECONFIG="$HOME/.kube/configs/${POLYMATIC_CURRENT_CLUSTER}";
    export KUBECONFIG;

    clog "current cluster -> ${POLYMATIC_CURRENT_CLUSTER}";

    # set cluster specific variables
    POLYMATIC_ENVIRONMENT_TAG="${POLYMATIC_ENVIRONMENT}-$(printf "%s" "${POLYMATIC_CURRENT_CLUSTER}" | rev | cut -d'-' -f1)";
    export POLYMATIC_ENVIRONMENT_TAG;

    # set variables for aux
    AUX_SERVICE_URL="${POLYMATIC_ENVIRONMENT_TAG}.${POLYMATIC_DOMAIN_NAME}";
    AUX_SERVICE_RELEASE="${POLYMATIC_HELM_RELEASE}-${POLYMATIC_SERVICE_NAME}";
    AUX_PREFIX="${POLYMATIC_GIT_SLUG}";
    AUX_VERSION="${POLYMATIC_GIT_NAME}";

    export AUX_SERVICE_URL;
    export AUX_SERVICE_RELEASE;
    export AUX_PREFIX;
    export AUX_VERSION;

    # shellcheck disable=SC2016
    < "${filename}" sed 's/\${/dolllarsign{/g' | sed 's/\$/\${DOLLAR}/g' | sed 's/dolllarsign{/\${/g' | envsubst > "${filename}.tmp";

    # shellcheck disable=SC2016
    < "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/default.env" sed 's/\${/dolllarsign{/g' | sed 's/\$/\${DOLLAR}/g' | sed 's/dolllarsign{/\${/g' | envsubst > "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/default.env.tmp";

    cat "${filename}.tmp" "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/default.env.tmp" > "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/complete.env";

    if [ -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/manifests.yml" ]; then
      clog "removing with -> kubectl";
      tempro "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/complete.env" kubectl delete --namespace "${POLYMATIC_K8S_NAMESPACE}" -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/manifests.yml";
    elif [ -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/values.yml" ]; then
      clog "removing with -> helm";

      # skip helm releases that are already uninstalled
      if ! helm status "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_SERVICE_NAME}" -n "${POLYMATIC_K8S_NAMESPACE}" > /dev/null 2>&1; then
        echo 'release is already uninstalled';
        continue;
      fi;

      # collect pvc names on review environment
      if [ "$POLYMATIC_ENVIRONMENT" = "review" ]; then
        stspvc="";
        statefulsets="$(helm get manifest "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_SERVICE_NAME}" -n "${POLYMATIC_K8S_NAMESPACE}" | (kubectl get -n "${POLYMATIC_K8S_NAMESPACE}" -f - 2>/dev/null || true) | (grep statefulset.apps || true) | cut -d' ' -f1 | cut -d'/' -f2 | tr '\n' ' ')";
        for sts in $statefulsets; do
          if [ -z "$sts" ]; then continue; fi;
          clog "getting labels from sts -> '${sts}'";
          label="$(kubectl get sts -n "${POLYMATIC_K8S_NAMESPACE}" "${sts}" -o json | jq -r '.spec.selector.matchLabels | to_entries[] | "\(.key)=\(.value)"' | sed -n '1{p;q}')";
          if [ -z "$label" ]; then continue; fi;
          clog "getting pvc from label -> ${label}";
          stspvc="${stspvc} $( (kubectl get pvc -n "${POLYMATIC_K8S_NAMESPACE}" -l "${label}" 2>/dev/null || true) | sed -n '2{p;q}' | cut -d' ' -f1)";
        done;
      fi;

      helm uninstall "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_SERVICE_NAME}" --namespace "${POLYMATIC_K8S_NAMESPACE}";

      # remove pvc on review environment (other clusters must remove their pvc manually)
      if [ "$POLYMATIC_ENVIRONMENT" = "review" ]; then
        for pvc in $stspvc; do
          if [ -z "${pvc// }" ]; then continue; fi;
          clog "deleting sts pvc -> ${pvc}";
          kubectl delete pvc -n "${POLYMATIC_K8S_NAMESPACE}" "${pvc}";
        done;
      fi;
    else
      echo 'unknown release method, contact your administrator';
      exit 1;
    fi;
  done;

  POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} ${filename} -> $(($(date +%s)-POLYMATIC_START)) ;";
done;

# uninstall applications

for filename in ./{pre,}"${POLYMATIC_ENVIRONMENT}"/*.values.y*ml; do
  [ -f "$filename" ] || continue;

  POLYMATIC_START="$(date +%s)";

  clog "processing -> ${filename}";

  POLYMATIC_DEPLOY_NAME=${filename#"./${POLYMATIC_ENVIRONMENT}/"};
  POLYMATIC_DEPLOY_NAME="${POLYMATIC_DEPLOY_NAME%".values.yaml"}"; 
  POLYMATIC_DEPLOY_NAME="${POLYMATIC_DEPLOY_NAME%".values.yml"}";

  for POLYMATIC_CURRENT_CLUSTER in ${POLYMATIC_K8S_CLUSTER_NAMES}; do
    KUBECONFIG="$HOME/.kube/configs/${POLYMATIC_CURRENT_CLUSTER}";
    export  KUBECONFIG;

    clog "current cluster -> ${POLYMATIC_CURRENT_CLUSTER}";

    if helm status "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_DEPLOY_NAME}" -n "${POLYMATIC_K8S_NAMESPACE}" > /dev/null 2>&1; then
      if [ "$POLYMATIC_ENVIRONMENT" = "review" ]; then
        stspvc="";
        statefulsets="$(helm get manifest "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_DEPLOY_NAME}" -n "${POLYMATIC_K8S_NAMESPACE}" | (kubectl get -n "${POLYMATIC_K8S_NAMESPACE}" -f - 2>/dev/null || true) | (grep statefulset.apps || true) | cut -d' ' -f1 | cut -d'/' -f2 | tr '\n' ' ')";
        for sts in $statefulsets; do
          if [ -z "$sts" ]; then continue; fi;
          clog "getting labels from sts -> ${sts}";
          label="$(kubectl get sts -n "${POLYMATIC_K8S_NAMESPACE}" "${sts}" -o json | jq -r '.spec.selector.matchLabels | to_entries[] | "\(.key)=\(.value)"' | sed -n '1{p;q}')";
          if [ -z "$label" ]; then continue; fi;
          clog "getting pvc from label -> ${label}";
          stspvc="${stspvc} $( (kubectl get pvc -n "${POLYMATIC_K8S_NAMESPACE}" -l "${label}" 2>/dev/null || true) | sed -n '2{p;q}' | cut -d' ' -f1)";
        done;
      fi;
      helm uninstall "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_DEPLOY_NAME}" --namespace "${POLYMATIC_K8S_NAMESPACE}";
      if [ "$POLYMATIC_ENVIRONMENT" = "review" ]; then
        for pvc in $stspvc; do
          if [ -z "${pvc// }" ]; then continue; fi;
          clog "deleting sts pvc -> ${pvc}";
          kubectl delete pvc -n "${POLYMATIC_K8S_NAMESPACE}" "${pvc}";
        done;
      fi;
    else
      echo 'release is already uninstalled';
    fi;

  done;

  POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} ${filename} -> $(($(date +%s)-POLYMATIC_START)) ;";
done;
