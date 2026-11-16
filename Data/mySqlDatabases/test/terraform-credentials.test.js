// Copyright 2026 The Radius Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

test('credential updates replace MySQL; unchanged credentials do not', () => {
  const result = spawnSync('terraform', ['test', '-json', '-verbose'], {
    cwd: path.resolve(__dirname, '../recipes/kubernetes/terraform'),
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout.slice(-6000)}\n${result.stderr}`);
  const events = result.stdout.trim().split(/\r?\n/).map(line => JSON.parse(line));
  for (const name of ['updated_credentials', 'updated_password', 'updated_username', 'unchanged_credentials']) {
    const plan = events.find(event => event.type === 'test_plan' && event['@testrun'] === name)?.test_plan;
    assert.ok(plan, `Missing plan for ${name}`);
    const change = address => plan.resource_changes.find(resource => resource.address === address).change;
    assert.deepEqual(change('kubernetes_deployment_v1.mysql').actions,
      name === 'unchanged_credentials' ? ['no-op'] : ['delete', 'create'], name);
    assert.deepEqual(change('kubernetes_secret_v1.mysql').actions,
      name === 'unchanged_credentials' ? ['no-op'] : ['update'], name);
    assert.deepEqual(change('kubernetes_service_v1.mysql').actions, ['no-op'], name);
    const trigger = change('terraform_data.credentials');
    assert.equal(trigger.after_sensitive.triggers_replace.password, true);
    assert.equal(trigger.after_sensitive.triggers_replace.username, true);
  }
});
