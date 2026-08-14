#!/usr/bin/env bash
#
# Exercises firestore.rules against the local Firestore emulator.
#
# ## Why this exists
#
# The rules are the security boundary of the shared playlist catalogue, and
# they run on Google's servers — not in the app. `flutter test` cannot reach
# them, so a green Flutter suite is no evidence at all that they are right. This
# is the only honest check short of deploying.
#
# It uses the emulator's REST API directly with per-user unsigned JWTs, which
# the emulator accepts and reads `request.auth` from. No npm, no extra
# dependency, no test framework — curl and the emulator the repo already
# configures.
#
# ## Running it
#
#   firebase emulators:start --only firestore --project demo-aurix   # terminal 1
#   bash tool/verify_rules.sh                                        # terminal 2
#
# Exits non-zero if any expectation fails.
#
# ## What it covers
#
# The properties the shared catalogue turns on: that any signed-in account can
# read a playlist somebody else imported, that nobody unauthenticated can, that
# personal collections stay unreadable across accounts, that a create cannot
# claim another user's name, that provenance and source identity are immutable,
# and that deletes belong to the importer.

HOST="http://127.0.0.1:8081"
PROJ="demo-aurix"
BASE="$HOST/v1/projects/$PROJ/databases/(default)/documents"

pass=0; fail=0

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

# The emulator accepts an unsigned JWT and reads request.auth from its payload.
token() {
  local uid="$1"
  local h='{"alg":"none","kid":"","typ":"JWT"}'
  local p="{\"iss\":\"https://securetoken.google.com/$PROJ\",\"aud\":\"$PROJ\",\"auth_time\":1700000000,\"user_id\":\"$uid\",\"sub\":\"$uid\",\"iat\":1700000000,\"exp\":1900000000,\"email_verified\":true,\"firebase\":{\"identities\":{},\"sign_in_provider\":\"password\"}}"
  printf '%s.%s.' "$(printf '%s' "$h" | b64url)" "$(printf '%s' "$p" | b64url)"
}

# check <expected-code> <label> <curl args...>
check() {
  local want="$1"; shift
  local label="$1"; shift
  local got
  got=$(curl -s -o /tmp/rc_body.json -w "%{http_code}" "$@")
  if [ "$got" = "$want" ]; then
    printf '  PASS  %-64s [%s]\n' "$label" "$got"; pass=$((pass+1))
  else
    printf '  FAIL  %-64s [got %s, want %s]\n' "$label" "$got" "$want"; fail=$((fail+1))
    head -c 300 /tmp/rc_body.json; echo
  fi
}

AUTH_A="Authorization: Bearer $(token user_a)"
AUTH_B="Authorization: Bearer $(token user_b)"
AUTH_C="Authorization: Bearer $(token user_c)"
OWNER="Authorization: Bearer owner"   # bypasses rules — used only to seed
JSON="Content-Type: application/json"

PL="pl_spotify_37i9dQZF1DX3lmpQSniUBH"

# Cleared first, so the script is idempotent. The create checks below assert
# `currentDocument.exists=false`, which returns 409 rather than 403 against a
# document a previous run left behind — a false failure that says nothing about
# the rules.
echo "== clearing previous state (rules bypassed) =="
for doc in "playlists/$PL/tracks/spotify_t1" "playlists/$PL" \
           "playlists/pl_spotify_sad" "playlists/pl_spotify_forged" \
           "playlists/pl_spotify_anon" "users/user_a/likedTracks/spotify_secret"; do
  curl -s -o /dev/null -X DELETE -H "$OWNER" "$BASE/$doc"
done
echo "   cleared"

echo
echo "== seeding (rules bypassed) =="
curl -s -o /dev/null -X PATCH "$BASE/playlists/$PL" -H "$OWNER" -H "$JSON" -d '{
 "fields":{
  "name":{"stringValue":"Love"},
  "description":{"stringValue":"Imported from Spotify"},
  "coverUrl":{"stringValue":"https://cdn.example/love.jpg"},
  "source":{"stringValue":"spotify"},
  "sourceId":{"stringValue":"37i9dQZF1DX3lmpQSniUBH"},
  "sourceUrl":{"stringValue":"https://open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH"},
  "searchTitle":{"stringValue":"love"},
  "searchTokens":{"arrayValue":{"values":[{"stringValue":"l"},{"stringValue":"lo"},{"stringValue":"lov"},{"stringValue":"love"}]}},
  "trackCount":{"integerValue":"1"},
  "importedByUserId":{"stringValue":"user_a"},
  "importedBy":{"stringValue":"Ada"},
  "importedAt":{"timestampValue":"2026-01-01T00:00:00Z"},
  "createdAt":{"timestampValue":"2026-01-01T00:00:00Z"},
  "updatedAt":{"timestampValue":"2026-01-01T00:00:00Z"}}}'

