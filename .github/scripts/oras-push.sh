#!/usr/bin/env bash
# nosi: push one artifact to GHCR with the standard annotation set.
# Sourced by .github/workflows/build.yml (the x86 matrix job and the
# Raspberry Pi job) so there is exactly one copy of the publish logic.
#
# Contract (all provided by the sourcing step):
#   env:  REPO ROLLING SHA   shell: report   cwd: the artifact directory
#   args: $1 ref  $2 artifact-type  $3 layer-media  $4 file
#         $5 metadata.json  $6 description
#
# Push + retag are retried: ghcr.io intermittently resets upload streams
# and is eventually consistent (a tag lookup right after a successful
# push can 404), so no registry interaction here is one-shot.
# shellcheck disable=SC2154  # report/ROLLING/SHA/REPO come from the sourcing step
oras_push() {
    local ref=$1 atype=$2 lmedia=$3 file=$4 meta=$5 desc=$6
    jq -e . "$meta" >/dev/null
    local variant shape distro distro_version kernel_release built arch
    variant=$(jq -r '.nosi.variant // empty' "$meta")
    shape=$(jq -r '.nosi.shape // empty' "$meta")
    distro=$(jq -r '.distro.id // empty' "$meta")
    distro_version=$(jq -r '.distro.version_id // empty' "$meta")
    kernel_release=$(jq -r '.kernel.release // empty' "$meta")
    built=$(jq -r '.nosi.built // empty' "$meta")
    arch=$(jq -r '.architecture // empty' "$meta")
    local attempts=0
    until oras push "$ref" \
        --artifact-type "$atype" \
        --annotation "org.opencontainers.image.title=nosi-${variant}" \
        --annotation "org.opencontainers.image.description=${desc}" \
        --annotation "org.opencontainers.image.version=${ROLLING}" \
        --annotation "org.opencontainers.image.created=${built}" \
        --annotation "org.opencontainers.image.revision=${SHA}" \
        --annotation "org.opencontainers.image.source=https://github.com/${REPO}" \
        --annotation "org.opencontainers.image.url=https://github.com/${REPO}" \
        --annotation "org.opencontainers.image.architecture=${arch}" \
        --annotation "org.opencontainers.image.os=linux" \
        --annotation "dev.nosi.variant=${variant}" \
        --annotation "dev.nosi.shape=${shape}" \
        --annotation "dev.nosi.distro=${distro}" \
        --annotation "dev.nosi.distro-version=${distro_version}" \
        --annotation "dev.nosi.kernel-release=${kernel_release}" \
        "${file}:${lmedia}" \
        "${file}.sha256:text/plain" \
        "${report}:application/vnd.nosi.build-report.v1+zip" \
        "${report}.sha256:text/plain" \
        "${meta}:application/vnd.nosi.metadata.v1+json"; do
        attempts=$((attempts + 1))
        if [ $attempts -ge 3 ]; then
            echo "::error::oras push $ref failed after $attempts attempts"
            return 1
        fi
        echo "::warning::oras push $ref attempt $attempts failed; retrying"
        sleep $((attempts * 15))
    done
    # Retag as :latest. Retried because GHCR is eventually
    # consistent: a lookup right after the push can 404 ("not
    # found") before the new tag propagates, even though the
    # push itself succeeded.
    local tag_attempts=0
    until oras tag "$ref" latest; do
        tag_attempts=$((tag_attempts + 1))
        if [ $tag_attempts -ge 5 ]; then
            echo "::error::oras tag $ref latest failed after $tag_attempts attempts"
            return 1
        fi
        echo "::warning::oras tag $ref latest attempt $tag_attempts failed (GHCR propagation lag?); retrying"
        sleep $((tag_attempts * 10))
    done
}
