package buildinfo

import "strings"

var (
	Version   = "0.1.0-dev"
	GitCommit = "unknown"
	BuildDate = "unknown"
)

func VersionString() string {
	return strings.TrimSpace(Version)
}

func GitCommitString() string {
	return strings.TrimSpace(GitCommit)
}
