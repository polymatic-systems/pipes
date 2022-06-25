
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START="$(date +%s)";

if [ "$(< ops/settings.json jq -r '.freeze')" = "yes" ]; then
  echo "deployments are currently blocked for this environment right now. contact your administrator.";
  exit 1;
fi;

POLYMATIC_PREDEPLOY="";
export POLYMATIC_PREDEPLOY;
if [ "${POLYMATIC_JOB_NAME}" = "deploy_pre${POLYMATIC_ENVIRONMENT}" ]; then
  POLYMATIC_PREDEPLOY="pre";
fi;

if [ ! -d "${POLYMATIC_ORIGINAL_DIRECTORY}/deploy/${POLYMATIC_PREDEPLOY}${POLYMATIC_ENVIRONMENT}" ]; then
  echo "nothing to deploy, missing directory: deploy/${POLYMATIC_PREDEPLOY}${POLYMATIC_ENVIRONMENT}";
  exit 1;
fi;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} validate -> $(($(date +%s)-POLYMATIC_START)) ;";

POLYMATIC_START="$(date +%s)";

# install needed binaries

clog "installing any needed binaries";

if [ ! "$(command -v wget)" ]; then
  if [ "$(command -v apt)" ]; then
    apt update && apt install -y wget;
  elif [ "$(command -v apk)" ]; then
    apk update && apk add wget;
  else
    clog 'unknown os package manager, must be apt or apk';
    exit 1;
  fi;
fi;

if [ ! "$(command -v curl)" ]; then
  if [ "$(command -v apt)" ]; then
    apt update && apt install -y curl;
  elif [ "$(command -v apk)" ]; then
    apk update && apk add curl;
  else
    clog 'unknown os package manager, must be apt or apk';
    exit 1;
  fi;
fi;

if [ ! "$(command -v ssh-agent)" ]; then
  if [ "$(command -v apt)" ]; then
    apt update && apt install -y openssh-client;
  elif [ "$(command -v apk)" ]; then
    apk update && apk add openssh-client;
  else
    clog 'unknown os package manager, must be apt or apk';
    exit 1;
  fi;
fi;

if [ ! "$(command -v jq)" ]; then
  curl -Ls https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /bin/jq;
  chmod +x /bin/jq;
fi;

if [ ! "$(command -v yq)" ]; then
  curl -Ls https://github.com/mikefarah/yq/releases/download/v4.12.0/yq_linux_amd64 -o /bin/yq;
  chmod +x /bin/yq;
fi;

if [ ! "$(command -v kubectl)" ]; then
  curl -SsLO https://storage.googleapis.com/kubernetes-release/release/v1.20.7/bin/linux/amd64/kubectl \
  && chmod +x kubectl \
  && mv -f kubectl /bin/kubectl;
fi;

if [ ! "$(command -v helm)" ]; then
  wget -q https://git.io/get_helm.sh \
  && chmod 770 get_helm.sh \
  && sed -i 's@#!/usr/bin/env bash@#!/bin/sh@g' get_helm.sh \
  && ./get_helm.sh -v v3.6.3;
fi;

if [ ! "$(command -v aws)" ]; then
  apt update && apt install -y bsdmainutils unzip;
  wget -q https://s3.amazonaws.com/aws-cli/awscli-bundle.zip \
  && unzip ./awscli-bundle.zip \
  && ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws;
fi;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} deploy binaries -> $(($(date +%s)-POLYMATIC_START)) ;";

POLYMATIC_START="$(date +%s)";

# options

if [ -n "$PIPE_DEPLOY_SIMULATE" ]; then
  clog 'using dry run';
  export PIPE_DEPLOY_SIMULATE="--dry-run";
fi

if [ -n "$PIPE_DEPLOY_FORCE" ]; then
  clog 'using force';
  export PIPE_DEPLOY_FORCE="--force";
fi

# set variables based on deploy environment

clog "setting deploy environment variables ->";

if [ "${POLYMATIC_ENVIRONMENT}" = "review" ]; then
  POLYMATIC_GIT_SLUG_TRUNC=$(printf "%s" "${POLYMATIC_GIT_SLUG}" | cut -c 1-16);
  POLYMATIC_GIT_SLUG=$(printf "%s" "${POLYMATIC_GIT_SLUG_TRUNC%-}");
  POLYMATIC_HELM_RELEASE="${POLYMATIC_PROJECT_NAME}-${POLYMATIC_GIT_SLUG}";
  POLYMATIC_SERVICE_URL_PREFIX="${POLYMATIC_PROJECT_NAME}-${POLYMATIC_GIT_SLUG}";
  POLYMATIC_ENVIRONMENT="review";
else
  POLYMATIC_GIT_SLUG="";
  POLYMATIC_HELM_RELEASE="${POLYMATIC_PROJECT_NAME}";
  POLYMATIC_SERVICE_URL_PREFIX="${POLYMATIC_PROJECT_NAME}";
fi

export POLYMATIC_GIT_SLUG;
export POLYMATIC_HELM_RELEASE;
export POLYMATIC_SERVICE_URL_PREFIX;
export POLYMATIC_ENVIRONMENT;

# determine k8s namespace

if [ -f "pipeline/namespace.txt" ]; then
  POLYMATIC_K8S_NAMESPACE="$(< pipeline/namespace.txt xargs)";
else
  POLYMATIC_K8S_NAMESPACE="${POLYMATIC_PROJECT_NAMESPACE}";
fi;

export POLYMATIC_K8S_NAMESPACE;

# operations

POLYMATIC_DOMAIN_NAME="$(< ops/settings.json jq -r '.domain_name')";
export POLYMATIC_DOMAIN_NAME;

