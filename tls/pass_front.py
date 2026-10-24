#!/usr/bin/env python3
# TLS-terminating CWMP front for the JMSD200A STB -> GenieACS.
# Serves a cert CHAIN that includes RILROOTCA (acs_chain.pem) so the client's app-level
# public-key pin (HttpClient.pinningPublicKey) matches and the device advances past InformResponse.
# The device uses SEPARATE TCP connections for Inform / empty-POST / RPC-response, tied by the
# GenieACS `session` cookie -> we route by cookie to the SAME upstream GenieACS connection so
# GenieACS sees one coherent session. Logs full request/response (gunzipped).
import ssl, socket, threading, http.client, datetime, gzip, re, os, argparse

_DIR = os.path.dirname(os.path.abspath(__file__))

# --- CLI / env config ---
# Ports: default both 8443 and 9443.  Override with --ports or TLS_PORTS env.
#   python3 pass_front.py                      # listen on 8443,9443
#   python3 pass_front.py --ports 8443         # single port
#   python3 pass_front.py --ports 8443,9443,443  # custom list
#   TLS_PORTS=8443 python3 pass_front.py       # env override
_parser = argparse.ArgumentParser(description="TLS-terminating CWMP front for JioSTB -> GenieACS")
_parser.add_argument("--ports", type=str, default=None, help="Comma-separated listen ports (default: 8443,9443)")
_parser.add_argument("--cert", type=str, default=None, help="TLS cert chain path")
_parser.add_argument("--genie-host", type=str, default=None, help="GenieACS CWMP host")
_parser.add_argument("--genie-port", type=int, default=None, help="GenieACS CWMP port")
_parser.add_argument("--log", type=str, default=None, help="Log file path")
_args = _parser.parse_args()

_ports_str = _args.ports or os.environ.get("TLS_PORTS", "8443,9443")
PORTS = [int(p.strip()) for p in _ports_str.split(",") if p.strip()]
BIND_ADDR = "0.0.0.0"
CERT = _args.cert or os.environ.get("TLS_CERT", os.path.join(_DIR, "acs_chain.pem"))
GENIE = (_args.genie_host or os.environ.get("GENIE_HOST", "127.0.0.1"),
         _args.genie_port or int(os.environ.get("GENIE_PORT", 7547)))
LOG = _args.log or os.environ.get("TLS_LOG", os.path.join(_DIR, "pass_front.log"))

# --- JioTR069Client network-check spoof: gates the CWMP flow. Serve a valid encrypted Network. ---
import base64
try:
    from Crypto.Cipher import AES
    _HAVE_AES=True
except Exception:
    _HAVE_AES=False
NETCHECK_KEY=b"6bm2I7pTdBaeABX0"; NETTYPE="FTTH"   # fleet-wide prod secretKey; FTTH = JioFiber STB
def _forge_netcheck():
    iv=os.urandom(16); data=NETTYPE.encode(); pl=16-(len(data)%16); data+=bytes([pl])*pl
    ct=AES.new(NETCHECK_KEY,AES.MODE_CBC,iv).encrypt(data)
    return base64.b64encode(iv+ct).decode()
loglock=threading.Lock()
def log(m):
    with loglock:
        with open(LOG,"a") as f: f.write(f"[{datetime.datetime.now().strftime('%H:%M:%S.%f')[:-3]}] {m}\n")

ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT)
try: ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
except Exception: pass

SESSIONS={}          # cookie-value -> {"conn":HTTPConnection,"lock":Lock}
REG=threading.Lock()
def sess_cookie(val):
    if not val: return None
    m=re.search(r'session=([0-9a-fA-F]+)', val); return m.group(1) if m else None

def dec(b, enc):
    if enc and "gzip" in enc.lower():
        try: return gzip.decompress(b)
        except Exception: return b
    return b

def read_http(rf):
    line=rf.readline()
    if not line: return None
    reqline=line.decode("latin1").rstrip("\r\n"); headers={}
    while True:
        h=rf.readline()
        if not h or h in (b"\r\n",b"\n"): break
        k,_,v=h.decode("latin1").partition(":"); headers[k.strip().lower()]=v.strip()
    body=b""
    if "content-length" in headers:
        n=int(headers["content-length"]); body=rf.read(n) if n else b""
    return reqline, headers, body

