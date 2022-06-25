
# set pipeline needed vars

clog () { echo -e "\033[0;35m PIPELOG ${1} \033[0m"; };
cex () { if command -v $1 > /dev/null 2>&1; then return 1; fi; }
clog 'setup -> variables';

if [ "${GITLAB_CI}" = "true" ]; then
  # mandatory
  export POLYMATIC_VERSION='1';
  export POLYMATIC_PROJECT_NAME="${CI_PROJECT_NAME}";
  export POLYMATIC_PROJECT_NAMESPACE="${CI_PROJECT_NAMESPACE}";
  export POLYMATIC_GIT_TAG="${CI_COMMIT_TAG}";
  export POLYMATIC_GIT_SHA="${CI_COMMIT_SHA}";
  export POLYMATIC_GIT_NAME="${CI_COMMIT_REF_NAME}";
  export POLYMATIC_GIT_SLUG="${CI_COMMIT_REF_SLUG}";
  export POLYMATIC_JOB_NAME="${CI_JOB_NAME}";
  export POLYMATIC_SCRIPT_NAME="${POLYMATIC_SCRIPT_NAME:-$POLYMATIC_JOB_NAME}";
  export POLYMATIC_PIPELINE_ID="${CI_PIPELINE_IID}";
  export POLYMATIC_GIT_HOST="${CI_SERVER_HOST}";
  export POLYMATIC_ORIGINAL_DIRECTORY="${CI_PROJECT_DIR}";
  # extras
  export POLYMATIC_VAULT_TOKEN="${VAULT_TOKEN_BASE64}";
  export POLYMATIC_VAULT_JWT="${CI_JOB_JWT}";
  export POLYMATIC_GIT_USER="gitlab-ci-token";
  export POLYMATIC_GIT_PASS="${CI_JOB_TOKEN}";
elif [ -n "${GITHUB_ACTION}" ]; then
  # mandatory
  export POLYMATIC_VERSION='1';
  export POLYMATIC_PROJECT_NAME="$(printf "%s" "${GITHUB_REPOSITORY}" | cut -d'/' -f2)";
  export POLYMATIC_PROJECT_NAMESPACE="${GITHUB_REPOSITORY_OWNER}";
  if [ "${GITHUB_REF_TYPE}" = "tag" ]; then
    export POLYMATIC_GIT_TAG="${GITHUB_REF_NAME}";
  else
    export POLYMATIC_GIT_TAG="";
  fi;
  export POLYMATIC_GIT_SHA="${GITHUB_SHA}";
  export POLYMATIC_GIT_NAME="${GITHUB_REF_NAME}";
  export POLYMATIC_GIT_SLUG="$(printf "%s" "${GITHUB_REF_NAME}" | tr '[:upper:]' '[:lower:]' | xargs printf '%.63s' | sed 's/[^0-9a-z]/-/g' )";
  export POLYMATIC_JOB_NAME="${GITHUB_JOB}";
  export POLYMATIC_SCRIPT_NAME="${POLYMATIC_JOB_NAME}";
  export POLYMATIC_PIPELINE_ID="${GITHUB_RUN_ID}-${GITHUB_RUN_NUMBER}";
  export POLYMATIC_GIT_HOST="${GITHUB_SERVER_URL}";
  export POLYMATIC_ORIGINAL_DIRECTORY="${GITHUB_WORKSPACE}";
  # vault
  export POLYMATIC_VAULT_TOKEN="${{ secrets.VAULT_TOKEN_BASE64 }}";
  export POLYMATIC_VAULT_JWT="";
else
  clog "unknown pipeline, not supported, must be gitlab or github.";
  exit 1;
fi;

# install any needed binaries

clog 'setup -> install';

POLYMATIC_START=`date +%s`;

if [[ "${POLYMATIC_CERTIFIED_IMAGE}" = "yes" ]]; then
  clog "certified image detected";
elif [[ $(command -v apt) ]]; then
  if [ "$(apt list --installed bsdmainutils curl git jq unzip wget zip 2>/dev/null | tail -n +2 | wc -l)" -ne "7" ]; then
    clog 'missing dependencies, installing with apt package manager';
    apt -qq update && apt install -qqy bsdmainutils curl git jq unzip wget zip;
  fi;
