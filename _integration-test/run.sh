#!/usr/bin/env bash
set -ex

source install/_lib.sh
source install/dc-detect-version.sh

echo "${_group}Setting up variables and helpers ..."
export SENTRY_TEST_HOST="${SENTRY_TEST_HOST:-http://localhost:9000}"
TEST_USER='test@example.com'
TEST_PASS='test123TEST'
COOKIE_FILE=$(mktemp)

# Courtesy of https://stackoverflow.com/a/2183063/90297
trap_with_arg() {
  func="$1"
  shift
  for sig; do
    trap "$func $sig "'$LINENO' "$sig"
  done
}

DID_TEAR_DOWN=0
# the teardown function will be the exit point
teardown() {
  if [ "$DID_TEAR_DOWN" -eq 1 ]; then
    return 0
  fi
  DID_TEAR_DOWN=1

  if [ "$1" != "EXIT" ]; then
    echo "An error occurred, caught SIG$1 on line $2"
  fi

  echo "Tearing down ..."
  rm $COOKIE_FILE
  echo "Done."
}
trap_with_arg teardown ERR INT TERM EXIT
echo "${_endgroup}"

echo "${_group}Starting Sentry for tests ..."
# Disable beacon for e2e tests
echo 'SENTRY_BEACON=False' >>$SENTRY_CONFIG_PY
echo y | $dcr web createuser --force-update --superuser --email $TEST_USER --password $TEST_PASS
$dc up -d
printf "Waiting for Sentry to be up"
timeout 90 bash -c 'until $(curl -Isf -o /dev/null $SENTRY_TEST_HOST); do printf '.'; sleep 0.5; done'
echo ""
echo "${_endgroup}"

