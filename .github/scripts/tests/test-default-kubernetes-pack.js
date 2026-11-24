// Copyright 2026 The Radius Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../../..');
const pack = fs.readFileSync(path.join(root, 'recipe-packs/kubernetes/default.bicep'), 'utf8');
const workflow = fs.readFileSync(path.join(root, '.github/workflows/publish-bicep-recipes.yaml'), 'utf8');
const folders = [
  'Compute/containers',
  'Compute/containerImages',
  'Compute/persistentVolumes',
  'Compute/routes',
  'Security/secrets',
  'Data/mySqlDatabases',
  'Data/mongoDatabases',
  'Data/postgreSqlDatabases',
  'Data/redisCaches',
  'Data/sqlServerDatabases',
  'Messaging/kafka',
  'Messaging/rabbitMQ',
  'Storage/objectStorage',
];
const entries = [...pack.matchAll(/^      '(Radius\.[^']+)': \{\r?\n([\s\S]*?)^      \}/gm)];

test('default Kubernetes pack covers exactly the supported non-AI default types once', () => {
  const expected = folders.map(folder => `Radius.${folder}`).sort();
  assert.deepEqual(entries.map(entry => entry[1]).sort(), expected);
});

test('every default recipe has paired local sources and a matching Kubernetes publisher', () => {
  for (const folder of folders) {
    const type = `Radius.${folder}`;
    const entry = entries.find(candidate => candidate[1] === type);
    assert.ok(entry, `Missing ${type}`);
    const alias = path.posix.basename(folder).toLowerCase();
    assert.match(entry[2], /kind: 'bicep'/);
    assert.ok(entry[2].includes(`source: 'ghcr.io/radius-project/kube-recipes/${alias}:latest'`),
      `${type} must use its published Kubernetes source`);
    const recipeRoot = path.join(root, folder, 'recipes/kubernetes');
    const bicepFiles = fs.readdirSync(path.join(recipeRoot, 'bicep')).filter(file => file.endsWith('.bicep'));
    assert.equal(bicepFiles.length, 1, `${type} must have one Bicep entry point`);
    const source = `${folder}/recipes/kubernetes/bicep/${bicepFiles[0]}`;
    assert.ok(workflow.includes(`run: ./.github/scripts/publish-bicep-recipe.sh ${alias} ${source}`),
      `${type} publication must use the matching source and default registry`);
    const terraformRoot = path.join(recipeRoot, 'terraform');
    assert.ok(fs.existsSync(path.join(terraformRoot, 'main.tf')), `${type} lacks a Terraform entry point`);
    const terraform = fs.readdirSync(terraformRoot).filter(file => file.endsWith('.tf'))
      .map(file => fs.readFileSync(path.join(terraformRoot, file), 'utf8')).join('\n');
    assert.match(terraform, /variable\s+"context"\s*\{/, `${type} must accept the Radius context`);
  }
});

test('new default entries use recipe-owned prerequisites, not stored credentials or license consent', () => {
  for (const folder of ['Data/mongoDatabases', 'Data/sqlServerDatabases', 'Messaging/kafka', 'Storage/objectStorage']) {
    const type = `Radius.${folder}`;
    const entry = entries.find(candidate => candidate[1] === type);
    assert.ok(entry, `Missing ${type}`);
    assert.deepEqual([...entry[2].matchAll(/^\s+(\w+):/gm)].map(match => match[1]).sort(),
      ['kind', 'source'], `${type} must not inject credentials or accept a license`);
  }
  assert.doesNotMatch(pack, /\b(?:mongoPassword|objectStorageAccountKey|sqlServerAcceptEula)\b/);
});
