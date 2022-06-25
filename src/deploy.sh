#!/bin/bash

set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START="$(date +%s)";

# this is for envsubst

export DOLLAR="$";

clog "pulling genero helm chart";

helm repo add polymatic https://polymatic-systems.github.io/helm-charts && helm repo update;

if [ -z "${PIPE_CHART_VERSION}" ]; then
  PIPE_CHART_VERSION="$(helm search repo polymatic | grep polymatic | sed 's/\t/ /g' | tr -s ' ' | cut -d' ' -f2)";
fi;

clog "using genero version -> ${PIPE_CHART_VERSION}";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} pull genero chart -> $(($(date +%s)-POLYMATIC_START)) ;";

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
    aux_name="$(printf "%s" "${aux_url}" | cut -d':' -f2 | cut -d'.' -f1 | sed 's/\//-/g')";
    aux_domain="$(printf "%s" "${aux_url}" | cut -d':' -f1 | cut -d'@' -f2)";

    if [ -n "${aux_key}" ]; then
       # private ssh clone
        printf "%s\n  %s\n  %s\n  %s\n  %s\n" "Host ${aux_name}.${aux_domain}" "Hostname ${aux_domain}" "IdentityFile ~/.ssh/${aux_name}_key" "IdentitiesOnly yes" "StrictHostKeyChecking no" >> ~/.ssh/config;
        printf "%s\n" "$(printf "%s" "${aux_key}" | base64 -d)" > ~/.ssh/"${aux_name}_key" && chmod 400 ~/.ssh/"${aux_name}_key";
        aux_url_distinct="$(printf "%s" "${aux_url}" | sed "s/${aux_domain}/${aux_name}.${aux_domain}/g")";
      else
        # public https clone
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

# k8s basic setup

clog "performing basic kubernetes set up";

for POLYMATIC_CURRENT_CLUSTER in ${POLYMATIC_K8S_CLUSTER_NAMES}; do
  export KUBECONFIG="$HOME/.kube/configs/${POLYMATIC_CURRENT_CLUSTER}";
  clog "current cluster -> ${POLYMATIC_CURRENT_CLUSTER}";

  # set cluster specific variables
  POLYMATIC_ENVIRONMENT_TAG="${POLYMATIC_ENVIRONMENT}-$(printf "%s" "${POLYMATIC_CURRENT_CLUSTER}" | rev | cut -d'-' -f1)";
  export POLYMATIC_ENVIRONMENT_TAG;

  # create namespace
  kubectl get ns "${POLYMATIC_K8S_NAMESPACE}" || kubectl create namespace "${POLYMATIC_K8S_NAMESPACE}";

  # create roles
  kubectl delete -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.pipes/manifests/roles/" -n "${POLYMATIC_K8S_NAMESPACE}" > /dev/null 2>&1 || true;
  kubectl apply -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.pipes/manifests/roles/" -n "${POLYMATIC_K8S_NAMESPACE}" > /dev/null 2>&1 || true;
done;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} k8s set up -> $(($(date +%s)-POLYMATIC_START)) ;";

# deploy auxiliary services

POLYMATIC_WATCH="";