if [ -n "${POLYMATIC_REGISTRY_URL}" ]; then
  POLYMATIC_K8S_REGISTRY_URL="${POLYMATIC_REGISTRY_URL}";
else
  POLYMATIC_K8S_REGISTRY_URL="registry.operations.${POLYMATIC_DOMAIN_NAME}";
fi;

export POLYMATIC_K8S_REGISTRY_URL;

# pipe chart version

if [ -f pipeline/pipe_version.txt ]; then
  PIPE_CHART_VERSION="$(< pipeline/pipe_version.txt xargs)";
  export PIPE_CHART_VERSION;
fi;

# get provider credentials

clog "fetching k8s provider credentials ->";

POLYMATIC_K8S_DEFAULT_REGION="$(< ops/settings.json jq -r '.k8s_region')";
POLYMATIC_K8S_CLUSTERS="$(< ops/settings.json jq -r '.k8s_clusters')";
POLYMATIC_K8S_CREDENTIALS_USER=$(< ops/settings.json jq -r '.k8s_user_base64' | base64 -d);
POLYMATIC_K8S_CREDENTIALS_PASSWORD=$(< ops/settings.json jq -r '.k8s_password_base64' | base64 -d);
POLYMATIC_K8S_PROVIDER_NAME=$(< ops/settings.json jq -r '.k8s_provider');
POLYMATIC_K8S_CREDENTIALS_PROFILE="pipe";

export POLYMATIC_K8S_DEFAULT_REGION;
export POLYMATIC_K8S_CLUSTERS;
export POLYMATIC_K8S_CREDENTIALS_USER;
export POLYMATIC_K8S_CREDENTIALS_PASSWORD;
export POLYMATIC_K8S_PROVIDER_NAME;
export POLYMATIC_K8S_CREDENTIALS_PROFILE;

if [ "${POLYMATIC_K8S_PROVIDER_NAME}" = "aws" ]; then
  clog "configuring provider -> aws";

  # used for getting k8s credentials for kubectl user
  aws configure set aws_access_key_id "${POLYMATIC_K8S_CREDENTIALS_USER}" --profile "${POLYMATIC_K8S_CREDENTIALS_PROFILE}";
  aws configure set aws_secret_access_key "${POLYMATIC_K8S_CREDENTIALS_PASSWORD}" --profile "${POLYMATIC_K8S_CREDENTIALS_PROFILE}";
  aws configure set region "${POLYMATIC_K8S_DEFAULT_REGION}" --profile "${POLYMATIC_K8S_CREDENTIALS_PROFILE}";
  aws configure set output json --profile "${POLYMATIC_K8S_CREDENTIALS_PROFILE}";

  # aws pull kubeconfig
  clog "configuring kubectl config";

  POLYMATIC_CLUSTER_COUNT="$(printf "%s" "${POLYMATIC_K8S_CLUSTERS}" | wc -w | xargs)";
  export POLYMATIC_CLUSTER_COUNT;

  mkdir -p "$HOME/.kube/configs";
  POLYMATIC_K8S_CLUSTER_NAMES="";
  export POLYMATIC_K8S_CLUSTER_NAMES;
  for POLYMATIC_CURRENT_CLUSTER in ${POLYMATIC_K8S_CLUSTERS}; do
    POLYMATIC_K8S_CLUSTER_NAME="$(printf "%s" "${POLYMATIC_CURRENT_CLUSTER}" | cut -d'@' -f1)";
    POLYMATIC_K8S_REGION="$(printf "%s" "${POLYMATIC_CURRENT_CLUSTER}" | cut -d'@' -f2)";
    POLYMATIC_K8S_CLUSTER_NAMES="${POLYMATIC_K8S_CLUSTER_NAMES} ${POLYMATIC_K8S_CLUSTER_NAME}";

    aws eks update-kubeconfig --name "${POLYMATIC_K8S_CLUSTER_NAME}" --region "${POLYMATIC_K8S_REGION}" --profile "${POLYMATIC_K8S_CREDENTIALS_PROFILE}" --kubeconfig "$HOME/.kube/configs/${POLYMATIC_K8S_CLUSTER_NAME}";
    KUBECONFIG="$HOME/.kube/configs/${POLYMATIC_K8S_CLUSTER_NAME}";
    export KUBECONFIG;
    kubectl config --kubeconfig="$HOME/.kube/configs/${POLYMATIC_K8S_CLUSTER_NAME}" set-credentials "$(kubectl config view -o jsonpath='{.users[0].name}')" --exec-arg="eks" --exec-arg="get-token" --exec-arg="--region" --exec-arg="${POLYMATIC_K8S_REGION}" --exec-arg="--cluster-name" --exec-arg="${POLYMATIC_K8S_CLUSTER_NAME}" --exec-arg="--profile" --exec-arg="${POLYMATIC_K8S_CREDENTIALS_PROFILE}";
    chmod 600 "$HOME/.kube/configs/${POLYMATIC_K8S_CLUSTER_NAME}";
  done;
  PIPELINE_K8S_CLUSTER_NAMES="$(printf "${PIPELINE_K8S_CLUSTER_NAMES}" | awk '{$1=$1;print}')";
  POLYMATIC_CLUSTER_PRIMARY="$(echo "${POLYMATIC_K8S_CLUSTER_NAMES}" | cut -d' ' -f1)";
  export POLYMATIC_CLUSTER_PRIMARY;
else
  clog 'unsupported cloud provider, please contact your administrator';
  exit 1;
fi;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} set up -> $(($(date +%s)-POLYMATIC_START)) ;";
