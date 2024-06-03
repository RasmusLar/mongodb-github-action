#!/bin/bash

if [ $# -ne 8 ]; then
  echo "Illegal number of parameters: $#, \"$@\""
  echo "MONGODB_VERSION=$1
  MONGODB_REPLICA_SET=$2
  MONGODB_PORT=$3
  MONGODB_DB=$4
  MONGODB_USERNAME=$5
  MONGODB_PASSWORD=$6
  MONGODB_RUNNER_OS=$7
  MONGODB_RUNNER_TEMP=$8
  "
  exit $(($# + 1))
fi

# Map input values from the GitHub Actions workflow to shell variables
MONGODB_VERSION=$1
MONGODB_REPLICA_SET=$2
MONGODB_PORT=$3
MONGODB_DB=$4
MONGODB_USERNAME=$5
MONGODB_PASSWORD=$6
MONGODB_RUNNER_OS=$7
MONGODB_RUNNER_TEMP=$8

# `mongosh` is used starting from MongoDB 5.x
MONGODB_CLIENT="mongosh --quiet"

if [ -z "$MONGODB_VERSION" ]; then
  echo ""
  echo "Missing MongoDB version in the [mongodb-version] input. Received value: $MONGODB_VERSION"
  echo ""
  exit 2
fi
if [[ "$MONGODB_VERSION" == v* ]]; then
  MONGODB_VERSION=$(echo "$MONGODB_VERSION" | sed 's/v//')
elif [ "$MONGODB_VERSION" = latest ]; then
  # Parse? https://www.mongodb.com/try/download/community-edition/releases
  MONGODB_VERSION="7.0.11"
fi
echo Version $MONGODB_VERSION

# TODO? Support and parse older clients? Needs a lot more parsing..
# echo "::group::Selecting correct MongoDB client"
# if [ "`echo $MONGODB_VERSION | cut -c 1`" -le "4" ]; then
#   MONGODB_CLIENT="mongo"
# fi
# echo "  - Using MongoDB client: [$MONGODB_CLIENT]"
# echo ""
# echo "::endgroup::"

# Install
downloadPath=${MONGODB_RUNNER_OS}
extension=".tgz"
downloadCall="wget -q"
executable=""

decompress () {
  if [[ $1 == *".tgz" || $1 == *".tar.gz" ]]; then
    tar xvfz $1
  else
    unzip $1
  fi
}

if [[ "$MONGODB_RUNNER_OS" == ubuntu* ]]; then
  # Cause I'm special.
  MONGODB_VERSION=$(echo "$MONGODB_VERSION" | sed 's/-/~/')

  if [[ "$MONGODB_RUNNER_OS" == ubuntu-20.04 ]]; then
    downloadArch="linux-x86_64-ubuntu2004"
    toolsDownload="ubuntu2204-x86_64-100.9.4.tgz"
  elif [[ "$MONGODB_RUNNER_OS" == ubuntu-22.04 || "$MONGODB_RUNNER_OS" == ubuntu-latest ]]; then
    downloadArch="linux-x86_64-ubuntu2204"
    toolsDownload="ubuntu2004-x86_64-100.9.4.tgz"
  else
    echo "Only supporting 20.04 and 22.04 as of now."
    exit 6
  fi
  downloadPath="linux"
  shellDownload="linux-x64.tgz"
elif [[ "$MONGODB_RUNNER_OS" == windows* ]]; then
  extension=".zip"
  executable=".exe"
  downloadCall="curl -O -L -sS"
  downloadArch="windows-x86_64"
  toolsDownload="windows-x86_64-100.9.4.zip"
  shellDownload="win32-x64.zip"
elif [[ "$MONGODB_RUNNER_OS" == macos* ]]; then
  downloadArch="macos-x86_64"
  downloadPath="osx"
  toolsDownload="macos-x86_64-100.9.4.zip"
  shellDownload="darwin-x64.zip"
else
  echo "Could not parse os:"
  echo "Input: \"${MONGODB_RUNNER_OS}\""
  exit 3
fi

if [[ -z ${MONGODB_RUNNER_TEMP} ]]; then
  MONGODB_RUNNER_TEMP="/tmp"
fi
MONGODB_RUNNER_TEMP=${MONGODB_RUNNER_TEMP}/mongo
mkdir -p ${MONGODB_RUNNER_TEMP}/db

mkdir -p ${MONGODB_RUNNER_TEMP}/mongodb
cd $MONGODB_RUNNER_TEMP/mongodb
$downloadCall "https://fastdl.mongodb.org/${downloadPath}/mongodb-${downloadArch}-${MONGODB_VERSION}${extension}"
decompress ./*$extension
rm ./*$extension
binaryFolder=$(find $(pwd) -name "bin" -type d)
if (( $(echo "${binaryFolder}" | wc -l) != 1 )); then
  echo "Didn't find 1 bin folders:"
  echo "${binaryFolder}"
  exit 5
fi
echo "$binaryFolder" >> $GITHUB_PATH
PATH=${binaryFolder}:${PATH}
cd -

mkdir -p ${MONGODB_RUNNER_TEMP}/mongodbTools
cd $MONGODB_RUNNER_TEMP/mongodbTools
$downloadCall "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-${toolsDownload}"
decompress ./*$extension
rm ./*$extension
binaryFolder=$(find $(pwd) -name "bin" -type d)
if (( $(echo "${binaryFolder}" | wc -l) != 1 )); then
  echo "Didn't find 1 bin folders:"
  echo "${binaryFolder}"
  exit 5
fi
echo "$binaryFolder" >> $GITHUB_PATH
PATH=${binaryFolder}:${PATH}
cd -


mkdir -p ${MONGODB_RUNNER_TEMP}/mongosh
cd $MONGODB_RUNNER_TEMP/mongosh
$downloadCall "https://downloads.mongodb.com/compass/mongosh-2.2.6-${shellDownload}"
decompress ./*$extension
rm ./*$extension
binaryFolder=$(find $(pwd) -name "bin" -type d)
if (( $(echo "${binaryFolder}" | wc -l) != 1 )); then
  echo "Didn't find 1 bin folders:"
  echo "${binaryFolder}"
  exit 5
fi
echo "$binaryFolder" >> $GITHUB_PATH
PATH=${binaryFolder}:${PATH}
cd -

# echo ${PATH}

# Helper function to wait for MongoDB to be started before moving on
wait_for_mongodb () {
  echo "::group::Waiting for MongoDB to accept connections"
  sleep 1
  TIMER=0

  # until ${WAIT_FOR_MONGODB_COMMAND}
  until $MONGODB_CLIENT --port $MONGODB_PORT $MONGODB_CLIENT_ARGS --eval "db.serverStatus()"
  do
    sleep 1
    TIMER=$((TIMER + 1))
    tail -1 ${MONGODB_RUNNER_TEMP}/mongod.log

    if [[ $TIMER -eq 60 ]]; then
      echo "MongoDB did not initialize within 60 seconds. Exiting."
      exit 2
    fi
  done
  echo "::endgroup::"
}


# check if the container already exists and remove it
## TODO: put this behind an option flag
# if [ "$(docker ps -q -f name=$MONGODB_CONTAINER_NAME)" ]; then
#  echo "Removing existing container [$MONGODB_CONTAINER_NAME]"
#  docker rm -f $MONGODB_CONTAINER_NAME
# fi


MONGODB_CLIENT_ARGS=""
MONGODB_ARGS=""
if [ -z "$MONGODB_REPLICA_SET" ]; then
  if [ -n "$MONGODB_USERNAME" ]
  then
    mongod --dbpath ${MONGODB_RUNNER_TEMP}/db --logpath ${MONGODB_RUNNER_TEMP}/mongod.log --port $MONGODB_PORT > /dev/null 2>&1 &
    wait_for_mongodb
    # no replica set, but username given: use them as args
    MONGODB_CLIENT_ARGS="--username $MONGODB_USERNAME --password $MONGODB_PASSWORD"
    MONGODB_ARGS="--auth"
    $MONGODB_CLIENT --port $MONGODB_PORT --eval "use admin
db.createUser(
  {
    user: "${MONGODB_USERNAME}",
    pwd: "${MONGODB_PASSWORD}",
    roles: [
      { role: "userAdminAnyDatabase", db: "admin" },
      { role: "readWriteAnyDatabase", db: "admin" }
    ]
  }
)
db.adminCommand( { shutdown: 1 } )
"
  sleep 3
  # Check it's down?
  ps -ef | grep mongod
  fi

  echo "::group::Starting single-node instance, no replica set"
  echo "  - port [$MONGODB_PORT]"
  echo "  - version [$MONGODB_VERSION]"
  echo "  - database [$MONGODB_DB]"
  echo "  - credentials [$MONGODB_USERNAME:$MONGODB_PASSWORD]"
  echo ""

  mongod ${MONGODB_ARGS} --dbpath ${MONGODB_RUNNER_TEMP}/db --logpath ${MONGODB_RUNNER_TEMP}/mongod.log --port $MONGODB_PORT > /dev/null 2>&1 &

   
  if [ $? -ne 0 ]; then
      echo "Error starting MongoDB Docker container"
      exit 2
  fi
  echo "::endgroup::"

  wait_for_mongodb
  $MONGODB_CLIENT --port ${MONGODB_PORT} ${MONGODB_CLIENT_ARGS} --eval "use ${MONGODB_DB}"

  exit 0
fi


echo "::group::Starting MongoDB as single-node replica set"
echo "  - port [$MONGODB_PORT]"
echo "  - version [$MONGODB_VERSION]"
echo "  - replica set [$MONGODB_REPLICA_SET]"
echo ""

mongod --dbpath ${MONGODB_RUNNER_TEMP}/db --logpath ${MONGODB_RUNNER_TEMP}/mongod.log --port $MONGODB_PORT --replSet $MONGODB_REPLICA_SET > /dev/null 2>&1 & # --fork doesn't work on Windows. > /dev/null 2>&1 &

if [ $? -ne 0 ]; then
    echo "Error starting MongoDB Docker container"
    exit 2
fi
echo "::endgroup::"

wait_for_mongodb

echo "::group::Initiating replica set [$MONGODB_REPLICA_SET]"

$MONGODB_CLIENT --port $MONGODB_PORT $MONGODB_CLIENT_ARGS --eval "
  rs.initiate({
    \"_id\": \"$MONGODB_REPLICA_SET\",
    \"members\": [ {
       \"_id\": 0,
      \"host\": \"localhost:$MONGODB_PORT\"
    } ]
  })
"

echo "Success! Initiated replica set [$MONGODB_REPLICA_SET]"
echo "::endgroup::"


echo "::group::Checking replica set status [$MONGODB_REPLICA_SET]"
$MONGODB_CLIENT --port $MONGODB_PORT --eval "rs.status()"
echo "::endgroup::"
