#!/bin/bash
# Copyright (c) 2014 Mirantis, Inc.
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

PROJECT_NAME=${1:-murano-engine}

# Error trapping first
#---------------------
set -o errexit

function trap_handler() {
    cat << EOF
################################################################################

Got error in "'$1'" on line "'$2'", error code "'$3'"

################################################################################
EOF
}
trap 'trap_handler ${0} ${LINENO} ${?}' ERR
#---------------------


# Enable debug output
#--------------------
PS4='+ [$(date --rfc-3339=seconds)] '
set -o xtrace
#--------------------


CI_ROOT_DIR=$(cd $(dirname "$0") && cd .. && pwd)


# Include of the common functions library file
source "${CI_ROOT_DIR}/scripts/common.inc"

# This file is generated by Nodepool while building snapshots
# It contains credentials to access RabbitMQ and an OpenStack lab
source ~/credentials


# Basic parameters
#-----------------
STACK_HOME='/opt/stack'

case $PROJECT_NAME in
    'murano-engine')
        PROJECT_DIR="${STACK_HOME}/murano"
        TESTS_DIR="murano/tests/functional"
    ;;
    'murano-dashboard')
        PROJECT_DIR="${STACK_HOME}/murano-dashboard"
        TESTS_DIR="muranodashboard/tests/functional"
    ;;
    *)
        echo "Unknown project name '$PROJECT_NAME'"
        exit 1
    ;;
esac

ZUUL_URL=${ZUUL_URL:-'https://github.com'}
ZUUL_REF=${ZUUL_REF:-'master'}

WORKSPACE=$(cd $WORKSPACE && pwd)
#-----------------


# Commands used in script
#------------------------
PYTHON_CMD=$(which python)
NOSETESTS_CMD=$(which nosetests)
GIT_CMD=$(which git)
NTPDATE_CMD=$(which ntpdate)
PIP_CMD=$(which pip)
SCREEN_CMD=$(which screen)
FW_CMD=$(which iptables)
#------------------------


# Virtual framebuffer settings
#-----------------------------
VFB_DISPLAY_SIZE='1280x1024'
VFB_COLOR_DEPTH=16
VFB_DISPLAY_NUM=22
#-----------------------------



# Functions
#-------------------------------------------------------------------------------
function get_ip_from_iface() {
    local iface_name=$1

    found_ip_address=$(ifconfig $iface_name | awk -F ' *|:' '/inet addr/{print $4}')

    if [ $? -ne 0 ] || [ -z "$found_ip_address" ]; then
        echo "Can't obtain ip address from interface $iface_name!"
        return 1
    else
        readonly found_ip_address
    fi
}


function get_floating_ip() {
    sudo apt-get install --yes python-novaclient

    export OS_USERNAME=${ADMIN_USERNAME}
    export OS_PASSWORD=${ADMIN_PASSWORD}
    export OS_TENANT_NAME=${ADMIN_TENANT}
    export OS_AUTH_URL="http://${KEYSTONE_URL}:5000/v2.0"

    floating_ip_address=$(nova floating-ip-list | grep " ${found_ip_address} " | cut -d ' ' -f 2)
    readonly floating_ip_address
}


function prepare_murano_apps() {
    local start_dir=$1
    local clone_dir="${start_dir}/murano-app-incubator"
    local git_url="https://github.com/murano-project/murano-app-incubator"

    cd ${start_dir}

    $GIT_CMD clone $git_url $clone_dir

    if [ $? -ne 0 ]; then
        echo "Error occured during git clone $git_url $clone_dir!"
        return 1
    fi

    cd ${clone_dir}
    local pkg_counter=0
    for package_dir in io.murano.*
    do
        if [ -f "${package_dir}/manifest.yaml" ]; then
            bash make-package.sh $package_dir
            pkg_counter=$((pkg_counter + 1))
        fi
    done

    if [ $PROJECT_NAME == 'murano-dashboard' ]; then
        cd ${start_dir}
        bash murano-app-incubator/make-package.sh MockApp
    fi

    if [ $pkg_counter -eq 0 ]; then
        echo "Warning: $pkg_counter packages was built at $clone_dir!"
        return 1
    fi
}


