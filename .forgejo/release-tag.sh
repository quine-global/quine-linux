#!/usr/bin/env bash
# Tags the next release and pushes the tag, which starts iso.yml's release
# build. Used by release.yml and beta-release.yml, from a checkout of main
# with full history and a remote `origin` it can push tags to.
#
# Environment:
#   BUMP     prerelease | release | patch | minor | major
#   PRE      prerelease label: alpha | beta | rc | none
#   VERSION  exact version instead (1.0.0 or 1.0.0-rc.1, no v); optional
#   DRY_RUN  true: only say what it would tag
#   HAS_TOKEN true when the push uses RELEASE_TOKEN (a tag pushed with the
#            automatic token doesn't start iso.yml)
#
# It tags the newest commit on main that isn't marked [skip ci] (or one of
# Forgejo's other skip strings): Forgejo skips a push whose head commit
# carries one, tag pushes included, so tagging such a commit would make a
# tag and no release. Those commits can't change the image, so the release
# is the same either way.
set -euo pipefail

: "${BUMP:?}" "${PRE:=none}" "${VERSION:=}" "${DRY_RUN:=false}" "${HAS_TOKEN:=false}"

git fetch --force --tags origin
# Newest v* tag in semver order: versionsort.suffix=- puts v0.1.0-alpha.2
# before v0.1.0.
last=$(git -c versionsort.suffix=- tag -l 'v*' --sort=-v:refname | head -1)
last=${last:-v0.0.0}
echo "last release: $last"

semver='^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+)\.([0-9]+))?$'
[[ ${last#v} =~ $semver ]] || { echo "::error::$last isn't vX.Y.Z or vX.Y.Z-label.N"; exit 1; }
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
label=${BASH_REMATCH[5]} n=${BASH_REMATCH[6]}
[ "$PRE" = none ] && PRE=

if [ -n "$VERSION" ]; then
  next=${VERSION#v}
  [[ $next =~ $semver ]] || { echo "::error::version $VERSION isn't X.Y.Z or X.Y.Z-label.N"; exit 1; }
else
  case $BUMP in
    prerelease)
      [ -n "$PRE" ] || { echo "::error::prerelease needs a pre label"; exit 1; }
      if [ -z "$label" ]; then
        next="$major.$minor.$((patch + 1))-$PRE.1"
      elif [ "$label" = "$PRE" ]; then
        next="$major.$minor.$patch-$PRE.$((n + 1))"
      else
        next="$major.$minor.$patch-$PRE.1"
      fi ;;
    release)
      [ -n "$label" ] || {
        echo "::error::$last is already a full release; for the next one, use bump: patch (or minor, major) with pre: none"
        exit 1
      }
      next="$major.$minor.$patch" ;;
    patch) next="$major.$minor.$((patch + 1))" ;;
    minor) next="$major.$((minor + 1)).0" ;;
    major) next="$((major + 1)).0.0" ;;
    *) echo "::error::unknown bump $BUMP"; exit 1 ;;
  esac
  if [ -n "$PRE" ] && [[ $BUMP =~ ^(patch|minor|major)$ ]]; then
    next="$next-$PRE.1"
  fi
fi
tag="v$next"

# Never move or reuse a tag, and only go forwards.
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "::error::$tag already exists"; exit 1
fi
# Semver order: X.Y.Z numerically, then a full release after its
# prereleases, then the label (alpha < beta < rc), then N.
key() {
  [[ ${1#v} =~ $semver ]]
  printf '%09d.%09d.%09d.%d.%s.%09d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
    "${BASH_REMATCH[3]}" "$([ -z "${BASH_REMATCH[5]}" ] && echo 1 || echo 0)" \
    "${BASH_REMATCH[5]:-~}" "${BASH_REMATCH[6]:-0}"
}
if [[ ! $(key "$tag") > $(key "$last") ]]; then
  echo "::error::$tag isn't newer than $last"; exit 1
fi

# The newest commit on main without a skip string.
commit=
while read -r sha; do
  if ! git log -1 --format=%B "$sha" |
    grep -qiF -e '[skip ci]' -e '[ci skip]' -e '[no ci]' -e '[skip actions]' -e '[actions skip]'; then
    commit=$sha; break
  fi
done < <(git rev-list --first-parent HEAD)
[ -n "$commit" ] || { echo "::error::every commit on main is marked [skip ci]"; exit 1; }
if [ "$commit" != "$(git rev-parse HEAD)" ]; then
  echo "main's newest commits are marked [skip ci]; tagging the last one that isn't"
fi
echo "next release: $tag on $(git log -1 --format='%h %s' "$commit")"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "tag=$tag" >> "$GITHUB_OUTPUT"

if [ "$DRY_RUN" = true ]; then
  echo "dry run: tagged nothing"
  exit 0
fi
[ "$HAS_TOKEN" = true ] || {
  echo "::error::RELEASE_TOKEN isn't set: a tag pushed with the automatic token wouldn't start iso.yml"
  exit 1
}
git config user.name "${GITHUB_ACTOR:-release}"
git config user.email "${GITHUB_ACTOR:-release}@noreply.forge.in.quineglobal.com"
git tag -a "$tag" -m "quine-linux $tag" "$commit"
git push origin "refs/tags/$tag"
echo "pushed $tag; iso.yml builds and publishes it:"
echo "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions"