export POLYMATIC_SERVICE_URL_LIST="";
for filename in ./"${POLYMATIC_PREDEPLOY}${POLYMATIC_ENVIRONMENT}"/*.env; do
  [ -f "$filename" ] || continue;

  POLYMATIC_START="$(date +%s)";

  clog "processing -> ${filename}";

  POLYMATIC_SERVICE_FILE="${filename#"./${POLYMATIC_PREDEPLOY}${POLYMATIC_ENVIRONMENT}/"}"; 
  export POLYMATIC_SERVICE_FILE="${POLYMATIC_SERVICE_FILE%".env"}";

  POLYMATIC_WATCH="${POLYMATIC_WATCH} ${POLYMATIC_HELM_RELEASE}-${POLYMATIC_SERVICE_FILE}";

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
    export KUBECONFIG="$HOME/.kube/configs/${POLYMATIC_CURRENT_CLUSTER}";
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

    cat "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/default.env.tmp" "${filename}.tmp" > "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/complete.env";

    if [ -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/values.yml" ]; then
      clog "deploying with -> helm";

      POLYMATIC_HELM_REPO_NAME="$(< "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/config.json" jq -r '.helm.repo.name')";
      POLYMATIC_HELM_REPO_URL="$(< "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/config.json" jq -r '.helm.repo.url')";
      POLYMATIC_HELM_CHART_NAME="$(< "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/config.json" jq -r '.helm.chart.name')";
      POLYMATIC_HELM_CHART_VERSION="$(< "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/config.json" jq -r '.helm.chart.version')";

      export POLYMATIC_HELM_REPO_NAME;
      export POLYMATIC_HELM_REPO_URL;
      export POLYMATIC_HELM_CHART_NAME;
      export POLYMATIC_HELM_CHART_VERSION;

      helm repo list | awk '{print $1}' | grep -E "^${POLYMATIC_HELM_REPO_NAME}$" > /dev/null || \
      (helm repo add "${POLYMATIC_HELM_REPO_NAME}" "${POLYMATIC_HELM_REPO_URL}" && helm repo update);

      tempro "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/complete.env" helm upgrade "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_SERVICE_NAME}" "${POLYMATIC_HELM_REPO_NAME}/${POLYMATIC_HELM_CHART_NAME}" \
        --version "${POLYMATIC_HELM_CHART_VERSION}" \
        --install ${PIPE_DEPLOY_FORCE} ${PIPE_DEPLOY_SIMULATE} \
        --namespace "${POLYMATIC_K8S_NAMESPACE}" \
        --values "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/values.yml";
      
      if [ "$?" != "0" ]; then
        export PIPELINE_JOB_FAIL="yes";
      fi;
    elif [ -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/manifests.yml" ]; then
      clog "deploying with -> kubectl";

      tempro "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/complete.env" kubectl apply --namespace "${POLYMATIC_K8S_NAMESPACE}" -f "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/manifests.yml";
    
      if [ "$?" != "0" ]; then
        export PIPELINE_JOB_FAIL="yes";
      fi;
    else
      echo "unknown format for auxiliary service";
      exit 1;
    fi;
  done;

  POLYMATIC_CURRENT_SERVICE_NOTES="$(< "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/config.json" jq -r '.notes')";
  if [ -n "${POLYMATIC_CURRENT_SERVICE_NOTES}" ]; then
    echo "${POLYMATIC_CURRENT_SERVICE_NOTES}";
  fi;

  POLYMATIC_CURRENT_SERVICE_HOST="$(< "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/config.json" jq -r '.service.host')";
  POLYMATIC_CURRENT_SERVICE_PORT="$(< "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.aux/${POLYMATIC_SERVICE_FILE}/config.json" jq -r '.service.port')";
  if [ -n "${POLYMATIC_CURRENT_SERVICE_HOST}" ]; then
    POLYMATIC_SERVICE_URL_LIST="${POLYMATIC_SERVICE_URL_LIST} ${POLYMATIC_SERVICE_URL_PREFIX}-${POLYMATIC_CURRENT_SERVICE_HOST}.${POLYMATIC_K8S_NAMESPACE}.svc:${POLYMATIC_CURRENT_SERVICE_PORT} ;";
    POLYMATIC_CURRENT_SERVICE_HOST_FULL="${POLYMATIC_SERVICE_URL_PREFIX}-${POLYMATIC_CURRENT_SERVICE_HOST}.${POLYMATIC_K8S_NAMESPACE}.svc";

    POLYMATIC_SERVICE_FILE_UPPER="$(echo "$POLYMATIC_SERVICE_FILE" | sed 's/-/_/g' | tr '[:lower:]' '[:upper:]')"
    echo "export AUX_${POLYMATIC_SERVICE_FILE_UPPER}_HOST=${POLYMATIC_CURRENT_SERVICE_HOST_FULL}" > "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/current_svc_url.env";
    echo "export AUX_${POLYMATIC_SERVICE_FILE_UPPER}_PORT=${POLYMATIC_CURRENT_SERVICE_PORT}" >> "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/current_svc_url.env";

    # shellcheck disable=SC1091
    . "${POLYMATIC_ORIGINAL_DIRECTORY}/ops/current_svc_url.env";
  fi;

  POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} ${filename} -> $(($(date +%s)-POLYMATIC_START)) ;";
done;

# helm deploy application

for filename in ./"${POLYMATIC_PREDEPLOY}${POLYMATIC_ENVIRONMENT}"/*.values.y*ml; do
  [ -f "$filename" ] || continue;

  POLYMATIC_START="$(date +%s)";

  clog "processing -> ${filename}";

  POLYMATIC_DEPLOY_NAME=${filename#"./${POLYMATIC_PREDEPLOY}${POLYMATIC_ENVIRONMENT}/"}; 
  POLYMATIC_DEPLOY_NAME="${POLYMATIC_DEPLOY_NAME%".values.yaml"}"; 
  POLYMATIC_DEPLOY_NAME="${POLYMATIC_DEPLOY_NAME%".values.yml"}";

  POLYMATIC_WATCH="${POLYMATIC_WATCH} ${POLYMATIC_HELM_RELEASE}-${POLYMATIC_DEPLOY_NAME}";

  # validate values.yaml file

  if [ "$(< "./${filename}" yq e '. | has("default")' -)" = "true" ]; then
    clog "defining the 'default' section in a values.yml file is not allowed";
    exit 1;
  fi;

  # possibly switch to single clusters

  export POLYMATIC_K8S_DEPLOY_CLUSTERS="${POLYMATIC_K8S_CLUSTER_NAMES}";

  if [ "$(< "./${filename}" yq e '. | has("cronjobs")' -)" = "true" ] || [ "$(< "./${filename}" yq e '.pipe.distinct' -)" = "true" ]; then
    POLYMATIC_K8S_DEPLOY_CLUSTERS="${POLYMATIC_CLUSTER_PRIMARY}";
  fi;

  # deploy

  for POLYMATIC_CURRENT_CLUSTER in ${POLYMATIC_K8S_DEPLOY_CLUSTERS}; do
    KUBECONFIG="$HOME/.kube/configs/${POLYMATIC_CURRENT_CLUSTER}";
    export KUBECONFIG;

    clog "current cluster -> ${POLYMATIC_CURRENT_CLUSTER}";

    # set cluster specific variables
    PIPELINE_CURRENT_CLUSTER_SHORT_NAME="$(printf "${PIPELINE_CURRENT_CLUSTER}" | sed 's/\(.\)[^-]*-*/\1/g')";
    export PIPELINE_CURRENT_CLUSTER_SHORT_NAME;
    POLYMATIC_ENVIRONMENT_TAG="${POLYMATIC_ENVIRONMENT}-$(printf "%s" "${POLYMATIC_CURRENT_CLUSTER}" | rev | cut -d'-' -f1)";
    export POLYMATIC_ENVIRONMENT_TAG;
    export CI_ENVIRONMENT_TAG="${POLYMATIC_ENVIRONMENT_TAG}"; # legacy

    # pull in cluster specific variables if needed
    POLYMATIC_CLUSTER_SPECIFIC_VAR_PATH="infra/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}";
    if vault kv list $POLYMATIC_CLUSTER_SPECIFIC_VAR_PATH | grep ${POLYMATIC_CURRENT_CLUSTER} > /dev/null; then
      clog "found infra env, pulling -> ${POLYMATIC_CLUSTER_SPECIFIC_VAR_PATH}/${POLYMATIC_CURRENT_CLUSTER}";
      vault2env "${POLYMATIC_CLUSTER_SPECIFIC_VAR_PATH}/${POLYMATIC_CURRENT_CLUSTER}" ../ops/vault-${POLYMATIC_CURRENT_CLUSTER}.env > /dev/null;
      cat ../ops/vault-${PIPELINE_CURRENT_CLUSTER}.env | sed 's/=.*//g' | sed 's/^/unset /g' > ../ops/vault-${PIPELINE_CURRENT_CLUSTER}-unset.env;
      set -a && . ../ops/vault-${PIPELINE_CURRENT_CLUSTER}-unset.env && set +a;
      vault2env "${POLYMATIC_CLUSTER_SPECIFIC_VAR_PATH}/${POLYMATIC_CURRENT_CLUSTER}" ../ops/vault-${POLYMATIC_CURRENT_CLUSTER}.env;
      set -a && . ../ops/vault-${PIPELINE_CURRENT_CLUSTER}.env && set +a;
    fi;

    rm -f values.yaml;
    # shellcheck disable=SC2016
    < "${filename}" sed 's/\${/dolllarsign{/g' | sed 's/\$/\${DOLLAR}/g' | sed 's/dolllarsign{/\${/g' | envsubst > values.yaml;

    helm upgrade "${POLYMATIC_HELM_RELEASE}-${POLYMATIC_DEPLOY_NAME}" polymatic/genero --version "${PIPE_CHART_VERSION}" \
      --install ${PIPE_DEPLOY_FORCE} ${PIPE_DEPLOY_SIMULATE} --namespace "${POLYMATIC_K8S_NAMESPACE}" \
      --values ./values.yaml \
      --set default.name="${POLYMATIC_HELM_RELEASE}-${POLYMATIC_DEPLOY_NAME}" \
      --set default.version="${POLYMATIC_GIT_NAME}" \
      --set default.image="${POLYMATIC_K8S_REGISTRY_URL}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}" \
      --set default.slug="${POLYMATIC_GIT_SLUG}" \
      --set default.env="${POLYMATIC_ENVIRONMENT}" \
      --set default.domain="${POLYMATIC_DOMAIN_NAME}" \
      --set default.registries='{registry-private,registry-ops,registry-hub}' \
      --set default.add.logs.json.'co\.elastic\.logs/json\.keys_under_root'='false' \
      --set default.add.metrics.enable.'prometheus\.io/scrape'='true' \
      --set default.add.metrics.enable.'prometheus\.io/port'='5000' \
      --set default.add.metrics.enable.'prometheus\.io/path'='/metrics' \
      --set default.add.metrics.disable.'prometheus\.io/scrape'='false' \
      --set default.add.mesh.enable.'linkerd\.io/inject'='enabled' \
      --set default.add.mesh.enable.'config\.linkerd\.io/skip-outbound-ports'='1-79\,81-8080\,8082-65535' \
      --set default.add.mesh.enable.'config\.alpha\.linkerd\.io/proxy-wait-before-exit-seconds'='80' \
      --set default.add.mesh.disable.'linkerd\.io/inject'='disabled' \
      --set default.add.dns.enable.'external-dns\.io/status'='enabled' \
      --set default.add.dns.disable.'external-dns\.io/status'='disabled';
    
    if [ "$?" != "0" ]; then
      export PIPELINE_JOB_FAIL="yes";
    fi;
  done;

  POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} ${filename} -> $(($(date +%s)-POLYMATIC_START)) ;";
