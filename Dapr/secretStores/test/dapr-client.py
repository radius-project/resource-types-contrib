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


# ROLE=allowed: the app ID is in the component scopes. Read the permitted
# secret, then confirm that Kubernetes RBAC denies a secret that the
# ServiceAccount cannot read.
# ROLE=denied: the app ID is not in the component scopes. Confirm that the
# connection alone does not let the app use the secret store.
STORE = os.environ['CONNECTION_SECRETSTORE_COMPONENTNAME']
ROLE = os.environ['ROLE']
ALLOWED = os.environ['ALLOWED_SECRET']
DENIED = os.environ['DENIED_SECRET']


def allowed_read():
    status, body = call('GET', f'/v1.0/secrets/{STORE}/{ALLOWED}')
    return status == 200 and json.loads(body).get('token') == 'dapr-allowed-value', status, body


def rbac_denied_read():
    status, body = call('GET', f'/v1.0/secrets/{STORE}/{DENIED}')
    return status not in (0, 200) and 'forbidden' in body.lower(), status, body


def scope_denied_read():
    status, body = call('GET', f'/v1.0/secrets/{STORE}/{ALLOWED}')
    not_loaded = 'ERR_SECRET_STORE_NOT_FOUND' in body or 'ERR_SECRET_STORES_NOT_CONFIGURED' in body
    return status not in (0, 200) and not_loaded, status, body


checks = [allowed_read, rbac_denied_read] if ROLE == 'allowed' else [scope_denied_read]

wait_for_sidecar()
for check in checks:
    while True:
        passed, status, body = check()
        if passed:
            break
        print(f'{check.__name__} is not complete: {status} {body}', flush=True)
        time.sleep(2)
mark_ready(f'Secret store {STORE} checks passed for the {ROLE} app.')