def handle(conn, addr):
    try: s=ctx.wrap_socket(conn, server_side=True)
    except Exception as e: log(f"TLS fail {addr}: {e}"); conn.close(); return
    rf=s.makefile("rb"); cid=f"{addr[0]}:{addr[1]}"
    try:
        while True:
            req=read_http(rf)
            if req is None: break
            reqline, headers, body = req
            method=reqline.split(" ",1)[0] if reqline else ""
            rb=dec(body, headers.get("content-encoding"))
            ck=sess_cookie(headers.get("cookie"))
            log(f"{cid} >>> {reqline} clen={len(body)} {'[EMPTY POST]' if len(body)==0 else ''} cookie={ck or '-'}")
            if rb and len(rb)<1600: log(f"{cid} >>> body: {rb.decode('latin1','replace')}")
            # netcheck short-circuit: /common/v1/network/check gates CWMP -> serve valid Network, don't proxy
            _parts=reqline.split(" "); _path=_parts[1] if len(_parts)>1 else ""
            if "network/check" in _path and _HAVE_AES:
                _nb=('{"Network":"%s"}' % _forge_netcheck()).encode()
                s.sendall(("\r\n".join(["HTTP/1.1 200 OK","Content-Type: application/json",
                    "Content-Length: %d"%len(_nb),"Connection: keep-alive"])+"\r\n\r\n").encode()+_nb)
                log(f"{cid} <<< 200 netcheck-spoof Network={NETTYPE}")
                continue
            # pick/create the upstream GenieACS connection sticky to this session cookie
            with REG:
                sess = SESSIONS.get(ck) if ck else None
                if sess is None:
                    sess = {"conn": http.client.HTTPConnection(*GENIE, timeout=40), "lock": threading.Lock()}
            fh={k:v for k,v in headers.items() if k not in ("host","connection")}
            with sess["lock"]:
                try:
                    sess["conn"].request(method, "/", body=body, headers=fh)
                    r=sess["conn"].getresponse(); rbody=r.read()
                except Exception as e:
                    # stale upstream conn -> retry once fresh
                    try: sess["conn"].close()
                    except Exception: pass
                    sess["conn"]=http.client.HTTPConnection(*GENIE, timeout=40)
                    try:
                        sess["conn"].request(method,"/",body=body,headers=fh); r=sess["conn"].getresponse(); rbody=r.read()
                    except Exception as e2:
                        log(f"{cid} genie err: {e2}"); break
                setck=sess_cookie(r.getheader("set-cookie"))
            respdec=dec(rbody, r.getheader("content-encoding"))
            hdrs="; ".join(f"{k}:{v}" for k,v in r.getheaders())
            log(f"{cid} <<< {r.status} {r.reason} len={len(rbody)} setcookie={setck or '-'} hdrs=[{hdrs}]")
            if respdec: log(f"{cid} <<< body: {respdec[:1600].decode('latin1','replace')}")
            # register/retire session mapping
            with REG:
                if setck: SESSIONS[setck]=sess
                if r.status==204 and ck:
                    SESSIONS.pop(ck, None)
                    try: sess["conn"].close()
                    except Exception: pass
            out=[f"HTTP/1.1 {r.status} {r.reason}"]
            for k,v in r.getheaders():
                if k.lower()=="transfer-encoding": continue
                out.append(f"{k}: {v}")
            if not any(o.lower().startswith("content-length") for o in out):
                out.append(f"Content-Length: {len(rbody)}")
            out.append("Connection: keep-alive")
            s.sendall(("\r\n".join(out)+"\r\n\r\n").encode()+rbody)
    except Exception as e:
        log(f"{cid} handle err: {e}")
    finally:
        try: s.close()
        except Exception: pass

def serve_port(port):
    srv=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    srv.bind((BIND_ADDR, port)); srv.listen(64)
    log(f"### listening on {BIND_ADDR}:{port} -> GenieACS {GENIE[0]}:{GENIE[1]} ###")
    while True:
        c,a=srv.accept(); threading.Thread(target=handle,args=(c,a),daemon=True).start()

ports_str = ",".join(str(p) for p in PORTS)
print(f"pass_front: :{ports_str} -> GenieACS {GENIE[0]}:{GENIE[1]}  cert={CERT}")
log(f"### pass_front (cookie-sticky, RILROOTCA chain) ports=[{ports_str}] -> GenieACS {GENIE} ###")

for port in PORTS[:-1]:
    threading.Thread(target=serve_port, args=(port,), daemon=True).start()
serve_port(PORTS[-1])
