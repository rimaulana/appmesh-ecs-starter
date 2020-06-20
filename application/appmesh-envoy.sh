#!/bin/bash

# Copyright 2020 Rio Maulana

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function print_help {
    echo "usage: $0 [start|stop|restart]"
    echo "Manage AppMesh envoy proxy"
    echo ""
    echo "-h,--help print this help"
    echo "--mesh The name of the App Mesh mesh. (default: appmesh-sample)"
    echo "--node The name of the App Mesh virtual node. (default: frontend-ec2)"
    echo "--region The EKS cluster region. (default: us-east-2)"
}

POSITIONAL=()
POLICY_DOCUMENTS=()
POLICY_ARNS=()

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        --mesh)
            MESH_NAME="$2"
            shift
            shift
            ;;
        --node)
            NODE_NAME="$2"
            shift
            shift
            ;;
        --region)
            REGION=$2
            shift
            shift
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
OPERATION="$1"

MESH_NAME="${MESH_NAME:-appmesh-sample}"
NODE_NAME="${NODE_NAME:-frontend-ec2}"
REGION="${REGION:-us-east-2}"

function start_envoy() {
  docker run \
    --detach \
    --env APPMESH_VIRTUAL_NODE_NAME=mesh/$MESH_NAME/virtualNode/$NODE_NAME \
    --env ENABLE_ENVOY_XRAY_TRACING="1" \
    -u 1337 \
    --name appmesh-envoy \
    --network host 840364872350.dkr.ecr.$REGION.amazonaws.com/aws-appmesh-envoy:v1.12.3.0-prod
}

function stop_envoy() {
  CONTAINER_ID=`docker ps | grep appmesh-envoy | awk '{print $1}'`

  if [[ ! -z $CONTAINER_ID ]]; then
    docker stop $CONTAINER_ID
    docker rm $CONTAINER_ID
  fi
}

case $OPERATION in 
    start)
        start_envoy
        ;;
    stop)
        stop_envoy
        ;;
    restart)
        stop_envoy
        start_envoy
        ;;
    *)
        echo "Operation $OPERATION does not exist, exiting"
        exit 1
        ;;
esac