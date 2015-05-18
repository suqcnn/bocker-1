#!/bin/bash

# Purpose: A Dockerfile compiler
# Author : Anh K. Huynh <kyanh@theslinux.org>
# License: MIT

# Copyright © 2015 Anh K. Huynh
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the “Software”), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall
# be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

set -u

ed_reset() {
  for _matter in \
    ${@:-\
      __MATTER_ENV__ \
      __MATTER_ONBUILD__ \
      __MATTER_VOLUME__ \
      __MATTER_EXPOSE__
    }; \
  do
    export $_matter=
  done
}

ed_from() {
  export __FROM="$@"
}

ed_maintainer() {
  export __MAINTAINER="$@"
}

ed_env() {
  local _name="$1"; shift
  export __MATTER_ENV__="${__MATTER_ENV__:-}^x^x^ENV ${_name^^} $@"
}

ed_onbuild() {
  export __MATTER_ONBUILD__="${__MATTER_ONBUILD__:-}^x^x^ONBUILD $@"
}

ed_expose() {
  while (( $# )); do
    export __MATTER_EXPOSE__="${__MATTER_EXPOSE__:-}^x^x^EXPOSE $1"
    shift
  done
}

ed_ship() {
  if [[ "${1:-}" == "--later" ]]; then
    shift
    while (( $# )); do
      export __MATTER_SHIP_LATER__="${__MATTER_SHIP_LATER__:-}^x^x^$1"
      shift
    done
    return
  fi

  # later => 0
  while (( $# )); do
    export __MATTER_SHIP__="${__MATTER_SHIP__:-}^x^x^$1"
    shift
  done
  return 0
}

ed_volume() {
  while (( $# )); do
    export __MATTER_VOLUME__="${__MATTER_VOLUME__:-}^x^x^VOLUME $1"
    shift
  done
}

ed_cmd() {
  export __MATTER_CMD__="CMD $@"
}

ed_entrypoint() {
  export __MATTER_ENTRYPOINT__="ENTRYPOINT $@"
}

__ed_bocker_filter() {
  __ed_method_body ed_bocker \
  | sed -e 's#\b\(ed_[a-z0-9]\+\)#__ed_ship_method \1#gi'
}

# Print the (body) definition of a function
__ed_method_body() {
  type "${1}" \
  | awk '{ if (NR > 3) { if ($0 != "}") {print $0;}} }' \
  | sed -e 's#^[ ]\+##g'
}

__do_matter() {
  local _sort_args="${@:--uk1}"

  sed -e 's,\^x^x^,\n,g' \
  | sed -e '/^[[:space:]]*$/d' \
  | sort $_sort_args
}

__ed_ensure_method() {
  if [[ "$(type -t ${1:-})" != "function" ]]; then
    echo >&2 ":: Bocker: method '${1:-}' not found or not a function"
    return 1
  fi
}

__ed_ship_method() {
  local METHOD="$1"

  case $METHOD in
  "ed_add")      shift; echo ""; echo "ADD $@"; return 0 ;;
  "ed_copy")     shift; echo ""; echo "COPY $@"; return 0 ;;
  "ed_user")     shift; echo ""; echo "USER $@"; return 0 ;;
  "ed_workdir")  shift; echo ""; echo "WORKDIR $@"; return 0 ;;
  "ed_run")      shift; echo ""; echo "RUN $@"; return 0;;
  esac

  __ed_ensure_method $METHOD || exit 127

  __ed_method_body $METHOD \
  | awk -vMETHOD=$METHOD \
    '
    BEGIN {
      printf("\n");
      printf("# Bocker method => %s\n", METHOD);
      printf("RUN set -eux; echo \":: Bocker method => %s\" >/dev/null; ", METHOD);
      printf("if [[ -f /bocker.sh ]]; then source /bocker.sh; fi; ");
    }
    {
      printf(" %s", $0);
    }
    END {
      printf("\n");
    }
    '
}

__ed_method_body_join() {
  local METHOD="$1"
  awk -vMETHOD="$METHOD" \
    '
    BEGIN {
      printf("%s(){ ", METHOD);
    }
    {
      printf("%s ", $0);
    }
    END {
      printf("; }; ");
    }
    '
}

__ed_ship() {
  local _methods=

  if [[ "${1:-}" == "--later" ]]; then
    shift
    _methods="$(echo "${__MATTER_SHIP_LATER__:-}" | __do_matter -uk1)"
  else
    _methods="$(echo "${__MATTER_SHIP__:-}" | __do_matter -uk1)"
  fi

  [[ -n "$_methods" ]] || return 0

  for METHOD in $_methods; do
    __ed_ensure_method $METHOD || return 127
  done

  echo ""
  echo "# Bocker method => $FUNCNAME"
  echo "# * The output is /bocker.sh in the result image."
  echo "# * List of methods: $(echo $_methods)."

  echo -n "RUN set -eux; "
  echo -n "if [[ -f /bocker.sh ]]; then source /bocker.sh; fi; "

  for METHOD in $_methods; do
    __ed_method_body "$METHOD" \
    | __ed_method_body_join "$METHOD"
  done

  echo -n "echo '#!/bin/bash' > /bocker.sh; "
  echo -n "echo '# This file is generated by Bocker.' >> /bocker.sh; "
  echo -n "declare -f >> /bocker.sh; "
  echo -n "echo 'if [[ -n \"\$@\" ]]; then \$@; fi; ' >> /bocker.sh; "
  echo "chmod 755 /bocker.sh"
  echo
}

__ed_configure_sh() {
  echo ""
  echo "$__FROM" | grep -qiE '(debian|ubuntu)'

  if [[ $? -eq 0 ]]; then
    echo "# On Debian-based system, /bin/sh is /bin/dash by default."
    echo "RUN set -eux; echo 'dash dash/sh boolean false' | debconf-set-selections; dpkg-reconfigure -f noninteractive dash"
  else
    echo "# On non Debian-based system, you may need to fix /bin/sh manually."
    echo "RUN /bin/sh -c 'declare >/dev/null' || { echo >&2 \":: Container shell doesn't have 'declare' method.\"; exit 127; }"
  fi
}

########################################################################
# All default settings
########################################################################

ed_from        debian:wheezy
ed_maintainer  "Anh K. Huynh <kyanh@theslinux.org>"
ed_env         DEBIAN_FRONTEND noninteractive
ed_reset       # reset all environments

readonly -f \
  __do_matter \
  __ed_bocker_filter \
  __ed_configure_sh \
  __ed_method_body \
  __ed_method_body_join \
  __ed_ship \
  __ed_ship_method \
  __ed_ensure_method \
  ed_cmd \
  ed_entrypoint \
  ed_env \
  ed_expose \
  ed_from \
  ed_maintainer \
  ed_onbuild \
  ed_reset \
  ed_ship \
  ed_volume

########################################################################
# Now loading all users definitions
########################################################################

for f in $@; do
  source $f || exit
done

########################################################################
# Basic checks
########################################################################

__ed_ensure_method ed_bocker || exit 127

########################################################################
# Shipping the contents
########################################################################

echo "###############################################################"
echo "# Dockerfile generated by Bocker-v1.0. Do not edit this file. #"
echo "###############################################################"

echo ""
echo "FROM $__FROM"
echo "MAINTAINER $__MAINTAINER"

if [[ -n "${__MATTER_ENV__:-}" ]]; then
  echo ""
  echo "${__MATTER_ENV__:-}" | __do_matter -uk1
fi

__ed_configure_sh
__ed_ship || exit 127

while read METHOD; do
  export -f $METHOD
done < <(declare -fF | awk '{print $NF}')

bash < <(__ed_bocker_filter) || exit

__ed_ship --later || exit 127

if [[ -n "${__MATTER_VOLUME__:-}" ]]; then
  echo ""
  echo "${__MATTER_VOLUME__:-}" | __do_matter -uk1
fi

if [[ -n "${__MATTER_EXPOSE__:-}" ]]; then
  echo ""
  echo "${__MATTER_EXPOSE__:-}" | __do_matter -unk2
fi

if [[ -n "${__MATTER_CMD__:-}" ]]; then
  echo ""
  echo "${__MATTER_CMD__:-}" | __do_matter -uk1
fi

if [[ -n "${__MATTER_ENTRYPOINT__:-}" ]]; then
  echo ""
  echo "${__MATTER_ENTRYPOINT__:-}" | __do_matter -uk1
fi

if [[ -n "${__MATTER_ONBUILD__:-}" ]]; then
  echo ""
  echo "${__MATTER_ONBUILD__:-}" | __do_matter -k1
fi
