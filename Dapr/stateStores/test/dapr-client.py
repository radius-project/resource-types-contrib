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


# Write a value through the Dapr state API, then read it back.
STORE = os.environ['CONNECTION_STATESTORE_COMPONENTNAME']
EXPECTED = 'dapr-state-' + os.urandom(8).hex()

wait_for_sidecar()
while True:
    status, body = call('POST', f'/v1.0/state/{STORE}', [{'key': 'radius-test', 'value': EXPECTED}])
    if status == 204:
        status, body = call('GET', f'/v1.0/state/{STORE}/radius-test')
        if status == 200 and json.loads(body) == EXPECTED:
            break
    print(f'State check is not complete: {status} {body}', flush=True)
    time.sleep(2)
mark_ready(f'Wrote and read a value through Dapr state store {STORE}.')
