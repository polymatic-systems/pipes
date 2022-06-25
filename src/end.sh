
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

clog "###############################################################################
the job results are above, everything below this point is metadata on the job execution
########################################################################################";

POLYMATIC_DOMAIN_NAME="$(< ops/settings.json jq -r '.domain_name')";
POLYMATIC_STORAGE_ACCESS_KEY_BASE64="$(< ops/settings.json jq -r '.artifacts_access_key_base64')";
POLYMATIC_STORAGE_SECRET_KEY_BASE64="$(< ops/settings.json jq -r '.artifacts_secret_key_base64')";
POLYMATIC_STORAGE_URL="$(< ops/settings.json jq -r '.artifacts_url')";
POLYMATIC_STORAGE_ENABLED="false";

export POLYMATIC_DOMAIN_NAME;
export POLYMATIC_STORAGE_ACCESS_KEY_BASE64;
export POLYMATIC_STORAGE_SECRET_KEY_BASE64;
export POLYMATIC_STORAGE_URL;
export POLYMATIC_STORAGE_ENABLED;

# print contents of artifacts

if [ -d ./artifacts ] && [ -n "$(ls -1A ./artifacts)" ]; then
  if [ -z "${POLYMATIC_STORAGE_ACCESS_KEY_BASE64}" ] || [ -z "${POLYMATIC_STORAGE_SECRET_KEY_BASE64}" ]; then
    clog "artifacts detected, but not uploading -> missing credentials";
  else
    clog "artifacts detected";
    export POLYMATIC_STORAGE_ENABLED="true";

    zip -q -r "${POLYMATIC_JOB_NAME}.zip" ./artifacts;
    mv "${POLYMATIC_JOB_NAME}.zip" "./artifacts/${POLYMATIC_JOB_NAME}.zip";

    POLYMATIC_ARTIFACT_ZIP_URLS="$(find ./artifacts -type f -name '*.zip' -follow -print | sed "s@\./artifacts@https://artifacts.operations.${POLYMATIC_DOMAIN_NAME}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_GIT_NAME}/${POLYMATIC_PIPELINE_ID}@g")";
    POLYMATIC_ARTIFACT_INDEX_URLS="$(find ./artifacts -type f -name '*index.html' -follow -print | sed "s@\./artifacts@https://artifacts.operations.${POLYMATIC_DOMAIN_NAME}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_GIT_NAME}/${POLYMATIC_PIPELINE_ID}@g")";
    POLYMATIC_ARTIFACT_REPORT_URLS="$(find ./artifacts -type f -name '*report.html' -follow -print | sed "s@\./artifacts@https://artifacts.operations.${POLYMATIC_DOMAIN_NAME}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_GIT_NAME}/${POLYMATIC_PIPELINE_ID}@g")";

    export POLYMATIC_ARTIFACT_ZIP_URLS;
    export POLYMATIC_ARTIFACT_INDEX_URLS;
    export POLYMATIC_ARTIFACT_REPORT_URLS;

    mkdir -p "./ops/artifacts/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_GIT_NAME}/${POLYMATIC_PIPELINE_ID}";
    cp -a ./artifacts/. "./ops/artifacts/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_GIT_NAME}/${POLYMATIC_PIPELINE_ID}";

    POLYMATIC_STORAGE_ACCESS_KEY="$(printf "%s" "${POLYMATIC_STORAGE_ACCESS_KEY_BASE64}" | base64 -d)";
    POLYMATIC_STORAGE_SECRET_KEY="$(printf "%s" "${POLYMATIC_STORAGE_SECRET_KEY_BASE64}" | base64 -d)";

    export POLYMATIC_STORAGE_ACCESS_KEY;
    export POLYMATIC_STORAGE_SECRET_KEY;
  fi;
else
  clog "artifacts directory is empty";
fi;

# upload cache if enabled