echo "${_group}Running tests ..."
get_csrf_token() { awk '$6 == "sc" { print $7 }' $COOKIE_FILE; }
sentry_api_request() { curl -s -H 'Accept: application/json; charset=utf-8' -H "Referer: $SENTRY_TEST_HOST" -H 'Content-Type: application/json' -H "X-CSRFToken: $(get_csrf_token)" -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$SENTRY_TEST_HOST/$1" "${@:2}"; }

login() {
  INITIAL_AUTH_REDIRECT=$(curl -sL -o /dev/null $SENTRY_TEST_HOST -w %{url_effective})
  if [ "$INITIAL_AUTH_REDIRECT" != "$SENTRY_TEST_HOST/auth/login/sentry/" ]; then
    echo "Initial /auth/login/ redirect failed, exiting..."
    echo "$INITIAL_AUTH_REDIRECT"
    exit 1
  fi

  CSRF_TOKEN_FOR_LOGIN=$(curl $SENTRY_TEST_HOST -sL -c "$COOKIE_FILE" | awk -F "['\"]" '
    /csrfmiddlewaretoken/ {
    print $4 "=" $6;
    exit;
  }')

  curl -sL --data-urlencode 'op=login' --data-urlencode "username=$TEST_USER" --data-urlencode "password=$TEST_PASS" --data-urlencode "$CSRF_TOKEN_FOR_LOGIN" "$SENTRY_TEST_HOST/auth/login/sentry/" -H "Referer: $SENTRY_TEST_HOST/auth/login/sentry/" -b "$COOKIE_FILE" -c "$COOKIE_FILE"
}

LOGIN_RESPONSE=$(login)
declare -a LOGIN_TEST_STRINGS=(
  '"isAuthenticated":true'
  '"username":"test@example.com"'
  '"isSuperuser":true'
)
for i in "${LOGIN_TEST_STRINGS[@]}"; do
  echo "Testing '$i'..."
  echo "$LOGIN_RESPONSE" | grep "${i}[,}]" >&/dev/null
  echo "Pass."
done
echo "${_endgroup}"

echo "${_group}Running moar tests !!!"
# Set up initial/required settings (InstallWizard request)
sentry_api_request "api/0/internal/options/?query=is:required" -X PUT --data '{"mail.use-tls":false,"mail.username":"","mail.port":25,"system.admin-email":"ben@byk.im","mail.password":"","system.url-prefix":"'"$SENTRY_TEST_HOST"'","auth.allow-registration":false,"beacon.anonymous":true}' >/dev/null

SENTRY_DSN=$(sentry_api_request "api/0/projects/sentry/internal/keys/" | jq -r '.[0].dsn.public')
# We ignore the protocol and the host as we already know those
DSN_PIECES=($(echo $SENTRY_DSN | sed -ne 's|^https\{0,1\}://\([0-9a-z]\{1,\}\)@[^/]\{1,\}/\([0-9]\{1,\}\)$|\1 \2|p' | tr ' ' '\n'))
SENTRY_KEY=${DSN_PIECES[0]}
PROJECT_ID=${DSN_PIECES[1]}

TEST_EVENT_ID=$(
  export LC_ALL=C
  head /dev/urandom | tr -dc "a-f0-9" | head -c 32
)
# Thanks @untitaker - https://forum.sentry.io/t/how-can-i-post-with-curl-a-sentry-event-which-authentication-credentials/4759/2?u=byk
echo "Creating test event..."
curl -sf --data '{"event_id": "'"$TEST_EVENT_ID"'","level":"error","message":"a failure","extra":{"object":"42"}}' -H 'Content-Type: application/json' -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=$SENTRY_KEY, sentry_client=test-bash/0.1" "$SENTRY_TEST_HOST/api/$PROJECT_ID/store/" -o /dev/null

EVENT_PATH="api/0/projects/sentry/internal/events/$TEST_EVENT_ID/"
export -f sentry_api_request get_csrf_token
export SENTRY_TEST_HOST COOKIE_FILE EVENT_PATH
printf "Getting the test event back"
timeout 60 bash -c 'until $(sentry_api_request "$EVENT_PATH" -Isf -X GET -o /dev/null); do printf '.'; sleep 0.5; done'
echo " got it!"

EVENT_RESPONSE=$(sentry_api_request "$EVENT_PATH")
declare -a EVENT_TEST_STRINGS=(
  '"eventID":"'"$TEST_EVENT_ID"'"'
  '"message":"a failure"'
  '"title":"a failure"'
  '"object":"42"'
)
for i in "${EVENT_TEST_STRINGS[@]}"; do
  echo "Testing '$i'..."
  echo "$EVENT_RESPONSE" | grep "${i}[,}]" >&/dev/null
  echo "Pass."
done
echo "${_endgroup}"

echo "${_group}Ensure cleanup crons are working ..."
$dc ps -a | tee debug.log | grep -E -e '\-cleanup\s+running\s+' -e '\-cleanup[_-].+\s+Up\s+'
# to debug https://github.com/getsentry/self-hosted/issues/1171
echo '------------------------------------------'
cat debug.log
echo '------------------------------------------'
echo "${_endgroup}"

echo "${_group}Test symbolicator works ..."
SENTRY_ORG="${SENTRY_ORG:-sentry}"
SENTRY_PROJECT="${SENTRY_PROJECT:-native}"
SENTRY_TEAM="${SENTRY_TEAM:-sentry}"
# First set up a new project if it doesn't exist already
PROJECT_JSON=$(jq -n -c --arg name "$SENTRY_PROJECT" --arg slug "$SENTRY_PROJECT" '$ARGS.named')
NATIVE_PROJECT_ID=$(sentry_api_request "api/0/teams/$SENTRY_ORG/$SENTRY_TEAM/projects/" | jq -r '.[]|select(.slug == "'"$SENTRY_PROJECT"'")|.id')
if [ -z "${NATIVE_PROJECT_ID}" ]; then
  NATIVE_PROJECT_ID=$(sentry_api_request "api/0/teams/$SENTRY_ORG/$SENTRY_TEAM/projects/" -X POST --data "$PROJECT_JSON" | jq -r '. // null | .id')
fi
# Set up sentry-cli command
SCOPES=$(jq -n -c --argjson scopes '["event:admin", "event:read", "member:read", "org:read", "team:read", "project:read", "project:write", "team:write"]' '$ARGS.named')
SENTRY_AUTH_TOKEN=$(sentry_api_request "api/0/api-tokens/" -X POST --data "$SCOPES" | jq -r '.token')
SENTRY_DSN=$(sentry_api_request "api/0/projects/sentry/native/keys/" | jq -r '.[0].dsn.secret')
# Then upload the symbols to that project (note the container mounts pwd to /work)
SENTRY_URL="$SENTRY_TEST_HOST" sentry-cli upload-dif --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" --auth-token "$SENTRY_AUTH_TOKEN" _integration-test/windows.sym
# Get public key for minidump upload
PUBLIC_KEY=$(sentry_api_request "api/0/projects/sentry/native/keys/" | jq -r '.[0].public')
# Upload the minidump to be processed, this returns the event ID of the crash dump
EVENT_ID=$(sentry_api_request "api/$NATIVE_PROJECT_ID/minidump/?sentry_key=$PUBLIC_KEY" -X POST -F 'upload_file_minidump=@_integration-test/windows.dmp' | sed 's/\-//g')
# We have to wait for the item to be processed
for i in {0..60..10}; do
  EVENT_PROCESSED=$(sentry_api_request "api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/events/" | jq -r '.[]|select(.id == "'"$EVENT_ID"'")|.id')
  if [ -z "$EVENT_PROCESSED" ]; then
    sleep "$i"
  else
    break
  fi
done
if [ -z "$EVENT_PROCESSED" ]; then
  echo "Hm, the event $EVENT_ID didn't exist... listing events that do exist:"
  sentry_api_request "api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/events/" | jq .
  exit 1
fi
echo "${_endgroup}"

echo "${_group}Test custom CAs work ..."
source _integration-test/custom-ca-roots/setup.sh
$dcr --no-deps web python3 /etc/sentry/test-custom-ca-roots.py
source _integration-test/custom-ca-roots/teardown.sh
echo "${_endgroup}"

echo "${_group}Test that replays work ..."
echo "Creating test replay..."
TEST_REPLAY_ID=$(
  export LC_ALL=C
  head /dev/urandom | tr -dc "a-f0-9" | head -c 32
)
TIME_IN_SECONDS=$(date +%s)
curl -sf --data '{"event_id":"'"$TEST_REPLAY_ID"'","sdk":{"name":"sentry.javascript.browser","version":"7.38.0"}}
{"type":"replay_event"}
{"type":"replay_event","replay_start_timestamp":$TIME_IN_SECONDS,"timestamp":$TIME_IN_SECONDS,"error_ids":[],"trace_ids":[],"urls":["example.com"],"replay_id":"'"$TEST_REPLAY_ID"'","segment_id":0,"replay_type":"session","event_id":"'"$TEST_REPLAY_ID"'","environment":"production","sdk":{"name":"sentry.javascript.browser","version":"7.38.0"},"request":{"url":"example.com","headers":{"platform":"javascript","contexts":{"replay":{"session_sample_rate":1,"error_sample_rate":1}}}
{"type":"replay_recording","length":19}
{"segment_id":0}
[]' -H 'Content-Type: application/json' -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=$SENTRY_KEY, sentry_client=test-bash/0.1" "$SENTRY_TEST_HOST/api/$PROJECT_ID/envelope/" -o /dev/null

printf "Getting the test replay back"
REPLAY_SEGMENT_PATH="api/0/projects/sentry/internal/replays/$TEST_EVENT_ID/recording-segments/?download"
REPLAY_EVENT_PATH="api/0/projects/sentry/internal/replays/$TEST_EVENT_ID/"
timeout 60 bash -c 'until $(sentry_api_request "$REPLAY_EVENT_PATH" -Isf -X GET -o /dev/null); do printf '.'; sleep 0.5; done'
timeout 60 bash -c 'until $(sentry_api_request "$REPLAY_SEGMENT_PATH" -Isf -X GET -o /dev/null); do printf '.'; sleep 0.5; done'
echo " got it!"
echo "${_endgroup}"

# Table formatting based on https://stackoverflow.com/a/39144364
COMPOSE_PS_OUTPUT=$(docker compose ps --format json | jq -r \
  '.[] |
   # we only care about running services. geoipupdate always exits, so we ignore it
   select(.State != "running" and .Service != "geoipupdate") |
   # Filter to only show the service name and state
   with_entries(select(.key | in({"Service":1, "State":1})))
 ')

if [[ "$COMPOSE_PS_OUTPUT" ]]; then
  echo "Services failed, oh no!"
  echo "$COMPOSE_PS_OUTPUT" | jq -rs '["Service","State"], ["-------","-----"], (.[]|[.Service, .State]) | @tsv'
  exit 1
fi
