/*
Copyright 2025 The Radius Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package resourcetypes provides embedded resource type manifests for default
// registration in Radius.
//
// This package is imported by the Radius binary (github.com/radius-project/radius)
// as a Go module dependency. It exposes a single variable, DefaultManifests, which
// is an embed.FS containing the manifest YAML files listed in defaults.yaml.
//
// How it works:
//  1. defaults.yaml lists canonical resource type names (e.g., Radius.Compute/containers)
//     that should be embedded into the Radius binary for default registration at startup.
//  2. Running `go generate` invokes cmd/gen-embed, which reads defaults.yaml, resolves
//     each name to a manifest file path, and writes manifests_gen.go with //go:embed
//     directives for exactly those files.
//  3. manifests_gen.go (generated, checked in) declares the DefaultManifests embed.FS
//     variable that the Radius binary imports.
//
// To add a new default resource type, see the instructions in defaults.yaml.
package resourcetypes

// go:generate runs cmd/gen-embed to regenerate manifests_gen.go from defaults.yaml.
// This must be run after any change to defaults.yaml.
//go:generate go run ./cmd/gen-embed
