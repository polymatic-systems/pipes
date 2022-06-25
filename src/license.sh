
set -e

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START=$(date +%s);

if ! command -v license; then
  clog "installing license finder";
  apt-get -qq update || yum -q check-update && \
  apt-get -qq install -y wget tar git || yum -q -y install wget tar git && \
  wget -q https://github.com/go-enry/go-license-detector/releases/download/v4.3.0/license-detector-v4.3.0-linux-amd64.tar.gz && \
  tar -xf license-detector-v4.3.0-linux-amd64.tar.gz > /dev/null && \
  rm -f license-detector-v4.3.0-linux-amd64.tar.gz && \
  mv license-detector /bin/license > /dev/null;
fi;

mkdir -p artifacts;
touch artifacts/licenses.txt;

clog "running license finder";

# first argument is directory depth
function check_licenses() {
  echo "$(< pipeline/options_license.txt)" | while read -r line; do
    clog "scanning for licenses -> src/${line}";
    current_dir_count="0";
    license_dir_count="$(find "src/${line}" -maxdepth 2 -mindepth 1 -type d | wc -l | xargs)";
    find "src/${line}" -maxdepth "${1}" -mindepth 1 -type d | while read -r dir; do
      current_dir_count="$((current_dir_count + 1))";
      if [ "$((current_dir_count % 10))" = "0" ]; then
        clog "scanning directory -> ${current_dir_count} / ${license_dir_count}";
      fi;
      result=$(/bin/license "$dir");
      if ! (echo "$result" | grep -q 'no license file was found'); then
        echo "${result}" >> artifacts/licenses.txt;
      fi;
    done;
  done;
}

if [ ! -f ./pipeline/options_license.txt ]; then
  clog "pipeline/options_license.txt not found, default to /src";
  echo 'src' > ./pipeline/options_license.txt;
  check_licenses "3";
else
  check_licenses "2";
fi;

echo '';
cat artifacts/licenses.txt;

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} licenses -> $(($(date +%s) - POLYMATIC_START)) ;"