curl -s -o /dev/null -X PATCH "$BASE/playlists/$PL/tracks/spotify_t1" -H "$OWNER" -H "$JSON" -d '{
 "fields":{"title":{"stringValue":"Track One"},"artist":{"stringValue":"Neon Meridian"},
 "position":{"doubleValue":1024}}}'

curl -s -o /dev/null -X PATCH "$BASE/users/user_a/likedTracks/spotify_secret" -H "$OWNER" -H "$JSON" -d '{
 "fields":{"title":{"stringValue":"A Private Favourite"},"artist":{"stringValue":"Neon Meridian"}}}'
echo "   seeded"

echo
echo "== discovery: the shared catalogue is readable by every signed-in user =="
check 403 "unauthenticated read of a shared playlist is refused" \
  "$BASE/playlists/$PL"
check 200 "User C (imported nothing) reads User A's playlist" \
  -H "$AUTH_C" "$BASE/playlists/$PL"
check 200 "User B reads User A's playlist" \
  -H "$AUTH_B" "$BASE/playlists/$PL"
check 200 "User C reads its tracks" \
  -H "$AUTH_C" "$BASE/playlists/$PL/tracks/spotify_t1"
check 200 "User C lists the whole catalogue collection" \
  -H "$AUTH_C" "$BASE/playlists?pageSize=10"
check 403 "unauthenticated list of the catalogue is refused" \
  "$BASE/playlists?pageSize=10"

echo
echo "== privacy: personal collections are untouched =="
check 403 "User C cannot read User A's liked songs" \
  -H "$AUTH_C" "$BASE/users/user_a/likedTracks/spotify_secret"
check 200 "User A can read their own liked songs" \
  -H "$AUTH_A" "$BASE/users/user_a/likedTracks/spotify_secret"
check 403 "User C cannot read User A's profile" \
  -H "$AUTH_C" "$BASE/users/user_a"
check 403 "User C cannot list User A's personal playlists" \
  -H "$AUTH_C" "$BASE/users/user_a/playlists?pageSize=10"

echo
echo "== writes: create must claim its own author =="
commit() { # commit <auth> <json>
  curl -s -o /tmp/rc_body.json -w "%{http_code}" -X POST "$BASE:commit" \
    -H "$1" -H "$JSON" -d "$2"
}

mkdoc() { # mkdoc <docid> <importedByUserId>
cat <<EOF
{"writes":[{"update":{"name":"projects/$PROJ/databases/(default)/documents/playlists/$1",
"fields":{
 "name":{"stringValue":"Sad"},
 "description":{"stringValue":"d"},
 "coverUrl":{"stringValue":""},
 "source":{"stringValue":"spotify"},
 "sourceId":{"stringValue":"$1"},
 "sourceUrl":{"stringValue":""},
 "searchTitle":{"stringValue":"sad"},
 "searchTokens":{"arrayValue":{"values":[{"stringValue":"sad"}]}},
 "trackCount":{"integerValue":"0"},
 "importedByUserId":{"stringValue":"$2"},
 "importedBy":{"stringValue":"Ben"}}},
"updateTransforms":[
 {"fieldPath":"importedAt","setToServerValue":"REQUEST_TIME"},
 {"fieldPath":"createdAt","setToServerValue":"REQUEST_TIME"},
 {"fieldPath":"updatedAt","setToServerValue":"REQUEST_TIME"}],
"currentDocument":{"exists":false}}]}
EOF
}

got=$(commit "$AUTH_B" "$(mkdoc pl_spotify_forged user_a)")
if [ "$got" = "403" ]; then printf '  PASS  %-64s [403]\n' "User B cannot publish under User A's name"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 403]\n' "User B cannot publish under User A's name" "$got"; fail=$((fail+1)); head -c 300 /tmp/rc_body.json; echo; fi

got=$(commit "$AUTH_B" "$(mkdoc pl_spotify_sad user_b)")
if [ "$got" = "200" ]; then printf '  PASS  %-64s [200]\n' "User B publishes their own import"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 200]\n' "User B publishes their own import" "$got"; fail=$((fail+1)); head -c 300 /tmp/rc_body.json; echo; fi

got=$(commit "" "$(mkdoc pl_spotify_anon user_x)")
if [ "$got" = "403" ]; then printf '  PASS  %-64s [403]\n' "an unauthenticated create is refused"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 403]\n' "an unauthenticated create is refused" "$got"; fail=$((fail+1)); fi

