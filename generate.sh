#!/bin/bash

set -euo pipefail

#
# Setup
#

echo "=> Setting up" >&2

# Save starting dir as the place to put the catalog files
catalog_dir="$(readlink -e .)"

# We need a few binaries at specific versions, so create a local cache for those
bin_dir="$(readlink -f bin)"
mkdir -p "$bin_dir"
export PATH="$bin_dir:$PATH"

# There will be some temporary files, put these together for neatness, and so
# they can be easily deleted.
work_dir="$(readlink -f workdir)"
rm -rf "$work_dir"
mkdir "$work_dir"

# Acquire any missing binaries
cd "$bin_dir"

# Being binaries, they're OS and Arch specific
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m | sed 's/x86_64/amd64/')"

# These are the specific versions we want
opm_version="v1.36.0"
yq_version="v4.22.1"
tf_version="v0.1.0"

# Store them first into a versioned filename so the bin dir never gets stale if
# the required versions change.
opm_filename="opm-$opm_version"
yq_filename="yq-$yq_version"
tf_filename="tf=$tf_version"

if ! [ -x "$opm_filename" ]
then
    echo "-> Downloading opm" >&2
    curl -sSfLo "$opm_filename" "https://github.com/operator-framework/operator-registry/releases/download/$opm_version/$os-$arch-opm"
    chmod +x "$opm_filename"
fi
ln -fs "$opm_filename" opm

if ! [ -x "$yq_filename" ]
then
    echo "-> Downloading yq" >&2
    curl -sSfLo "$yq_filename" "https://github.com/mikefarah/yq/releases/download/$yq_version/yq_${os}_$arch"
    chmod +x "$yq_filename"
fi
ln -fs "$yq_filename" yq

# tap-fitter doesn't have binary downloads at the moment, so assume golang is
# available and use that to install.
if ! [ -x "$tf_filename" ]
then
    echo "-> Downloading tap-fitter" >&2
    GOBIN="$bin_dir" go install "github.com/release-engineering/tap-fitter/cmd/tap-fitter@$tf_version"
    mv tap-fitter "$tf_filename"
fi
ln -fs "$tf_filename" tap-fitter

#
# Generate Config YAMLs
#

cd "$work_dir"

echo "=> Generating catalog configuration" >&2

# TODO Determine this from the repo somehow?
operator_name="rhbk-operator"

# TODO Determine this automatically somehow?
ocp_versions=(
    "v4.10"
    "v4.11"
    "v4.12"
    "v4.13"
    "v4.14"
    "v4.15"
)

echo "-> Applying bundle image list" >&2
render_config="semver-template.yaml"
{
    # Write intial config values
    cat <<EOF
schema: olm.semver
generatemajorchannels: true
generateminorchannels: false
stable:
  bundles:
EOF
    # Append the bundle image coordinates
    xargs -a "$catalog_dir/bundles" printf '    - image: %s\n'
} > "$render_config"

echo "-> Defining supported OCP versions" >&2
{
    # Preamble
    cat <<EOF
schema: olm.composite
components:
EOF
    # One component entry per OCP version supported
    for olm_version in "${ocp_versions[@]}"
    do
        cat <<EOF
  - name: $olm_version
    destination:
      path: $operator_name
    strategy:
      name: semver
      template:
        schema: olm.builder.semver
        config:
          input: $render_config
          output: catalog.yaml
EOF
    done
} > contributions.yaml

{
    # Preamble
    cat <<EOF
schema: olm.composite.catalogs
catalogs:
EOF
    # One catalog per OCP version supported
    for olm_version in "${ocp_versions[@]}"
    do
        cat <<EOF
- name: $olm_version
  destination:
    workingDir: catalog/$olm_version
  builders:
    - olm.builder.semver
EOF
    done
} > catalogs.yaml

#
# Generate Catalog
#

echo "=> Generating catalog for $operator_name" >&2

echo "-> opm render"
opm alpha render-template composite -f catalogs.yaml -c contributions.yaml

echo "-> tap-fitter"
tap-fitter --catalog-path catalogs.yaml --composite-path contributions.yaml --provider "$operator_name"

echo "-> Copying generated files"
cp -rf "catalog/." "$catalog_dir"

{
    echo ""
    echo "Catalog generated OK!"
} >&2
