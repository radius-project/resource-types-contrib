#!/bin/sh
set -eo pipefail

# Note: Uncomment the following line if you get "Connection refused" on localhost:5000 while building recipes
# exec socat TCP-LISTEN:5000,reuseaddr,fork TCP:host.docker.internal:5000
