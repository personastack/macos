package localcluster

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"
)

const downloadBudget = 10 * time.Minute

func artifactClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{Proxy: nil, ForceAttemptHTTP2: true, TLSHandshakeTimeout: 15 * time.Second, ResponseHeaderTimeout: 30 * time.Second,
			MaxConnsPerHost: 2, MaxIdleConns: 4, MaxIdleConnsPerHost: 1, IdleConnTimeout: 30 * time.Second, MaxResponseHeaderBytes: 1 << 20},
		CheckRedirect: func(request *http.Request, previous []*http.Request) error {
			if len(previous) >= 4 {
				return fmt.Errorf("artifact redirect limit exceeded")
			}
			return validateDownloadURL(request.URL)
		},
	}
}

func validateDownloadURL(location *url.URL) error {
	if location.Scheme != "https" || location.User != nil || location.Fragment != "" {
		return fmt.Errorf("unsupported artifact transport")
	}
	switch location.Host {
	case "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "cloud-images.ubuntu.com":
		return nil
	default:
		return fmt.Errorf("unsupported artifact download origin")
	}
}

func acquireArtifact(ctx context.Context, tree *ownedTree, client *http.Client, artifact Artifact) error {
	name := "artifacts/" + string(artifact.Component)
	existing, err := tree.open(name, os.O_RDONLY)
	if err == nil {
		err = verifyArtifact(artifact, contextReader{ctx, existing})
		existing.Close()
		if err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return runtimeCustodyFailure(ctx, fmt.Errorf("inspect cached artifact: %w", err))
	}
	ctx, cancel := context.WithTimeout(ctx, downloadBudget)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, artifact.URL, nil)
	if err != nil {
		return fmt.Errorf("prepare pinned artifact: %w", err)
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("fetch pinned artifact: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || (response.ContentLength >= 0 && response.ContentLength != artifact.Size) {
		return fmt.Errorf("pinned artifact response did not match")
	}
	file, err := tree.open(name, os.O_CREATE|os.O_RDWR)
	if err != nil {
		return runtimeCustodyFailure(ctx, err)
	}
	defer file.Close()
	err = file.Truncate(0)
	if err != nil {
		return runtimeCustodyFailure(ctx, fmt.Errorf("prepare owned artifact file: %w", err))
	}
	reader := io.TeeReader(contextReader{ctx, response.Body}, file)
	err = verifyArtifact(artifact, reader)
	if err != nil {
		return runtimeFailure(ctx, ReasonIntegrityFailed, fmt.Errorf("verify downloaded artifact: %w", err))
	}
	return nil
}

type contextReader struct {
	ctx   context.Context
	input io.Reader
}

func (reader contextReader) Read(data []byte) (int, error) {
	if reader.ctx.Err() != nil {
		return 0, reader.ctx.Err()
	}
	return reader.input.Read(data)
}
