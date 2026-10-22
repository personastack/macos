// Explicit native consumer acceptance only. No API or private storage dependency.
import http from 'node:http';
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  response.setHeader('Cache-Control', 'private, no-store');
  if (url.pathname === '/stream') {
    response.setHeader('Content-Type', 'text/html');
    response.setHeader('Set-Cookie', 'native_download_fixture=authorized; HttpOnly; SameSite=Strict; Path=/');
    response.end('<!doctype html><title>Download fixture</title><p id="stream">Stream remains loaded</p><a id="file" download>Download</a>');
    return;
  }
  if (url.pathname === '/login') {
    response.writeHead(200, { 'Content-Type': 'text/html' }).end('<p>Sign in</p>');
    return;
  }
  if (url.pathname !== '/user/stacks/assets/download' || !request.headers.cookie?.includes('native_download_fixture=authorized')) {
    response.writeHead(403).end('Denied');
    return;
  }
  if (url.searchParams.get('result') === 'redirect') {
    response.writeHead(302, { Location: '/login' }).end();
    return;
  }
  if (url.searchParams.get('result') === 'denied') {
    response.writeHead(403, { 'Content-Disposition': 'attachment; filename="denied.txt"' }).end('Denied');
    return;
  }
  if (url.searchParams.get('result') === 'error') {
    response.writeHead(503, { 'Content-Disposition': 'attachment; filename="error.txt"' }).end('Unavailable');
    return;
  }
  const filename = url.searchParams.get('filename');
  if (!/^native-stack-download-[a-f0-9-]+\.txt$/.test(filename ?? '')) {
    response.writeHead(400).end();
    return;
  }
  response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': `attachment; filename="${filename}"` });
  response.end('private stack bytes\n');
});
server.listen(0, '127.0.0.1', () => console.log(`http://127.0.0.1:${server.address().port}`));
