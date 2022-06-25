
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

clog "printing date time of job start ->";

date;

# print halicun (identifies docker image) & quatrak (timestamp of image's creation)

if [ -f /mark/halicun ]; then
  clog "printing halicun (container image identifier) ->";
  cat /mark/halicun;
fi;

if [ -f /mark/quatrak ]; then
  clog "printing quatrak (container image creation timestamp) ->";
  cat /mark/quatrak;
fi;

# validate repo

# shellcheck disable=SC2010
if [ "$(ls -d ./*/ | grep -c -v -E "artifacts|build|deploy|docs|ops|pipeline|src" | tr -d ' ')" -ne 0 ]; then
  clog "unknown directory in root. repository structure must match:
  - build/
  - deploy/
  - docs/
  - pipeline/
  - src/
  - .*
";

  echo "current contents of directory: ";

  ls -d ./*/;

  exit 1;
fi;

# make directories

mkdir -p cache artifacts ops

# grab variables

POLYMATIC_DOMAIN_NAME="$(< ops/settings.json jq -r '.domain_name')";
export POLYMATIC_DOMAIN_NAME;

# optionally grab cache

POLYMATIC_STORAGE_ACCESS_KEY_BASE64="$(< ops/settings.json jq -r '.artifacts_access_key_base64')";
POLYMATIC_STORAGE_SECRET_KEY_BASE64="$(< ops/settings.json jq -r '.artifacts_secret_key_base64')";
POLYMATIC_STORAGE_URL="$(< ops/settings.json jq -r '.artifacts_url')";
POLYMATIC_STORAGE_ACCESS_KEY="$(printf "%s" "${POLYMATIC_STORAGE_ACCESS_KEY_BASE64}" | base64 -d)";
POLYMATIC_STORAGE_SECRET_KEY="$(printf "%s" "${POLYMATIC_STORAGE_SECRET_KEY_BASE64}" | base64 -d)";

export POLYMATIC_STORAGE_ACCESS_KEY_BASE64;
export POLYMATIC_STORAGE_SECRET_KEY_BASE64;
export POLYMATIC_STORAGE_URL;
export POLYMATIC_STORAGE_ACCESS_KEY;
export POLYMATIC_STORAGE_SECRET_KEY;

if [ -n "${PIPE_CACHE}" ]; then
  POLYMATIC_START="$(date +%s)";

  clog "cache is enabled";

  POLYMATIC_CACHE="";
  export POLYMATIC_CACHE;
  if [ "${PIPE_CACHE}" = "bzip2" ]; then
    clog "cache compression set to bzip2";
    POLYMATIC_CACHE="tar.bz2";
    if ! command -v pbzip2 > /dev/null 2>&1; then
      if command -v apt-get > /dev/null 2>&1; then
        echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections;
        apt-get -qq update;
        apt-get -qq install -y --no-install-recommends apt-utils > /dev/null 2>&1;
        apt-get -qq install -y pbzip2 > /dev/null;
      else
        clog 'unable to install pbzip2 on the fly, cache will not be saved!';
        POLYMATIC_CACHE="";
      fi;
    fi;
  elif [ "${PIPE_CACHE}" = "gzip" ]; then
    clog "cache compression set to gzip";
    POLYMATIC_CACHE="tar.gz";
    if ! command -v pigz > /dev/null 2>&1; then
      if command -v apt-get > /dev/null 2>&1; then
        echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections;
        apt-get -qq update;
        apt-get -qq install -y --no-install-recommends apt-utils > /dev/null 2>&1;
        apt-get -qq install -y pigz > /dev/null;
      else
        clog 'unable to install pigz on the fly, cache will not be saved!';
        POLYMATIC_CACHE="";
      fi;
    fi;
  elif [ "${PIPE_CACHE}" = "none" ]; then
    clog "cache compression off, will only tar";
    POLYMATIC_CACHE="tar";
  else
    clog "unknown cache compression, defaulting to gzip";
    POLYMATIC_CACHE="tar.gz";
  fi;

  if [ -z "${POLYMATIC_STORAGE_ACCESS_KEY_BASE64}" ] || [ -z "${POLYMATIC_STORAGE_SECRET_KEY_BASE64}" ]; then
    clog "cache enabled, but will not be used -> missing credentials";
    POLYMATIC_CACHE="";
  fi;

  if [ -n "${POLYMATIC_CACHE}" ]; then
    if ! command -v aws > /dev/null 2>&1; then
      if command -v apt > /dev/null 2>&1; then
        curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
        && unzip -qq awscliv2.zip \
        && ./aws/install \
        && rm -rf ./aws awscliv2.zip;
      elif command -v apk > /dev/null 2>&1; then
        apk update && apk add aws-cli;
      else
        clog 'unable to install aws s3 cli on the fly, cache will not be pulled!';
        POLYMATIC_CACHE="";
      fi;
    fi;
  fi;

  if [ -n "${POLYMATIC_CACHE}" ]; then
    export POLYMATIC_CACHE_REMOTE_FOUND="false";

    aws configure set profile.artifacts.aws_access_key_id "${POLYMATIC_STORAGE_ACCESS_KEY}";
    aws configure set profile.artifacts.aws_secret_access_key "${POLYMATIC_STORAGE_SECRET_KEY}";
    aws configure set profile.artifacts.region us-east-1;
    aws configure set profile.artifacts.output json;
    aws configure set profile.artifacts.s3.signature_version s3v4;

    cd ./cache;

    clog "checking for existing cache -> cache/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_ENVIRONMENT}/${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}";
    aws --endpoint-url "${POLYMATIC_STORAGE_URL}" s3 cp --quiet --profile artifacts \
      "s3://cache/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_ENVIRONMENT}/${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}" \
      "./${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}" \
      && POLYMATIC_CACHE_REMOTE_FOUND="true";

    if [ "${POLYMATIC_CACHE_REMOTE_FOUND}" = "true" ]; then
      if [ "${POLYMATIC_CACHE}" = "tar.bz2" ]; then
        clog 'cache found, untarring -> bzip2';
        pbzip2 -dc "./${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}" | tar -xf - ;
      elif [ "${POLYMATIC_CACHE}" = "tar.gz" ]; then
        clog 'cache found, untarring -> pigz';
        pigz -dc "./${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}" | tar -xf - ;
      elif [ "${POLYMATIC_CACHE}" = "none" ]; then
        clog 'cache found, untarring -> tar';
        tar xf "./${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}";
      else
        clog "unknown cache compression, defaulting to gzip";
        pigz -dc "./${POLYMATIC_JOB_NAME}.tar.gz" | tar -xf - ;
      fi;

      rm -f "./${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}";
    else
      clog "no cache found";
    fi;

    cd .. ;
  fi;

  POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} cache download -> $(($(date +%s)-POLYMATIC_START)) ;";
fi;

clog "###############################################################################
the job results are below, everything above this point is set up for the job
########################################################################################";
