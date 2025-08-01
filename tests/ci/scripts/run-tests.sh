#!/bin/bash
# Use Docker Compose to spin up containers and test different Python versions
# against different XDMoD web server versions.

set -exo pipefail

export MIN_PYTHON_VERSION=3.8
export MAX_PYTHON_VERSION=3.13
export XDMOD_11_0_IMAGE=tools-ext-01.ccr.xdmod.org/xdmod:x86_64-rockylinux8.9.20231119-v11.0.0-1.0-03

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR=$BASE_DIR/../../..

docker compose -f $BASE_DIR/docker-compose.yml up -d

declare -a python_containers=$(yq '.services | keys | .[] | select(. == "python-*")' $BASE_DIR/docker-compose.yml)
declare -a xdmod_containers=$(yq '.services | keys | .[] | select(. == "xdmod-*")' $BASE_DIR/docker-compose.yml)

# Copy the xdmod-data source code to the Python containers, lint
# with Flake 8, and install the package and its testing
# dependencies.
for python_container in $python_containers; do
  docker cp $PROJECT_DIR/. $python_container:/home/circleci/project
  docker exec $python_container bash -c 'sudo chown -R circleci:circleci /home/circleci/project'
  docker exec -w /home/circleci/project $python_container bash -c 'python3 -m pip install --upgrade pip'
  docker exec -w /home/circleci/project $python_container bash -c 'python3 -m pip install --upgrade flake8 flake8-commas flake8-quotes'
  docker exec -w /home/circleci/project $python_container bash -c 'python3 -m flake8 . --max-complexity=10 --show-source --exclude __init__.py'
  docker exec -w /home/circleci/project $python_container bash -c 'python3 -m pip install -e .'
  docker exec -w /home/circleci/project $python_container bash -c 'python3 -m pip install --upgrade python-dotenv pytest coverage'
  # The minimum version of each dependency should be tested in the
  # container with the minimum Python version.
  if [ "$python_container" = "python-min" ]; then
    min_dependency_versions=$(awk \
      '/install_requires/ {flag=1} flag && !/install_requires/ && NF {print $0} flag && /^\[.*\]$/ {flag=0}' \
      setup.cfg | tr -d '\n' | sed 's/ >= /==/g'
    )
    docker exec -w /home/circleci/project $python_container bash -c "python3 -m pip install --force-reinstall $min_dependency_versions"
  fi
done

# Set up XDMoD web server containers.
for xdmod_container in $xdmod_containers; do
  # Generate OpenSSL key and certificate.
  docker exec $xdmod_container bash -c "openssl genrsa -rand /proc/cpuinfo:/proc/filesystems:/proc/interrupts:/proc/ioports:/proc/uptime 2048 > /etc/pki/tls/private/$xdmod_container.key"
  docker exec $xdmod_container bash -c "openssl req -new -key /etc/pki/tls/private/$xdmod_container.key -x509 -sha256 -days 365 -set_serial $RANDOM -extensions v3_req -out /etc/pki/tls/certs/$xdmod_container.crt -subj '/C=XX/L=Default City/O=Default Company Ltd/CN=$xdmod_container' -addext 'subjectAltName=DNS:$xdmod_container'"
  # Update the server hostnames and certificates so the Python
  # containers can make requests to them.
  docker exec $xdmod_container bash -c "sed -i \"s/localhost/$xdmod_container/g\" /etc/httpd/conf.d/xdmod.conf"
  if [[ "$xdmod_container" =~ 'xdmod-*-dev' ]]; then
    if [ "$xdmod_container" = 'xdmod-main-dev' ]; then
      branch='main'
    else
      branch="xdmod$(echo $xdmod_container | sed 's/xdmod-\(.*\)-dev/\1/' | sed 's/-/./')"
    fi
    # Install and run the latest development version of the XDMoD
    # web server.
    docker exec $xdmod_container bash -c 'git clone --depth=1 --branch=$branch https://github.com/ubccr/xdmod.git /root/xdmod'
    docker exec -w /root/xdmod $xdmod_container bash -c 'composer install'
    docker exec -w /root/xdmod $xdmod_container bash -c '/root/bin/buildrpm xdmod'
    docker exec -w /root/xdmod $xdmod_container bash -c 'XDMOD_TEST_MODE=upgrade ./tests/ci/bootstrap.sh'
    docker exec -w /root/xdmod $xdmod_container bash -c './tests/ci/validate.sh'
  elif [[ "$xdmod_container" =~ xdmod-* ]]; then
    # Run the XDMoD web server.
    docker exec $xdmod_container bash -c '/root/bin/services start'
  fi
  # Copy the 10,000 users file into the container and shred it.
  # We use this file so we can test filters with more than 10,000
  # values and date ranges that span multiple quarters.
  docker cp $PROJECT_DIR/tests/ci/artifacts/10000users.log $xdmod_container:.
  docker exec $xdmod_container xdmod-shredder -r frearson -f slurm -i 10000users.log
  # Ingest and aggregate.
  date=$(date --utc +%Y-%m-%d)
  docker exec $xdmod_container xdmod-ingestor --ingest
  docker exec $xdmod_container xdmod-ingestor --aggregate=job --last-modified-start-date $date
  # Copy certificate (for doing requests) from the XDMoD container.
  docker cp $xdmod_container:/etc/pki/tls/certs/$xdmod_container.crt $PROJECT_DIR
  # Copy certificate to one of the Python containers and get an
  # XDMoD API token for the XDMoD container.
  docker cp $xdmod_container.crt $python_container:/home/circleci/project
  rest_token=$(docker exec \
    -e CURL_CA_BUNDLE="/home/circleci/project/$xdmod_container.crt" \
    $python_container \
    bash -c "curl \
      -sS \
      -X POST \
      -c xdmod.cookie \
      -d 'username=normaluser&password=normaluser' \
      https://$xdmod_container/rest/auth/login \
      | jq -r '.results.token'"
  )
  docker exec $python_container bash -c 'echo -n "XDMOD_API_TOKEN="' > ${xdmod_container}-token
  docker exec \
    -e CURL_CA_BUNDLE="/home/circleci/project/$xdmod_container.crt" \
    $python_container \
    bash -c "curl \
      -sS \
      -X POST \
      -b xdmod.cookie \
      https://$xdmod_container/rest/users/current/api/token?token=$rest_token \
      | jq -r '.data.token'" \
      >> ${xdmod_container}-token
done

# Run the tests against each XDMoD web server.
for python_container in $python_containers; do
  for xdmod_container in $xdmod_containers; do
    # Copy certificate (for doing requests) to the Python
    # container.
    docker cp $xdmod_container.crt $python_container:/home/circleci/project
    # Copy XDMoD API token to the Python container.
    docker cp $PROJECT_DIR/${xdmod_container}-token $python_container:/home/circleci/.xdmod-data-token
    # Run tests in the Python container.
    docker exec \
      -e CURL_CA_BUNDLE="/home/circleci/project/$xdmod_container.crt" \
      -e XDMOD_HOST="https://$xdmod_container" \
      -e XDMOD_VERSION="$xdmod_container" \
      $python_container \
      bash -c 'python3 -m coverage run --branch --append -m pytest -vvs -o log_cli=true tests/'
  done
  # Make sure 100% test coverage.
  docker exec $python_container bash -c 'python3 -m coverage report -m --fail-under=100'
done