done;

if [ -n "${POLYMATIC_SERVICE_URL_LIST}" ]; then
  clog "The dependencies can be reached at ->" && echo "${POLYMATIC_SERVICE_URL_LIST}" | tr ';' '\n';
fi;

# push to environment branch if needed

if [ "${POLYMATIC_ENVIRONMENT}" != "review" ] && [ -z "${POLYMATIC_PREDEPLOY}" ]; then
  clog "updating branch -> ${POLYMATIC_ENVIRONMENT}";

  POLYMATIC_DEPLOY_KEY_PRIVATE_BASE64="$(< ../ops/settings.json jq -r '.repo_ssh_key_base64')";
  export POLYMATIC_DEPLOY_KEY_PRIVATE_BASE64;
  if [ -n "${POLYMATIC_DEPLOY_KEY_PRIVATE_BASE64}" ]; then
    POLYMATIC_START="$(date +%s)";

    clog "setting up for git tracking";

    printf "%s\n" "$(printf "%s" "${POLYMATIC_DEPLOY_KEY_PRIVATE_BASE64}" | base64 -d)" > ~/.ssh/private_deploy_key && chmod 400 ~/.ssh/private_deploy_key;
    printf "%s\n  %s\n  %s\n  %s\n  %s\n" "Host ${POLYMATIC_GIT_HOST}" "Hostname ${POLYMATIC_GIT_HOST}" "IdentityFile ~/.ssh/private_deploy_key" "IdentitiesOnly yes" "StrictHostKeyChecking no" >> ~/.ssh/config;

    cd "${POLYMATIC_ORIGINAL_DIRECTORY}";
    mkdir -p tracking && cd tracking;
    git config --global init.defaultBranch "${POLYMATIC_ENVIRONMENT}";
    git config --global user.name "pipeline";
    git config --global user.email "pipeline@${POLYMATIC_GIT_HOST}";
    git config pull.rebase true;
    git init;
    git remote add control "git@${POLYMATIC_GIT_HOST}:${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}.git";

    clog "creating git branch if needed and pushing";

    git switch "${POLYMATIC_ENVIRONMENT}" 2>/dev/null || git switch -c "${POLYMATIC_ENVIRONMENT}";
    git pull --quiet control "${POLYMATIC_ENVIRONMENT}" 2>/dev/null || true;

    POLYMATIC_DEPLOY_TIMESTAMP="$(date '+%Y-%m-%d-%H-%M-%S')";
    echo "${POLYMATIC_DEPLOY_TIMESTAMP} ${POLYMATIC_GIT_NAME} ${POLYMATIC_GIT_SHA}";
    echo "${POLYMATIC_DEPLOY_TIMESTAMP} ${POLYMATIC_GIT_NAME} ${POLYMATIC_GIT_SHA}" > new.log;
    mv tracking.log old.log 2>/dev/null || touch old.log;
    cat new.log old.log > tracking.log && rm new.log old.log;

    git add . ;
    git commit --quiet -m "${POLYMATIC_DEPLOY_TIMESTAMP}";
    git push --quiet control "${POLYMATIC_ENVIRONMENT}" || true;

    POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} git deploy tracking -> $(($(date +%s)-POLYMATIC_START)) ;";

    clog "successfully updated branch -> ${POLYMATIC_ENVIRONMENT}";
  else
    clog "skipping branch update -> missing ssh key";
  fi;
