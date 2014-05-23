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
function run_component_deploy()
{
    local retval=0
    if [ -z "$1" ]; then
        echo "\"${FUNCNAME[0]} called without parameters!"
        retval=1
    else
        local component=$1
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
    sudo RUN_DB_SYNC=${run_db_sync} bash -x ${CI_ROOT_DIR}/infra/configure_api.sh $RABBITMQ_HOST $RABBITMQ_PORT False murano$BUILD_NUMBER murano$BUILD_NUMBER
    if [ $? -ne 0 ]; then
        echo "\"${FUNCNAME[0]}\" return error!"
        retval=1
    fi
    return $retval
}
#
function prepare_tests()
{
    local retval=0
    local git_url="https://github.com/Mirantis/tempest"
    local branch_name="platform/stable/havana"
    local tests_dir=$TEMPEST_DIR
    if [ -d "$tests_dir" ]; then
        rm -rf $tests_dir
    fi
    $GIT_CMD clone $git_url $tests_dir
    cd $tests_dir
    $GIT_CMD checkout $branch_name
    sudo $PIP_CMD install .
    if [ $? -ne 0 ]; then
        echo "\"pip install .\" fails!"
        retval=1
    else
        local murano_url="http://127.0.0.1:8082/v1/"
        local tempest_config=${tests_dir}/etc/tempest.conf
        cp ${tests_dir}/etc/tempest.conf.sample $tempest_config
        iniset 'identity' 'uri' "$(shield_slashes http://${KEYSTONE_URL}:5000/v2.0/)" "$tempest_config"
        iniset 'identity' 'admin_username' "$ADMIN_USERNAME" "$tempest_config"
        iniset 'identity' 'admin_password' "$ADMIN_PASSWORD" "$tempest_config"
        iniset 'identity' 'admin_tenant_name' "$ADMIN_TENANT" "$tempest_config"
        iniset 'murano' 'murano_url' "$(shield_slashes $murano_url)" "$tempest_config"
        iniset 'service_available' 'murano' "true" "$tempest_config"
    fi
    cd $WORKSPACE
    return $retval
}
#
function run_tests()
{
    local retval=0
    local tests_dir=$TEMPEST_DIR
    $NOSETESTS_CMD -s -v --with-xunit --xunit-file=test_report$BUILD_NUMBER.xml ${tests_dir}/api/murano/test_murano_envs.py ${tests_dir}/api/murano/test_murano_services.py ${tests_dir}/api/murano/test_murano_sessions.py
    if [ $? -ne 0 ]; then
        handle_rabbitmq del || retval=$?
    fi
    return $retval
}
#
function move_results()
{
    retval=0
    local tests_dir=$TEMPEST_DIR
    mv ${tests_dir}/test_report$BUILD_NUMBER.xml $WORKSPACE/
    if [ $? -ne 0 ]; then
        echo "Can't move file \"${tests_dir}/test_report$BUILD_NUMBER.xml\" to the \"$WORKSPACE/\"!"
        retval=1
    fi
    return $retval
}
#
#Staring up:
WORKSPACE=$(cd $WORKSPACE && pwd)
TEMPEST_DIR="${WORKSPACE}/tempest"
cd $WORKSPACE
sudo $NTPDATE_CMD -u ru.pool.ntp.org || exit $?
handle_rabbitmq add || exit $?
run_component_deploy murano-api || (e_code=$?; handle_rabbitmq del; exit $e_code)
run_component_configure || (e_code=$?; handle_rabbitmq del; exit $e_code)
prepare_tests || (e_code=$?; handle_rabbitmq del; exit $e_code)
run_tests || exit $?
handle_rabbitmq del || exit $?
move_results || exit $?
exit 0