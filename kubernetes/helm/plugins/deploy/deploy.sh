#!/bin/bash

usage() {
cat << EOF
Install (or upgrade) an umbrella Helm Chart, and its subcharts, as separate Helm Releases 

The umbrella Helm Chart is broken apart into a parent release and subchart releases.
Subcharts the are disabled (<chart>.enabled=false) will not be installed or upgraded.
All releases are grouped and deployed within the same namespace.


The deploy arguments must be a release and chart. The chart
argument can be either: a chart reference('stable/onap'), a path to a chart directory,
a packaged chart, or a fully qualified URL. For chart references, the latest
version will be specified unless the '--version' flag is set.

To override values in a chart, use either the '--values' flag and pass in a file
or use the '--set' flag and pass configuration from the command line, to force string
values, use '--set-string'.

You can specify the '--values'/'-f' flag multiple times. The priority will be given to the
last (right-most) file specified. For example, if both myvalues.yaml and override.yaml
contained a key called 'Test', the value set in override.yaml would take precedence:

	$ helm deploy demo ./onap --namespace onap -f openstack.yaml -f overrides.yaml

You can specify the '--set' flag multiple times. The priority will be given to the
last (right-most) set specified. For example, if both 'bar' and 'newbar' values are
set for a key called 'foo', the 'newbar' value would take precedence:

	$ helm deploy demo local/onap --namespace onap -f overrides.yaml --set log.enabled=false --set vid.enabled=false

Usage:
  helm deploy [RELEASE] [CHART] [flags]

Flags:
      --namespace string         namespace to install the release into. Defaults to the current kube config namespace.
      --set stringArray          set values on the command line (can specify multiple or separate values with commas: key1=val1,key2=val2)
      --set-string stringArray   set STRING values on the command line (can specify multiple or separate values with commas: key1=val1,key2=val2)
  -f, --values valueFiles        specify values in a YAML file or a URL(can specify multiple) (default [])
      --verbose                  enables full helm install/upgrade output during deploy
EOF
}

parse_yaml() {
  local prefix=$2
  local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
  sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
       -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
  awk -F$fs '{
     indent = length($1)/2;
     vname[indent] = $2;
     for (i in vname) {if (i > indent) {delete vname[i]}}
     if (length($3) > 0) {
        vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
        printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
     }
  }'
}

generate_overrides() {
  SUBCHART_NAMES=($(cat $COMPUTED_OVERRIDES | grep -v '^\s\s'))

  for index in "${!SUBCHART_NAMES[@]}"; do
    START=${SUBCHART_NAMES[index]}
    END=${SUBCHART_NAMES[index+1]}
    if [[ $START == "global:" ]]; then
      echo "global:" > $GLOBAL_OVERRIDES
      cat $COMPUTED_OVERRIDES | sed '/common:/,/consul:/d' \
        | sed -n '/'"$START"'/,/'log:'/p' | sed '1d;$d' >> $GLOBAL_OVERRIDES  
    else
      SUBCHART_DIR="$CACHE_SUBCHART_DIR/$(cut -d':' -f1 <<<"$START")"
      if [[ -d "$SUBCHART_DIR" ]]; then
        cat $COMPUTED_OVERRIDES | sed -n '/'"$START"'/,/'"$END"'/p' \
          | sed '1d;$d' | cut -c3- > $SUBCHART_DIR/subchart-overrides.yaml
      fi
    fi
  done
}

