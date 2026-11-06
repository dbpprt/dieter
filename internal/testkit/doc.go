// Package testkit holds shared fixtures for Go tests: isolated Dieter homes
// and stores, Git repositories, fake and mock harness runners, loopback HTTP
// servers, and race-aware polling. In-process gateway and daemon topologies
// live in the topology subpackage.
//
// Fixtures never touch the operator's daemon or DIETER_HOME: every root is a
// test temporary directory and every listener a random loopback port.
//
// testkit imports the store and harness packages, so their own internal tests
// (and those of the packages they import) cannot use it without an import
// cycle; they keep minimal local setup instead. The external tests of the
// store aggregates (package <aggregate>_test) use its store fixtures.
package testkit
