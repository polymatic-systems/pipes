
# run this in image -> returntocorp/semgrep-agent

set -e;

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START=$(date +%s);

# https://github.com/returntocorp/semgrep
# https://github.com/returntocorp/semgrep-rules

PIPE_SEMGREP_FLAGS='--metrics=off --config=p/ci';
export PIPE_SEMGREP_FLAGS;
if [ -f ./pipeline/options_scan_semgrep.txt ]; then
  PIPE_SEMGREP_FLAGS="$(cat ./pipeline/options_scan_semgrep.txt)";
fi;

mkdir -p ./artifacts/scan;

semgrep "${PIPE_SEMGREP_FLAGS}" /src -o ./artifacts/scan/report.html;

clog "completed scan";
clog "you can view the results above or by downloading the artifacts";

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} scan -> $(($(date +%s)-POLYMATIC_START)) ;";