resolve_deploy_flags() {
  DEPLOY_FLAGS=$1
  for flag in -f --values --set --set-string
  do
    while true ; do
      # extract value of flag
      length=${#flag}
      length=$((length+1))
      FLAG_VALUE="$(echo $DEPLOY_FLAGS | sed -n 's/.*\('$flag'\).\s*/\1/p' | cut -c$length- | cut -d' ' -f1)"

      # purge flag and value from
      DEPLOY_FLAGS="${DEPLOY_FLAGS//$flag $FLAG_VALUE/}"
      DEPLOY_FLAGS=$(echo $DEPLOY_FLAGS | awk '{$1=$1};1')
      if [ -z "$FLAG_VALUE" ] ; then
        break
      fi
    done
  done
  echo "$DEPLOY_FLAGS"
}

deploy() {
  # validate params
  if [[ -z "$1" || -z "$2" ]]; then
    usage
    exit 0
  fi

  RELEASE=$1
  CHART_URL=$2
  FLAGS=${@:3}
  CHART_REPO="$(cut -d'/' -f1 <<<"$CHART_URL")"
  CHART_NAME="$(cut -d'/' -f2 <<<"$CHART_URL")"
  CACHE_DIR=~/.helm/plugins/deploy/cache
  CHART_DIR=$CACHE_DIR/$CHART_NAME
  CACHE_SUBCHART_DIR=$CHART_DIR-subcharts
  LOG_DIR=$CHART_DIR/logs

  # determine if verbose output is enabled
  VERBOSE="false"
  if [[ $FLAGS = *"--verbose"* ]]; then
    FLAGS="$(echo $FLAGS| sed -n 's/--verbose//p')"
    VERBOSE="true"
  fi

  # should pass all flags instead
  NAMESPACE="$(echo $FLAGS | sed -n 's/.*\(namespace\).\s*/\1/p' | cut -c10- | cut -d' ' -f1)"

  # Remove all override values passed in as arguments. These will be used during dry run
  # to resolve computed override values. Remaining flags will be passed on during
  # actual upgrade/install of parent and subcharts.
  DEPLOY_FLAGS=$(resolve_deploy_flags "$FLAGS")

  # determine if upgrading individual subchart or entire parent + subcharts
  SUBCHART_RELEASE="$(cut -d'-' -f2 <<<"$RELEASE")"
  if [[ ! -d "$CACHE_SUBCHART_DIR/$SUBCHART_RELEASE" ]]; then
    SUBCHART_RELEASE=
  else
    # update specified subchart without parent
    RELEASE="$(cut -d'-' -f1 <<<"$RELEASE")"
  fi

  # clear previously cached charts
  rm -rf $CACHE_DIR

  # create log driectory
  mkdir -p $LOG_DIR

  # fetch umbrella chart (parent chart containing subcharts)
  if [[ -d "$CHART_URL" ]]; then
    mkdir -p $CHART_DIR
    cp -R $CHART_URL/* $CHART_DIR/

    charts=$CHART_DIR/charts/*
    for subchart in $charts ; do
      tar xzf ${subchart} -C $CHART_DIR/charts/
    done
    rm -rf $CHART_DIR/charts/*.tgz
  else
    echo "fetching $CHART_URL"
    helm fetch $CHART_URL --untar --untardir $CACHE_DIR
  fi

  # move out subcharts to process separately
  mkdir -p $CACHE_SUBCHART_DIR
  mv $CHART_DIR/charts/* $CACHE_SUBCHART_DIR/
  # temp hack - parent chart needs common subchart
  mv $CACHE_SUBCHART_DIR/common $CHART_DIR/charts/

  # disable dependencies
  rm $CHART_DIR/requirements.lock
  mv $CHART_DIR/requirements.yaml $CHART_DIR/requirements.deploy

  # compute overrides for parent and all subcharts
  COMPUTED_OVERRIDES=$CACHE_DIR/$CHART_NAME/computed-overrides.yaml
  helm upgrade -i $RELEASE $CHART_DIR $FLAGS --dry-run --debug \
   | sed -n '/COMPUTED VALUES:/,/HOOKS:/p' | sed '1d;$d' > $COMPUTED_OVERRIDES

  # extract global overrides to apply to parent and all subcharts
  GLOBAL_OVERRIDES=$CHART_DIR/global-overrides.yaml
  generate_overrides $COMPUTED_OVERRIDES $GLOBAL_OVERRIDES

  # upgrade/install parent chart first
  if [[ -z "$SUBCHART_RELEASE" ]]; then
    LOG_FILE=$LOG_DIR/${RELEASE}.log
    :> $LOG_FILE

    helm upgrade -i $RELEASE $CHART_DIR $DEPLOY_FLAGS -f $COMPUTED_OVERRIDES \
     > $LOG_FILE.log 2>&1

    echo "release $RELEASE deployed"

    if [[ $VERBOSE == "true" ]]; then
      cat $LOG_FILE
    fi
  fi

  # parse computed overrides - will use to determine if a subchart is "enabled"
  eval $(parse_yaml $COMPUTED_OVERRIDES "computed_")

  # upgrade/install each "enabled" subchart
  cd $CACHE_SUBCHART_DIR/
  for subchart in * ; do
    VAR="computed_${subchart}_enabled"
    COMMAND="$"$VAR
    eval "SUBCHART_ENABLED=$COMMAND"
    if [[ $SUBCHART_ENABLED == "true" ]]; then
      if [[ -z "$SUBCHART_RELEASE" || $SUBCHART_RELEASE == "$subchart" ]]; then
        LOG_FILE=$LOG_DIR/"${RELEASE}-${subchart}".log
        :> $LOG_FILE

        SUBCHART_OVERRIDES=$CACHE_SUBCHART_DIR/$subchart/subchart-overrides.yaml
        helm upgrade -i "${RELEASE}-${subchart}" $CACHE_SUBCHART_DIR/$subchart \
         $DEPLOY_FLAGS -f $GLOBAL_OVERRIDES -f $SUBCHART_OVERRIDES \
         > $LOG_FILE 2>&1

        echo "release ${RELEASE}-${subchart} deployed"

        if [[ $VERBOSE == "true" ]]; then
          cat $LOG_FILE
        fi
      fi
    else
      array=($(helm ls -q | grep "${RELEASE}-${subchart}"))
      n=${#array[*]}
      for (( i = n-1; i >= 0; i-- )); do
        helm del "${array[i]}" --purge
      done
    fi
  done

  # report on success/failures of installs/upgrades
  helm ls | grep FAILED | grep $RELEASE
}

case "${1:-"help"}" in
  "help")
    usage
    ;;
  "--help")
    usage
    ;;
  "-h")
    usage
    ;;
  *)
    deploy $1 $2 ${@:3}
    ;;
esac

exit 0