fi;

# watch deployment status

POLYMATIC_START="$(date +%s)";

POLYMATIC_DEPLOYMENT_WATCH="";
for line in ${POLYMATIC_WATCH}; do
  is_not_deploy=$(kubectl get deploy -n "${POLYMATIC_K8S_NAMESPACE}" "${line}" 2>&1 | grep 'not found' || true);
  if [ -z "$is_not_deploy" ]; then
    POLYMATIC_DEPLOYMENT_WATCH="${POLYMATIC_DEPLOYMENT_WATCH} ${line}";
  fi;
done;

PIPELINE_DEPLOYMENT_WATCH_ALL="";
for line in ${PIPELINE_DEPLOYMENT_WATCH}; do
  for PIPELINE_CURRENT_CLUSTER in ${PIPELINE_K8S_CLUSTER_NAMES}; do
    PIPELINE_DEPLOYMENT_WATCH_ALL="$PIPELINE_DEPLOYMENT_WATCH_ALL ${PIPELINE_CURRENT_CLUSTER}:$line";
  done;
done;
PIPELINE_DEPLOYMENT_WATCH_ALL="$(printf "${PIPELINE_DEPLOYMENT_WATCH_ALL}" | xargs) ";

if [ -z "$POLYMATIC_DEPLOYMENT_WATCH" ]; then
  clog "no deployments to watch";
