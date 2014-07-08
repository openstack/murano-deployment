#!/bin/bash
#    Copyright (c) 2014 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#
CI_ROOT_DIR=$(cd $(dirname "$0") && cd .. && pwd)
#Include of the common functions library file:
INC_FILE="${CI_ROOT_DIR}/scripts/common.inc"
if [ -f "$INC_FILE" ]; then
    source "$INC_FILE"
else
    echo "\"$INC_FILE\" - file not found, exiting!"
    exit 1
fi
#Basic parameters:
PYTHON_CMD=$(which python)
NOSETESTS_CMD=$(which nosetests)
GIT_CMD=$(which git)
NTPDATE_CMD=$(which ntpdate)
PIP_CMD=$(which pip)
#
#This file is generated by Nodepool while building snapshots
#It contains credentials to access RabbitMQ and an OpenStack lab
source ~/credentials
#sudo su -c 'echo "ServerName localhost" >> /etc/apache2/apache2.conf'
STORE_AS_ARTIFACTS="/tmp/murano*.log /var/log/murano/"
#Functions:
function handle_rabbitmq()
{
    local retval=0
    local action=$1
    case $action in
        add)
            $PYTHON_CMD ${CI_ROOT_DIR}/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -rabbitmq_host $RABBITMQ_URL -action create
            if [ $? -ne 0 ]; then
                echo "\"${FUNCNAME[0]} $action\" return error!"
                retval=1
            fi
            ;;
        del)
            $PYTHON_CMD ${CI_ROOT_DIR}/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -rabbitmq_host $RABBITMQ_URL -action delete
            if [ $? -ne 0 ]; then
                echo "\"${FUNCNAME[0]} $action\" return error!"
                retval=1
            fi
            ;;
        *)
            echo "\"${FUNCNAME[0]} called without parameters!"
            retval=1
            ;;
    esac
    return $retval
}
#
function run_component_deploy()
{
    local retval=0
    if [ -z "$1" ]; then
        echo "\"${FUNCNAME[0]} called without parameters!"
        retval=1
    else
        local component=$1
        echo "Running: sudo bash -x ${CI_ROOT_DIR}/infra/deploy_component_new.sh $ZUUL_REF $component noop $ZUUL_URL"
        sudo bash -x ${CI_ROOT_DIR}/infra/deploy_component_new.sh $ZUUL_REF $component noop $ZUUL_URL
        if [ $? -ne 0 ]; then
            echo "\"${FUNCNAME[0]}\" return error!"
            retval=1
        fi
    fi
    return $retval
}
#
function run_component_configure()
{
    local retval=0
    local run_db_sync=true
    sudo RUN_DB_SYNC=${run_db_sync} bash -x ${CI_ROOT_DIR}/infra/configure_api.sh $RABBITMQ_HOST $RABBITMQ_PORT False murano$BUILD_NUMBER murano$BUILD_NUMBER $KEYSTONE_URL
    if [ $? -ne 0 ]; then
        echo "\"${FUNCNAME[0]}\" return error!"
        retval=1
    fi
    return $retval
}
#
function prepare_incubator_at()
{
    local retval=0
    local git_url="https://github.com/murano-project/murano-app-incubator"
    local start_dir=$1
    local clone_dir="${start_dir}/murano-app-incubator"
    $GIT_CMD clone $git_url $clone_dir
    if [ $? -ne 0 ]; then
        echo "Error occured during git clone $git_url $clone_dir!"
        retval=1
    else
        cd $clone_dir
        local pkg_counter=0
        for package_dir in io.murano.*
        do
            if [ -d "$package_dir" ]; then
                if [ -f "${package_dir}/manifest.yaml" ]; then
                    sudo bash make-package.sh $package_dir
                    pkg_counter=$((pkg_counter + 1))
                fi
            fi
        done
        cd ${start_dir}
        if [ $pkg_counter -eq 0 ]; then
            echo "Warning: $pkg_counter packages was built at $clone_dir!"
            retval=1
        fi
    fi
    return $retval
}
#
function prepare_tests()
{
    sudo pip install -r $SOURCE_DIR/test-requirements.txt

    local murano_url="http://127.0.0.1:8082/v1/"
    local tests_config=$SOURCE_DIR/functionaltests/engine/config.conf
    sudo chown -R jenkins:jenkins $SOURCE_DIR/functionaltests
    iniset 'murano' 'auth_url' "$(shield_slashes http://${KEYSTONE_URL}:5000/v2.0/)" "$tests_config"
    iniset 'murano' 'user' "$ADMIN_USERNAME" "$tests_config"
    iniset 'murano' 'password' "$ADMIN_PASSWORD" "$tests_config"
    iniset 'murano' 'tenant' "$ADMIN_TENANT" "$tests_config"
    iniset 'murano' 'murano_url' "$(shield_slashes $murano_url)" "$tests_config"
    iniset 'murano' 'linux_image' "$LINUX_IMAGE" "$tests_config"

    cd $SOURCE_DIR/functionaltests
    prepare_incubator_at $(pwd) || retval=$?

    return 0
}
#
function run_tests()
{
    cd $SOURCE_DIR
    $NOSETESTS_CMD -s -v --with-xunit --xunit-file=$WORKSPACE/test_report$BUILD_NUMBER.xml $SOURCE_DIR/functionaltests/engine/base.py
    if [ $? -ne 0 ]; then
        collect_artifacts $STORE_AS_ARTIFACTS
        handle_rabbitmq del
        retval=1
    else
        collect_artifacts $STORE_AS_ARTIFACTS
    fi
    return 0
}
#
function collect_artifacts()
{
    local sources=$@
    local destination=${WORKSPACE}/artifacts
    sudo mkdir -p $destination
    for src_element in $sources; do
        if [ -d "${src_element}" ]; then
            sudo cp -R ${src_element}/* ${destination}/
        else
            sudo cp -R ${src_element} ${destination}/
        fi
    done
    sudo chown -R jenkins:jenkins $WORKSPACE/artifacts/*
}
#
#Starting up:
WORKSPACE=$(cd $WORKSPACE && pwd)
SOURCE_DIR=/opt/git/murano
TEMPEST_DIR="${WORKSPACE}/tempest"
cd $WORKSPACE
sudo $NTPDATE_CMD -u ru.pool.ntp.org || exit $?
handle_rabbitmq add || exit $?
run_component_deploy murano || (e_code=$?; handle_rabbitmq del; exit $e_code) || exit $?
run_component_configure || (e_code=$?; handle_rabbitmq del; exit $e_code) || exit $?
prepare_tests || (e_code=$?; handle_rabbitmq del; exit $e_code) || exit $?
run_tests || exit $?
handle_rabbitmq del || exit $?
exit 0
