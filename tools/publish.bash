#!/usr/bin/env bash

set -euo pipefail

: ${DOCKER_REPO}
: ${DOMAIN}
: ${S3_BUCKET}

if [[ -z "${DEPLOY_SSH_PRIVATE_KEY:-}" ]]; then
    DEPLOY_SSH_PRIVATE_KEY="$(base64 < "${DEPLOY_SSH_PUBLIC_KEY_FILE%.pub}")"
fi

make image push I=admin
make pull image push I=packaging

declare -A published_hashes
while read line; do
    pkg="$(awk -F/ '{ print $2 }' <<< "${line}")"
    hash="$(awk -F/ '{ print $3 }' <<< "${line}")"
    published_hashes["${pkg}"]="${hash}"
done < <(tools/list-s3-hashes.bash)

readarray -t langs < <(ls langs | grep '\.yaml$' | grep -Eo '^[^.]+')

for lang in "${langs[@]}"; do
    for type in lang config; do
        make script L="${lang}" T="${type}"
    done
done

fmt='%-31s %-8s %s\n'
printf "${fmt}" "PACKAGE" "CHANGE" "HASH"
printf "${fmt}" "-------" "------" "----"

declare -A local_hashes
for lang in "${langs[@]}"; do
    for type in lang config; do
        pkg="riju-${type}-${lang}"
        hash="$(sha1sum "build/${type}/${lang}/build.bash" | awk '{ print $1 }')"
        local_hashes["${pkg}"]="${hash}"
        published_hash="${published_hashes["${pkg}"]:-}"
        if [[ -z "${published_hash}" ]]; then
            printf "${fmt}" "${pkg}" "create" "${hash}"
        elif [[ "${published_hash}" != "${hash}" ]]; then
            printf "${fmt}" "${pkg}" "update" "${published_hash} => ${hash}"
        else
            printf "${fmt}" "${pkg}" "" "${hash}"
        fi
    done
done

if [[ -n "${CONFIRM:-}" ]]; then
    echo "Press enter to continue, or ctrl-C to abort..."
    read
fi

for lang in "${langs[@]}"; do
    for type in lang config; do
        pkg="riju-${type}-${lang}"
        hash="${local_hashes["${pkg}"]}"
        published_hash="${published_hashes["${pkg}"]:-}"
        if [[ "${published_hash}" != "${hash}" ]]; then
            make shell I=packaging CMD="make pkg L='${lang}' T='${type}'"
            make upload L="${lang}" T="${type}"
        fi
    done
done

for lang in "${langs[@]}"; do
    for type in lang config; do
        pkg="riju-${type}-${lang}"
        hash="${local_hashes["${pkg}"]}"
        published_hash="${published_hashes["${pkg}"]:-}"
        if [[ "${published_hash}" == "${hash}" ]]; then
            make download L="${lang}" T="${type}"
        fi
    done
done

composite_scripts_hash="$(node tools/hash-composite-image.js scripts)"
composite_registry_hash="$(node tools/hash-composite-image.js registry)"

if [[ "${composite_scripts_hash}" != "${composite_registry_hash}" ]]; then
    make image push I=composite
else
    make pull I=composite
fi

make shell I=composite CMD="make test PATIENCE=4"

make pull image push I=compile
make pull image push I=app

sha="$(git describe --match=always-omit-tag --always --abbrev=40 --dirty)"

image="${DOCKER_REPO}:app-${sha}"

docker tag "${DOCKER_REPO}:app" "${image}"
docker push "${image}"

tmpdir="$(mktemp -d)"

function cleanup {
    rm -rf "${tmpdir}"
}

trap cleanup EXIT

base64 -d <<< "${DEPLOY_SSH_PRIVATE_KEY}" > "${tmpdir}/id"
chmod go-rwx "${tmpdir}/id"

ssh -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i "${tmpdir}/id" "deploy@${DOMAIN}" "${image}"
