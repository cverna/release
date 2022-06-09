#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/local/go/bin:/usr/libexec/origin:/opt/OpenShift4-tools:$PATH
export REPORT_HANDLE_PATH="/usr/bin"
export ENABLE_PRINT_EVENT_STDOUT=true

export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# create link for oc to kubectl
mkdir -p "${HOME}"
if ! which kubectl; then
    export PATH=$PATH:$HOME
    ln -s "$(which oc)" ${HOME}/kubectl
fi

which extended-platform-tests

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#setup bastion
if test -f "${SHARED_DIR}/bastion_public_address"
then
    QE_BASTION_PUBLIC_ADDRESS=$(cat "${SHARED_DIR}/bastion_public_address")
    export QE_BASTION_PUBLIC_ADDRESS
fi
if test -f "${SHARED_DIR}/bastion_private_address"
then
    QE_BASTION_PRIVATE_ADDRESS=$(cat "${SHARED_DIR}/bastion_private_address")
    export QE_BASTION_PRIVATE_ADDRESS
fi

# configure enviroment for different cluster
echo "CLUSTER_TYPE is ${CLUSTER_TYPE}"
case "${CLUSTER_TYPE}" in
gcp)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export KUBE_SSH_USER=core
    export SSH_CLOUD_PRIV_GCP_USER=core
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
    eval export SSH_CLOUD_PRIV_KEY="~/.ssh/google_compute_engine"
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
    ;;
aws)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
    eval export SSH_CLOUD_PRIV_KEY="~/.ssh/kube_aws_rsa"
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    export SSH_CLOUD_PRIV_AWS_USER=core
    ;;
azure4)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_azure_rsa || true
    eval export SSH_CLOUD_PRIV_KEY="~/.ssh/kube_azure_rsa"
    export SSH_CLOUD_PRIV_AZURE_USER=core
    export TEST_PROVIDER=azure
    ;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    ;;
vsphere)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc.sh"
    export VSPHERE_CONF_FILE="${SHARED_DIR}/vsphere.conf"
    oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' > "$VSPHERE_CONF_FILE"
    # The test suite requires a vSphere config file with explicit user and password fields.
    sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
    sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
    export TEST_PROVIDER=vsphere;;
openstack*)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cinder_credentials.sh"
    export TEST_PROVIDER='{"type":"openstack"}';;
ovirt) export TEST_PROVIDER='{"type":"ovirt"}';;
equinix-ocp-metal)
    export TEST_PROVIDER='{"type":"skeleton"}';;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

# create execution directory
mkdir -p /tmp/output
cd /tmp/output

if [[ "${CLUSTER_TYPE}" == gcp ]]; then
    pushd /tmp
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-256.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir -p gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${PROJECT}"
    popd
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

# check if the cluster is ready
oc version --client
oc wait nodes --all --for=condition=Ready=true --timeout=10m
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m

# execute the cases
function run {
    test_scenarios=""
    echo "TEST_SCENRAIOS_POSTUPG: \"${TEST_SCENRAIOS_POSTUPG:-}\""
    echo "TEST_ADDITIONAL_POSTUPG: \"${TEST_ADDITIONAL_POSTUPG:-}\""
    echo "TEST_IMPORTANCE: \"${TEST_IMPORTANCE}\""
    echo "TEST_FILTERS_POSTUPG: \"~NonUnifyCI&;~CPaasrunOnly&;~VMonly&;~ProdrunOnly&;~StagerunOnly&;NonPreRelease&;PstChkUpgrade&;${TEST_FILTERS_POSTUPG}\""
    echo "TEST_TIMEOUT: \"${TEST_TIMEOUT}\""
    if [[ -n "${TEST_SCENRAIOS_POSTUPG:-}" ]]; then
        readarray -t scenarios <<< "${TEST_SCENRAIOS_POSTUPG}"
        for scenario in "${scenarios[@]}"; do
            test_scenarios="${test_scenarios}|${scenario}"
        done
    else
        echo "there is no scenario"
        return
    fi

    if [ "W${test_scenarios}W" == "WW" ]; then
        echo "fail to parse ${TEST_SCENRAIOS_POSTUPG}"
        exit 1
    fi
    echo "test scenarios: ${test_scenarios:1:-1}"
    test_scenarios="${test_scenarios:1:-1}"

    test_additional=""
    if [[ -n "${TEST_ADDITIONAL_POSTUPG:-}" ]]; then
        readarray -t additionals <<< "${TEST_ADDITIONAL_POSTUPG}"
        for additional in "${additionals[@]}"; do
            test_additional="${test_additional}|${additional}"
        done
    else
        echo "there is no additional"
    fi

    if [ "W${test_additional}W" != "WW" ]; then
        echo "test additional: ${test_additional:1:-1}"
        test_scenarios="${test_scenarios}|${test_additional:1:-1}"
    fi

    echo "final scenarios: ${test_scenarios}"
    extended-platform-tests run all --dry-run | \
        grep -E "${test_scenarios}" | grep -E "${TEST_IMPORTANCE}" > ./case_selected

    handle_filters "~NonUnifyCI&;~CPaasrunOnly&;~VMonly&;~ProdrunOnly&;~StagerunOnly&;NonPreRelease&;PstChkUpgrade&;${TEST_FILTERS_POSTUPG}"
    echo "------------------the case selected------------------"
    selected_case_num=$(cat ./case_selected|wc -l)
    if [ "W${selected_case_num}W" == "W0W" ]; then
        echo "No Case Selected"
        if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
            echo "do not force success exit"
            exit 1
        fi
        echo "force success exit"
        exit 0
    fi
    echo ${selected_case_num}
    cat ./case_selected
    echo "-----------------------------------------------------"

    ret_value=0
    set -x
    if [ "W${TEST_PROVIDER}W" == "WnoneW" ]; then
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected || ret_value=$?
    else
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        --provider "${TEST_PROVIDER}" -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected || ret_value=$?
    fi
    set +x
    set +e
    rm -fr ./case_selected
    echo "try to handle result"
    handle_result
    echo "done to handle result"
    if [ "W${ret_value}W" == "W0W" ]; then
        echo "success"
        exit 0
    fi
    echo "fail"
    # it ensure the the step after this step in test will be executed per https://docs.ci.openshift.org/docs/architecture/step-registry/#workflow
    # please refer to the junit result for case result, not depends on step result.
    if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
        exit 1
    fi
    exit 0
}

