import json
import os
import time
import urllib.error
import urllib.request

DAPR = 'http://127.0.0.1:' + os.environ.get('DAPR_HTTP_PORT', '3500')


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        DAPR + path, data=data, method=method, headers={'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()
    except OSError as error:
        return 0, str(error)


def wait_for_sidecar():
    while call('GET', '/v1.0/healthz/outbound')[0] != 204:
        time.sleep(2)


def mark_ready(message):
    print(message, flush=True)
    open('/tmp/dapr-ready', 'w').close()
    while True:
        time.sleep(3600)


# Read a value through the Dapr configuration API. The test runner writes the
# value to the Recipe-owned Redis, because the configuration API is read-only.
STORE = os.environ['CONNECTION_CONFIGSTORE_COMPONENTNAME']
KEY = 'radius-test-key'
EXPECTED = 'dapr-config-ok'

wait_for_sidecar()
while True:
    status, body = call('GET', f'/v1.0/configuration/{STORE}?key={KEY}')
    if status == 200 and json.loads(body).get(KEY, {}).get('value') == EXPECTED:
        break
    print(f'Configuration check is not complete: {status} {body}', flush=True)
    time.sleep(2)
mark_ready(f'Read a configuration value through Dapr configuration store {STORE}.')