function prepare_tests() {
    local retval=0
    local project_tests_dir="${PROJECT_DIR}/${TESTS_DIR}"

    if [ ! -d "$project_tests_dir" ]; then
        echo "Directory with tests isn't exist"
        return 1
    fi

    sudo chown -R $USER ${project_tests_dir}

    if [ $PROJECT_NAME == 'murano-dashboard' ]; then
        local tests_config=${project_tests_dir}/config/config_file.conf
    else
        local tests_config=${project_tests_dir}/engine/config.conf
    fi

    iniset 'common' 'keystone_url' "$(shield_slashes http://${KEYSTONE_URL}:5000/v2.0/)" "$tests_config"
    iniset 'common' 'horizon_url' "$(shield_slashes http://${found_ip_address}/)" "$tests_config"
    iniset 'common' 'murano_url' "$(shield_slashes http://${found_ip_address}:8082)" "$tests_config"
    iniset 'common' 'user' "$ADMIN_USERNAME" "$tests_config"
    iniset 'common' 'password' "$ADMIN_PASSWORD" "$tests_config"
    iniset 'common' 'tenant' "$ADMIN_TENANT" "$tests_config"

    iniset 'murano' 'linux_image' "$LINUX_IMAGE" "$tests_config"
    iniset 'murano' 'auth_url' "$(shield_slashes http://${KEYSTONE_URL}:5000/v2.0/)" "$tests_config"

    prepare_murano_apps ${project_tests_dir} || retval=$?

    return $retval
}


function run_tests() {
    local retval=0
    local project_tests_dir="${PROJECT_DIR}/${TESTS_DIR}"

    # TODO(dteselkin): Remove this workaround as soon as
    #     https://bugs.launchpad.net/murano/+bug/1349934 is fixed.
    sudo rm -f /tmp/parser_table.py

    pushd ${project_tests_dir}

    if [ ${PROJECT_NAME} == 'murano-dashboard' ]; then
#        $NOSETESTS_CMD -s -v sanity_check || retval=$?
        $NOSETESTS_CMD -s -v sanity_check.py:TestSuiteSmoke || retval=$?
        $NOSETESTS_CMD -s -v sanity_check.py:TestSuiteEnvironment || retval=$?
        $NOSETESTS_CMD -s -v sanity_check.py:TestSuiteImage || retval=$?
#        $NOSETESTS_CMD -s -v sanity_check.py:TestSuiteFields || retval=$?
        $NOSETESTS_CMD -s -v sanity_check.py:TestSuiteApplications || retval=$?
    else
        $NOSETESTS_CMD -s -v \
            --with-xunit \
            --xunit-file=${WORKSPACE}/test_report${BUILD_NUMBER}.xml \
            ${project_tests_dir}/engine/base.py || retval=$?
    fi

    collect_artifacts

    popd

    return $retval
}


function collect_artifacts() {
    local dst=${WORKSPACE}/artifacts
    local rsync_cmd="rsync --recursive --verbose --copy-links"

    sudo mkdir -p ${dst}

    ### Add correct Apache log path
    if [ $distro_based_on == "redhat" ]; then
        apache_log_dir="/var/log/httpd"
    else
        apache_log_dir="/var/log/apache2"
    fi

    # rsync might fail if there is no file or folder,
    # so I disable error catching
    set +o errexit

    # Copy devstack logs
    sudo ${rsync_cmd} --include='*.log' --exclude='*' ${STACK_HOME}/log/ ${dst}/devstack

    # Copy murano logs from /tmp
    sudo ${rsync_cmd} --include='murano*.log' --exclude='*' /tmp/ ${dst}/tmp

    # Copy murano logs from /var/log/murano
    sudo ${rsync_cmd} --include='*/' --include='*.log' --exclude='*' /var/log/murano/ ${dst}/murano

    if [ $PROJECT_NAME == 'murano-dashboard' ]; then
        # Copy Apache logs
        sudo ${rsync_cmd} --include='*.log' --exclude='*' ${apache_log_dir}/ ${dst}/apache

        # Copy screenshots for failed tests
        sudo ${rsync_cmd} ${PROJECT_DIR}/${TESTS_DIR}/screenshots/ ${dst}/screenshots
    fi

    # return error catching back
    set -o errexit

    sudo chown -R jenkins:jenkins ${dst}
}


function git_clone_devstack() {
    # Assuming the script is run from 'jenkins' user
    local git_dir=/opt/git

    sudo mkdir -p "$git_dir/openstack-dev"
    sudo chown -R jenkins:jenkins "$git_dir/openstack-dev"
    cd "$git_dir/openstack-dev"
    git clone https://github.com/openstack-dev/devstack

    #source ./devstack/functions-common
}


