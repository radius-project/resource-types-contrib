#!/bin/sh
set -eo pipefail

# Note: Using docker outside of docker means the oras server will run on the host docker daemon.
# Thus the "localhost:5000" used in the build scripts will not work inside the devcontainer, it should be <host-ip>:5000.
# We can use host.docker.internal to access the host from inside the container. We'll proxy the port using socat.
exec socat TCP-LISTEN:5000,reuseaddr,fork TCP:host.docker.internal:5000