if [ -n "${PIPE_CACHE}" ] && [ -d ./cache ] && [ -n "$(ls -1A ./cache)" ]; then
  if [ -z "${POLYMATIC_STORAGE_ACCESS_KEY_BASE64}" ] || [ -z "${POLYMATIC_STORAGE_SECRET_KEY_BASE64}" ]; then
    clog "cache detected, but not uploading -> missing credentials";
  else 
    POLYMATIC_START="$(date +%s)";

    clog "cache enabled and files detected";
    export POLYMATIC_STORAGE_ENABLED="true";

    export POLYMATIC_CACHE="";
    if [ "${PIPE_CACHE}" = "bzip2" ]; then
      clog "cache compression set to bzip2";
      export POLYMATIC_CACHE="tar.bz2";
      if ! command -v pbzip2 > /dev/null 2>&1; then
        if command -v apt > /dev/null 2>&1; then
          echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections;
          apt-get -qq update;
          apt-get -qq install -y --no-install-recommends apt-utils > /dev/null 2>&1;
          apt-get -qq install -y pbzip2 > /dev/null;
        else
          clog 'unable to install pbzip2 on the fly, cache will not be saved!';
          export POLYMATIC_CACHE="";
        fi;
      fi;
    elif [ "${PIPE_CACHE}" = "gzip" ]; then
      clog "cache compression set to gzip";
      export POLYMATIC_CACHE="tar.gz";
      if ! command -v pigz > /dev/null 2>&1; then
        if command -v apt-get > /dev/null 2>&1; then
          echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections;
          apt-get -qq update;
          apt-get -qq install -y --no-install-recommends apt-utils > /dev/null 2>&1;
          apt-get -qq install -y pigz > /dev/null;
        else
          clog 'unable to install pigz on the fly, cache will not be saved!';
          export POLYMATIC_CACHE="";
        fi;
      fi;
    elif [ "${PIPE_CACHE}" = "none" ]; then
      clog "cache compression off, will only tar";
      export POLYMATIC_CACHE="tar";
    else
      clog "unknown cache compression, defaulting to gzip";
      export POLYMATIC_CACHE="tar.gz";
    fi;

    mkdir -p ./ops/cache;
    cd ./cache;

    if [ "${POLYMATIC_CACHE}" = "tar.bz2" ]; then
      clog "generating cache tar (bzip2)";
      tar -c . | pbzip2 -c -p4 -m1000 > "../ops/cache/${POLYMATIC_JOB_NAME}.tar.bz2";
    elif [ "${POLYMATIC_CACHE}" = "tar.gz" ]; then
      clog "generating cache tar (gzip)";
      tar -c . | pigz -c -p 4 > "../ops/cache/${POLYMATIC_JOB_NAME}.tar.gz";
    elif [ "${POLYMATIC_CACHE}" = "tar" ]; then
      clog "generating cache tar (tar)";
      tar -cf "../ops/cache/${POLYMATIC_JOB_NAME}.tar .";
    fi;

    cd ..;

    POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} cache compress/tar -> $(($(date +%s)-POLYMATIC_START)) ;";
  fi;
fi;

# upload artifacts and/or cache

if [ "${POLYMATIC_STORAGE_ENABLED}" = "true" ]; then
  if ! command -v aws > /dev/null 2>&1; then
    if command -v apt > /dev/null 2>&1; then
      curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
      && unzip -qq awscliv2.zip \
      && ./aws/install \
      && rm -rf ./aws awscliv2.zip;
    elif command -v apk > /dev/null 2>&1; then
      apk update && apk add aws-cli;
    else
      clog 'unable to install aws s3 cli on the fly, artifacts/cache will not be saved!';
      export POLYMATIC_STORAGE_ENABLED="false";
    fi;
  fi;
fi;

if [ "${POLYMATIC_STORAGE_ENABLED}" = "true" ]; then
  aws configure set profile.artifacts.aws_access_key_id "${POLYMATIC_STORAGE_ACCESS_KEY}";
  aws configure set profile.artifacts.aws_secret_access_key "${POLYMATIC_STORAGE_SECRET_KEY}";
  aws configure set profile.artifacts.region us-east-1;
  aws configure set profile.artifacts.output json;
  aws configure set profile.artifacts.s3.signature_version s3v4;

  if [ -d ./ops/artifacts ] && [ -n "$(ls -1A ./ops/artifacts)" ]; then
    POLYMATIC_START="$(date +%s)";

    cd ./ops/artifacts;

    clog "uploading contents of artifacts directory";

    aws --endpoint-url "${POLYMATIC_STORAGE_URL}" s3 cp \
      --quiet --recursive --profile artifacts \
      "./${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_GIT_NAME}/${POLYMATIC_PIPELINE_ID}" "s3://artifacts/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_GIT_NAME}/${POLYMATIC_PIPELINE_ID}";

    clog "artifacts uploaded to -> ";

    echo "${POLYMATIC_ARTIFACT_ZIP_URLS}";
    echo "${POLYMATIC_ARTIFACT_INDEX_URLS}";
    echo "${POLYMATIC_ARTIFACT_REPORT_URLS}";

    cd ../..;

    POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} artifacts upload -> $(($(date +%s)-POLYMATIC_START)) ;";
  fi;

  if [ -d ./ops/cache ] && [ -n "$(ls -1A ./ops/cache)" ]; then
    POLYMATIC_START="$(date +%s)";

    cd ./ops/cache;

    clog "uploading contents of cache directory";

    aws --endpoint-url "${POLYMATIC_STORAGE_URL}" s3 cp \
      --quiet --profile artifacts \
      "./${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}" "s3://cache/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}/${POLYMATIC_ENVIRONMENT}/${POLYMATIC_JOB_NAME}.${POLYMATIC_CACHE}";

    cd ../..;

    POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} cache upload -> $(($(date +%s)-POLYMATIC_START)) ;";
  fi;
fi;

# print all recorded run times

clog "printing execution times for script sections ->";

echo "${POLYMATIC_RUNTIME}" | tr ';' '\n';

clog "printing date time of job completion ->";

date;

# print vault results

clog "printing versions pulled from vault ->";

echo "${POLYMATIC_VAULT_RESULTS}";

# non-zero exit if previous stage marked the job as a fail

if [ "${POLYMATIC_JOB_FAIL}" = "yes" ] || [ "${PIPE_JOB_FAIL}" = "yes" ]; then
  clog "job was marked as fail";
  exit 1;
fi;
