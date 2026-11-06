"""极简 requests 替身 —— 只用标准库 urllib，给微云上传脚本用。

为什么存在：这台机器 pip 连不上 PyPI（镜像也超时），装不了 requests。
而 upload_to_weiyun.py 通篇只用到 requests.post(url, headers=, json=, timeout=)
这一种用法（第 242 行），其余逻辑都是纯标准库 + 自带的 SHA1 实现。

用法：把这个目录塞进 PYTHONPATH，import requests 就会落到这里。
    set PYTHONPATH=D:\Program Files\Blockly\pkg\工具\_pyshim
"""
import json as _json
import os
import urllib.error
import urllib.request


def _proxy_headers(url):
    """从 CODEBUDDY_MCP_CONFIG 里捞出这个 MCP 端点要求的头。

    本地代理（127.0.0.1:49951）除了 Authorization 还要 X-WorkBuddy-MCP-Context，
    脚本自己只发 Authorization，缺一个就 401。这里按 url 精确匹配补全。
    """
    cfg = os.environ.get('CODEBUDDY_MCP_CONFIG')
    if not cfg:
        return {}
    try:
        j = _json.loads(cfg)
        for srv in (j.get('mcpServers') or {}).values():
            if srv.get('url') == url:
                return dict(srv.get('headers') or {})
    except Exception:
        pass
    return {}


class _Resp:
    """装成 requests.Response 的最小接口：status_code / text / content / json()。"""

    def __init__(self, code, body):
        self.status_code = code
        self.text = body
        self.content = body.encode('utf-8', 'replace')

    def json(self):
        return _json.loads(self.text)

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError('HTTP %d: %s' % (self.status_code, self.text[:400]))

    def __repr__(self):
        return '<Resp %d %d bytes>' % (self.status_code, len(self.text or ''))


def _do(method, url, headers, body, timeout):
    hdrs = dict(headers or {})
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return _Resp(getattr(r, 'status', 200), r.read().decode('utf-8', 'replace'))
    except urllib.error.HTTPError as e:
        return _Resp(e.code, e.read().decode('utf-8', 'replace'))


def post(url, headers=None, json=None, data=None, timeout=60, **kw):
    # 代理要求的头先垫底，脚本自己的头覆盖在上面（值通常一致）
    hdrs = _proxy_headers(url)
    hdrs.update(dict(headers or {}))
    body = None
    if json is not None:
        body = _json.dumps(json, ensure_ascii=False).encode('utf-8')
        hdrs.setdefault('Content-Type', 'application/json; charset=utf-8')
    elif data is not None:
        body = data if isinstance(data, bytes) else str(data).encode('utf-8')
    return _do('POST', url, hdrs, body, timeout)


def get(url, headers=None, timeout=60, **kw):
    hdrs = _proxy_headers(url)
    hdrs.update(dict(headers or {}))
    return _do('GET', url, hdrs, None, timeout)
