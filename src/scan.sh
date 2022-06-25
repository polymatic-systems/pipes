
set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}/src";

POLYMATIC_START=$(date +%s);

mkdir -p ../artifacts/scan;

if false; then
  clog "ruby detected, running brakeman";
  gem install brakeman;
  brakeman -q --no-exit-on-warn --no-exit-on-error -o ../artifacts/scan/source-ruby-report.json;
fi;

# https://slscan.io/en/latest/

PIPE_SHIFTLEFT_FLAGS='--metrics=off --config=p/ci';
export PIPE_SHIFTLEFT_FLAGS;
if [ -f ./pipeline/options_scan.txt ]; then
  PIPE_SHIFTLEFT_FLAGS="$(cat ./pipeline/options_scan.txt)";
fi;

# shellcheck disable=SC2034
scan --build --mode ci --local-only --convert --out_dir ../artifacts/scan || POLYMATIC_JOB_FAIL='yes';

clog "completed code scan";
clog "you can view the results above or by downloading the artifacts";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} scan -> $(($(date +%s)-POLYMATIC_START)) ;";
