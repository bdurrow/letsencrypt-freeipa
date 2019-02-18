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

# Exit if not being run as root
if [ "${EUID:-$(id -u)}" -ne "0" ] ; then
    echo "This script needs superuser privileges, suggest running it as root"
    exit 1
fi

# If there is no TTY then it's not interactive
if ! [[ -t 1 ]]; then
    interactive=false
fi
# Default is interactive mode unless already set
interactive="${interactive:-true}"

if ${interactive} ; then
    while ! [[ "${REPLY:-}" =~ ^[NnYy]$ ]]; do
	  read -rp "Please confirm you want to download and install letsencrypt FreeIPA scripts (y/n):" -n 1
	  echo
    done
else
    REPLY="y"
fi

if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "Let's Encrypt FreeIPA installation cancelled by user"
    exit 1
fi

#Compute the absolute path of the source for this script
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

destination='/usr/sbin/renew_letsencrypt_cert.sh'
cronfile="/etc/cron.d/$(basename ${destination})"
export interactive
old_umask="$(umask)"
umask 0002

if [[ ${DIR}/register.sh ]]; then
    echo "Found existing register.sh in the same directory as this script; using that..."
    bash ${DIR}/register.sh
else
    wget https://raw.githubusercontent.com/antevens/letsencrypt-freeipa/master/register.sh -O - | bash
fi

if [[ ${DIR}/renew.sh ]]; then
    echo "Found existing renew.sh in the same directory as this script; using that..."
    cp ${DIR}/renew.sh ${destination}
else
    wget https://raw.githubusercontent.com/antevens/letsencrypt-freeipa/master/renew.sh -O "${destination}"
fi

chown root:root "${destination}"
chmod 0700 "${destination}"
umask "${old_umask}"
bash "${destination}"

echo  "Your system has been configured for using LetsEncrypt, adding a cronjob for renewals"

#certbot maintainers suggest attempting to renew every 12 hours
#https://community.letsencrypt.org/t/cerbot-cron-job/23895/4
(( minute %= 60 ))
(( hour %= 12 ))
cronjob="${minute}  ${hour}/12    * * * root ${destination} > /dev/null"

echo "Adding Cronjob: ${cronjob} to ${cronfile}"
echo "${cronjob}" > "${cronfile}"
