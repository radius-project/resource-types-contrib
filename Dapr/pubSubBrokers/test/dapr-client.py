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

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Subscribe to a topic, publish a message through the Dapr pub/sub API, and
# wait until the subscriber receives it.
STORE = os.environ['CONNECTION_PUBSUB_COMPONENTNAME']
TOPIC = 'radius-test'
EXPECTED = 'dapr-pubsub-' + os.urandom(8).hex()
received = threading.Event()


class Subscriber(BaseHTTPRequestHandler):
    def reply(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == '/dapr/subscribe':
            self.reply(200, [{'pubsubname': STORE, 'topic': TOPIC, 'route': '/messages'}])
        else:
            self.reply(404, {})

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        event = json.loads(self.rfile.read(length) or b'{}')
        if self.path == '/messages':
            data = event.get('data')
            if isinstance(data, dict) and data.get('id') == EXPECTED:
                received.set()
            self.reply(200, {'status': 'SUCCESS'})
        else:
            self.reply(404, {})

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('APP_PORT', '3000'))), Subscriber)
threading.Thread(target=server.serve_forever, daemon=True).start()

wait_for_sidecar()
while not received.is_set():
    status, body = call('POST', f'/v1.0/publish/{STORE}/{TOPIC}', {'id': EXPECTED})
    if status != 204:
        print(f'Publish is not complete: {status} {body}', flush=True)
    received.wait(5)
mark_ready(f'Published and received a message through Dapr pub/sub {STORE}.')
