
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

# operations

POLYMATIC_DOMAIN_NAME="$(< ops/settings.json jq -r '.domain_name')";
export POLYMATIC_DOMAIN_NAME

if [[ -n "${POLYMATIC_REGISTRY_URL}" ]]; then
  export POLYMATIC_K8S_REGISTRY_URL="${POLYMATIC_REGISTRY_URL}";
else
  export POLYMATIC_K8S_REGISTRY_URL="registry.operations.${POLYMATIC_DOMAIN_NAME}";
fi;

# variable set up

if [ -n "$PIPE_BUILD_NO_CACHE" ]; then 
  export PIPE_BUILD_NO_CACHE="--no-cache"; 
else
  unset PIPE_BUILD_NO_CACHE; 
fi

# login to the registry

POLYMATIC_K8S_REGISTRY_USER=$(< ops/settings.json jq -r '.registry_user_base64' | base64 -d);
POLYMATIC_K8S_REGISTRY_PASSWORD=$(< ops/settings.json jq -r '.registry_password_base64' | base64 -d);

clog "logging into registry -> ${POLYMATIC_K8S_REGISTRY_URL}";

for i in 1 2 3 4 5; do
  if [ "$i" = "5" ]; then
    echo "could not log into registry" && exit 1;
  fi;
  
  if echo "${POLYMATIC_K8S_REGISTRY_PASSWORD}" | docker login --username "${POLYMATIC_K8S_REGISTRY_USER}" --password-stdin "${POLYMATIC_K8S_REGISTRY_URL}"; then
    break;
  else
    sleep 2;
  fi;
done;

# save POLYMATIC_ vars to a file

env | grep -E "^POLYMATIC_.*\=.*" > ops/cicd.env;

# build images

POLYMATIC_START="$(date +%s)";

mkdir -p ./.ops/logs/build;
sbuilds="";
for filename in ./build/*Dockerfile; do
  [ -f "$filename" ] || continue;
  sname=${filename#"./build/"};
  clog "processing build -> ${sname}";
  rname=${sname%"Dockerfile"};
  if [[ -n "$rname" ]]; then
    rname="-$(printf "%s" "${rname%"."}" | tr '.' '-')"
  fi;

  cat ops/vault.env ops/cicd.env \
    | grep -E "\S=\S" | sed 's/=.*//g' \
    | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ --build-arg /g' \
    | xargs -t -I {} sh -c "docker image build --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from ${POLYMATIC_K8S_REGISTRY_URL}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}${rname} --cache-from ${POLYMATIC_K8S_REGISTRY_URL}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:master${rname} ${PIPE_BUILD_NO_CACHE} --build-arg {} --tag ${POLYMATIC_K8S_REGISTRY_URL}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}${rname} -f ${filename} . " > "./.ops/logs/build/${sname}" 2>&1 &

  sbuilds="$sbuilds $!";

  sleep 1;
done;

for sbuild in $sbuilds; do
  wait $sbuild || export PIPELINE_JOB_FAIL="yes";
done;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} image builds -> $(($(date +%s)-POLYMATIC_START)) ;";

# print build logs

for filename in ./build/*Dockerfile; do
  [ -f "$filename" ] || continue;
  sname=${filename#"./build/"};

  clog "logs for build -> ${sname}";
  < "./.ops/logs/build/${sname}" tail -n +2;
  rm -f "./.ops/logs/build/${sname}";
  sleep 1;
done;

# push images

POLYMATIC_START="$(date +%s)";

mkdir -p ./.ops/logs/push
for filename in ./build/*Dockerfile; do
  [ -f "$filename" ] || continue;
  sname=${filename#"./build/"};
  clog "processing push -> ${sname}";
  rname=${sname%"Dockerfile"};
  if [[ -n "$rname" ]]; then
    rname="-$(printf "%s" "${rname%"."}" | tr '.' '-')"
  fi;

  docker image push "${POLYMATIC_K8S_REGISTRY_URL}/${POLYMATIC_PROJECT_NAMESPACE}/${POLYMATIC_PROJECT_NAME}:${POLYMATIC_GIT_NAME}${rname}" > "./.ops/logs/push/${sname}" 2>&1 &

  sleep 1;
done;

wait;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} image pushes -> $(($(date +%s)-POLYMATIC_START)) ;";

# print push logs

for filename in ./build/*Dockerfile; do
  [ -f "$filename" ] || continue;
  sname=${filename#"./build/"};

  clog "logs for push -> ${sname}";
  cat "./.ops/logs/push/${sname}";
  rm -f "./.ops/logs/push/${sname}";

  sleep 1;
done;
