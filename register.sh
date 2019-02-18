#!/bin/bash

# Copyright (c) 2017 Antonia Stevens a@antevens.com

#  Permission is hereby granted, free of charge, to any person obtaining a
#  copy of this software and associated documentation files (the "Software"),
#  to deal in the Software without restriction, including without limitation
#  the rights to use, copy, modify, merge, publish, distribute, sublicense,
#  and/or sell copies of the Software, and to permit persons to whom the
#  Software is furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
#  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
#  DEALINGS IN THE SOFTWARE.

# Set strict mode
set -euo pipefail

# Version
version='0.0.2'

# If there is no TTY then it's not interactive
if ! [[ -t 1 ]]; then
    interactive=false
fi
# Default is interactive mode unless already set
interactive="${interactive:-true}"

# Safely loads config file
# First parameter is filename, all consequent parameters are assumed to be
# valid configuration parameters
function load_config()
{
    config_file="${1}"
    # Verify config file permissions are correct and warn if they are not
    # Dual stat commands to work with both linux and bsd
    shift
    while read line; do
        if [[ "${line}" =~ ^[^#]*= ]]; then
            setting_name="$(echo ${line} | awk --field-separator='=' '{print $1}' | sed --expression 's/^[[:space:]]*//' --expression 's/[[:space:]]*$//')"
            setting_value="$(echo ${line} | cut --fields=1 --delimiter='=' --complement | sed --expression 's/^[[:space:]]*//' --expression 's/[[:space:]]*$//')"

            if echo "${@}" | grep -q "${setting_name}" ; then
                export ${setting_name}="${setting_value}"
                echo "Loaded config parameter ${setting_name} with value of '${setting_value}'"
            fi
        fi
    done < "${config_file}";
}

message="
This script will modify your FreeIPA setup so that this server can automatically
apply for LetsEncrypt SSL/TLS certificates for all hostnames/principals associted.

This script needs the host to be already registered in FreeIPA, the IPA client
is installed and that the user running this script is in the IPA admins group.

The following steps will be taken:

1. Adding the Let's Encrypt Root and Intermediate CAs as trusted CAs in your cert store.
2. Installing CertBot (Let's Encrypt client)
3. Create a DNS Administrator role in FreeIPA, members of which can edit DNS Records
4. Create a new service, allow it to manage DNS entries
5. Allow members of the admin group to create and retrieve keytabs for the service
6. Create bogus TXT initialization records for the host.
"

if ${interactive} ; then
    while ! [[ "${REPLY:-}" =~ ^[NnYy]$ ]]; do
	echo "${message}"
	read -rp "Please confirm you want to continue and modify your system/setup (y/n):" -n 1
	echo

	# Get a fresh kerberos ticket if needed
        klist || ( [ "${EUID:-$(id -u)}" -eq 0 ] && kinit "${SUDO_USER:-${USER}}" ) || kinit
    done
else
    REPLY="y"
fi

if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "Let's Encrypt FreeIPA registration cancelled by user"
    exit 1
fi

if [[ -n "${IPA_CONFIG_FILE:-}" ]]; then
  #Skip setup because IPA_CONFIG_FILE is already set
  cd . #NO-OP, do nothing
elif [[ -e "/etc/ipa/server.conf" ]]; then
  IPA_CONFIG_FILE="/etc/ipa/server.conf"
elif [[ -e "/etc/ipa/default.conf" ]]; then
  IPA_CONFIG_FILE="/etc/ipa/default.conf"
else
  errcho "FATAL: No ipa config found; exiting!!!"
  exit 1
fi

load_config ${IPA_CONFIG_FILE} realm domain

#I am not sure if this is the desired logic but
#sometimes the hosting platform mangles the hostname
#such that the domain name is provided by the platform
#instead of my intended hostname
if [[ -n ${domain} ]]; then
  host="$(hostname -s).${domain}"
else
  host="$(hostname --fqdn)"
fi

group='admins'
principals="$(ipa host-show ${host} --raw | sed --quiet --expression 's/^[[:space:]]*krbprincipalname:[[:space:]]*host\/\(.*\)@'${realm}'[[:space:]]*$/\1/p')"


wget https://letsencrypt.org/certs/isrgrootx1.pem | sudo ipa-cacert-manage install isrgrootx1.pem -n ISRGRootCAX1 -t C,,
wget https://letsencrypt.org/certs/letsencryptauthorityx3.pem | sudo ipa-cacert-manage install letsencryptauthorityx3.pem -n ISRGRootCAX3 -t C,,
if [ "${EUID}" -ne 0 ] && ${interactive} ; then
    sudo -E bash -c "export KRB5CCNAME='${KRB5CCNAME:-}' && ipa-certupdate -v"
else
    ipa-certupdate
fi

if [[ ! -x $(which certbot) ]]; then
  sudo yum -y install certbot || sudo apt-get -y install certbot
fi

ipa service-add "lets-encrypt/${host}@${realm}"
ipa role-add "DNS Administrator"
ipa role-add-privilege "DNS Administrator" --privileges="DNS Administrators"
ipa role-add-member "DNS Administrator" --services="lets-encrypt/${host}@${realm}"
ipa service-allow-create-keytab "lets-encrypt/${host}@${realm}" --groups=${group}
ipa service-allow-retrieve-keytab "lets-encrypt/${host}@${realm}" --groups=${group}

getkeytab_command="ipa-getkeytab -p "lets-encrypt/${host}" -k /etc/lets-encrypt.keytab" #add -r to renew
if [[ -e /etc/lets-encrypt.keytab ]]; then
    echo "/etc/lets-encrypt.keytab already exists; skipping retrieval..."
elif [ "${EUID}" -ne 0 ] && ${interactive} ; then
    sudo -E bash -c "${getkeytab_command}"
else
    bash -c "${getkeytab_command}"
fi

for principal in ${principals} ; do
    ipa dnsrecord-add "${domain}." "_acme-challenge.${principal}." --txt-rec='INITIALIZED'
done

# Apply for the initial certificate if script is available
if [ -f "$(dirname ${0})/renew.sh" ] ; then
    sudo bash -c "$(dirname ${0})/renew.sh"
else
    echo "Could not find location renew.sh; please run it manually."
fi
