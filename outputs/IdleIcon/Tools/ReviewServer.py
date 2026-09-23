from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parent.parent.parent
NEW_NOTES=ROOT/'逐项批注记录.json'
OLD_NOTES=ROOT/'0.7审阅批注.json'
NOTES=NEW_NOTES if NEW_NOTES.exists() or not OLD_NOTES.exists() else OLD_NOTES
class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs):super().__init__(*args,directory=str(ROOT),**kwargs)
    def do_GET(self):
        if self.path == '/api/comments':
            body=NOTES.read_bytes() if NOTES.exists() else b'{}'
            self.send_response(200);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        else:super().do_GET()
    def do_POST(self):
        if self.path!='/api/comments':self.send_error(404);return
        size=int(self.headers.get('Content-Length','0'))
        if size>200000 or size<0:self.send_error(413);return
        try:
            obj=json.loads(self.rfile.read(size))
            if not isinstance(obj,dict) or any(not isinstance(k,str) or not isinstance(v,str) for k,v in obj.items()):raise ValueError()
            data=json.dumps(obj,ensure_ascii=False,indent=2).encode()
            tmp=NOTES.with_suffix('.tmp');tmp.write_bytes(data);tmp.replace(NOTES)
        except Exception:self.send_error(400);return
        self.send_response(204);self.end_headers()
ThreadingHTTPServer(('127.0.0.1',8765),Handler).serve_forever()