elif [[ $(command -v apk) ]]; then
  if [ "$(apk info curl git jq unzip wget zip 2>/dev/null | grep description | wc -l)" -ne "7" ]; then
    clog 'missing dependencies, installing with apk package manager';
    apk update && apk add curl git jq unzip wget zip;
  fi;
else
  clog 'unknown os package manager, must be apt or apk';
  exit 1;
fi;

if cex vault; then 
  clog 'missing vault, installing ...';
  wget -q https://releases.hashicorp.com/vault/1.8.11/vault_1.8.11_linux_amd64.zip \
    && unzip -q vault_1.8.11_linux_amd64.zip \
    && mv -f vault /bin/vault \
    && rm -f vault_1.8.11_linux_amd64.zip;
fi;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} install -> $((`date +%s`-POLYMATIC_START)) ;";

# clone the repo

clog 'setup -> clone';

POLYMATIC_START=$(date +%s);

# git clone, if branch no longer exists (assume merged) and pull master|main instead
export POLYMATIC_BRANCH_EXISTS=$(git ls-remote --heads ${POLYMATIC_REPOSITORY_URL} ${POLYMATIC_GIT_NAME} | wc -l | tr -d ' ');

echo "${POLYMATIC_BRANCH_EXISTS}";

ls -la;
if [ "$POLYMATIC_BRANCH_EXISTS" -eq "1" ]; then
  clog "branch still exists, cloning -> ${POLYMATIC_GIT_NAME}";
  git clone -b ${POLYMATIC_GIT_NAME} --single-branch ${POLYMATIC_REPOSITORY_URL} . 2>/dev/null || true;
else
  if [ "$(git ls-remote --heads ${POLYMATIC_REPOSITORY_URL} master | wc -l | tr -d ' ')" -eq "1" ]; then
    clog "branch no longer exists, cloning -> master";
    git clone -b master --single-branch ${POLYMATIC_REPOSITORY_URL} . 2>/dev/null || true;
  elif [ "$(git ls-remote --heads ${POLYMATIC_REPOSITORY_URL} main | wc -l | tr -d ' ')" -eq "1" ]; then
    clog "branch no longer exists, cloning -> main";
    git clone -b main --single-branch ${POLYMATIC_REPOSITORY_URL} . 2>/dev/null || true;
  else
    clog "branch no longer exists, could not find master or main branch, cannot clone anything.";
    exit 1;
  fi;
fi;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} clone -> $(($(date +%s) - POLYMATIC_START)) ;"

# general pipeline preparation

clog 'setup -> prepare';
mkdir -p ops artifacts;

# determine environment

clog 'setup -> environment';

if [[ -n "$PIPE_DEPLOY_OPERATIONS" ]]; then
  export POLYMATIC_ENVIRONMENT="operations";
elif ([[ "$POLYMATIC_GIT_NAME" == "master" ]] || [[ "$POLYMATIC_GIT_NAME" == "main" ]]) && [[ -z "$POLYMATIC_GIT_TAG" ]]; then
  export POLYMATIC_ENVIRONMENT="staging";
elif [[ "$POLYMATIC_GIT_NAME" != "master" ]] && [[ "$POLYMATIC_GIT_NAME" != "main" ]] && [[ -z "$POLYMATIC_GIT_TAG" ]]; then
  if [[ -n "$PIPE_DEPLOY_STAGING" ]]; then
    export POLYMATIC_ENVIRONMENT="staging";
  else
    export POLYMATIC_ENVIRONMENT="review";
  fi;
elif [[ -n "$POLYMATIC_GIT_TAG" ]]; then
  if [[ -n "$(echo ${POLYMATIC_JOB_NAME} | grep integrations)" ]]; then
    export POLYMATIC_ENVIRONMENT="integrations";
  elif [[ -n "$(echo ${POLYMATIC_JOB_NAME} | grep staging)" ]]; then
    export POLYMATIC_ENVIRONMENT="staging";
  else
    export POLYMATIC_ENVIRONMENT="production";
  fi;
fi;

clog "environment -> ${POLYMATIC_ENVIRONMENT}";

