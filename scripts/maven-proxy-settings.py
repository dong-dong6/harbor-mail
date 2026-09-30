#!/usr/bin/env python3
"""Use the current managed proxy for Maven. No credentials printed or shipped."""
import os
import pathlib
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

proxy = urllib.parse.urlparse(os.getenv('HTTPS_PROXY') or os.getenv('https_proxy',''))
if not proxy.hostname:
    raise SystemExit('HTTPS_PROXY is not a valid proxy URL')
root = ET.Element('settings')
proxies = ET.SubElement(root,'proxies')
p = ET.SubElement(proxies,'proxy')
fields = {'id':'managed-runtime','active':'true','protocol':'http',
          'host':proxy.hostname,'port':str(proxy.port or 80),
          'nonProxyHosts':'localhost|127.*|[::1]'}
if proxy.username: fields['username']=urllib.parse.unquote(proxy.username)
if proxy.password: fields['password']=urllib.parse.unquote(proxy.password)
for key,value in fields.items(): ET.SubElement(p,key).text=value
directory=pathlib.Path(sys.argv[1]);directory.mkdir(parents=True,exist_ok=True)
fd,path=tempfile.mkstemp(prefix='maven-runtime-',suffix='.xml',dir=directory)
os.fchmod(fd,0o600)
with os.fdopen(fd,'wb') as f: f.write(ET.tostring(root,encoding='utf-8',xml_declaration=True))
print(path)
