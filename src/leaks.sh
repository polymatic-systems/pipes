
set -e

cd "${POLYMATIC_ORIGINAL_DIRECTORY}";

POLYMATIC_START=$(date +%s);

# view files in ops directory

if ! command -v gitleaks > /dev/null; then
  clog "installing gitleaks";
  curl -s -L https://github.com/zricethezav/gitleaks/releases/download/v7.5.0/gitleaks-linux-amd64 -o /bin/gitleaks
fi;

clog "running gitleaks";

POLYMATIC_LEAKS="$(gitleaks --no-git --quiet --path="${PWD}/src" | jq -r '"\(.file)@\(.lineNumber)@\(.rule)"')"

POLYMATIC_RUNTIME="${POLYMATIC_RUNTIME} leaks -> $(($(date +%s) - POLYMATIC_START)) ;"

if [ -n "${POLYMATIC_LEAKS}" ]; then
  echo "#######################################################
  
secrets detected!
";

  printf "%s" "FILE@LINE@TYPE\n${POLYMATIC_LEAKS}" | awk -F '@' '{ printf("%-16s %-6s %s\n", $3, $2, $1) }';

  echo "
#######################################################";

  # shellcheck disable=SC2034
  POLYMATIC_JOB_FAIL="yes";
else
  echo "#######################################################

no secrets found
...
#######################################################";

fi;