echo
echo "== writes: who may change a shared playlist =="
rename() { # rename <auth> <newname>
cat <<EOF
{"writes":[{"update":{"name":"projects/$PROJ/databases/(default)/documents/playlists/$PL",
"fields":{"name":{"stringValue":"$1"},
 "searchTitle":{"stringValue":"spam"},
 "searchTokens":{"arrayValue":{"values":[{"stringValue":"spam"}]}},
 "trackCount":{"integerValue":"1"}}},
"updateMask":{"fieldPaths":["name","searchTitle","searchTokens","trackCount","updatedAt"]},
"updateTransforms":[{"fieldPath":"updatedAt","setToServerValue":"REQUEST_TIME"}]}]}
EOF
}

got=$(commit "$AUTH_C" "$(rename SPAM)")
if [ "$got" = "403" ]; then printf '  PASS  %-64s [403]\n' "a passer-by cannot retitle a shared playlist"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 403]\n' "a passer-by cannot retitle a shared playlist" "$got"; fail=$((fail+1)); head -c 300 /tmp/rc_body.json; echo; fi

got=$(commit "$AUTH_A" "$(rename 'Love Songs')")
if [ "$got" = "200" ]; then printf '  PASS  %-64s [200]\n' "the importer may retitle it"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 200]\n' "the importer may retitle it" "$got"; fail=$((fail+1)); head -c 300 /tmp/rc_body.json; echo; fi

syncbump() {
cat <<EOF
{"writes":[{"update":{"name":"projects/$PROJ/databases/(default)/documents/playlists/$PL",
"fields":{"trackCount":{"integerValue":"2"}}},
"updateMask":{"fieldPaths":["trackCount","syncedAt","updatedAt"]},
"updateTransforms":[
 {"fieldPath":"syncedAt","setToServerValue":"REQUEST_TIME"},
 {"fieldPath":"updatedAt","setToServerValue":"REQUEST_TIME"}]}]}
EOF
}

got=$(commit "$AUTH_C" "$(syncbump)")
if [ "$got" = "200" ]; then printf '  PASS  %-64s [200]\n' "any signed-in user may record a re-sync"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 200]\n' "any signed-in user may record a re-sync" "$got"; fail=$((fail+1)); head -c 300 /tmp/rc_body.json; echo; fi

steal() {
cat <<EOF
{"writes":[{"update":{"name":"projects/$PROJ/databases/(default)/documents/playlists/$PL",
"fields":{"importedByUserId":{"stringValue":"user_c"},"trackCount":{"integerValue":"2"}}},
"updateMask":{"fieldPaths":["importedByUserId","trackCount","updatedAt"]},
"updateTransforms":[{"fieldPath":"updatedAt","setToServerValue":"REQUEST_TIME"}]}]}
EOF
}
got=$(commit "$AUTH_C" "$(steal)")
if [ "$got" = "403" ]; then printf '  PASS  %-64s [403]\n' "provenance cannot be taken over"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 403]\n' "provenance cannot be taken over" "$got"; fail=$((fail+1)); head -c 300 /tmp/rc_body.json; echo; fi

repoint() {
cat <<EOF
{"writes":[{"update":{"name":"projects/$PROJ/databases/(default)/documents/playlists/$PL",
"fields":{"sourceId":{"stringValue":"somethingelse"},"trackCount":{"integerValue":"2"}}},
"updateMask":{"fieldPaths":["sourceId","trackCount","updatedAt"]},
"updateTransforms":[{"fieldPath":"updatedAt","setToServerValue":"REQUEST_TIME"}]}]}
EOF
}
got=$(commit "$AUTH_A" "$(repoint)")
if [ "$got" = "403" ]; then printf '  PASS  %-64s [403]\n' "even the importer cannot repoint it at other content"; pass=$((pass+1));
else printf '  FAIL  %-64s [got %s, want 403]\n' "even the importer cannot repoint it at other content" "$got"; fail=$((fail+1)); head -c 300 /tmp/rc_body.json; echo; fi

echo
echo "== deletes =="
check 403 "User C cannot delete a track from a shared playlist" \
  -X DELETE -H "$AUTH_C" "$BASE/playlists/$PL/tracks/spotify_t1"
check 403 "User C cannot delete the shared playlist" \
  -X DELETE -H "$AUTH_C" "$BASE/playlists/$PL"
check 200 "the importer can delete a track" \
  -X DELETE -H "$AUTH_A" "$BASE/playlists/$PL/tracks/spotify_t1"
check 200 "the importer can delete the playlist" \
  -X DELETE -H "$AUTH_A" "$BASE/playlists/$PL"

echo
echo "== song catalogue is unchanged =="
check 403 "unauthenticated read of /catalog/global/songs is refused" \
  "$BASE/catalog/global/songs/sng_x"

echo
echo "-------------------------------------------"
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