# select the cases per FILTERS
function handle_filters {
    filter_tmp="$1"
    if [ "W${filter_tmp}W" == "WW" ]; then
        echo "there is no filter"
        return
    fi
    echo "try to handler filters..."
    IFS=";" read -r -a filters <<< "${filter_tmp}"

    filters_and=()
    filters_or=()
    for filter in "${filters[@]}"
    do
        echo "${filter}"
        valid_filter "${filter}"
        filter_logical="$(echo $filter | grep -Eo '[&]?$')"

        if [ "W${filter_logical}W" == "W&W" ]; then
            filters_and+=( "$filter" )
        else
            filters_or+=( "$filter" )
        fi
    done

    echo "handle AND logical"
    for filter in ${filters_and[*]}
    do
        echo "handle filter_and ${filter}"
        handle_and_filter "${filter}"
    done

    echo "handle OR logical"
    rm -fr ./case_selected_or
    for filter in ${filters_or[*]}
    do
        echo "handle filter_or ${filter}"
        handle_or_filter "${filter}"
    done
    if [[ -e ./case_selected_or ]]; then
        sort -u ./case_selected_or > ./case_selected && rm -fr ./case_selected_or
    fi
}

function valid_filter {
    filter="$1"
    if ! echo ${filter} | grep -E '^[~]?[a-zA-Z0-9]{1,}[&]?$'; then
        echo "the filter ${filter} is not correct format. it should be ^[~]?[a-zA-Z0-9]{1,}[&]?$"
        exit 1
    fi
    action="$(echo $filter | grep -Eo '^[~]?')"
    value="$(echo $filter | grep -Eo '[a-zA-Z0-9]{1,}')"
    logical="$(echo $filter | grep -Eo '[&]?$')"
    echo "$action--$value--$logical"
}

function handle_and_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9]{1,}')"

    ret=0
    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" > ./case_selected_and || ret=$?
        check_case_selected "${ret}"
    else
        cat ./case_selected | grep -v -E "${value}" > ./case_selected_and || ret=$?
        check_case_selected "${ret}"
    fi
    if [[ -e ./case_selected_and ]]; then
        cp -fr ./case_selected_and ./case_selected && rm -fr ./case_selected_and
    fi
}

function handle_or_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9]{1,}')"

    ret=0
    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" >> ./case_selected_or || ret=$?
        check_case_selected "${ret}"
    else
        cat ./case_selected | grep -v -E "${value}" >> ./case_selected_or || ret=$?
        check_case_selected "${ret}"
    fi
}
function handle_result {
    resultfile=`ls -rt -1 ${ARTIFACT_DIR}/junit/junit_e2e_* 2>&1 || true`
    echo $resultfile
    if (echo $resultfile | grep -E "no matches found") || (echo $resultfile | grep -E "No such file or directory") ; then
        echo "there is no result file generated"
        return
    fi
    current_time=`date "+%Y-%m-%d-%H-%M-%S"`
    newresultfile="${ARTIFACT_DIR}/junit/junit_e2e_${current_time}.xml"
    replace_ret=0
    python3 ${REPORT_HANDLE_PATH}/handleresult.py -a replace -i ${resultfile} -o ${newresultfile} || replace_ret=$?
    if ! [ "W${replace_ret}W" == "W0W" ]; then
        echo "replacing file is not ok"
        rm -fr ${resultfile}
        return
    fi 
    rm -fr ${resultfile}

    echo ${newresultfile}
    split_ret=0
    python3 ${REPORT_HANDLE_PATH}/handleresult.py -a split -i ${newresultfile} || split_ret=$?
    if ! [ "W${split_ret}W" == "W0W" ]; then
        echo "splitting file is not ok"
        rm -fr ${newresultfile}
        return
    fi
    cp -fr import-*.xml "${ARTIFACT_DIR}/junit/"
    rm -fr ${newresultfile}
}
function check_case_selected {
    found_ok=$1
    if [ "W${found_ok}W" == "W0W" ]; then
        echo "find case"
    else
        echo "do not find case"
    fi
}
run