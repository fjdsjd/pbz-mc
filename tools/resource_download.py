"""Verified, resumable resource downloads with mirror/origin failover."""
from __future__ import annotations

import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

_lock = threading.Lock()
_unavailable = set()
_file_locks = {}


def digest(path, algorithm='sha256'):
    h = hashlib.new(algorithm)
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def resource_urls(url):
    """Only rewrite approved, immutable upstream paths; never accept a user URL."""
    for prefix in ('https://piston-data.mojang.com/', 'https://piston-meta.mojang.com/'):
        if url.startswith(prefix):
            mirrors = ['https://bmclapi2.bangbang93.com/' + url[len(prefix):]]
            break
    else:
        prefix = 'https://resources.download.minecraft.net/'
        bedrock = 'https://raw.githubusercontent.com/Mojang/bedrock-samples/'
        if url.startswith(prefix):
            mirrors = ['https://bmclapi2.bangbang93.com/assets/' + url[len(prefix):]]
        elif url.startswith(bedrock):
            path = url[len(bedrock):]
            if not re.match(r'^[0-9a-f]{40}/', path):
                raise ValueError('Bedrock downloads require a pinned commit')
            mirrors = ['https://' + host + '/gh/Mojang/bedrock-samples@' + path
                       for host in ('gcore.jsdelivr.net', 'cdn.jsdelivr.net')]
        else:
            raise ValueError('Unapproved resource URL')
    mode = os.environ.get('PBZMC_DOWNLOAD_SOURCE', 'auto')
    if mode not in ('auto', 'official'):
        raise ValueError('PBZMC_DOWNLOAD_SOURCE must be auto or official')
    return [url] if mode == 'official' else mirrors + [url]


class _HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != 'https':
            raise ValueError('Insecure download redirect rejected')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open(request, timeout):
    handlers = [_HTTPSRedirect()]
    if os.environ.get('PBZMC_DOWNLOAD_PROXY') == 'direct':
        handlers.append(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener(*handlers).open(request, timeout=timeout)


def _event(log, row):
    if log:
        with _lock:
            log.parent.mkdir(parents=True, exist_ok=True)
            with log.open('a', encoding='utf-8') as stream:
                stream.write(json.dumps(row, ensure_ascii=True) + '\n')


def download(urls, target, expected, algorithm='sha256', *, log=None,
             opener=None, timeout=20, attempts=2):
    # Different Minecraft versions can reference the same content hash.
    # Share the transfer as well as the final cache file across worker threads.
    with _lock:
        file_lock = _file_locks.setdefault(str(Path(target).resolve()), threading.Lock())
    with file_lock:
        return _download(urls, target, expected, algorithm, log=log,
                         opener=opener, timeout=timeout, attempts=attempts)


def _download(urls, target, expected, algorithm='sha256', *, log=None,
              opener=None, timeout=20, attempts=2):
    """Commit only a complete pinned file. Keep partial bytes across launches.

    The optional opener is a test seam, not an installation URL override.
    """
    target = Path(target)
    if algorithm not in ('sha1', 'sha256') or not re.fullmatch(
            '[0-9a-f]{40}' if algorithm == 'sha1' else '[0-9a-f]{64}', expected):
        raise ValueError('Invalid pinned digest')
    if not urls or any(urllib.parse.urlsplit(u).scheme != 'https' for u in urls):
        raise ValueError('HTTPS download required')
    if target.is_file() and digest(target, algorithm) == expected:
        _event(log, dict(file=target.name, status='cached', digest=expected))
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_name(target.name + '.download')
    meta = target.with_name(target.name + '.download.json')
    identity = dict(algorithm=algorithm, digest=expected)
    try:
        compatible = json.loads(meta.read_text('utf-8')) == identity
    except (OSError, ValueError):
        compatible = False
    if not compatible:
        temp.unlink(missing_ok=True)
    meta.write_text(json.dumps(identity), encoding='utf-8')
    if temp.is_file() and digest(temp, algorithm) == expected:
        os.replace(temp, target)
        meta.unlink(missing_ok=True)
        _event(log, dict(file=target.name, status='resumed-complete', digest=expected))
        return
    errors = []
    for attempt in range(attempts):
        with _lock:
            ordered = sorted(urls, key=lambda u: urllib.parse.urlsplit(u).netloc in _unavailable)
        for url in ordered:
            host = urllib.parse.urlsplit(url).netloc
            offset = temp.stat().st_size if temp.exists() else 0
            headers = {'User-Agent': 'PBZMC/0.1 resource-downloader', 'Accept-Encoding': 'identity'}
            if offset:
                headers['Range'] = f'bytes={offset}-'
            try:
                request = urllib.request.Request(url, headers=headers)
                with (opener or _open)(request, timeout) as response:
                    if response.headers.get('Content-Encoding', 'identity') != 'identity':
                        raise ValueError('Unexpected transfer encoding')
                    status = response.status
                    total = None
                    if status == 206:
                        match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                        if not match or int(match[1]) != offset or int(match[2]) < offset or int(match[2]) >= int(match[3]):
                            raise ValueError('Invalid resume range')
                        total = int(match[3])
                    elif status == 200:
                        offset = 0  # Range ignored: replace partial, never append.
                        if response.headers.get('Content-Length'):
                            total = int(response.headers['Content-Length'])
                    else:
                        raise ValueError('Unexpected HTTP status ' + str(status))
                    started = time.monotonic()
                    with temp.open('ab' if offset else 'wb') as output:
                        while block := response.read(256 * 1024):
                            output.write(block)
                            if time.monotonic() - started > 300:
                                raise TimeoutError('Transfer stalled; retrying with retained partial file')
                    if total is not None and temp.stat().st_size != total:
                        raise OSError('Incomplete response')
                    if digest(temp, algorithm) != expected:
                        temp.unlink(missing_ok=True)
                        raise ValueError('Checksum mismatch')
                    os.replace(temp, target)
                    meta.unlink(missing_ok=True)
                    _event(log, dict(file=target.name, status='verified', source=url,
                                    final_host=urllib.parse.urlsplit(response.geturl()).netloc,
                                    resumed_bytes=offset, digest=expected, bytes=target.stat().st_size))
                    return
            except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException) as error:
                # Never print signed CDN redirects or proxy credentials.
                code = getattr(error, 'code', None)
                reason = f'HTTP {code}' if code else type(error).__name__
                if code == 416:
                    temp.unlink(missing_ok=True)
                if isinstance(error, urllib.error.URLError) and (code is None or code >= 500):
                    with _lock:
                        _unavailable.add(host)
                errors.append(host + ': ' + reason)
                _event(log, dict(file=target.name, status='retry', host=host, reason=reason, attempt=attempt + 1))
                print(f'Download retry: {target.name} via {host} ({reason})', flush=True)
    raise RuntimeError('Download failed: ' + target.name + '; ' + '; '.join(dict.fromkeys(errors)) +
                       '. Keep the cache and run the launcher again.')


def fetch(url, target, expected, algorithm='sha256'):
    log = os.environ.get('PBZMC_DOWNLOAD_LOG')
    return download(resource_urls(url), target, expected, algorithm,
                    log=Path(log) if log else None)
