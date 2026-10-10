package targetruntime

import "testing"

func TestDesktopAgentBridgeNumericListenerBindEvidence(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name, raw string
		ok        bool
	}{
		{"ipv4", "p812\nf21\nn127.0.0.1:25907\n", true},
		{"ipv6", "p812\nf21\nn[::1]:25907\n", true},
		{"dual stack", "p812\nf21\nn127.0.0.1:25907\nf22\nn[::1]:25907\n", true},
		{"same PID repeated", "p812\nf21\nn127.0.0.1:25907\np812\nf22\nn[::1]:25907\n", true},
		{"wildcard", "p812\nf21\nn*:25907\n", false},
		{"ipv4 all hosts", "p812\nf21\nn0.0.0.0:25907\n", false},
		{"ipv6 all hosts", "p812\nf21\nn[::]:25907\n", false},
		{"lan override", "p812\nf21\nn192.168.0.54:25907\n", false},
		{"mixed hosts", "p812\nf21\nn127.0.0.1:25907\nf22\nn192.168.0.54:25907\n", false},
		{"hostname", "p812\nf21\nnlocalhost:25907\n", false},
		{"foreign port", "p812\nf21\nn127.0.0.1:25908\n", false},
		{"multiple PIDs", "p812\nf21\nn127.0.0.1:25907\np900\nf22\nn[::1]:25907\n", false},
		{"no name", "p812\nf21\n", false},
		{"missing name in second descriptor", "p812\nf21\nn127.0.0.1:25907\nf22\n", false},
		{"unknown field", "p812\nf21\nxloopback\n", false},
		{"malformed PID", "pnotpid\nf21\nn127.0.0.1:25907\n", false},
		{"malformed descriptor", "p812\nfunknown\nn127.0.0.1:25907\n", false},
		{"empty", "", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			pid, err := ListenerPID([]byte(test.raw), "25907")
			if test.ok {
				if err != nil || pid != "812" {
					t.Fatalf("owned loopback refused %s %v", pid, err)
				}
			} else if err == nil || pid != "" {
				t.Fatal("unproven actual bind admitted")
			}
		})
	}
}