else
  clog "watching k8s deployment for rollout status -> ${POLYMATIC_DEPLOYMENT_WATCH}";

  if [ "${POLYMATIC_ENVIRONMENT}" = "review" ]; then
    POLYMATIC_TIMEOUT_LENGTH=1200 # 20 minutes
  else
    POLYMATIC_TIMEOUT_LENGTH=300 # 5 minutes
  fi;
  POLYMATIC_TIMEOUT=$(( $(date +%s) + POLYMATIC_TIMEOUT_LENGTH ));

  POLYMATIC_WATCH_COUNT="$(printf "%s" "$POLYMATIC_DEPLOYMENT_WATCH" | wc -w | xargs)";
  POLYMATIC_CLUSTER_COUNT="$(printf "$POLYMATIC_K8S_CLUSTER_NAMES" | wc -w | xargs)";
  POLYMATIC_WATCH_COUNT=$((POLYMATIC_WATCH_COUNT * POLYMATIC_CLUSTER_COUNT));

  PIPELINE_DEPLOY_INFO_COUNT="9";
  while :; do
    sleep 10;

    for line in ${POLYMATIC_DEPLOYMENT_WATCH}; do
      for POLYMATIC_CURRENT_CLUSTER in ${POLYMATIC_K8S_CLUSTER_NAMES}; do
        KUBECONFIG="$HOME/.kube/configs/${POLYMATIC_CURRENT_CLUSTER}";
        export KUBECONFIG;

        clog "current cluster -> ${POLYMATIC_CURRENT_CLUSTER}";

        updated=$(kubectl get deploy -n "${POLYMATIC_K8S_NAMESPACE}" "$line" -o jsonpath='{.status.updatedReplicas}');
        replicas=$(kubectl get deploy -n "${POLYMATIC_K8S_NAMESPACE}" "$line" -o jsonpath='{.status.replicas}');
        stati=$(kubectl get pods -n "${POLYMATIC_K8S_NAMESPACE}" | grep "$line" | tr -s ' ' | cut -d' ' -f3 | (grep -v Running || true) | (grep -v Terminating || true) | (grep -v Init || true) | (grep -v ContainerCreating || true) | tr '\n' '|');

        # less than 20% of the pods have been updated, consider this deployment a failure
        if [ $(date +%s) -gt $PIPELINE_TIMEOUT ] && [ "$((replicas / updated))" -ge "5" ]; then
          clog "it appears a deployment has failed, printing the current status of your pods -> ";
          for sline in ${POLYMATIC_DEPLOYMENT_WATCH}; do
            kubectl get pods -n "${POLYMATIC_K8S_NAMESPACE}" | grep "$sline";
          done;
          exit 1;
        fi;

        echo "deployment status -> $line $updated/$replicas $stati";

        if [ "$updated" = "$replicas" ]; then
          echo "######## complete -> $line";
          PIPELINE_DEPLOYMENT_WATCH_ALL="$(printf "$PIPELINE_DEPLOYMENT_WATCH_ALL" | sed "s/$PIPELINE_CURRENT_CLUSTER:$line//" | tr -s ' ')";
          if [ "$(printf "$PIPELINE_DEPLOYMENT_WATCH_ALL" | grep $line)" = "" ]; then
            PIPELINE_DEPLOYMENT_WATCH="$(printf "$PIPELINE_DEPLOYMENT_WATCH" | sed "s/$line//" | tr -s ' ')";
          fi;
          POLYMATIC_WATCH_COUNT=$((POLYMATIC_WATCH_COUNT - 1));
        fi;
      done;
    done;

    PIPELINE_DEPLOY_INFO_COUNT="$((PIPELINE_DEPLOY_INFO_COUNT - 1))";
    if [ "${PIPELINE_DEPLOY_INFO_COUNT}" -le "0" ]; then
      clog "remaining cluster/deployment to watch -> ${POLYMATIC_WATCH_COUNT}";
      echo "---------------------------------------------";
      echo "$PIPELINE_DEPLOYMENT_WATCH_ALL" | sed 's/:/\//g' | tr ' ' '\n';
      echo "---------------------------------------------";
      PIPELINE_DEPLOY_INFO_COUNT="9";
    fi;

    if [ "${POLYMATIC_WATCH_COUNT}" -lt "1" ]; then
      break;
    fi;
  done;
fi;

clog "deployment complete";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} deployment watch -> $(($(date +%s)-POLYMATIC_START)) ;";

if [ -n "${PIPE_SLACK_TOKEN}" ]; then
  clog "sending slack message";

  ${PIPE_SLACK_ENVIRONMENTS:=production};
  if [ "$PIPE_SLACK_ENVIRONMENTS" != "${PIPE_SLACK_ENVIRONMENTS/${POLYMATIC_ENVIRONMENT}/}" ]; then
    curl -X POST -H 'Content-Type: application/json' -d "{\"text\":\"deployment -> ${POLYMATIC_ENVIRONMENT} ${POLYMATIC_PROJECT_NAME}\"}" "https://hooks.slack.com/services/${PIPE_SLACK_TOKEN}";
  fi;
fi;

# go back to root of repo so other scripts can find directories

cd ..;