function deploy_devstack() {
    # Assuming the script is run from 'jenkins' user
    local git_dir=/opt/git

    sudo mkdir -p "$git_dir/stackforge"
    sudo chown -R jenkins:jenkins "$git_dir/stackforge"
    cd "$git_dir/stackforge"
    git clone https://github.com/stackforge/murano-api

    # NOTE: Source path MUST ends with a slash!
    rsync --recursive --exclude README.* "$git_dir/stackforge/murano-api/contrib/devstack/" "$git_dir/openstack-dev/devstack/"

    cd "$git_dir/openstack-dev/devstack"

    cat << EOF > local.conf
[[local|localrc]]
HOST_IP=${KEYSTONE_URL}             # IP address of OpenStack lab
ADMIN_PASSWORD=.                    # This value doesn't matter
MYSQL_PASSWORD=swordfish            # Random password for MySQL installation
SERVICE_PASSWORD=${ADMIN_PASSWORD}  # Password of service user
SERVICE_TOKEN=.                     # This value doesn't matter
SERVICE_TENANT_NAME=${ADMIN_TENANT}
MURANO_ADMIN_USER=${ADMIN_USERNAME}
RABBIT_HOST=${floating_ip_address}
RABBIT_PASSWORD=guest
MURANO_RABBIT_VHOST=/
RECLONE=True
SCREEN_LOGDIR=/opt/stack/log/
LOGFILE=\$SCREEN_LOGDIR/stack.sh.log
ENABLED_SERVICES=
enable_service mysql
enable_service rabbit
enable_service horizon
enable_service murano
enable_service murano-api
enable_service murano-engine
enable_service murano-dashboard
EOF

    if [ $PROJECT_NAME == 'murano-dashboard' ]; then
        cat << EOF >> local.conf
MURANO_DASHBOARD_REPO=${ZUUL_URL}/stackforge/murano-dashboard
MURANO_DASHBOARD_BRANCH=${ZUUL_REF}
EOF
    else
        cat << EOF >> local.conf
MURANO_REPO=${ZUUL_URL}/stackforge/murano
MURANO_BRANCH=${ZUUL_REF}
MURANO_PYTHONCLIENT_REPO=https://github.com/stackforge/python-muranoclient
MURANO_PYTHONCLIENT_BRANCH=master
EOF
    fi


    sudo ./tools/create-stack-user.sh

    sudo chown -R stack:stack "$git_dir/openstack-dev/devstack"

    sudo su -c "cd $git_dir/openstack-dev/devstack && ./stack.sh" stack

    # Fix iptables to allow outbound access
    sudo iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
}


function configure_apt_cacher() {
    local mode=$1
    local apt_proxy_host=${2:-'172.18.124.201'}
    local apt_proxy_file=/etc/apt/apt.conf.d/01proxy

    case $mode in
        enable)
            sudo sh -c "echo 'Acquire::http { Proxy \"http://${apt_proxy_host}:3142\"; };' > ${apt_proxy_file}"
            sudo apt-get update
        ;;
        disable)
            sudo rm -f $apt_proxy_file
            sudo apt-get update
        ;;
    esac
}


function start_xvfb_session() {
    if [ $PROJECT_NAME != 'murano-dashboard' ]; then
        echo "Skipping 'start_xvfb_session' ..."
        return
    fi

    export DISPLAY=:${VFB_DISPLAY_NUM}

    fonts_path="/usr/share/fonts/X11/misc/"
    if [ $distro_based_on == "redhat" ]; then
        fonts_path="/usr/share/X11/fonts/misc/"
    fi

    # Start XVFB session
    sudo Xvfb -fp ${fonts_path} ${DISPLAY} -screen 0 ${VFB_DISPLAY_SIZE}x${VFB_COLOR_DEPTH} &

    # Start VNC server
    sudo apt-get install --yes x11vnc
    x11vnc -nopw -display ${DISPLAY} &
    sudo iptables -I INPUT 1 -p tcp --dport 5900 -j ACCEPT

    # Launch window manager
    sudo apt-get install --yes openbox
    exec openbox &
}
#-------------------------------------------------------------------------------



sudo sh -c "echo '127.0.0.1 $(hostname)' >> /etc/hosts"
sudo $NTPDATE_CMD -u ru.pool.ntp.org
sudo $FW_CMD -F

# Clone devstack first as we will use
# some of its files (functions-common, for example)
git_clone_devstack

get_os

get_ip_from_iface eth0

get_floating_ip

cat << EOF
********************************************************************************
Fixed IP: ${found_ip_address}
Floating IP: ${floating_ip_address}
Horizon URL: http://${floating_ip_address}
SSH connection string: ssh jenkins@${floating_ip_address}
********************************************************************************
EOF

configure_apt_cacher enable

deploy_devstack

start_xvfb_session

prepare_tests

run_tests

exit 0