# authenticate to vault

clog 'setup -> authenticate';

POLYMATIC_START=`date +%s`;

export VAULT_SKIP_VERIFY=true && export VAULT_ADDR="http://vault.pipeline.svc.cluster.local:8200";

if [[ -n "$POLYMATIC_VAULT_TOKEN" ]]; then
  clog "authenticating to Vault with token";
  vault login -field=policies token="$(echo "${POLYMATIC_VAULT_TOKEN}" | base64 -d)"; echo;
  vault token renew ${VAULT_TOKEN} | grep token_duration;
  export VAULT_TOKEN=$(echo "${POLYMATIC_VAULT_TOKEN}" | base64 -d);
else
  clog "authenticating to Vault with jwt";
  export VAULT_TOKEN="$(vault write -field=token auth/jwt/login role=pipe jwt=$POLYMATIC_VAULT_JWT)";
fi;

vault kv get -format=json pipe/${POLYMATIC_ENVIRONMENT}/settings | jq -r '.data.data' > ops/settings.json;

export POLYMATIC_PIPES_URL="$(cat ops/settings.json | jq -r '.pipes_url')";
export POLYMATIC_PIPES_DEPLOY_KEY="$(cat ops/settings.json | jq -r '.pipes_deploy_key' | grep -v null)";
export POLYMATIC_PIPES_VERSION="$(cat ops/settings.json | jq -r '.pipes_version' | grep -v null)";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} authenticate -> $((`date +%s`-POLYMATIC_START)) ;";

# download pipe scripts

clog 'setup -> download';

POLYMATIC_START=`date +%s`;

eval $(ssh-agent -s);

mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/config;
git config --global advice.detachedHead false;
rm -rf ${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.pipes/* && mkdir -p ${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.pipes;

if [[ "${POLYMATIC_PIPES_URL}" ]]; then
  count="0";
  for pipes_url in $(printf ${POLYMATIC_PIPES_URL} | tr ',' ' '); do
    count="$(($count + 1))";
    pipes_key="$(printf "${POLYMATIC_PIPES_DEPLOY_KEY}" | cut -d',' -f$count)";
    pipes_name="$(printf "${pipes_url}" | cut -d':' -f2 | cut -d'.' -f1 | sed 's/\//-/g')"
    pipes_domain="$(printf "${pipes_url}" | cut -d':' -f1 | cut -d'@' -f2)"
    if [[ -n "${pipes_key}" ]]; then
        printf "%s\n  %s\n  %s\n  %s\n  %s\n" "Host ${pipes_name}.${pipes_domain}" "Hostname ${pipes_domain}" "IdentityFile ~/.ssh/${pipes_name}_key" "IdentitiesOnly yes" "StrictHostKeyChecking no" >> ~/.ssh/config;
        printf "%s\n" "$(printf "%s" "${pipes_key}" | base64 -d)" > ~/.ssh/${pipes_name}_key && chmod 400 ~/.ssh/${pipes_name}_key;
        pipes_url_distinct="$(printf "${pipes_url}" | sed "s/${pipes_domain}/${pipes_name}.${pipes_domain}/g")";
      else
        pipes_url_distinct="${pipes_url}";
    fi;

    clog "checking -> ${pipes_url_distinct}";

    pipes_grep_version="$(printf "${POLYMATIC_PIPES_VERSION}" | cut -d',' -f$count)";
    if [[ -n "$pipes_grep_version" ]]; then
        export pipes_version="v$(git ls-remote --tags ${pipes_url_distinct} | cut -d'/' -f3 | tr -d 'v' | grep -E "^${pipes_grep_version}\." | sort -V | sed '1!G;h;$!d' | head -n1)";
      else
        export pipes_version="v$(git ls-remote --tags ${pipes_url_distinct} | cut -d'/' -f3 | tr -d 'v' | sort -V | sed '1!G;h;$!d' | head -n1)";
    fi;
    if [[ "$pipes_version" = "v" ]]; then
      echo "could not determine pipe scripts version";
      exit 1;
    fi;

    clog "fetching pipe scripts -> ${pipes_version}";

    git clone --depth 1 --branch ${pipes_version} ${pipes_url_distinct} ${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.tmp || exit 1;
    cp -rf ${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.tmp/src/* ${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.pipes/ && rm -rf mv ${POLYMATIC_ORIGINAL_DIRECTORY}/ops/.tmp;
  done;
fi;

POLYMATIC_TEMPRO_VERSION="v$(git ls-remote --tags https://github.com/polymatic-systems/tempro | cut -d'/' -f3 | tr -d 'v' | grep -E "^1\." | sort -V | sed '1!G;h;$!d' | head -n1)";
clog "installing tempro -> ${POLYMATIC_TEMPRO_VERSION}";
curl -sL https://github.com/polymatic-systems/tempro/releases/download/${POLYMATIC_TEMPRO_VERSION}/tempro -o /bin/tempro || (echo "could not install tempro" && exit 1);
chmod 550 /bin/tempro && echo "installed tempro";

POLYMATIC_VAULT2ENV_VERSION="v$(git ls-remote --tags https://github.com/polymatic-systems/vault2env | cut -d'/' -f3 | tr -d 'v' | grep -E "^1\." | sort -V | sed '1!G;h;$!d' | head -n1)";
clog "installing vault2env -> ${POLYMATIC_VAULT2ENV_VERSION}";
curl -sL https://github.com/polymatic-systems/vault2env/releases/download/${POLYMATIC_VAULT2ENV_VERSION}/vault2env -o /bin/vault2env || (echo "could not install vault2env" && exit 1);
chmod 550 /bin/vault2env && echo "installed vault2env";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} download -> $((`date +%s`-POLYMATIC_START)) ;";

# get environment variables from vault

clog 'setup -> vault2env';

POLYMATIC_START=`date +%s`;

POLYMATIC_VAULT_VERSION='';
if [ -n "${PIPE_VAULT_VERSION}" ]; then
  POLYMATIC_VAULT_VERSION=":${PIPE_VAULT_VERSION}";
fi;

export POLYMATIC_REMOTE_VAULT_PATHS="$(echo "pipe/${POLYMATIC_ENVIRONMENT}/global,app/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_ENVIRONMENT}/${POLYMATIC_PROJECT_NAME}${POLYMATIC_VAULT_VERSION},$(env | grep PIPE_ENVAR_ | sed "s@.*=@app/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_ENVIRONMENT}/@g")" | grep .)";
export POLYMATIC_VAULT_RESULT_FULL="$(vault2env "${POLYMATIC_REMOTE_VAULT_PATHS}" ops/vault.env)";
if [ "$?" != "0" ]; then
  clog "there was an error fetching a vault path, exiting."; exit 1;
fi;

export POLYMATIC_VAULT_RESULTS=$(echo "$POLYMATIC_VAULT_RESULT_FULL" | grep 'version=');

echo "$POLYMATIC_VAULT_RESULT_FULL";
set -a && . ops/vault.env && set +a;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} vault2env -> $((`date +%s`-POLYMATIC_START)) ;";

# run pre scripts

clog 'setup -> prescript';

if [ -f ./pipeline/before/${POLYMATIC_SCRIPT_NAME}.sh ]; then
  clog "running -> pipeline/before/${POLYMATIC_SCRIPT_NAME}.sh";
  . pipeline/before/${POLYMATIC_SCRIPT_NAME}.sh;
fi;

# run job scripts

clog 'setup -> jobscript';

echo '#!/bin/sh' > ci.sh && chmod 775 ci.sh;
cat ops/.pipes/start.sh >> ci.sh;
if [ -f ops/.pipes/${POLYMATIC_SCRIPT_NAME}_setup.sh ]; then
  cat ops/.pipes/${POLYMATIC_SCRIPT_NAME}_setup.sh >> ci.sh;
fi;
if [ -f ./pipeline/${POLYMATIC_SCRIPT_NAME}.sh ]; then
  cat ./pipeline/${POLYMATIC_SCRIPT_NAME}.sh >> ci.sh;
else
  cat ops/.pipes/${POLYMATIC_SCRIPT_NAME}.sh >> ci.sh;
fi;
cat ops/.pipes/end.sh >> ci.sh;

. ci.sh;
