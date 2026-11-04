package localcluster

import "fmt"

// RuntimeRequirements discloses the configured VM budget before native setup
// creates keys or downloads files. It does not describe currently free memory.
type RuntimeRequirements struct {
	CPUs                   int    `json:"cpus"`
	MemoryBytes            uint64 `json:"memory_bytes"`
	DiskBytes              uint64 `json:"disk_bytes"`
	InitialDownloadBytes   uint64 `json:"initial_download_bytes"`
	MinimumHostMemoryBytes uint64 `json:"minimum_host_memory_bytes"`
}

// Requirements has no filesystem or process effects. Bundled Lima and later
// provider images are excluded from the initial runtime download.
func (runtime *Runtime) Requirements() RuntimeRequirements {
	_, download := installerArtifacts()
	memory := uint64(runtime.options.Resources.MemoryGiB) * (1 << 30)
	return RuntimeRequirements{
		CPUs: runtime.options.Resources.CPUs, MemoryBytes: memory,
		DiskBytes:            uint64(runtime.options.Resources.DiskGiB) * (1 << 30),
		InitialDownloadBytes: uint64(download), MinimumHostMemoryBytes: 2 * memory,
	}
}

func checkHostMemory(memory uint64, requirements RuntimeRequirements) error {
	if memory < requirements.MinimumHostMemoryBytes {
		return fmt.Errorf("local runtime requires at least twice its VM memory in physical host memory")
	}
	return nil
}
