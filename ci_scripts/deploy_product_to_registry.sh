#!/usr/bin/env bash
test -n "${VERBOSE}" && set -x

#
# Usage printing function
#
usage ()
{
    test -n "${*}" && echo "${*}"
cat <<END_USAGE
Usage: ${0} {options}
    where {options} include:

    * -p, --product
        The name of the product for which to build a docker image
    * -r, --registry
        The registry to deploy new image tags to
    -s, --shim
        the name of the operating system for which to build a docker image
    -v, --version
        the version of the product for which to build a docker image
        this setting overrides the versions in the version file of the target product
    --verbose-build
        verbose docker build not using docker buildkit
    --dry-run
        does everything except actually call the docker command and prints it instead
    --help
        Display general usage information
END_USAGE
    exit 99
}

function tag_and_push ()
{
    _source="${FOUNDATION_REGISTRY}/${productToDeploy}:${fullTag}"
    _target="${registryToDeployTo}/${productToDeploy}:${1}"
    ${dryRun} docker tag ${_source} ${_target}
    if test -z "${isLocalBuild}" || test -n "${dryRun}" ; 
    then
        banner Pushing ${_target}
        ${dryRun} docker push ${_target}
        ${dryRun} docker image rm -f ${_target}
    fi
}

while ! test -z "${1}" ; 
do
    case "${1}" in
        -d|--default-shim)
            shift
            test -z "${1}" && usage "You must provide a default OS Shim"
            defaultShim="${1}"
            ;;
        -p|--product)
            shift
            test -z "${1}" && usage "You must provide a product to build"
            productToDeploy="${1}"
            ;;
        -r|--registry)
            shift
            test -z "${1}" && usage "You must provide a registry"
            registryToDeployTo=${1}
            ;;
        -s|--shim)
            shift
            test -z "${1}" && usage "You must provide an OS Shim"
            shimsToDeploy="${shimsToDeploy:+${shimsToDeploy} }${1}"
            ;;
        -v|--version)
            shift
            test -z "${1}" && usage "You must provide a version to build"
            versionsToDeploy="${versionsToDeploy:+${versionsToDeploy} }${1}"
            ;;
        --dry-run)
            dryRun="echo"
            ;;
        --help)
            usage
            ;;
        *)
            usage "Unrecognized option"
            ;;
    esac
    shift
done

test -z "${dryRun}" \
    && test ! $(git tag --points-at "$CI_COMMIT_SHA") \
    && test ! $(git rev-parse --abbrev-ref "$CI_COMMIT_SHA") = "master" \
    && echo "ERROR: are you sure this script should be running??" \
    && exit 1

test -z "${registryToDeployTo}" \
    && usage "Specifying a registry to deploy to is required"
test -z "${productToDeploy}" \
    && usage "Specifying a product to deploy is required"

if test -z "${CI_COMMIT_REF_NAME}" ;
then
    # shellcheck disable=SC2046 
    CI_PROJECT_DIR="$( cd $( dirname "${0}" )/.. || exit 97 ; pwd )"
    test -z "${CI_PROJECT_DIR}" && echo "Invalid call to dirname ${0}" && exit 97
fi
CI_SCRIPTS_DIR="${CI_PROJECT_DIR}/ci_scripts"
# shellcheck source=./ci_tools.lib.sh
. "${CI_SCRIPTS_DIR}/ci_tools.lib.sh"

if test -z "${versionsToDeploy}" ; 
then
    versionsToDeploy=$( _getAllVersionsToDeployForProduct ${productToDeploy} )
fi
latestVersion=$( _getLatestVersionForProduct ${productToDeploy} )

#
# Determine whether the commit is associated with a sprint tag 
#   a print tag ends with 4 digits, YYMM
#
for tag in $( git tag --points-at "$gitRevLong" ) ; do
    if test -z "$( echo ${tag} | sed 's/^[0-9]\{4\}$//' )" ; then
        sprint="${tag}"
        break
    fi
done


for _version in ${versionsToDeploy} ; 
do
    if test -z "${shimsToDeploy}" ; 
    then 
        _shimsToDeploy=$( _getShimsToDeployForProductVersion ${productToDeploy} ${_version} ) 
    else
        _shimsToDeploy=${shimsToDeploy}
    fi
    if test -z "${defaultShim}" ; then 
        defaultShim=$( _getDefaultShimForProductVersion ${productToDeploy} ${_version} )
    fi
    for _shim in ${_shimsToDeploy} ; 
    do
        _shimLongTag=$( _getLongTag "${_shim}" )
        fullTag="${_version}-${_shimLongTag}-${ciTag}"
        docker pull ${FOUNDATION_REGISTRY}/${productToDeploy}:${fullTag}
        tag_and_push "${_version}-${_shimLongTag}-edge"

        if test -n "${sprint}" ; 
        then
            tag_and_push "${sprint}-${_shimLongTag}-${_version}"
            if test "${_version}" = "${latestVersion}" ;
            then
                tag_and_push "${sprint}-${_shimLongTag}-latest"
                tag_and_push "${_shimLongTag}-latest"
            fi

            if test "${_shim}" = "${defaultShim}" ;
            then
                tag_and_push "${sprint}-${_version}"
                tag_and_push "${_version}-latest"
                tag_and_push "${_version}"

                #if it's latest product version and a sprint, then it's "latest" overall and also just "edge". 
                if test "${_version}" = "${latestVersion}" ;
                then
                    tag_and_push "latest"
                    tag_and_push "${sprint}"
                fi
            fi
        fi

        if test "${_shim}" = "${defaultShim}" ; then
            tag_and_push "${_version}-edge"
        fi

        if test "${_version}" = "${latestVersion}" ; then
            tag_and_push "${_shimLongTag}-edge"
            if test "${_shim}" = "${defaultShim}" ; then
                tag_and_push "edge"
            fi
        fi
        docker image rm -f ${FOUNDATION_REGISTRY}/${productToDeploy}:${fullTag}
    done
done
exit 0