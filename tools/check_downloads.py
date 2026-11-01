"""Exercise both production downloaders against real local HTTP fault fixtures.

Only transport creation is redirected to loopback; production URL policy, hash
checks, partial files, reads, retry and commit logic run unchanged.
"""
from __future__ import annotations

import hashlib
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

import resource_download as net

ROOT = Path(__file__).resolve().parents[1]
DATA = bytes(range(256)) * 4096
SHA = hashlib.sha256(DATA).hexdigest()
REQUESTS = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        name = self.path.strip('/')
        offset = int(self.headers.get('Range', 'bytes=0-').split('=')[1].split('-')[0])
        REQUESTS.append((name, offset))
        if name == 'stall':
            time.sleep(2.5)
        if name == 'slow':
            time.sleep(0.1)
        if name in ('fail', 'missing', 'range-end'):
            self.send_error({'fail': 503, 'missing': 404, 'range-end': 416}[name])
            return
        data = DATA if name != 'corrupt' else b'X' * len(DATA)
        if name in ('ok', 'bad-range') and offset:
            self.send_response(206)
            start = offset if name == 'ok' else offset + 1
            self.send_header('Content-Range', f'bytes {start}-{len(data)-1}/{len(data)}')
            data = data[offset:]
        else:
            self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if name == 'truncated':
            data = data[:512 * 1024]
            self.close_connection = True
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = Path(tempfile.mkdtemp(prefix='pbzmc-download-check-')).resolve()
    base = f'http://127.0.0.1:{server.server_port}'

    def opener(request, timeout):
        path = urllib.parse.urlsplit(request.full_url).path
        local = urllib.request.Request(base + path, headers=dict(request.header_items()))
        return urllib.request.build_opener(urllib.request.ProxyHandler({})).open(local, timeout=timeout)

    script = root/'download.ps1'
    script.write_text("""param([string]$SpecFile,[string]$Destination)
$ErrorActionPreference='Stop'
. HELPER
# Local fault server is the only substituted dependency.
function Open-PBZDownload([string]$Url,[long]$Offset) {
    $uri=[Uri]$Url;$request=[Net.HttpWebRequest]::Create(BASE+$uri.AbsolutePath)
    $request.Proxy=$null;$request.Timeout=2000;$request.ReadWriteTimeout=2000
    if ($Offset -gt 0) { $request.AddRange($Offset) }
    return $request.GetResponse()
}
$spec=Get-Content -LiteralPath $SpecFile -Raw|ConvertFrom-Json
try { Download-Pinned $spec $Destination } catch { Write-Host $_.Exception.Message;exit 1 }
""".replace('HELPER', ps_quote(ROOT/'distribution/Download-PBZMC.ps1'))
        .replace('BASE', ps_quote(base)), encoding='utf-8')

    def execute(engine, name, routes, initial=None, partial=None, stale=False, ok=True):
        directory=root/engine/name;directory.mkdir(parents=True)
        dest=directory/'resource.bin'
        if initial is not None:
            dest.write_bytes(initial)
        if partial is not None:
            dest.with_name(dest.name+'.download').write_bytes(partial)
            if engine=='python':
                dest.with_name(dest.name+'.download.json').write_text(json.dumps(
                    dict(algorithm='sha256',digest='0'*64 if stale else SHA)))
            else:
                dest.with_name(dest.name+'.download.sha256').write_text('0'*64 if stale else SHA)
        urls=['https://www.python.org/'+route for route in routes]
        REQUESTS.clear();net._unavailable.clear()
        if engine=='python':
            try:
                net.download(urls,dest,SHA,opener=opener,timeout=2)
                succeeded=True
            except (RuntimeError,ValueError):
                succeeded=False
        else:
            spec=directory/'spec.json'
            spec.write_text(json.dumps(dict(url=urls[-1],mirrors=urls[:-1],filename=dest.name,sha256=SHA)))
            result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',
                                   str(script),str(spec),str(dest)],capture_output=True,text=True,errors='replace')
            succeeded=result.returncode==0
        assert succeeded==ok,(engine,name,'unexpected result',result.stdout if engine=='powershell' else '')
        if ok:
            assert dest.read_bytes()==DATA,(engine,name,'wrong committed bytes')
            assert not dest.with_name(dest.name+'.download').exists(),(engine,name,'unremoved partial')
        elif initial is not None:
            assert dest.read_bytes()==initial,(engine,name,'damaged previous file')
        else:
            assert not dest.exists(),(engine,name,'committed a failed download')
        return list(REQUESTS)

    count=0
    try:
        engines=['python']+(['powershell']if shutil.which('powershell.exe')else [])
        for engine in engines:
            execute(engine,'fresh',['ok']);count+=1
            assert not execute(engine,'cached',['fail'],initial=DATA);count+=1
            execute(engine,'fallback',['fail','ok']);count+=1
            execute(engine,'timeout-fallback',['stall','ok']);count+=1
            assert execute(engine,'corrupt',['corrupt','ok'])[-1]==('ok',0);count+=1
            events=execute(engine,'drop-resume',['truncated','ok'])
            assert any(name=='ok' and offset>0 for name,offset in events),events;count+=1
            assert execute(engine,'resume',['ok'],partial=DATA[:1000])==[('ok',1000)];count+=1
            assert not execute(engine,'complete-partial',['fail'],partial=DATA);count+=1
            execute(engine,'range-ignored',['ignore'],partial=DATA[:1000]);count+=1
            execute(engine,'wrong-range',['bad-range','ok'],partial=DATA[:1000]);count+=1
            assert execute(engine,'range-416',['range-end','ok'],partial=DATA[:1000])[-1]==('ok',0);count+=1
            assert execute(engine,'stale',['ok'],partial=b'old version',stale=True)==[('ok',0)];count+=1
            execute(engine,'failed-keeps-old',['corrupt'],initial=b'keep me',ok=False);count+=1
            execute(engine,'all-unavailable',['missing','fail'],ok=False);count+=1
        # Actual URL-policy entry points, without the local transport seam.
        try:
            net.resource_urls('https://unapproved.example/file')
            raise AssertionError('unapproved source accepted')
        except ValueError:
            count+=1
        try:
            net._HTTPSRedirect().redirect_request(None,None,302,'',{},'http://insecure.example/file')
            raise AssertionError('HTTPS downgrade accepted')
        except ValueError:
            count+=1
        if 'powershell' in engines:
            command='. '+ps_quote(ROOT/'distribution/Download-PBZMC.ps1')+";try { Open-PBZDownload 'http://insecure.example/' 0;exit 1 } catch { exit 0 }"
            subprocess.run(['powershell.exe','-NoProfile','-Command',command],check=True);count+=1
        REQUESTS.clear()
        with ThreadPoolExecutor(max_workers=2) as pool:
            jobs=[pool.submit(net.download,['https://www.python.org/slow'],root/'shared.bin',SHA,opener=opener)for _ in range(2)]
            for job in jobs:job.result()
        assert REQUESTS==[('slow',0)],'concurrent workers downloaded the same resource twice'
        assert (root/'shared.bin').read_bytes()==DATA;count+=1
        print(f'PASS: {count} download checks ({", ".join(engines)}); fixture {root}')
    finally:
        server.shutdown();server.server_close()


if __name__=='__main__':
    main()
