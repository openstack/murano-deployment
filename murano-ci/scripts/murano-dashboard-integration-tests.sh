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
SCREEN_CMD=$(which screen)
FW_CMD=$(which iptables)
DISPLAY_NUM=22
#
#This file is generated by Nodepool while building snapshots
#It contains credentials to access RabbitMQ and an OpenStack lab
source ~/credentials


#Functions:
function handle_rabbitmq()
{
    local retval=0
    local action=$1
    case $action in
        add)
            $PYTHON_CMD ${CI_ROOT_DIR}/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -rabbitmq_url $RABBITMQ_URL
            if [ $? -ne 0 ]; then
                echo "\"${FUNCNAME[0]} $action\" return error!"
                retval=1
            fi
            ;;
        del)
            $PYTHON_CMD ${CI_ROOT_DIR}/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -rabbitmq_url $RABBITMQ_URL -action delete
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
function get_ip_from_iface()
{
    local retval=0
    local iface_name=$1
    found_ip_address=$(ifconfig $iface_name | awk -F ' *|:' '/inet addr/{print $4}')
    if [ $? -ne 0 ] || [ -z "$found_ip_address" ]; then
        echo "Can't obtain ip address from interface $iface_name!"
        retval=1
    else
        readonly found_ip_address
    fi
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
        echo "Running: sudo bash -x ${CI_ROOT_DIR}/infra/deploy_component_new.sh $ZUUL_REF $component $KEYSTONE_URL $ZUUL_URL"
        sudo bash -x ${CI_ROOT_DIR}/infra/deploy_component_new.sh $ZUUL_REF $component $KEYSTONE_URL $ZUUL_URL
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
    sudo RUN_DB_SYNC=${run_db_sync} bash -x ${CI_ROOT_DIR}/infra/configure_api.sh $RABBITMQ_HOST $RABBITMQ_PORT False murano$BUILD_NUMBER murano$BUILD_NUMBER
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
    local retval=0
    local git_url="https://git.openstack.org/stackforge/murano-tests"
    local tests_dir=$TESTS_DIR
    if [ -d "$tests_dir" ]; then
        rm -rf $tests_dir
    fi
    $GIT_CMD clone $git_url $tests_dir
    if [ $? -ne 0 ]; then
        echo "Error occured during git clone $git_url $tests_dir!"
        retval=1
    else
        cd $tests_dir
        local tests_config=${tests_dir}/muranodashboard-tests/config/config_file.conf
        iniset 'common' 'keystone_url' "$(shield_slashes http://${KEYSTONE_URL}:5000/v2.0/)" "$tests_config"
        iniset 'common' 'horizon_url' "$(shield_slashes http://${found_ip_address}/horizon)" "$tests_config"
        iniset 'common' 'murano_url' "$(shield_slashes http://${found_ip_address}:8082)" "$tests_config"
        iniset 'common' 'user' "$ADMIN_USERNAME" "$tests_config"
        iniset 'common' 'password' "$ADMIN_PASSWORD" "$tests_config"
        iniset 'common' 'tenant' "$ADMIN_TENANT" "$tests_config"
        iniset 'common' 'tomcat_repository' "$(shield_slashes https://github.com/sergmelikyan/hello-world-servlet)" "$tests_config"
        cd $tests_dir/muranodashboard-tests
        prepare_incubator_at $(pwd) || retval=$?
    fi
    cd $WORKSPACE
    return $retval
}
#
function run_tests()
{
    local retval=0
    local tests_dir=$TESTS_DIR
    cd ${tests_dir}/muranodashboard-tests
    $NOSETESTS_CMD sanity_check --nologcapture
    if [ $? -ne 0 ]; then
        handle_rabbitmq del || retval=$?
    fi
    cd $WORKSPACE
    return $retval
}
#
#Starting up:
WORKSPACE=$(cd $WORKSPACE && pwd)
TESTS_DIR="${WORKSPACE}/murano-tests"
cd $WORKSPACE
export DISPLAY=:${DISPLAY_NUM}
$SCREEN_CMD -dmS display sudo Xvfb -fp /usr/share/fonts/X11/misc/ :${DISPLAY_NUM} -screen 0 1024x768x16 || exit $?
sudo $NTPDATE_CMD -u ru.pool.ntp.org || exit $?
sudo $FW_CMD -F
get_ip_from_iface eth0 || exit $?
handle_rabbitmq add || exit $?
run_component_deploy murano-dashboard || (e_code=$?; handle_rabbitmq del; exit $e_code) || exit $?
run_component_configure || (e_code=$?; handle_rabbitmq del; exit $e_code) || exit $?
prepare_tests || (e_code=$?; handle_rabbitmq del; exit $e_code) || exit $?
run_tests || exit $?
handle_rabbitmq del || exit $?
exit 0
