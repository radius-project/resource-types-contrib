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
// The defaults.yaml file lists the canonical resource type names that should be
// embedded and registered by default when Radius starts. Running `go generate`
// resolves those names to manifest file paths by convention and produces
// manifests_gen.go with //go:embed directives for the corresponding files.
package resourcetypes

//go:generate go run ./cmd/gen-embed
